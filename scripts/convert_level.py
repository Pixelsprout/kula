#!/usr/bin/env python3
"""Convert a Roll Away Hiro level from the player's own disc image to a Kula level file.

Usage:
    python3 scripts/convert_level.py DISC.bin LEVEL [--list] [-o OUT]

DISC.bin is a one-track MODE2/2352 image. LEVEL counts from 1. Without -o the
level text goes to stdout. --list prints every block type, record type and
object the level uses, with counts, and converts nothing.

Formats: wiki.kula.quest/archives/pak/ and wiki.kula.quest/levels/level/.
Code references are to github.com/dezgeg/kula-world-decomp.
"""

import argparse
import struct
import sys
import zlib
from collections import Counter

SECTOR_SIZE = 2352
# Sync (12), header (4) and the Mode 2 Form 1 subheader (8) come before the user data.
USER_DATA_OFFSET = 24
USER_DATA_SIZE = 2048

PAK_PATH = ["HIRO", "HIRO.PAK"]

SIZE = 34
GRID_BYTES = SIZE * SIZE * SIZE * 2
RECORD_COUNT_OFFSET = 0x13314
RECORDS_OFFSET = 0x13316
RECORD_SIZE = 256
FACE_SLOT_OFFSET = 0x02
FACE_SLOT_SIZE = 32
POSITION_OFFSET = 0xFA

CELL_NAMES = {-1: "empty", 0: "plain", 1: "fire", 2: "ice", 3: "invisible", 4: "acid"}

# Record types 0 to 4 are object blocks: a block with six object slots, one per face.
RECORD_NAMES = {
    0: "object block (plain)",
    1: "object block (fire)",
    2: "object block (ice)",
    3: "object block (invisible)",
    4: "object block (acid)",
    5: "moving block",
    6: "crumbling block",
    7: "flashing block",
    8: "laser block",
    9: "level flags",
    666: "level settings",
}

# include/common.h, ObjectType. Ids 7 and 8 mean the exit and the timer pause in a face slot.
OBJECT_NAMES = {
    0x01: "fire patch",
    0x02: "ice patch",
    0x03: "invisible patch",
    0x04: "acid patch",
    0x05: "transporter",
    0x06: "crumbling face",
    0x07: "exit",
    0x08: "timer pause",
    0x09: "button",
    0x0A: "bounce pad",
    0x0B: "moving spike",
    0x0C: "spike",
    0x1A: "hidden exit",
    0x1B: "fruit bowl",
    0x1C: "arrow",
    0x1D: "player spawn (paused)",
    0x1E: "player spawn",
    0x1F: "key",
    0x20: "lethargy pill",
    0x21: "bouncy pill",
    0x22: "invincibility pill",
    0x23: "hourglass",
    0x24: "gem",
    0x25: "coin",
    0x26: "sunglasses",
    0x27: "purple present",
    0x28: "red present",
    0x29: "yellow present",
    0x2A: "spike trap",
    0x2B: "apple",
    0x2C: "watermelon",
    0x2D: "pumpkin",
    0x2E: "banana",
    0x2F: "strawberry",
    0x30: "blue present",
    0x31: "green present",
    0x32: "slow star",
    0x33: "tire",
    0x34: "fast star",
    0x35: "capture pod",
    0x38: "captivator",
}

OBJ_EXIT = 0x07
OBJ_PLAYER_SPAWN_PAUSED = 0x1D
OBJ_PLAYER_SPAWN = 0x1E
OBJ_KEY = 0x1F

# Face slots and directions share one order (wiki "Directions", block_utils.c).
DIRECTIONS = [(0, 0, -1), (1, 0, 0), (0, 1, 0), (0, -1, 0), (-1, 0, 0), (0, 0, 1)]
DIRECTION_NAMES = ["Z-", "X+", "Y+", "Y-", "X-", "Z+"]

# SetPlayerRotation in level_update2.c: the start forward for each spawn face
# before the spawn's rotation turns it. gravityDir there is the ball's up.
SPAWN_FORWARD = {0: (0, 1, 0), 1: (0, 1, 0), 2: (0, 0, -1), 3: (0, 0, 1), 4: (0, 1, 0), 5: (0, 1, 0)}
SPAWN_RIGHT = {0: (-1, 0, 0), 1: (0, 0, -1), 2: (1, 0, 0), 3: (1, 0, 0), 4: (0, 0, 1), 5: (1, 0, 0)}


class Unsupported(Exception):
    pass


def to_kula(v):
    """Map an original vector or cell (x, y, z) to Kula's axes: (x, -z, y).

    Hiro levels lie on the original's Z- faces: the spawn there gets
    gravityDir, the ball's up, of -z (SetPlayerRotation). So original -z is
    Kula's +y. Original +y becomes Kula's +z, so a spawn with rotation 3 faces
    Kula's default -z. The map is a turn, not a mirror, and both games use
    right = forward x up.
    """
    x, y, z = v
    return (x, -z, y)


