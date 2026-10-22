# Kula

A clone of Kula World (PS1, 1998) on the rocco engine. A ball rolls over a
grid of blocks. Gravity turns when the ball rolls over an edge. Collect
every key, then roll into the exit. Three levels follow one another, each
in its own Theme.

`SPEC.md` holds the original's numbers and says which of them this clone
copies.

## Run

Kula needs only Roc. Install the Roc nightly `nightly-2026-10-11-7d256b9`.
The v0.3.0 release built the bundles with it. Then, from this directory:

```sh
roc main.roc
roc test main.roc
```

Roc downloads the platform and the packages from the bundle URLs in the
`main.roc` header. They come from the
[rocco v0.3.0 release](https://github.com/Pixelsprout/rocco-engine/releases/tag/v0.3.0):

| Bundle | URL |
|---|---|
| platform | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.3.0/platform-CVfyXJcNgi6CL3vEUUGgQBh4j1swttiRsjt9wZNFKBj7.tar.zst |
| linalg | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.3.0/linalg-C1juJZYY4R86QntuhBGakmnPKb77MpBxngEYNg2976wK.tar.zst |
| mesh | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.3.0/mesh-5kHC5kD57HyJDDYnvD3g3GLMoep5Jchc67kv8kUdcrYD.tar.zst |
| ui | https://github.com/Pixelsprout/rocco-engine/releases/download/v0.3.0/ui-A9KQX4wyuzV5ZtJQz5RWwAKDRy42e6mMCirmkBucgLcz.tar.zst |

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
`roc test` and 30 frames of `roc main.roc` against the bundle URLs.

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

Left, Right and Space act on the press. Hold Up to keep rolling. Escape
quits at any time. The controls are tank controls: they are relative to the
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
back and the exit closes.

## Keys and the exit

- A key sits on the top face of a block. The ball collects it when a move
  into its cell commits. A collected key disappears.
- The exit is a block. It is open when the ball has collected every key.
  An open exit draws brighter than a closed one.
- When the ball enters the cell above the open exit of level 1 or 2, the
  phase changes to `Cleared`. The next level starts. See Levels and Themes.
- When the ball enters the cell above the open exit of level 3, the phase
  changes to `Won`. The ball finishes its move and stops. The ball changes
  colour.
- In `Won`, every input except Escape does nothing.
- A closed exit does nothing. The ball can roll over it.
- A panel at the top-left shows the keys collected out of the level's
  total, such as `Keys 1 / 2`. It shows in every phase.

## Levels and Themes

`Theme.roc` holds one Theme for each level:

| Level | File | Theme |
|---|---|---|
| 1 | `levels/level1.txt` | `haze` |
| 2 | `levels/level2.txt` | `inca` |
| 3 | `levels/level3.txt` | `arctic` |

Each Theme is also a pack name. The pack of Theme `<theme>` holds
`<theme>_face` and `sky/<theme>`. The face texture
carries the Theme's colour. The sun is painted in the sky where the Theme's
sun light comes from.

1. `init` sends Load for the `kula` pack and Load for the level 1 Theme.
   The `kula` pack holds `ball` and `sound/bounce`, which every level uses.
   It never unloads.
2. When the ball clears a level before the last, Kula sends Load for the
   next level's Theme.
3. When the host calls `loaded` for that pack, Kula takes its mesh ids and
   starts the next level. The ball stays still for 1 s, the `Starting` phase.
4. The next step sends Unload for the old Theme.

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

A level needs exactly one `S`. A level that does not parse stops the game
with the parse error when that level starts.

### Example: level1

`levels/level1.txt` is one column wide. It has two layers:

```text
E        .
#        .
#        .
.        .
#        .
#        K
#        #
K        .
#        .
S        .
```

The left column is layer 0 and the right column is layer 1. In the file,
layer 1 comes after layer 0 and a blank line. The route:

1. Roll from `S` along `-z` over the first key.
2. Climb the wall of layer 1 and roll onto its top.
3. Collect the second key. Roll over the far edge onto the side of the
   block.
4. Climb back onto layer 0.
5. Jump the gap.
6. Roll on to the exit.

## Meshes and skies

The blocks draw as faces, not as whole cubes. The camera can then sit inside
a block, as in the original, and still see the ball. Keys are primitive
cubes.

| File | What it is |
|---|---|
| `assets/meshes/<theme>_face.glb` | A 1 × 1 quad facing +y, one-sided, with the Theme's texture |
| `assets/meshes/ball.glb` | A sphere of diameter 1 with eight white and red wedges |
| `assets/sky/<theme>/` | Six PNG cube faces of the Theme's sky |

`assets/source/make_meshes.py` builds the meshes and their textures.
`assets/source/make_skies.py` renders the skies. Each Theme in a script
uses the same name and sun direction as in `Theme.roc`. Run both with
Blender from this directory:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_meshes.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python assets/source/make_skies.py
```

Commit the scripts and their outputs. The build does not run Blender.

## Sound

The ball bounces with a short thud when it lands from a forward jump or
from a fall onto a block. A jump in place, a roll and a fall off the level
make no sound. As in the original, the ball is silent when the player has
no control, so a landing in `Cleared` or `Won` makes no sound. Kula has no
transporters yet; a landing after one must stay silent too.

`step` returns `Sound.play` with the bounce's Sound id in the step the ball
lands. `Ball.landed` decides the landing.

| File | What it is |
|---|---|
| `assets/sound/bounce.wav` | The bounce, 0.2 s of 16-bit mono at 48 kHz |

`assets/source/make_sounds.py` synthesizes it with the Python standard
library. It does not copy the original's sound. Run it from this directory
and commit its output:

```sh
python3 assets/source/make_sounds.py
```
