# Writes Kula's HUD icons as 64 x 64 RGBA PNG files into assets/images/.
# Python standard library only. Run it from anywhere:
#   python3 assets/source/make_icons.py
#
# The HUD shows each icon at 32 x 32, so the Linear filter halves them. Each
# pixel averages 4 x 4 samples of signed distance shapes. A rerun writes the
# same bytes. The art is a first pass, not taken from the original game.

import math
import os
import struct
import zlib

IMAGES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "images")

SIZE = 64
SAMPLES = 4
OUTLINE = 2.5


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", header))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def circle(cx, cy, r):
    return lambda x, y: math.hypot(x - cx, y - cy) - r


def box(x0, y0, x1, y1):
    cx, cy, hx, hy = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2

    def d(x, y):
        qx, qy = abs(x - cx) - hx, abs(y - cy) - hy
        return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0)

    return d


# A square turned 45 degrees, r from the centre to each corner.
def diamond(cx, cy, r):
    return lambda x, y: (abs(x - cx) + abs(y - cy) - r) / math.sqrt(2.0)


# An ellipse turned by angle degrees. The distance is close enough near the edge.
def ellipse(cx, cy, rx, ry, angle):
    c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))

    def d(x, y):
        u, v = (x - cx) * c + (y - cy) * s, -(x - cx) * s + (y - cy) * c
        k = math.hypot(u / rx, v / ry)
        return (k - 1.0) * min(rx, ry)

    return d


# A capsule from (ax, ay) to (bx, by) with radius r.
def stick(ax, ay, bx, by, r):
    def d(x, y):
        px, py, dx, dy = x - ax, y - ay, bx - ax, by - ay
        t = max(0.0, min(1.0, (px * dx + py * dy) / (dx * dx + dy * dy)))
        return math.hypot(px - dx * t, py - dy * t) - r

    return d


def union(*shapes):
    return lambda x, y: min(s(x, y) for s in shapes)


def minus(shape, hole):
    return lambda x, y: max(shape(x, y), -hole(x, y))


def outlined(shape):
    return lambda x, y: shape(x, y) - OUTLINE


# Each layer is a shape and a colour function. The last layer that covers a
# sample gives its colour.
def render(layers):
    rows = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            r = g = b = a = 0.0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    x = px + (sx + 0.5) / SAMPLES
                    y = py + (sy + 0.5) / SAMPLES
                    colour = None
                    for shape, paint in layers:
                        if shape(x, y) < 0.0:
                            colour = paint(x, y)
                    if colour is not None:
                        r, g, b, a = r + colour[0], g + colour[1], b + colour[2], a + 1.0
            n = SAMPLES * SAMPLES
            if a == 0.0:
                row.extend((0, 0, 0, 0))
            else:
                row.extend((round(255 * r / a), round(255 * g / a), round(255 * b / a), round(255 * a / n)))
        rows.append(row)
    return rows


def flat(rgb):
    return lambda x, y: rgb


# Lighter at the top left, darker at the bottom right.
def shaded(rgb, light):
    def paint(x, y):
        k = 1.0 + light * (1.0 - (x + y) / SIZE)
        return tuple(min(1.0, c * k) for c in rgb)

    return paint


# A gold key, upright like key.glb: a diamond bow with a hole, a shaft and two teeth.
def key():
    bow = minus(diamond(32.0, 18.0, 14.0), diamond(32.0, 18.0, 5.5))
    shaft = box(28.0, 27.0, 36.0, 58.0)
    teeth = union(box(35.0, 44.0, 44.0, 49.0), box(35.0, 52.0, 42.0, 57.0))
    body = union(bow, shaft, teeth)
    return render(
        [
            (outlined(body), flat((0.30, 0.18, 0.02))),
            (body, shaded((0.95, 0.72, 0.15), 0.35)),
            (stick(25.5, 14.5, 29.0, 11.0, 1.3), flat((1.0, 0.95, 0.7))),
        ]
    )


# A red apple with a stem and a leaf.
def fruit():
    body = union(circle(24.0, 37.0, 16.0), circle(40.0, 37.0, 16.0), circle(32.0, 43.0, 17.0))
    stem = stick(31.0, 24.0, 34.0, 9.0, 1.8)
    leaf = ellipse(43.0, 15.0, 9.0, 4.5, -30.0)
    whole = union(body, stem, leaf)
    return render(
        [
            (outlined(whole), flat((0.18, 0.06, 0.04))),
            (stem, flat((0.42, 0.26, 0.12))),
            (leaf, shaded((0.25, 0.65, 0.18), 0.3)),
            (body, shaded((0.85, 0.12, 0.12), 0.45)),
            (ellipse(22.0, 31.0, 5.0, 3.0, -40.0), flat((1.0, 0.75, 0.75))),
        ]
    )


def main():
    os.makedirs(IMAGES, exist_ok=True)
    for name, draw in (("key", key), ("fruit", fruit)):
        write_png(os.path.join(IMAGES, name + ".png"), draw())


if __name__ == "__main__":
    main()
