"""Tests for convert_level.py on a synthetic disc image. CI has no real disc.

Run: python3 -m unittest discover -s scripts
"""

import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import convert_level as cl  # noqa: E402

EMPTY_SLOT = struct.pack("<4h", 0, -1, -1, 0) + b"\0" * 24


def record(record_type, position, slots=None):
    """One 256-byte record. slots maps a face index to (object id, direction) or (object id, direction, variant)."""
    data = bytearray(struct.pack("<h", record_type))
    for face in range(6):
        if slots and face in slots:
            object_id, direction, variant = (slots[face] + (0,))[:3]
            data += struct.pack("<4h", object_id, direction, variant, 0) + b"\0" * 24
        else:
            data += EMPTY_SLOT
    data += b"\xff" * (0xFA - len(data))
    data += struct.pack("<3h", *position)
    return bytes(data)


def grid_index(cell):
    x, y, z = cell
    return (x * cl.SIZE + y) * cl.SIZE + z


def level_bytes(plain, records, seconds=99):
    """plain is a list of cells. records is a list of (type, cell, slots). seconds is the start time."""
    grid = [-1] * (cl.SIZE**3)
    for cell in plain:
        grid[grid_index(cell)] = 0
    for n, (_, cell, _) in enumerate(records):
        grid[grid_index(cell)] = cl.RECORD_POINTER + n
    data = struct.pack(f"<{len(grid)}h", *grid)
    data += struct.pack("<3h", len(plain) + len(records), 0, len(records))
    data += b"".join(record(t, cell, slots) for t, cell, slots in records)
    data += struct.pack("<7h", cl.RECORD_LEVEL_SETTINGS, 0, 0, 0, 0, 0, seconds) + b"\xff" * 242
    return data


def with_cell(data, cell, value):
    changed = bytearray(data)
    struct.pack_into("<h", changed, grid_index(cell) * 2, value)
    return bytes(changed)


def pak_bytes(files):
    count = len(files)
    names = b""
    name_offsets = []
    head = 4 + count * 12
    for name, _ in files:
        name_offsets.append(head + len(names))
        names += name.encode() + b"\n\0"
    names += b"\0" * (-len(names) % 4)
    body = b""
    entries = b""
    for _, data in files:
        packed = zlib.compress(data)
        entries += struct.pack("<II", head + len(names) + len(body), len(packed))
        body += packed
    return struct.pack("<I", count) + entries + b"".join(struct.pack("<I", o) for o in name_offsets) + names + body


def dir_record(name, lba, size, is_dir):
    raw = name if isinstance(name, bytes) else name.encode()
    length = 33 + len(raw) + (1 - len(raw) % 2)
    rec = struct.pack("<BB", length, 0)
    rec += struct.pack("<I", lba) + struct.pack(">I", lba)
    rec += struct.pack("<I", size) + struct.pack(">I", size)
    rec += b"\0" * 7 + bytes([2 if is_dir else 0, 0, 0]) + struct.pack("<H", 1) + struct.pack(">H", 1)
    rec += bytes([len(raw)]) + raw
    return rec + b"\0" * (length - len(rec))


