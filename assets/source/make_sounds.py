# Writes Kula's Sounds as 16-bit mono wav files into assets/sound/. Python
# standard library only, so it needs no Blender. Run it from anywhere:
#   python3 assets/source/make_sounds.py
#
# The sounds are synthesized here, not taken from the original game. A rerun
# writes the same bytes.

import math
import os
import random
import struct
import wave

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

RATE = 48000
TAU = 2.0 * math.pi


def write(path, samples):
    clipped = [round(max(-1.0, min(1.0, s)) * 32767) for s in samples]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(clipped)}h", *clipped))


# A raised cosine from 1 down to 0 over the last `seconds` of a sound `length`
# seconds long, so the sound ends at exactly zero.
def tail(t, length, seconds):
    left = length - t
    if left >= seconds:
        return 1.0
    return 0.5 - 0.5 * math.cos(math.pi * max(left, 0.0) / seconds)


# A dry wooden tock for the last 20 s of the level clock: a short high tone
# with a weaker partial a fifth above, gone in 60 ms. The game sets its gain.
def tick():
    length = 0.06
    samples = []
    for i in range(int(length * RATE)):
        t = i / RATE
        attack = min(t / 0.0005, 1.0)
        body = math.exp(-t / 0.012) * (math.sin(TAU * 1400.0 * t) + 0.4 * math.sin(TAU * 2100.0 * t))
        samples.append(0.5 * attack * tail(t, length, 0.01) * body)
    return samples


# A rubber thud: a low tone that drops in pitch as it dies away, with a short
# soft click of noise where the ball meets the block.
def bounce():
    length = 0.2
    noise = random.Random(7)
    samples = []
    phase = 0.0
    for i in range(int(length * RATE)):
        t = i / RATE
        freq = 85.0 + 150.0 * math.exp(-t / 0.03)
        phase += TAU * freq / RATE
        attack = min(t / 0.001, 1.0)
        body = math.exp(-t / 0.05) * (math.sin(phase) + 0.25 * math.sin(2.0 * phase))
        click = 0.3 * math.exp(-t / 0.004) * (noise.random() * 2.0 - 1.0)
        samples.append(0.7 * attack * tail(t, length, 0.01) * (body + click))
    return samples


folder = os.path.join(ASSETS, "sound")
os.makedirs(folder, exist_ok=True)
write(os.path.join(folder, "bounce.wav"), bounce())
write(os.path.join(folder, "tick.wav"), tick())
