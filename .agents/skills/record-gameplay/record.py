#!/usr/bin/env python3
"""Play Kula over the rocco Bridge from a route file and save an MP4.

Usage: record.py ROUTE.json OUT.mp4 [--frames DIR] [--game-dir DIR]

See SKILL.md beside this file for the route format.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

FRAME_STEPS = 4  # 120 steps a second / 4 = 30 fps
BALL_ID = 0
DEFAULT_PRESS = 1
DEFAULT_SETTLE = 47
# A host screenshot is about 8 MB, so a long route can fill the disk. Each
# frame shrinks to the video's width as soon as it is saved.
FRAME_WIDTH = 1280


class BridgeError(Exception):
    pass


class Bridge:
    def __init__(self, port, process, wait=120.0):
        deadline = time.monotonic() + wait
        while True:
            if process.poll() is not None:
                raise BridgeError(f"the game exited with code {process.returncode} before the Bridge opened")
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=300)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise BridgeError(f"no Bridge on port {port} after {wait:.0f} s")
                time.sleep(0.25)
        self.lines = self.sock.makefile("rb")

    def request(self, req):
        self.sock.sendall((json.dumps(req) + "\n").encode())
        line = self.lines.readline()
        if not line:
            raise BridgeError(f"the Bridge closed during {req['op']}")
        reply = json.loads(line)
        if not reply.get("ok"):
            raise BridgeError(f"{req['op']} failed: {reply.get('error')}")
        return reply

    def close(self):
        self.lines.close()
        self.sock.close()


# Up to v0.4.0 a Scene lists its Draws in `draws`; later ones nest them as
# `{"Draw": ...}` nodes in a tree.
def find_draw(value, draw_id):
    if isinstance(value, dict):
        if value.get("id") == draw_id and "mesh" in value and "pos" in value:
            return value
        values = value.values()
    elif isinstance(value, list):
        values = value
    else:
        return None
    for child in values:
        found = find_draw(child, draw_id)
        if found is not None:
            return found
    return None


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Recorder:
    def __init__(self, bridge, frames_dir, uses_pad):
        self.bridge = bridge
        self.frames_dir = frames_dir
        self.uses_pad = uses_pad
        self.frame = 0

    def ball(self):
        draw = find_draw(self.bridge.request({"op": "scene"})["scene"], BALL_ID)
        if draw is None:
            return "(no ball)"
        p = draw["pos"]
        return f"({p['x']:.2f}, {p['y']:.2f}, {p['z']:.2f})"

    # Taps go in the first request only, so a tap is one press.
    def run(self, steps, keys=None, pad=None, record=True):
        keys = keys or {}
        pad = pad or {}
        commands = []
        first = True
        while steps > 0:
            n = min(FRAME_STEPS, steps)
            req = {"op": "step", "n": n}
            if keys.get("held"):
                req["held"] = keys["held"]
            if first and keys.get("tap"):
                req["tap"] = keys["tap"]
            # A pad left out of a step is a pad unplugged, so a route with
            # pad moves keeps slot 0 in every step.
            if self.uses_pad:
                one = {"slot": 0}
                if pad.get("held"):
                    one["held"] = pad["held"]
                if first and pad.get("tap"):
                    one["tap"] = pad["tap"]
                req["gamepads"] = [one]
            reply = self.bridge.request(req)
            commands += reply.get("commands", [])
            first = False
            steps -= n
            if record:
                self.save_frame()
            if "Quit" in reply.get("commands", []):
                break
        return commands

    def save_frame(self):
        path = os.path.join(self.frames_dir, f"f{self.frame:05d}.png")
        self.bridge.request({"op": "screenshot", "path": path})
        shrink(path)
        self.frame += 1

    def move(self, move):
        record = move.get("record", True)
        keys = {"held": move.get("held", []), "tap": move.get("tap", [])}
        pad = move.get("pad", {})
        commands = self.run(move.get("press", DEFAULT_PRESS), keys, pad, record)
        commands += self.run(move.get("settle", DEFAULT_SETTLE), record=record)
        return commands


def summary(commands):
    names = [c if isinstance(c, str) else next(iter(c)) + " " + json.dumps(next(iter(c.values()))) for c in commands]
    return "; ".join(names)


def shrink(path):
    small = path[:-len(".png")] + ".small.png"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf", f"scale={FRAME_WIDTH}:-2", small], check=True)
    os.replace(small, path)


def encode(frames_dir, out):
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-framerate", str(120 // FRAME_STEPS), "-i", os.path.join(frames_dir, "f%05d.png"),
         "-vf", "scale=1280:720", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-movflags", "+faststart", out],
        check=True,
    )


def main(argv):
    parser = argparse.ArgumentParser(description="Play Kula over the Bridge from a route file and save an MP4.")
    parser.add_argument("route", help="the route JSON file")
    parser.add_argument("out", help="the MP4 to write")
    parser.add_argument("--frames", help="keep the PNG frames in this folder (default: a temp folder, removed after)")
    parser.add_argument("--game-dir", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")),
                        help="the Kula checkout to run (default: the repo that holds this script)")
    args = parser.parse_args(argv)

    if not shutil.which("ffmpeg"):
        raise BridgeError("ffmpeg is not on PATH")
    with open(args.route) as f:
        route = json.load(f)
    moves = route["moves"]
    uses_pad = any("pad" in m for m in moves)
    frames_dir = os.path.abspath(args.frames) if args.frames else tempfile.mkdtemp(prefix="kula-frames-")
    os.makedirs(frames_dir, exist_ok=True)

    port = free_port()
    game = subprocess.Popen(["roc", "main.roc"], cwd=args.game_dir, env={**os.environ, "ROCCO_BRIDGE": str(port)},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        bridge = Bridge(port, game)
        hello = bridge.request({"op": "hello"})
        if hello.get("headless"):
            raise BridgeError("a Headless run draws nothing; unset ROCCO_HEADLESS")
        rec = Recorder(bridge, frames_dir, uses_pad)
        rec.run(route.get("warmup", 150), record=moves[0].get("record", True) if moves else True)
        print(f"{'start':32s} ball {rec.ball()}", flush=True)
        for i, move in enumerate(moves):
            commands = rec.move(move)
            label = move.get("label", f"move {i + 1}")
            print(f"{label:32s} ball {rec.ball()}  {summary(commands)}", flush=True)
            if "Quit" in commands:
                break
        else:
            rec.run(route.get("tail", 120))
            bridge.request({"op": "quit"})
        bridge.close()
        game.wait(timeout=30)
        if rec.frame == 0:
            raise BridgeError("no frames were recorded")
        encode(frames_dir, args.out)
        print(f"frames {rec.frame}, video {args.out} ({rec.frame / (120 / FRAME_STEPS):.1f} s)")
    finally:
        if game.poll() is None:
            game.kill()
        if not args.frames:
            shutil.rmtree(frames_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BridgeError as e:
        print(f"record: {e}", file=sys.stderr)
        sys.exit(1)