def disc_image(pak, pak_name="HIRO.PAK;1"):
    """A MODE2/2352 image with HIRO/<pak_name> in its ISO9660 file system."""
    root_lba, hiro_lba, pak_lba = 20, 21, 22
    root = dir_record(b"\0", root_lba, 2048, True) + dir_record(b"\1", root_lba, 2048, True) + dir_record("HIRO", hiro_lba, 2048, True)
    hiro = dir_record(b"\0", hiro_lba, 2048, True) + dir_record(b"\1", root_lba, 2048, True) + dir_record(pak_name, pak_lba, len(pak), False)
    pvd = bytearray(2048)
    pvd[0:6] = b"\x01CD001"
    pvd[156:190] = dir_record(b"\0", root_lba, 2048, True)
    sectors = {16: bytes(pvd), root_lba: root, hiro_lba: hiro}
    for n in range(0, len(pak), 2048):
        sectors[pak_lba + n // 2048] = pak[n : n + 2048]
    out = bytearray()
    for lba in range(max(sectors) + 1):
        data = sectors.get(lba, b"")
        out += b"\0" * cl.USER_DATA_OFFSET + data + b"\0" * (2048 - len(data)) + b"\0" * 280
    return bytes(out)


# A floor on the original's Z- faces, as the Hiro levels lie.
PLAIN = [(10, 10, 10), (10, 11, 10), (11, 11, 10), (12, 11, 10)]
RECORDS = [
    (0, (10, 12, 10), {0: (cl.OBJ_PLAYER_SPAWN, 3)}),
    (0, (11, 12, 10), {0: (cl.OBJ_KEY, 0)}),
    (0, (12, 12, 10), {0: (cl.OBJ_EXIT, 0), 1: (cl.OBJ_KEY, 0)}),
]


def count_text(text):
    """Count the blocks, keys, exits and starts of a level text the way Level.roc reads it."""
    counts = {"blocks": 0, "key": 0, "exit": 0, "start": 0, "coin": 0, "fruit": 0}
    for line in text.splitlines():
        if " " in line:
            parts = line.split()
            counts["start" if parts[0] == "start" else parts[-1]] += 1
        else:
            counts["blocks"] += sum(ch in "#SKE" for ch in line)
            counts["key"] += line.count("K")
            counts["exit"] += line.count("E")
            counts["start"] += line.count("S")
    return counts


def count_grid(level):
    counts = {"blocks": 0, "key": 0, "exit": 0, "start": 0, "coin": 0, "fruit": 0}
    for value in level["cells"].values():
        if value == 0 or (value >= cl.RECORD_POINTER and level["records"][value - cl.RECORD_POINTER]["type"] == 0):
            counts["blocks"] += 1
    for r in level["records"]:
        for _, object_id, _, _ in r["objects"]:
            if object_id == cl.OBJ_KEY:
                counts["key"] += 1
            elif object_id == cl.OBJ_EXIT:
                counts["exit"] += 1
            elif object_id in (cl.OBJ_PLAYER_SPAWN, cl.OBJ_PLAYER_SPAWN_PAUSED):
                counts["start"] += 1
            elif object_id == cl.OBJ_COIN:
                counts["coin"] += 1
            elif object_id in cl.FRUITS:
                counts["fruit"] += 1
    return counts


class ConvertTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def disc(self, levels, pak_name="HIRO.PAK;1"):
        files = [(f"LEVEL {n + 1}", data) for n, data in enumerate(levels)]
        return self.write("disc.bin", disc_image(pak_bytes(files), pak_name))

    def write(self, name, data):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cl.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_text_counts_match_the_grid(self):
        data = level_bytes(PLAIN, RECORDS + [(0, (12, 10, 10), {0: (cl.OBJ_COIN, 0, 2), 2: (0x2E, 0)})])
        disc = self.disc([level_bytes(PLAIN[:1], RECORDS[:1]), data])
        out_path = os.path.join(self.dir.name, "level.txt")
        code, _, err = self.run_main(disc, "2", "-o", out_path)
        self.assertEqual(code, 0, err)
        with open(out_path) as f:
            text = f.read()
        self.assertEqual(count_text(text), count_grid(cl.parse_level(data)))
        self.assertEqual(count_text(text), {"blocks": 8, "key": 2, "exit": 1, "start": 1, "coin": 1, "fruit": 1})

    def test_axes_turn_original_minus_z_to_kula_up(self):
        text = cl.convert(cl.parse_level(level_bytes(PLAIN, RECORDS)))
        self.assertEqual(
            text,
            "#..\n"
            "###\n"
            "###\n"
            "\n"
            "2 0 2 +y exit\n"
            "1 0 2 +y key\n"
            "2 0 2 +x key\n"
            "start 0 0 2 +y -z\n",
        )

    def test_bronze_coins_and_any_fruit_write_entries(self):
        records = RECORDS + [(0, (12, 10, 10), {0: (cl.OBJ_COIN, 0, 2), 2: (0x2E, 0)}), (0, (11, 10, 10), {0: (0x2B, 0)})]
        text = cl.convert(cl.parse_level(level_bytes(PLAIN, records)))
        self.assertEqual(
            text.split("\n\n")[1],
            "2 0 0 +y coin\n"
            "2 0 2 +y exit\n"
            "1 0 0 +y fruit\n"
            "2 0 0 +z fruit\n"
            "1 0 2 +y key\n"
            "2 0 2 +x key\n"
            "start 0 0 2 +y -z\n",
        )

    def test_unsupported_objects_are_named(self):
        records = RECORDS + [(0, (12, 10, 10), {0: (0x25, 0), 2: (0x25, 0, 1), 5: (0x1B, 0)}), (6, (11, 10, 10), None)]
        with self.assertRaises(cl.Unsupported) as caught:
            cl.convert(cl.parse_level(level_bytes(PLAIN, records)))
        self.assertEqual(str(caught.exception), "Kula cannot show: crumbling block, fruit bowl, gold coin, silver coin")

    def test_bad_record_pointers_are_named_with_the_other_features(self):
        records = RECORDS + [(0, (12, 10, 10), {0: (0x25, 0)})]
        data = with_cell(level_bytes(PLAIN, records), PLAIN[0], cl.RECORD_POINTER + 10)
        with self.assertRaises(cl.Unsupported) as caught:
            cl.convert(cl.parse_level(data))
        self.assertEqual(str(caught.exception), "Kula cannot show: cell (10, 10, 10) points to record 10, past the last record, gold coin")

    def test_fire_cells_are_named(self):
        disc = self.disc([with_cell(level_bytes(PLAIN, RECORDS), PLAIN[0], 1)])
        code, out, err = self.run_main(disc, "1")
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(err, "Hiro level 1: Kula cannot show: fire block\n")

    def test_unknown_cell_values_are_named(self):
        with self.assertRaises(cl.Unsupported) as caught:
            cl.convert(cl.parse_level(with_cell(level_bytes(PLAIN, RECORDS), PLAIN[0], -2)))
        self.assertEqual(str(caught.exception), "Kula cannot show: cell value -2")

    def test_a_start_time_other_than_99_writes_a_time_line(self):
        self.assertNotIn("time", cl.convert(cl.parse_level(level_bytes(PLAIN, RECORDS))))
        self.assertTrue(cl.convert(cl.parse_level(level_bytes(PLAIN, RECORDS, seconds=45))).endswith("time 45\n"))

    def test_list_counts_every_feature(self):
        records = RECORDS + [(0, (12, 10, 10), {0: (0x25, 0, 2)})]
        code, out, _ = self.run_main(self.disc([level_bytes(PLAIN, records)]), "1", "--list")
        self.assertEqual(code, 0)
        self.assertEqual(
            out,
            "Hiro level 1\n"
            "  cells:\n"
            "    plain: 4\n"
            "    record: 4\n"
            "  records:\n"
            "    level settings: 1\n"
            "    object block (plain): 4\n"
            "  objects:\n"
            "    coin (variant 2) on Z- (Kula +y): 1\n"
            "    exit on Z- (Kula +y): 1\n"
            "    key on X+ (Kula +x): 1\n"
            "    key on Z- (Kula +y): 1\n"
            "    player spawn on Z- (Kula +y): 1\n"
            "  start time: 99 s\n",
        )

    def assert_fails(self, args, message):
        code, out, err = self.run_main(*args)
        self.assertEqual((code, out, err), (1, "", message + "\n"))

    def test_a_missing_disc_is_one_line(self):
        path = os.path.join(self.dir.name, "missing.bin")
        self.assert_fails([path, "1"], f"{path}: No such file or directory")

    def test_a_disc_that_is_not_iso9660_is_one_line(self):
        path = self.write("bad.bin", b"\0" * (cl.SECTOR_SIZE * 17))
        self.assert_fails([path, "1"], f"{path}: no ISO9660 primary volume descriptor at sector 16")

    def test_a_damaged_pak_is_one_line(self):
        path = self.write("damaged.bin", disc_image(b"\xff" * 64))
        code, out, err = self.run_main(path, "1")
        self.assertEqual((code, out), (1, ""))
        self.assertTrue(err.startswith(f"{path}: not a Roll Away disc image ("), err)
        self.assertEqual(err.count("\n"), 1)

    def test_a_disc_without_the_pak_is_one_line(self):
        path = self.disc([level_bytes(PLAIN, RECORDS)], pak_name="OTHER.PAK;1")
        self.assert_fails([path, "1"], f"{path}: HIRO/HIRO.PAK is not on the disc")

    def test_a_level_out_of_range_is_one_line(self):
        path = self.disc([level_bytes(PLAIN, RECORDS)])
        self.assert_fails([path, "2"], f"{path}: Hiro level 2 is not in HIRO.PAK")
        self.assert_fails([path, "0", "--list"], f"{path}: Hiro level 0 is not in HIRO.PAK")


if __name__ == "__main__":
    unittest.main()
