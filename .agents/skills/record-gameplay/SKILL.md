---
name: record-gameplay
description: Record an MP4 of Kula played over the rocco Bridge. Use when asked to play a level, show gameplay, or send a video of a run.
---

# Record gameplay

`record.py` starts Kula in a window with the Bridge, plays a route of moves, saves a screenshot every 4 steps (30 fps at 120 steps a second), scales each one to 1280 wide at once and encodes the frames to a 1280x720 H.264 MP4. It prints the ball position after each move. Needs `roc`, `ffmpeg` and a display: a Headless run draws nothing.

## Steps

1. **Plan the route.** Read `levels/levelN.txt` and the README sections "Moves", "Keys and the exit", "Level end" and "Level files". Trace the ball cell by cell from the start, and write the cell you expect after each move into its label. Done when the route collects every key, ends on the exit and then presses Space to go on.
2. **Write the route file** in the scratchpad, never in the repo. See [Route format](#route-format).
3. **Run it** from the repo root:
   ```sh
   python3 .agents/skills/record-gameplay/record.py route.json out.mp4 --frames frames/
   ```
   The game window opens on the screen and closes when the run ends.
4. **Check the log.** Every move's ball position must match its label. The ball is Draw id 0 and `pos` is its centre: on top of a block at layer `y`, `pos.y` is about `y + 0.7`. After the exit move the ball hides, so the log shows `(no ball)` until the press. The press after the level end of a level whose next level has a new Theme shows a `Load` of that Theme. If a move goes wrong, fix the route from that move and run again; every run starts fresh. Done when the log matches the plan.
5. **Look at frames**: one after a key pickup (the panel reads `Keys n / total`), one mid jump and the last one. Scale a frame down with `ffmpeg -i frames/f00100.png -vf scale=960:-1 small.png` to read it.
6. **Send the MP4** to the user. Say which level, which commit, and whether keys or the pad played it.

## Route format

```json
{
  "warmup": 150,
  "tail": 120,
  "moves": [
    {"label": "roll to z8", "held": ["Up"]},
    {"label": "jump the gap to z2", "held": ["Up"], "tap": ["Space"], "press": 4, "settle": 76},
    {"label": "roll to z1 with the pad", "pad": {"held": ["DpadUp"]}},
    {"label": "turn left", "tap": ["Left"], "press": 1, "settle": 40}
  ]
}
```

- `held` and `tap` are `pf.Key` names. `pad` holds `held` and `tap` lists of Button names for a pad in slot 0. The pad needs rocco v0.5.0 or later in the `main.roc` header.
- `press` is the steps with the input on (default 1). `settle` is the idle steps after (default 47, a bit more than the slowest roll).
- A tap counts once, at the first step of the move.
- `warmup` idle steps cover the Theme load and the `Starting` wait. `tail` idle steps run after the last move.
- `"record": false` plays a move without frames. The warmup records only if the first move does. The game always starts on level 1, so a video of level 2 first plays level 1 with `"record": false`. The next level starts 1 s after the press that ends the level end, so the first recorded move of level 2 needs a `press` that waits out that delay, or an idle move before it.

## Timing

- Up held for 1 step starts one roll. Up still held when a roll ends starts the next roll, so hold it longer only to chain rolls on purpose.
- A forward jump is Up held with a Space tap in the same step. It lasts 0.54 s (65 steps), so give it a settle near 76.
- A turn takes 0.32 s (39 steps).
- After the exit, the level waits for a press. Give the exit move a `settle` of about 240 to show the whole level end: `WELL DONE` fades in over 1.7 s while the score counts up by 5000 a second. Then add a move `{"label": "go on to level N", "tap": ["Space"], "settle": 150}`. A Space tap before the banner and the count finish only finishes them, so a route that taps early needs a second tap.
