# Writes Kula's Sounds as 16-bit mono wav files into assets/sound/. Python
# standard library only, so it needs no Blender. Run it from anywhere:
#   python3 assets/source/make_sounds.py
#
# Each sound is synthesized here, not taken from the original game. A rerun
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


# A short bright chime for a coin: a struck note and a fifth above it a moment
# later, each with a quieter bell partial and a tick of noise at the strike.
def chime():
    length = 0.35
    noise = random.Random(37)
    notes = [(0.0, 1318.5), (0.06, 1975.5)]
    samples = []
    for i in range(int(length * RATE)):
        t = i / RATE
        sound = 0.0
        for start, freq in notes:
            since = t - start
            if since < 0.0:
                continue
            attack = min(since / 0.002, 1.0)
            ring = math.exp(-since / 0.09) * math.sin(TAU * freq * since)
            bell = 0.3 * math.exp(-since / 0.03) * math.sin(TAU * 2.76 * freq * since)
            tick = 0.15 * math.exp(-since / 0.002) * (noise.random() * 2.0 - 1.0)
            sound += attack * (ring + bell) + tick
        samples.append(0.45 * tail(t, length, 0.02) * sound)
    return samples


# A rising jingle for a fruit: four quick notes up a major chord to the
# octave, each a soft mallet tone with a warm second partial.
def jingle():
    length = 0.6
    notes = [(0.0, 1046.5), (0.06, 1318.5), (0.12, 1568.0), (0.18, 2093.0)]
    samples = []
    for i in range(int(length * RATE)):
        t = i / RATE
        sound = 0.0
        for start, freq in notes:
            since = t - start
            if since < 0.0:
                continue
            attack = min(since / 0.003, 1.0)
            tone = math.sin(TAU * freq * since) + 0.35 * math.exp(-since / 0.05) * math.sin(TAU * 2.0 * freq * since)
            sound += attack * math.exp(-since / 0.14) * tone
        samples.append(0.3 * tail(t, length, 0.05) * sound)
    return samples


# A bright metal zing for a key: a tone that glides up an octave in 50 ms,
# with an inharmonic ring above it that shimmers as it dies away.
def key():
    length = 0.4
    samples = []
    phase = 0.0
    for i in range(int(length * RATE)):
        t = i / RATE
        freq = 1760.0 - 880.0 * math.exp(-t / 0.018)
        phase += TAU * freq / RATE
        attack = min(t / 0.002, 1.0)
        shimmer = 1.0 + 0.25 * math.sin(TAU * 18.0 * t)
        tone = math.sin(phase) + 0.35 * shimmer * math.exp(-t / 0.06) * math.sin(2.41 * phase)
        samples.append(0.4 * attack * tail(t, length, 0.05) * math.exp(-t / 0.12) * tone)
    return samples


# The last key opens the exit: the key's zing, then a held major chord
# that swells in and shimmers, a longer sound than any pickup.
def last_key():
    length = 1.2
    chord = [1046.5, 1318.5, 1568.0, 2093.0]
    zing = key()
    samples = []
    for i in range(int(length * RATE)):
        t = i / RATE
        since = t - 0.08
        sound = 0.0
        if since >= 0.0:
            swell = min(since / 0.06, 1.0) * math.exp(-since / 0.45)
            shimmer = 1.0 + 0.3 * math.sin(TAU * 7.0 * since)
            sound = 0.12 * swell * shimmer * sum(math.sin(TAU * f * since) for f in chord)
        if i < len(zing):
            sound += zing[i]
        samples.append(tail(t, length, 0.1) * sound)
    return samples


folder = os.path.join(ASSETS, "sound")
os.makedirs(folder, exist_ok=True)
write(os.path.join(folder, "bounce.wav"), bounce())
write(os.path.join(folder, "chime.wav"), chime())
write(os.path.join(folder, "tick.wav"), tick())
write(os.path.join(folder, "jingle.wav"), jingle())
write(os.path.join(folder, "key.wav"), key())
write(os.path.join(folder, "last_key.wav"), last_key())
