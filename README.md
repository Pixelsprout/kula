# Kula

A clone of Kula World (PS1, 1998) on the rocco engine. A ball rolls over a
grid of blocks. Gravity turns when the ball rolls over an edge. Collect
every key, then roll into the exit. The three levels are Hiro levels 1 to 3
of the original. They follow one another in one Theme.

`SPEC.md` holds the original's numbers and says which of them this clone
copies.

## Run

Kula needs only Roc. Install the Roc nightly `nightly-2026-10-11-7d256b9`.
The v0.6.0-rc.1 release built the bundles with it. Then, from this directory:

```sh
roc main.roc
roc test main.roc
```

Roc downloads the platform and the packages from the bundle URLs in the
`main.roc` header. They come from the
[rocco v0.6.0-rc.1 release](https://github.com/Pixelsprout/rocco-engine/releases/tag/v0.6.0-rc.1):

| Bundle | URL |
|---|---|
| platform | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/platform-DovzqwbAVit5yFpSzvKzqgwS8dpakvq2mdQJH3qcAHkb.tar.zst |
| linalg | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/linalg-4N62Pw77Sky6ba8RiBfvULjHuAQeQiqHbUor7qSeor7F.tar.zst |
| mesh | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/mesh-5Fmg6uFHADmSBmZxNWDg25VStK6mU7YqhkWEXHjMEGNP.tar.zst |
| ui | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/ui-5msrKWjNRwuEBomX2R1CBFRycCCjrQCPjhEvJXtwWbU6.tar.zst |

To move to a new rocco release, copy the URLs and the nightly from its
release notes into the header and this table.

Kula loads its meshes in packs. See Levels and Themes.

### Against a local rocco-engine

To run Kula on engine changes that are not released, use a rocco-engine
checkout. Build its sokol libraries once, as its `README.md` says. Then:

```sh
scripts/local.sh on
roc main.roc
scripts/local.sh off
```

`scripts/local.sh on` saves the header to `.header.url` and points `pf`,
`linalg`, `mesh` and `ui` at `../rocco-engine`. Set `ROCCO_DIR` to use a
different checkout. `scripts/local.sh on` then builds the debug host and
inputs there.
`scripts/local.sh off` puts the saved header back.

A header with a local path must not be committed. `scripts/local.sh on`
enables `.githooks/pre-commit`, which stops such a commit. To enable the
hook in a new clone, run `git config core.hooksPath .githooks`. CI runs the
same check with `scripts/check-header.sh`.

### CI

`.github/workflows/ci.yml` runs on macOS arm64, Ubuntu and Windows with only
Roc installed. It checks the header, then runs `roc fmt --check`, `roc check`,
`roc test` and 30 frames of `roc main.roc` against the bundle URLs. A
`scripts` job on Ubuntu runs the tests of `scripts/convert_level.py`.

## Controls

| Input | Action |
|---|---|
| Up, held | Roll forward, one cell after another |
| Left | Turn 90° left |
| Right | Turn 90° right |
| Space | Jump in place |
| Up and Space | Jump forward |
| Space during a roll | Jump forward |
| Escape | Quit |
| Pad DpadUp, or the left stick more than half way up, held | Roll forward, as Up |
| Pad DpadLeft | Turn 90° left |
| Pad DpadRight | Turn 90° right |
| Pad South | Jump, as Space |
| Pad Start | Quit |

Left, Right and Space act on the press. Hold Up to keep rolling. Escape
quits at any time. The pad buttons act the same way, on any connected pad. The controls are tank controls: they are relative to the
ball, not to the screen.

A move starts only when the ball is still and not turning. Two moves also
accept input:

- During a floor roll, Space starts a forward jump. During an edge roll,
  Space starts a forward jump until the ball reaches the edge.
- During a jump in place, Left and Right turn the ball.

A Left or Right press during a turn waits. The next turn starts when the
current one ends.

## Words

| Word | Meaning |
|---|---|
| Cell | An integer grid position `{ x, y, z }`. One block fills one cell. |
| Axis | A cell with one component of 1 or -1. `up` and `forward` are axes. |
| Pose | `{ cell, up, forward }`. The ball is in `cell` and stands on the block at `cell - up`. |
| Up | The direction away from the face the ball stands on. Gravity points along `-up`. |
| Forward | The direction the ball rolls. It is always at right angles to `up`. |
| Right | `forward × up`. |
| Face | One side of a block that touches an empty cell. Only faces draw. |
| Commit | A move sets the new pose when it starts. The ball then moves to that pose over the time of the move. |
| Open end | A block with no block to its left or right, as the ball sees it. Only an open end lets the ball roll over the edge. |
| Phase | `Playing`, `Cleared`, `Starting` or `Won`. `Cleared` waits for the next Theme to load. In `Starting`, the ball waits before the next level plays. |
| Theme | The look of one level: a pack of a textured face and a sky, a sun and its lights. |

## Moves

All moves are on the grid. The ball does not start a new move until the
current one ends, except for the cases in Controls.

If Up is held when a roll or a jump ends, the next roll starts at once. The
ball does not stop at the cell.

### Roll

The ball tests three cases in this order:

1. **Climb.** A block is in the cell ahead. The ball stays in its cell and
   turns onto that block's face. The new up is the old `-forward`. The new
   forward is the old up. Time: 0.28 s.
2. **Floor.** A block is ahead and one cell down. The ball moves one cell
   forward. Time: 0.26 s.
3. **Edge.** No block is ahead. The ball rolls over the edge onto the side
   of the block it stands on. The new up is the old forward. The new
   forward is the old `-up`. Time: 0.34 s.

The edge roll needs an open end. If a block is to the left or right of the
block the ball stands on, the ball does not move.

### Turn

Left and Right turn the ball 90° about up. The cell does not change.
Time: 0.32 s.

### Jump

A jump takes 0.54 s and rises half a cell. There are two kinds.

**Jump in place.** Space while the ball is still and Up is not held. The
ball rises and lands on the same cell. Left and Right turn the ball in the
air. The turn can last longer than the jump. A block above the ball bounces
the jump: the ball does not move.

**Forward jump.** Space while Up is held, Space during a floor roll, or
Space during an edge roll before the ball reaches the edge. The jump aims
two cells ahead, at the same level. During a roll, the jump starts at once
from where the ball is. It aims two cells past the cell the ball is nearest
to. No input acts during a forward jump.

- If a block is above the ball, or in either of the two cells ahead, the
  jump bounces. A still ball does not move. A rolling ball rolls on.
- If a block is under the landing cell, the ball lands there.
- If no block is under the landing cell, the ball falls.

A climb, a turn or an edge roll past the edge cannot start a jump. A jump
never lands on top of the block ahead. To get onto a wall, roll into it.

The ball can land only in the last 11 of the jump's 27 frames. On level
ground it lands when the jump ends.

### Fall and restart

A fall drops the ball three cells along `-up` over 0.5 s. When the fall
ends, the level restarts: the ball goes back to the start, the keys come
back and the exit closes. The fall also costs points. See Score.

## Keys and the exit

- A key sits on one face of a block. It spins and bobs above the face.
- The ball collects a key when the ball centre comes within 0.35 cell of the
  key centre, as in the original. The test runs every step in `Playing`, so
  a key collects in the middle of a roll or a jump. A collected key
  disappears.
- A forward jump passes too high over a key on the floor of the cell it
  jumps over, so that key stays. See `SPEC.md`, Items.
- The exit is a block. It is open when the ball has collected every key.
  An open exit draws brighter than a closed one.
- When the ball moves onto the face of the open exit of level 1 or 2, the
  phase changes to `Cleared`. The next level starts. See Levels and Themes.
- When the ball moves onto the face of the open exit of level 3, the phase
  changes to `Won`. The ball finishes its move and stops. The ball changes
  colour.
- In `Won`, every input except Escape does nothing.
- A closed exit does nothing. The ball can roll over it.
- A panel at the bottom left shows the keys collected out of the level's
  total, such as `Keys 1 / 2`. It shows in every phase.

## Coins

- A coin is a bronze disc on one face of a block. It spins and bobs like a
  key, 20 units (0.04 cell) higher.
- The ball collects a coin when the ball centre comes within 0.37 cell of
  the coin centre. The coin adds 250 to the level score and plays a chime.
- A forward jump collects a coin on the floor of the cell it jumps over only
  when the coin is near the top of its bob. See `SPEC.md`, Items.
- A fall brings back every coin of the level.

## Fruit

Kula copies the original's five fruits: apple, watermelon, pumpkin, banana
and strawberry. See `SPEC.md`, Items.

- A level entry `fruit` shows the first fruit not yet collected, in that
  order. A new game shows an apple on the first level with a fruit, then a
  watermelon, then a pumpkin.
- A fruit spins slowly, tilts and bobs. The ball collects it when the ball
  centre comes within 0.40 cell of the fruit centre. The fruit adds 2500
  to the level score and plays a jingle.
- The exit keeps the fruit collected. A fall loses the fruit collected
  since the last exit.
- A panel at the bottom right shows the fruit collected out of five, such
  as `Fruit 1 / 5`.
- Kula has no bonus level, so five fruits do nothing more.

## Score

Kula copies the original's two scores. See `SPEC.md`, Score.

- The level score holds the points of the current try at the level. A key
  adds 1000, a coin 250 and a fruit 2500.
- The exit adds the level score to the total score and sets the level score
  to 0.
- A fall takes the level score and a penalty off the total score. The
  penalty is 50 times the level number, at most 5000.
- The total score does not go below 0. Kula has no game over and no lives.
- A panel at the bottom shows `Level n` over `Score n`, 30% of the way
  across the window, where the original draws its scores.

## Level clock

Kula copies the original's level clock. See `SPEC.md`, Level clock.

- Each level starts with the time of its `time n` line, or 99 s without one.
- The clock counts whole steps down. It runs only in `Playing`, so it stops
  at the exit and in the `Starting` pause.
- At 0 the level restarts, the same as a fall, and the fall's penalty comes
  off the total score.
- A restart sets the clock back to the start time.
- At 50 s or less, a panel at the top centre shows `Time n`. Its text fades
  in from black. As in the original, `n` is 1 more than the whole seconds
  left, so the panel reads `Time 1` in the last second.
- In the last 20 s, a tick plays each time `n` drops, louder each time.

## Levels and Themes

`Theme.roc` holds one Theme for each level:

| Level | File | Original | Theme |
|---|---|---|---|
| 1 | `levels/level1.txt` | Hiro level 1 | `haze` |
| 2 | `levels/level2.txt` | Hiro level 2 | `haze` |
| 3 | `levels/level3.txt` | Hiro level 3 | `haze` |

The original has one look for each world, so all three levels use one
Theme. No level uses the `inca` and `arctic` Themes yet. They wait for
levels from other worlds.

Each Theme is also a pack name. The pack of Theme `<theme>` holds
`<theme>_face` and `sky/<theme>`. The face texture
carries the Theme's colour. The sun is painted in the sky where the Theme's
sun light comes from.

1. `init` sends Load for the `kula` pack and Load for the level 1 Theme.
   The `kula` pack holds `ball`, `coin`, `apple`, `watermelon`, `pumpkin`,
   `sound/bounce`, `sound/chime`, `sound/tick` and `sound/jingle`, which
   every level uses.
   It never unloads.
2. When the ball clears a level before the last, Kula sends Load for the
   next level's Theme.
3. When the host calls `loaded` for that pack, Kula takes its mesh ids and
   starts the next level. The ball stays still for 1 s, the `Starting` phase.
4. The next step sends Unload for the old Theme.

If the next level has the same Theme, Kula sends no Load and no Unload,
because the host ignores a Load for a pack that is already loaded. The
step after the exit starts the next level with the Theme's ids, and the
`Starting` pause follows. Levels 1 to 3 take this path.

A fall restarts the level the ball is on, not level 1.

## Level files

A level is a text file in `levels/`. It holds layers of the grid, bottom
layer first. A blank line separates two layers.

- The layer index is `y`.
- The row index in a layer is `z`. The first row is `z = 0`.
- The column index in a row is `x`.
- Every row in the file must have the same length.

| Character | Meaning |
|---|---|
| `.` | Empty |
| `#` | A block |
| `S` | A block. The ball starts on top of it, facing `-z`. |
| `K` | A block with a key on top |
| `E` | The exit block |

A line with a space is an entry. An entry puts an item or the start on any
face of a block. Entries come after the last layer, one on each line:

| Entry | Meaning |
|---|---|
| `x y z face item` | Item `key`, `coin`, `fruit` or `exit` on face `face` of the block at `x y z` |
| `start x y z face forward` | The ball starts on face `face` of the block at `x y z`, facing `forward` |
| `time n` | The level clock starts at `n` seconds, 1 or more. At most one line. Without it, the clock starts at 99 s |

A face or a forward is `+x`, `-x`, `+y`, `-y`, `+z` or `-z`. The forward
must be at right angles to the face. The block must be in the grid. `K` and
`E` are shortcuts for an entry on the `+y` face. `S` is a shortcut for
`start x y z +y -z`.

A level needs exactly one start, from `S` or from an entry. A level that
does not parse stops the game with the parse error when that level starts.

### Convert a level from the original

`scripts/convert_level.py` reads a Hiro level of Roll Away, the USA
release, from your own disc image and writes it in this format. It needs
only Python 3. The image must be one MODE2/2352 track (`.bin`). Kula does
not ship any disc data.

```sh
python3 scripts/convert_level.py DISC.bin 1 --list
python3 scripts/convert_level.py DISC.bin 1 -o levels/level1.txt
```

`--list` prints every block type, record type and object of the level, with
counts. Without `--list`, the script stops if the level uses a feature that
Kula cannot show, and it names each one. The script turns the original
`(x, y, z)` to Kula's `(x, -z, y)`. The original's `-z` is the up of the
Hiro start face, so it becomes Kula's `+y`. The turn keeps right-handed
axes, so the level is not mirrored. The script moves the lowest block to 0
on each axis. If the level's start time is not 99 s, the script writes a
`time n` line.

The script writes `coin` for a bronze coin. It stops on a gold or a silver
coin. It writes `fruit` for any fruit, because the game shows the first
fruit not yet collected, whatever fruit the level stores.

`python3 -m unittest discover -s scripts` tests the script on a synthetic
disc image.

### Example: level1

`levels/level1.txt` is Hiro level 1. It has one layer, a ring of 4 × 7
blocks round two holes:

```text
####
#..#
#..#
####
#..#
#..#
####

0 0 4 +y coin
3 0 1 +y coin
0 0 0 +y exit
3 0 6 +y fruit
3 0 3 +y key
start 0 0 6 +y -z
```

The route that collects every item:

1. Roll from the start along `-z` over the first coin to the middle row.
2. Turn right and roll along the middle row to the key.
3. Turn right and roll to the fruit.
4. Turn about and roll along the right column, over the second coin, to
   the far row.
5. Turn left and roll to the exit.

## Meshes and skies

The blocks draw as faces, not as whole cubes. The camera can then sit inside
a block, as in the original, and still see the ball. Keys are primitive
cubes. A banana and a strawberry are tinted primitive spheres, because
Kula's levels never show them.

| File | What it is |
|---|---|
| `assets/meshes/<theme>_face.glb` | A 1 × 1 quad facing +y, one-sided, with the Theme's texture |
| `assets/meshes/ball.glb` | A sphere of diameter 1 with eight white and red wedges |
| `assets/meshes/coin.glb` | A bronze metal disc 0.4 wide, with a raised rim and a bevelled edge. It stands on its edge, with its faces along ±z |
| `assets/meshes/apple.glb` | A red apple 0.39 wide with a stem and a leaf |
| `assets/meshes/watermelon.glb` | A striped watermelon 0.48 long, lying along ±z |
| `assets/meshes/pumpkin.glb` | A ribbed orange pumpkin 0.44 wide with a stem |
| `assets/sky/<theme>/` | Six PNG cube faces of the Theme's sky |

`assets/source/make_meshes.py` builds the meshes and their textures.
`assets/source/make_skies.py` renders the skies. Each Theme in a script
uses the same name and sun direction as in `Theme.roc`. Run both with
Blender from this directory:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_meshes.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_skies.py
```

Names after `--` build only those meshes, for example `-- coin`. Each
fruit mesh has one material and one base colour texture, as the engine
allows. Its origin is the fruit's centre. Commit the scripts and their
outputs. The build does not run Blender.

## Sound

The ball bounces with a short thud when it lands from a forward jump or
from a fall onto a block. A jump in place, a roll and a fall off the level
make no sound. As in the original, the ball is silent when the player has
no control, so a landing in `Cleared` or `Won` makes no sound. Kula has no
transporters yet; a landing after one must stay silent too.

`step` returns `Sound.play` with the bounce's Sound id in the step the ball
lands. `Ball.landed` decides the landing. It returns one `Sound.play` with
the chime's Sound id for each coin the step collects, and one with the
jingle's Sound id for each fruit.

In the last 20 s of the level clock, `step` returns a `Play` of the tick
with a gain that rises as the time runs out. See Level clock.

| File | What it is |
|---|---|
| `assets/sound/bounce.wav` | The bounce, 0.2 s of 16-bit mono at 48 kHz |
| `assets/sound/chime.wav` | The coin chime, 0.35 s: two bright notes a fifth apart |
| `assets/sound/tick.wav` | The clock tick, 0.06 s of 16-bit mono at 48 kHz |
| `assets/sound/jingle.wav` | The fruit jingle, 0.6 s: four soft notes up a major chord |

`assets/source/make_sounds.py` synthesizes them with the Python standard
library. It does not copy the original's sounds. Run it from this directory
and commit its output:

```sh
python3 assets/source/make_sounds.py
```

## Credits

Level layouts from Roll Away / Kula World (Game Design Sweden, 1998).