def read_iso_file(image, path):
    def sector(lba):
        image.seek(lba * SECTOR_SIZE + USER_DATA_OFFSET)
        return image.read(USER_DATA_SIZE)

    def extent(lba, size):
        data = b"".join(sector(lba + n) for n in range((size + USER_DATA_SIZE - 1) // USER_DATA_SIZE))
        return data[:size]

    pvd = sector(16)
    if pvd[0:6] != b"\x01CD001":
        raise ValueError("no ISO9660 primary volume descriptor at sector 16")
    lba, size = struct.unpack_from("<I", pvd, 158)[0], struct.unpack_from("<I", pvd, 166)[0]
    for i, part in enumerate(path):
        entries = dir_entries(extent(lba, size))
        if part not in entries:
            raise ValueError(f"{'/'.join(path[: i + 1])} is not on the disc")
        lba, size, is_dir = entries[part]
        if is_dir != (i < len(path) - 1):
            raise ValueError(f"{'/'.join(path[: i + 1])} has the wrong kind")
    return extent(lba, size)


def dir_entries(data):
    entries = {}
    i = 0
    while i < len(data):
        length = data[i]
        if length == 0:
            # Records do not cross a sector boundary, so a zero pads to the next sector.
            i = (i // USER_DATA_SIZE + 1) * USER_DATA_SIZE
            continue
        record = data[i : i + length]
        name = record[33 : 33 + record[32]]
        if name not in (b"\x00", b"\x01"):
            name = name.decode("ascii").split(";")[0]
            entries[name] = (struct.unpack_from("<I", record, 2)[0], struct.unpack_from("<I", record, 10)[0], bool(record[25] & 2))
        i += length
    return entries


def unpack_pak(data):
    count = struct.unpack_from("<I", data, 0)[0]
    files = []
    for n in range(count):
        offset, size = struct.unpack_from("<II", data, 4 + n * 8)
        name_offset = struct.unpack_from("<I", data, 4 + count * 8 + n * 4)[0]
        name = data[name_offset : data.index(b"\0", name_offset)].decode("ascii").strip()
        files.append((name, zlib.decompress(data[offset : offset + size])))
    return files


def level_data(files, number):
    name = f"LEVEL {number}"
    for file_name, data in files:
        if file_name == name:
            return data
    raise ValueError(f"{name} is not in the PAK")


def parse_level(data):
    """Return the cells, records and face objects of one level, in original axes."""
    cells = {}
    for x in range(SIZE):
        for y in range(SIZE):
            row = struct.unpack_from(f"<{SIZE}h", data, (x * SIZE * SIZE + y * SIZE) * 2)
            for z, value in enumerate(row):
                if value != -1:
                    cells[(x, y, z)] = value
    # The count leaves out the optional level settings record, which follows the counted records.
    count = struct.unpack_from("<h", data, RECORD_COUNT_OFFSET)[0]
    total = max(count, (len(data) - RECORDS_OFFSET) // RECORD_SIZE)
    records = []
    for n in range(total):
        base = RECORDS_OFFSET + n * RECORD_SIZE
        record_type = struct.unpack_from("<h", data, base)[0]
        position = struct.unpack_from("<3h", data, base + POSITION_OFFSET)
        objects = []
        if 0 <= record_type <= 4:
            for face in range(6):
                slot = base + FACE_SLOT_OFFSET + face * FACE_SLOT_SIZE
                object_id, rotation, variant = struct.unpack_from("<3h", data, slot)
                if object_id != 0:
                    objects.append((face, object_id, rotation, variant))
        records.append({"type": record_type, "position": position, "objects": objects, "raw": data[base : base + RECORD_SIZE]})
    return {"cells": cells, "records": records, "count": count}


def block_records(level):
    """Yield (cell, record) for each grid cell that points to a record."""
    for cell, value in sorted(level["cells"].items()):
        if value >= 5:
            index = value - 5
            if index >= level["count"]:
                raise Unsupported(f"cell {cell} points to record {index}, past the last record")
            yield cell, level["records"][index]


def features(level):
    cells = Counter("record" if v >= 5 else CELL_NAMES.get(v, f"cell value {v}") for v in level["cells"].values())
    records = Counter(RECORD_NAMES.get(r["type"], f"record type {r['type']}") for r in level["records"])
    objects = Counter()
    for r in level["records"]:
        for face, object_id, _, variant in r["objects"]:
            name = OBJECT_NAMES.get(object_id, f"object 0x{object_id:02X}")
            if variant > 0:
                name += f" (variant {variant})"
            objects[f"{name} on {DIRECTION_NAMES[face]} (Kula {axis_name(to_kula(DIRECTIONS[face]))})"] += 1
    return cells, records, objects


def format_list(number, level):
    cells, records, objects = features(level)
    lines = [f"Hiro level {number}"]
    for title, counts in [("cells", cells), ("records", records), ("objects", objects)]:
        lines.append(f"  {title}:")
        lines += [f"    {name}: {count}" for name, count in sorted(counts.items())]
    settings = [r for r in level["records"] if r["type"] == 666]
    for r in settings:
        seconds = struct.unpack_from("<h", r["raw"], 0x0C)[0]
        lines.append(f"  start time: {seconds} s")
    for r in level["records"]:
        if r["type"] == 9:
            hidden, farsighted = struct.unpack_from("<2h", r["raw"], 2)
            lines.append(f"  level flags: hidden {hidden}, farsighted invisible {farsighted}")
    return "\n".join(lines) + "\n"


def axis_name(v):
    for name, axis in [("+x", (1, 0, 0)), ("-x", (-1, 0, 0)), ("+y", (0, 1, 0)), ("-y", (0, -1, 0)), ("+z", (0, 0, 1)), ("-z", (0, 0, -1))]:
        if axis == v:
            return name
    raise ValueError(f"{v} is not an axis")


def spawn_forward(face, rotation):
    forward, right = SPAWN_FORWARD[face], SPAWN_RIGHT[face]
    if rotation == 2:
        return right
    if rotation == 3:
        return tuple(-c for c in forward)
    if rotation == 4:
        return tuple(-c for c in right)
    return forward


def convert(level):
    """Return Kula's level text. Raise Unsupported that names every feature Kula lacks."""
    problems = []
    blocks = set()
    items = []
    starts = []
    for cell, value in level["cells"].items():
        if value == 0:
            blocks.add(cell)
        elif value < 5:
            problems.append(f"{CELL_NAMES[value]} block" if value in CELL_NAMES else f"cell value {value}")
    for cell, record in block_records(level):
        record_type = record["type"]
        if record_type != 0:
            problems.append(RECORD_NAMES.get(record_type, f"record type {record_type}"))
            continue
        if tuple(record["position"]) != cell:
            problems.append(f"record at {cell} names position {record['position']}")
        blocks.add(cell)
        for face, object_id, rotation, _ in record["objects"]:
            if object_id == OBJ_KEY:
                items.append((cell, face, "key"))
            elif object_id == OBJ_EXIT:
                items.append((cell, face, "exit"))
            elif object_id in (OBJ_PLAYER_SPAWN, OBJ_PLAYER_SPAWN_PAUSED):
                if object_id == OBJ_PLAYER_SPAWN_PAUSED:
                    problems.append("player spawn (paused): the face pauses the level clock")
                starts.append((cell, face, spawn_forward(face, rotation)))
            else:
                problems.append(OBJECT_NAMES.get(object_id, f"object 0x{object_id:02X}"))
    referenced = {id(r) for _, r in block_records(level)}
    for record in level["records"]:
        if id(record) in referenced:
            continue
        if record["type"] == 9:
            if any(struct.unpack_from("<2h", record["raw"], 2)):
                problems.append("level flags")
        elif record["type"] != 666:
            problems.append(f"{RECORD_NAMES.get(record['type'], 'record type ' + str(record['type']))} with no cell")
    if len(starts) != 1:
        problems.append(f"{len(starts)} player spawns")
    if problems:
        names = ", ".join(f"{name} ({count})" if count > 1 else name for name, count in sorted(Counter(problems).items()))
        raise Unsupported(f"Kula cannot show: {names}")
    return write_text(blocks, items, starts[0])


def write_text(blocks, items, start):
    kula_blocks = {to_kula(c) for c in blocks}
    xs, ys, zs = zip(*kula_blocks)
    lo = (min(xs), min(ys), min(zs))
    hi = (max(xs), max(ys), max(zs))

    def local(c):
        return tuple(a - b for a, b in zip(to_kula(c), lo))

    lines = []
    for y in range(lo[1], hi[1] + 1):
        if lines:
            lines.append("")
        for z in range(lo[2], hi[2] + 1):
            lines.append("".join("#" if (x, y, z) in kula_blocks else "." for x in range(lo[0], hi[0] + 1)))
    lines.append("")
    for cell, face, item in sorted(items, key=lambda e: (e[2], local(e[0]), e[1])):
        x, y, z = local(cell)
        lines.append(f"{x} {y} {z} {axis_name(to_kula(DIRECTIONS[face]))} {item}")
    cell, face, forward = start
    x, y, z = local(cell)
    lines.append(f"start {x} {y} {z} {axis_name(to_kula(DIRECTIONS[face]))} {axis_name(to_kula(forward))}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert a Roll Away Hiro level to a Kula level file.")
    parser.add_argument("disc", help="the disc image, one MODE2/2352 track")
    parser.add_argument("level", type=int, help="the Hiro level number, from 1")
    parser.add_argument("--list", action="store_true", help="print the block types, record types and objects the level uses")
    parser.add_argument("-o", "--output", help="the level file to write; stdout without it")
    args = parser.parse_args(argv)

    with open(args.disc, "rb") as image:
        pak = read_iso_file(image, PAK_PATH)
    level = parse_level(level_data(unpack_pak(pak), args.level))
    if args.list:
        sys.stdout.write(format_list(args.level, level))
        return 0
    try:
        text = convert(level)
    except Unsupported as err:
        print(f"Hiro level {args.level}: {err}", file=sys.stderr)
        return 1
    if args.output:
        with open(args.output, "w", newline="\n") as out:
            out.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
