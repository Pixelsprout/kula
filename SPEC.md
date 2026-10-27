# Kula behaviour spec

This file states how the original Kula World (PAL, SCES-01000) moves the
ball, places the camera and draws blocks. It also states what this clone
copies. Each fact has a label:

- **Code**: read in the decompilation, `github.com/dezgeg/kula-world-decomp`
  at commit `2ca79ff`. Paths below are in that repository.
- **Reported**: a third party states it. Nobody checked it in code.
- **Inferred**: derived from Code facts.

## Units

The original uses 512 units for one block and 4096 for a full turn. The
game logic runs once per video frame, at 50 frames per second on PAL. This
clone uses cells, radians and seconds. One PAL frame is 0.02 s.

## Ball

| Fact | Original | Label | Clone |
|---|---|---|---|
| Radius | 100 units, 0.195 cell | Code: the ball centre rests 100 units above a face | `Ball.radius = 0.195` |
| Visual radius | Not found | | Same as the collision radius |
| Spin | A rate, `rotX`. Each frame turns the ball `rotX` × 6/4096 of a turn about its right axis. A roll sets `rotX` to the roll speed. A forward jump sets 40, the top roll speed. A jump in place sets 0. A fall adds 6 a frame, up to 40, while Up is held. Otherwise it takes 1 away a frame, down to 0 (`player_movement.c:204, 316, 414-424, 456`) | Code | A roll: the distance the centre travels over the radius. A forward jump: the top roll rate, 1 cell per 0.26 s over the radius. A jump in place: no spin. A fall keeps the top rate in the arc. In the drop, Up held adds to the rate, up to the top in 0.13 s. Without Up, the spin stops in 0.8 s |

The ball centre is 0.195 cell above the face it stands on. The draw centre
is the cell centre minus 0.305 along up.

`RotMatrixX` multiplies the matrix it gets. The original sets `matrix_254`
only at level start and then turns it by `rotX` every frame. `rotX` is
therefore a rate, not an angle (Inferred). At the top rate the original
turns 0.37 rad a frame. The clone turns 0.39 rad a frame, the rate that
rolls without slip. The spin carries on from one move to the next.

The original reads Up for the fall through `rollingForward`. Each frame
clears it, then sets it when Up is held (`level_update2.c:610, 686`, Code).
The clone reads Up in the same step.

### Idle bob

The original squashes and stretches the ball about its up axis
(`SetBallShapeAndRotationWhenRollingOrIdle`, `src/player_movement.c:1252-1272`,
Code). It keeps a phase in 4096ths of a turn. Each frame it adds
`(100 * FPS - levelTimeLeft) / 40 + 40` to the phase. `levelTimeLeft` counts
PAL frames. The bob amount `s` is `rsin(phase) * 200 / 4096`, from -200 to 200.

`ballMorphMatrix` scales by `4096 + s` across up and `4096 - 2s` along up
(`:999-1001`, Code). It acts in the ball's frame, after the spin
(`:1025-1027`). Column 2 of `matrix_234` is minus `gravityDir`, and
`gravityDir` is the ball's up (`:953-955`, Code). The edge roll sets
`gravityDir` to the old forward (`:585`), so the name does not mean down.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Amount | ±4.9% across up, ∓9.8% along up | Code | Same. `View.ball_draw` scales by 1 + s across up and 1 - 2s along up |
| Volume | Nearly constant: (1 + a)²(1 - 2a) ≈ 1 | Inferred | Same |
| Floor contact | The draw centre moves `-200s / 4096` units along up, up to 0.019 cell. The bottom stays on the floor (`:1042-1044`) | Code | Same: the draw centre drops by 2s × radius. The camera follows the centre without the bob |
| Phase step | 165 - 1.25 × seconds left, in 4096ths of a turn a frame | Inferred | `Ball.bob_rate` |
| Period | 2.05 s with 100 s left, 0.91 s with 60 s, 0.64 s with 30 s, 0.50 s at 0 | Inferred | 2.05 s, the rate for 100 s left, whatever the level clock shows |
| Clock changes | The phase carries on, so a rate change has no jump. A Timer pause face stops the clock and holds the rate (`SubtractLevelTimer`). An hourglass flips the time left and changes the rate at once (`level_update3.c:311`) | Code | The clone has a level clock (see Level clock), but the bob does not read it yet. The rate does not change |
| When it runs | Every frame except in a forward jump (`:930-934`). It also stops while `turningWhere` is not 0: each frame of the edge wrap, and one frame as a turn or a climb starts | Code | Every step except a forward jump, the arc of a fall and the edge wrap. A turn or a climb does not stop it |
| In a forward jump | The shape holds its last value. The jump stretch acts through `flattenFactor` | Code | The bob phase holds |
| Landing squish | Adds to `s`. While it runs, the phase stops and the bob holds its value | Code | Same. See Landing squish |

The ball's `rot` is its spin. The clone sets the Draw's `scale_rot` so the
scale acts along up whatever the spin (rocco-engine `docs/adr/0002-a-scale-acts-along-its-own-axes.md`).

### Landing squish

Each touch-down on a block starts a 4-frame squish (Code):
`CheckIfPlayerLanded` (`src/player_movement.c:798-803`), the end of a jump
in place (`:497-500`) and a moving platform (`SetLandingSquishVars`,
`src/level_update.c:306, 365`). `SetBallShapeAndRotationWhenRollingOrIdle`
(`:1254-1271`) adds the squish to the bob amount `s`, so it acts through
`ballMorphMatrix` like the bob.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Rise | Up by 187 a frame for 4 frames, to 748/4096 (`:1254-1257`) | Code | Same, linear between frames. At the peak the ball is 18% wider across up and 37% shorter along up |
| Fall | The step down starts at 90 and drops by 10 a frame, down to 20 (`:1258-1266`). The squish is 0 at frame 27 | Code | Same. `Ball.squash` is 0 from 0.54 s after the contact |
| Contact frame | The landing sets the counter before the draw of the same frame, so the contact frame shows 187 | Inferred | The contact step shows 187/4096 |
| Bob | The phase stops and the bob amount holds while the squish runs (`:1258-1270`) | Code | The bob phase holds until the squish ends |
| New landing | A new touch-down starts the squish again from 0 | Code | Same |
| Which landings | A forward jump, a fall, a jump in place, a bounce and a moving platform | Code | All but the moving platform, which Kula does not have |

## Moves

The clone moves on a grid. The pose commits when a move starts. A move then
plays out over its duration.

### Roll

The ball tests three cases in this order (`src/player_movement.c`,
`src/level_update.c`, Code):

1. **Climb.** A block is directly ahead. The ball stays in its cell. New up
   is minus old forward. New forward is old up.
2. **Floor.** A block is ahead and below. The ball moves one cell forward.
3. **Edge.** Otherwise the ball rolls over the edge onto the side of the
   block it stands on. New up is old forward. New forward is minus old up.

The edge roll needs an open end. If a block sits to the left or the right
of the block the ball stands on, the ball does not roll (Code,
`HandleViewportRotationStart`). The speedrun notes on
speeddemosarchive.com report the same rule.

| Move | Original | Label | Clone |
|---|---|---|---|
| Floor roll | Speeds up by 7 units a frame to 40 units a frame | Code | 0.26 s, the time for one cell at top speed |
| Climb | The camera turns 90° in 14 frames. The ball does not move | Code | 0.28 s |
| Edge roll | The ball wraps the edge in 4 frames. The camera turns 90° in 11 frames | Code | 0.34 s: half a cell at top speed, the wrap, half a cell (inferred) |
| Turn | 90° in 16 frames, linear | Code | 0.32 s |

Round an edge, the original moves the ball centre on a fixed arc. Each of
the 4 frames steps (up, forward) by (38, 8), (32, 22), (22, 32), (8, 39)
units, about one radius in all (Code, `ProcessMovement` case `ROTATING`).
The clone moves the centre half a cell to the edge, a quarter circle of one
radius about the edge line, then half a cell down the side. The ball never
enters the block.

The original stops the ball at a cell centre when forward is not held. The
clone has no speed-up.

### Jump

The original has two kinds of jump, chosen when the jump starts
(`StartMovementIfNeeded`, `src/player_movement.c:125-188`, Code). The
buttons are read every frame (`HandlePlayerButtons`, `src/level_update2.c`).

- **Forward jump.** X while Up is held, or X while the ball rolls.
- **Jump in place.** X while the ball is still and Up is not held.

Speed does not change the kind. No input acts during a forward jump. During
a jump in place, L and R still turn the ball.

The ball stays in the rolling state until it reaches the edge of its block
(`HandleViewportRotationStart`, Code). Only then does the edge turn start.
X can therefore start a forward jump on the way to an edge.

A turn press during a turn waits. The next turn starts when the current one
ends (`startTurningLeftNextFrame`, `HandlePlayerButtons`, Code). The clone
copies this for every turn.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Choice of kind | Forward when Up is held or the ball rolls; in place otherwise | Code | Same. A floor roll, or an edge roll before the ball reaches the edge, can start a jump. Climbs and turns cannot |
| Forward distance | 1024 units, two cells ahead at the same level (`player_movement.c:391`) | Code | Same |
| Start of a rolling jump | At once, from the ball's current position. Only the sideways offset snaps to the cell centre (`AutoAlignJumpStartPos`) | Code | At once, from the ball's current position. The ball lands two cells past the cell it is nearest to. On the way to an edge, that is the cell the ball rolls from. The clone's ball is always on the cell line, so it has no sideways snap |
| Jump in place | Same curve with only the vertical part. Lands on the same cell (`ProcessMovement`, `JUMPING_INPLACE`) | Code | `JumpingInPlace`: same duration and peak as the forward jump |
| Turn in mid-air | Forward jump: no input acts. Jump in place: L and R still turn the ball | Code | Same. The turn takes 0.32 s and can outlast the jump |
| No floor there | The jump ends, then the ball falls straight down. Gravity adds 6 units a frame to the fall speed, up to 80. It lands on the first block below (`CheckIfPlayerLanded`). The level ends only when the ball leaves the grid, -1 to 35 on each axis (`ProcessEnemiesRenderItemsAndCheckFellOff`) | Code | `Falling`: the jump arc, then a drop at 29.3 cells/s², up to 7.8 cells/s. The drop starts at the arc's end speed. It lands on the first block below. With no block below, the level restarts 2 cells past the lowest block along gravity |
| A block in the path | Forward jump only. Past 412/512 of its cell, a block ahead at the ball's height bounces it back and it falls (`CheckForPlayerWallHit`) | Code | Forward jump only, for a block one or two cells ahead. See Bounce |
| A block above | Both kinds. A rising ball at height 412 or more under a block bounces down and falls (`CheckPlayerHitCeiling`) | Code | Both kinds, for a block above the cell the jump starts from. See Bounce |
| Landing window | The last 11 frames of the jump can land (`CheckPlayerJumpingStuff`) | Code | Same (`Ball.can_land`, t >= 16/27). The ball lands when its centre is at or below rest height over a floor. On level ground this is the end of the jump |
| After landing | Up held keeps the ball rolling at full speed (`CheckIfPlayerLanded`) | Code | Same. With Up held, the next roll starts in the step the jump lands and gets the time left over. A roll that ends with Up held does the same |
| Duration | 27 frames | Reported, wiki.kula.quest. The frame count is in GGI data (`ggiPart5JumpAnimData`), not in the C code | 0.54 s |
| Peak height | In GGI data. The Roll Away (US) jump in `HIRO.GGI` peaks 458 units above rest | Inferred, from the disc's GGI data | 0.5 cell |

A jump never lands on top of the block ahead. The only way onto a wall is
to roll into it.

### Bounce

A wall hit or a ceiling hit turns the jump into a fall
(`src/player_movement.c`, Code). The ball then lands as from any fall.
The clone keeps its grid: it lands on a cell centre.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Wall contact | When the ball centre is 412 of 512 units into its cell and a block is ahead at the ball's height (`CheckForPlayerWallHit`, `:662-712`) | Code | When the centre is one radius short of the wall face: 0.082 s into the jump for a wall one ahead, 0.352 s for two ahead, from a still ball |
| Wall rebound | The ball moves back by 2 frames of its forward speed (`:699-701`), then moves back at that speed. The back speed drops by 7 units a frame to 0 (`:431-436`, PAL). A ball that was rising starts to drop at 10 units a frame, else at 0 (`:703-705`). Gravity then adds 6 a frame (`:438`) | Code | Same speeds, in cells and seconds (`rebound` in `Ball.roc`) |
| Ceiling contact | When the ball centre is 412 units into its cell, 312 above rest, under a block (`CheckPlayerHitCeiling`, `:724-757`) | Code | Kula's jump peaks at 0.5 cell, under the 0.61 cell that a contact needs. The clone hits at 312/458 of its peak, as the Roll Away jump does at frame 6: 0.118 s in |
| Ceiling rebound | The ball moves down by 2 frames of its rising speed and drops at that speed. The forward motion stops (`:742-752`) | Code | Same speeds |
| Where it lands | Where the fall ends. The speeds take a ball back about to the centre of the cell before the wall | Inferred | On the centre of the cell nearest the contact, which it reaches as it lands. Off a wall one ahead or a ceiling, that is its own cell. Off a wall two ahead, the cell between. With no block under that cell, the ball falls on |
| Duration | | | From a still ball: 0.186 s for a wall one ahead, 0.528 s for two ahead, 0.197 s for a ceiling |
| Spin | The hit sets `rotX` to 0. The fall rule then adds 6 a frame while Up is held (`:707, 747, 414-424`) | Code | The spin stops at the hit. Up does not start it again |
| Input | A jump in place can turn until the ceiling hit | Code | No input acts during a bounce |

### Bounce sound

Every bounce plays `SFX_BALL_BOUNCE` (102, `include/common.h:90`) at volume
7000, not placed in 3D (Code). It starts in the frame of the contact. The
clone plays `sound/bounce` at gain 1 in the step of the contact. A blocked
jump bounces twice: at the hit and at the landing.

| Event | Original | Label | Clone |
|---|---|---|---|
| Forward jump lands | `CheckIfPlayerLanded` (`player_movement.c:764-781`), only with control, not paused and not after a transporter | Code | `Ball.landed`, only in `Playing` |
| Fall lands | The same, from the `FALLING` case of `CheckPlayerJumpingStuff` (`:626`) | Code | Same. A fall off the level is silent |
| Jump in place lands | `ProcessMovement`, `JUMPING_INPLACE` (`:495-500`). No control check | Code | `Ball.landed`, only in `Playing`. Kula has no jump in place outside `Playing` |
| Wall hit | `CheckForPlayerWallHit` (`:693`). No control check | Code | `Ball.hit`, in any phase while the level stays the same |
| Ceiling hit | `CheckPlayerHitCeiling` (`:739`). No control check | Code | Same |
| Moving platform | `HandleMovingPlatforms` (`level_update.c:276, 314`) | Code | Kula has no moving platforms |
| Roll, climb, edge roll, turn | No sound | Code | Same |

### Long jump

The long jump is not a button combination (Code):

- The Bouncy pill (`OBJ_BOUNCY_PILL`, `src/level_update3.c:184`) makes the
  ball jump all the time for 14 s. While it acts, Up and X held for more
  than 3 frames start a long jump (`level_update2.c`).
- A bounce pad (`OBJ_BOUNCEPAD`, `level_update3.c:1076-1093`) forces a long
  jump.
- A long jump scales the jump curve by 3/2. It lands 1536 units, three
  cells, ahead (`player_movement.c:371-389`).
- A wall hit, a ceiling hit or a landing ends it.

## Camera

The camera is rigid in the ball's frame (`HandlePlayerMovementStuff`,
`src/level_update.c`, Code):

- The camera basis is the ball's right, up and forward, pitched down by
  250/4096 of a turn, 21.97°.
- In view space the ball centre sits 250 units below the screen centre at a
  depth of 800 units.
- The camera has no smoothing and no collision test.

Inferred from these: the eye is 1.27 cells behind the ball centre and 1.04
cells above it. The clone builds the eye from the same view-space numbers.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Vertical field of view | 73.7° on 4:3 | Inferred from a projection distance of 160 on a 320-pixel screen | 1.286 rad |
| Smoothing | None | Code | None |
| Turn during a climb or edge roll | Linear in angle | Code | Normalised lerp of up and forward |
| Look up and look down | R1 and R2 | Code | Not copied yet |

After a climb, the eye sits inside the floor block the ball left (Inferred).
The next section explains why that floor does not hide the ball.

## Blocks

At level load, the original builds one quad for each block face. It skips a
face when the neighbour cell holds a solid block (`ProcessCubesIntoFaces`,
`src/level_init.c`, Code). Faces carry a flag that the decompiler marks as
back-face culling, with a question mark.

The clone draws each exposed face as its Theme's face mesh, a one-sided
quad like the primitive plane with a bordered texture. The engine culls
back faces. A camera inside a block therefore sees through that block,
because every face of it points away. No face exists between two blocks, so the neighbours do
not hide the ball.

Halfway through a climb, the eye passes down through the top face of the
floor the ball left. Just before that, the engine's near plane cuts that
floor inside the screen, and a hole shows. The original's near-polygon code
(`SubdivideLevelGeometryPolys`) is still assembly, so its behaviour is not
known.

The clone hides a face only when the near plane cuts it inside the screen
(`View.cut_by_near_plane`). Two conditions must both be true:

- The face is within 0.2 cell of the eye. The corners of the near plane's
  window are 0.183 cell from the eye, with the engine's near plane at 0.1
  and a 16:9 screen.
- The face's plane passes through that window.

In a climb at the level1 wall, this hides the old floor for about 2 ms.
A face that crosses the near plane outside the screen still draws, so the
ball's floor and the walls beside the ball do not vanish (Inferred).

A whole-cube mesh would draw the faces between blocks. Do not use one for
level blocks.

## Look

The clone keeps the original's feel: a sky, a palette and a mood for each
world. It draws them with smooth modern lighting instead of the PS1 tricks.

A **Theme** is the look of one world: a sky, a set of lights and a set of
block meshes. It is Kula game data. The engine has no Theme.
A table in Kula code maps each level to its Theme.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Background | A textured sky sphere, unlit, that turns with the camera and its gravity roll (`render1.c:86-106`, `skybox.c`). Bonus levels draw a gradient sphere | Code | A cubemap sky for each Theme. With no sky, the host clears to black |
| Block shading | No real-time lighting. Each face direction picks a fixed brightness and a Theme tint (`level_init.c:1059`, `BlockColors` in `common.h`) | Code | A Theme sun, a dim fill opposite it and an ambient, all fixed in the world. Each face direction gets its own shade |
| Ball shadow | A shadow sprite (`DrawShadowSprites`, `render1.c`) | Code | A shadow map from the Theme sun. The shadow falls away from the sun, not always below the ball |
| Sun | A sun for each world with a lens flare (`lensflare.c`) | Code | The sun is painted in the sky, in line with the Theme sun. No lens flare |
| Distance fade | Distant faces fade toward the Theme block colour (`SetFarColor`, `render1.c`) | Inferred | No fog yet |
| Ball shine | A specular sprite (`DrawPlayerSpecularSprites`, `render3.c`) | Code | A specular term from the ball's glTF material |
| Pickup flash | Each item pickup starts a light effect on the item's face and a particle that sets the light's colour each frame. The light ends with the particle (`AddLightEffect` in `level_update3.c:164-315`, `particles.c:157-160`) | Code | Each pickup starts a Point light that fades (`Flash.roc`). No particles |
| Flash colour | Each frame sums the particle's two sprites, colour × `PARTICLE_COLOR_DATA` >> 9 (`particles.c:246-271`). Key and coin use one table (type 6 and 2, `PARTICLE_TYPE_2_6_7`, PAL data at `data_particles.c:401-432`): black, then (25, 25, 45) at frame 4, held to frame 9, grey (19, 19, 19) at frame 23, black at frame 33. A fruit (type 4, `:185-217`) peaks at (41, 30, 41) and is black by frame 24 | Code (data), Inferred (sums) | Key and coin: the same five points, linear between them, 0.02 s a frame. Peak from 0.08 s to 0.18 s, gone at 0.66 s. Fruit: points at frames 0, 4, 8, 11, 13, 16, 20 and 24, within 1 PS1 unit of each frame of the table. Peak from 0.16 s to 0.22 s, gone at 0.48 s |
| Flash reach | The item's face gets weight 2 at each corner. Each face beside it gets 2 at the near edge and 0 at the far edge, 1.5 blocks out. A wall that rises at an edge takes the place of the floor there (`light_effect.c:15-144`). The asm that applies the weights is not decompiled (`asm_light_effect.c:36`) | Code (weights) | A Point light one cell above the item's face with a range of 2 cells, so it lights 1.73 cells out across the face. It falls off faster than the original: the face edge gets 0.6 of the centre's light, one cell out 0.16 (Inferred) |
| Flash strength | The light colour is in PS1 colour units, where 128 is a full vertex colour (`particles.c:246-271`) | Inferred | At its peak the face under the flash gets (0.39, 0.39, 0.70): the PS1 colour over 128, times the weight 2 (Inferred) |
| Flashes at once | 32 light effects (`light_effect.c:13`) and 16 particles (`particles.c:118`) | Code | The host draws 8 Directional and Point lights (rocco `guide/scene.md`, Lights). The Theme sun and fill take 2, so 6 flashes can overlap. Past 6, the oldest flash loses its light |
| Highlights | Not applicable | | A fixed tone map before the sRGB encode |

## Levels

| Fact | Original | Label | Clone |
|---|---|---|---|
| Level entries | An object block holds one object slot for each face, so a key, the exit or the spawn can sit on any face. The spawn face sets the ball's up and a start forward. The spawn rotation then turns the forward (`SetPlayerRotation`, `src/level_update2.c:1206`, called at `:386`) | Code | An entry puts a key, a coin, the exit or the start on any face of a block. A start entry names its forward. `scripts/convert_level.py` writes the forward of the turned spawn |
| Levels | A world holds 15 levels. The level number is `curWorld * 15 + curLevel + 1` (`memcard2.c:92`). Hiro is the first world (`LEVEL_DIRS`, `loading.c:23-35`) | Code | Levels 1 to 3 are Hiro levels 1 to 3, converted from the player's own disc image. Kula ships the level text and no other disc data |
| Look of a world | Each world has its own directory. A new world loads its TGI file, which holds the look, and its level PAK (`LEVEL_DIRS`, `loading.c:23-35`; `ReadDataFile` in `main.c:315-330`). So all levels of a world share one look | Code (load), Inferred (one look) | One Theme, `haze`, for levels 1 to 3. A level whose next level has the same Theme starts it with no Load |
| Coin and fruit entries | A coin's variant sets its score: 750, 500 or 250 (`level_update3.c:228-240`). Hiro levels 1 to 3 hold only variant 2. Level init swaps any fruit object for the first fruit not yet collected (`level_update2.c:126-144`) | Code | The converter writes `coin` for variant 2 and stops on variants 0 and 1. It writes `fruit` for any of the five fruits |

## Items

The original collects an item when the ball centre comes near the item
centre. It does not test the ball's cell or face (`HandleItemTouching`,
`src/level_update3.c:113-323`, Code). The clone copies this test for keys,
coins and fruit.

| Fact | Original | Label | Clone |
|---|---|---|---|
| When the test runs | Every frame while the player has control and the game is not paused (`level_update2.c:538-540`) | Code | Every step in `Playing`, after the ball moves (`Rules.collect`) |
| Items tested | Every item slot on the six faces of the 3 × 3 × 3 blocks round the ball (`level_update3.c:119-131`) | Code | Every pickup in the level. The reach is less than one cell, so the result is the same (Inferred) |
| Test | The squared distance from the ball centre to the item centre is below the item's `collisionDistance` + 10000 (`level_update3.c:138-144`) | Code | Same, in cells (`Pickup.touches`) |
| Reach | `collisionDistance` is 22500 for a key, 25600 for a coin and 32400 for a fruit (`level_update2.c:188, 154, 131`). With the 10000, a key reaches 180 units (0.35 cell), a coin 189 (0.37) and a fruit 206 (0.40) | Code (numbers), Inferred (roots) | Key: 0.35 cell. Coin: 0.37 cell. Fruit: 0.40 cell |
| Height above the face | The item moves out from the block centre by 386 for a key or a fruit and 406 for a coin (`level_update2.c:191, 133, 156`). The face is 256 out, so a key or a fruit is 130 units above the face and a coin 150 | Code (numbers), Inferred (face) | Key and fruit: 130 units, 0.25 cell. Coin: 150 units, 0.29 cell |
| Spin | Key and coin: -90/4096 of a turn a frame about the face normal (`level_update3.c:457-466`). Fruit: +24/4096 (`:447`) | Code | Key and coin: the same rate, 1.10 turns a second. Fruit: 0.29 turns a second the other way. The direction is not checked |
| Bob | 10 + 20 sin(phase) units along the face normal. The phase changes by -70/4096 a frame for a key or a coin (`:461-462`) and by -60/4096 for a fruit (`:449-450`) | Code | Same. A key's or a fruit's centre moves from 120 to 160 units above the face, a coin's from 140 to 180 |
| Tilt | Fruit only: up to 150/4096 of a turn about an axis in the face. Its phase changes by -80/4096 a frame (`:448, 452`) | Code | Fruit: same. `Pickup.rot` applies the tilt about the item's x axis, then the spin, so the tilt axis spins with the fruit |
| Item centre in the test | Includes the bob. The draw code writes `itemState.pos` each frame (`level_update3.c:526-529`) | Code | Same (`Pickup.centre`) |
| Start phases | Random, 0 to 4095, for the spin, tilt and bob of each item (`level_update2.c:209-214`) | Code | Spread by the golden ratio from the item's place in the level, so a restart looks the same |
| After a pickup | The slot clears and the item stops drawing (`level_update3.c:319-322`) | Code | The pickup leaves `Model.pickups` and stops drawing |
| Key look | `OBJ_KEY` (`0x1F`, `common.h:128`) draws a model from the world's GGI file, which the C code does not hold. In the Hiro file the key stands up on its face, 124 × 30 × 291 units (0.24 × 0.06 × 0.57 cell): a hexagonal shaft, one tooth at the bottom and a solid faceted diamond bow on top. It has no texture. Each face has one gold colour with the light baked in: the main colour (141, 121, 42), the brightest (255, 228, 79) | Reported | `key.glb` from `make_meshes.py`, to the same size, with its origin at the item centre: a hexagonal shaft, one tooth at the bottom and a faceted diamond bow on top. Kula's own shape, built from these numbers. The engine lights it, so a lit face changes as the key spins. In a Bridge screenshot the median key pixel is about (140, 122, 39) and the lit faces reach about (185, 168, 80) |
| Key sound | `SFX_KEY_COLLECTION` (31). The key that leaves no keys plays `SFX_LAST_KEY_COLLECTION` (114) in its place. Both at volume 7000, not placed in 3D (`level_update3.c:212-219`, `common.h:74, 101`) | Code | `sound/key`, a 0.4 s zing, and `sound/last_key`, a 1.2 s zing with a held chord, from `make_sounds.py`. Not the original's sounds. Each key a step collects counts down the keys left, and the one that leaves none plays `sound/last_key` alone |
| Coin kinds | `OBJ_COIN` (`0x25`) with variant 0, 1 or 2 (`common.h:134`, `level_update3.c:231-239`). The wiki names them gold, silver and bronze. Hiro levels 1 to 3 hold only variant 2 | Code (variants), Reported (names) | The level entry `coin` is a bronze coin. No gold or silver |
| Coin look | The model, its size and its colour are GGI data, which the C code does not hold | Code | `coin.glb` from `make_meshes.py`: a bronze disc 0.4 cell wide with a raised rim and a bevelled edge. Its material is metallic 0.4, not 1: the engine has no environment map, so a full metal draws the flat face almost black. It stands on its edge, so the spin about the face normal shows its face and then its edge. Kula's own design |
| Coin sound | `SFX_COIN_COLLECTION` at volume 7000, not placed in 3D (`level_update3.c:230`, `common.h:80`) | Code | `sound/chime`, a 0.35 s two-note chime from `make_sounds.py`. Not the original's sound. One `Sound.play` for each coin a step collects |
| Fruit kinds | `OBJ_APPLE` to `OBJ_STRAWBERRY` (`common.h:140-144`). At level start a fruit slot shows the first fruit not in `fruitsCollectedBitmask`, in the order apple, watermelon, pumpkin, banana, strawberry (`level_update2.c:126-144`). With all five collected, the slot keeps the kind the level file stores | Code | The level entry `fruit`. A level start shows the first fruit not in the fruit set, in the same order (`Fruit.next`). With all five, Kula shows a strawberry, because its level files store no kind |
| Fruit set | A pickup sets bit 1, 2, 4, 8 or 16 of `fruitsCollectedBitmask` (`level_update3.c:242-296`). An exit saves the set. A death sets it back to the saved set (`main.c:914-920`). A new game clears both (`main.c:286-287`) | Code | Same (`Fruit.Fruits`): `now` and `saved`. The exit calls `Fruit.bank` and a fall calls `Fruit.die`. A new game starts with `Fruit.none` |
| Fresh game | Hiro levels 1 to 3 each store a fruit slot, so a new game shows an apple, a watermelon and a pumpkin on them | Inferred | Same, when the Hiro levels hold `fruit` entries |
| Five fruits | An exit with all five fruits saved clears the set and goes to a bonus level (`main.c:1025-1033`). `OBJ_FRUIT_BOWL` sets all five bits at once (`level_update3.c:297-307`) | Code | Not copied. Kula has no bonus level and no fruit bowl. Five fruits stay in the set |
| Fruit look | The models, sizes and colours are GGI data, which the C code does not hold | Code | `apple.glb`, `watermelon.glb` and `pumpkin.glb` from `make_meshes.py`, each with one material and one base colour texture. The origin is the fruit's centre. Each fruit reaches at most 0.21 cell below it, so the bob and the tilt keep it off the face. A banana and a strawberry draw as tinted primitive spheres. Kula's own design |
| Fruit sound | `SFX_FRUIT_1` to `SFX_FRUIT_5`, one for each kind, at volume 7000, not placed in 3D (`level_update3.c:247-291`, `common.h:82-86`) | Code | `sound/jingle`, one 0.6 s jingle from `make_sounds.py` for every kind. Not the original's sound. One `Sound.play` for each fruit a step collects |

A pickup can happen at any point of a move: in a roll, a climb, a turn or
a jump (Inferred). In a roll onto a key's cell, the ball collects the key
about a third of a cell before the cell centre.

A forward jump passes 0.695 cell above the face of its middle cell. A key
on that face bobs at most 0.31 cell up, so the gap is at least 0.38 cell
and the key stays (Inferred). At the top of the jump, a key on a wall
beside the middle cell is at most 0.33 cell from the ball centre, so the
jump collects it (Inferred).

A coin on the face of the middle cell bobs 140 to 180 units up. The jump
reaches it only while the coin centre is more than 167 units up, in the
upper part of its bob. So the jump collects the coin for about 39% of the
coin's bob phases at the jump's start, and passes over it for the rest
(Inferred, from the clone's jump curve). The original's jump curve is GGI
data, so the original's result is not checked.

## Score

The original keeps two scores (`main.c:146, 153`, Code). `levelScore`
holds the points of the current try at a level. `totalScore` holds the
points that earlier exits banked. The original has no lives: a death costs
points, and a total below 0 ends the game (Code, `main.c:824`).

| Fact | Original | Label | Clone |
|---|---|---|---|
| Start | Both are 0 at a new game (`main.c:288-289`). `levelScore` goes back to 0 after each level end (`main.c:895`) | Code | `Score.zero` at a new game. The level score is 0 at each level start |
| Key | `levelScore += 1000` (`level_update3.c:211`) | Code | Same (`Pickup.points`) |
| Coin | `levelScore += 750`, `500` or `250` for coin variant 0, 1 or 2 (`level_update3.c:228-240`) | Code | 250 for a bronze coin, the only kind (`Pickup.points`) |
| Fruit | 2500 for a fruit (`level_update3.c:242-296`) | Code | Same (`Pickup.points`) |
| Exit | `totalScore += levelScore` (`main.c:919`) | Code | Same (`Score.bank`). The level score goes to 0 at once, so the HUD shows the banked total in `Cleared` |
| Death | `totalScore -= levelScore + penalty` (`main.c:913`). A fall and a time out are both deaths | Code | Same for a fall and a time out (`Score.die`) |
| Penalty | (world × 15 + level + 1) × 50, at most 5000 (`main.c:909-911`). `curLevel` counts from 0 (`main.c:183, 876`) | Code | Level number × 50, at most 5000. Kula's level number counts from 1, and Hiro levels 1 to 3 are world 0 (Inferred) |
| Loss on a death | The try's points never join the total, and the same amount comes off it, so a death loses them twice over | Inferred | Same |
| Below 0 | Game over. The game goes back to the first level of the world and the total to 0 (`main.c:871-884`) | Code | No game over. The total stops at 0 and the level restarts |
| Level score on screen | Counts up: each frame it closes a fifth of the gap, plus 1 (`hud.c:136-142`) | Code | Not copied. The HUD shows the level score at once |

## Level clock

The original counts the time left in a level in PAL frames, `levelTimeLeft`
(Code). The clone counts whole steps left, `Rules.Model.clock`, at the
fixed step rate `Clock.step_hz`, 120 Hz. A step count does not drift, as a
sum of `dt` would (Inferred).

| Fact | Original | Label | Clone |
|---|---|---|---|
| Start | `startTime` × 50 frames from the level settings record (type 666). Without the record, 4950 frames, 99 s (`level_update2.c:347-351`) | Code | `time n` in the level file: n × 120 steps. Without the line, 99 s (`Clock.default_seconds`). `scripts/convert_level.py` writes the line when the record does not say 99 |
| Hiro levels 1 to 3 | The settings record says 99 s | Code (`convert_level.py --list`) | No `time` line |
| Rate | `SubtractLevelTimer(1)` once a frame, at the top of `ProcessPlayer` (`level_update2.c:416`) | Code | One step a step, in `Rules.run_clock`. It runs first in the step, before the ball moves and before the pickups. At 0 it restarts the level, and the rest of that step plays on the restarted level. The original plays the rest of that frame on the old level, then ends it (Inferred) |
| When it runs | `ProcessPlayer` runs only when the game is not paused, no level end is set and the get-ready screen is not up (`main.c:581-585`) | Code | Only in `Playing`. It stops at the exit and in `Starting` |
| Timer pause face, debug flag, copycat mode | The clock does not count (`level_update3.c:1145-1158`) | Code | Not in the clone |
| At 0 | `levelEndReason = LEVEL_END_TIME_OUT` (`level_update3.c:1149-1151`). A time out is a death, the same as a fall: the same penalty and a restart of the same level (`main.c:907-914`) | Code | The level restarts with `Score.die` in the step the clock reaches 0, the same as a fall. No time-out screen |
| After a restart | `LevelInit` sets the clock again (`level_update2.c:347-351`) | Code (`LevelInit`), Inferred (that a restart runs it) | The clock goes back to the start time |
| Shown seconds | `1 + levelTimeLeft / 50`, two digits (`hud.c:270`) | Code | `Clock.shown`: 1 + steps left / 120. It reads 1 in the last second |
| Time panel | The digits show only at 50 s or less. Their colour goes from 0 at 50 s to `(50 - secs) × 128 / 50` (`hud.c:271-283`), so they fade in from black. An hourglass shows above them at all times | Code | `Time n` in a panel at the top centre (`time` in `Hud.roc`), only at 50 s or less. The text colour goes from black at 50 s to 49/50 of white at 1 s. No hourglass |
| Tick | In the last 20 s, `SFX_HOURGLASS_TICK` plays when `levelTimeLeft` steps from a multiple of 50 to 1 below it, while the level plays (`main.c:640-647`). So it plays as the shown seconds drop to 20, 19 and so on to 1 | Code (condition), Inferred (when it fires) | Same. `Clock.tick` compares the clock before and after the step |
| Tick volume | `8000 - 10 × (levelTimeLeft - 250)`: 510 as the time drops to 20 s, 10010 as it drops to 1 s (`main.c:643-646`). The landing bounce plays at 7000 (`player_movement.c:693`) | Code | Gain (10510 - 500 n) / 7000 as the time drops to n: 0.07 at 20, 1.43 at 1. The bounce plays at gain 1 |
| Tick tag | Each other second passes 37000 instead of 0 as the second argument of `SndPlaySfx`. That argument is a tag, not a pitch (`snd.c:155`) | Code | One tick sound at pitch 1 |
| Tick sound | `SFX_HOURGLASS_TICK` | Code | `assets/sound/tick.wav`, a 60 ms wooden tock from `make_sounds.py` |
| Hourglass item | Flips the time left and adds points (`level_update3.c:309-315`) | Code | Not in the clone |
| Lethargy pill | The clock runs 5 times as fast while it acts (`level_update3.c:1118-1121`) | Code | Not in the clone |
| Idle bob | Speeds up as the time runs out. See Idle bob | Code | Not copied yet |

## HUD

The original draws its HUD with sprites on a 320 × 256 screen. Kula draws
Text panels (`Hud.ui`), because the engine has no UI images. The original
hides the HUD once a level ends (`main.c:648-680`, Code). Kula keeps it, so
the banked total shows in `Cleared` and `Won`.

| Fact | Original | Label | Clone |
|---|---|---|---|
| Keys | One icon a key, lit when collected, from x 16, y 219 (`hud.c:456-466`, `sprite_init.c:75-76`) | Code | `Keys n / total` in a panel at the bottom left |
| Level score | 7 digits at x 100, y 218 (`hud.c:142`, `sprite_init.c:511`) | Code | `Level n` in a panel at the bottom, 30% of the way across |
| Total score | 7 digits at x 100, y 236, under the level score (`hud.c:135`, `sprite_init.c:510`) | Code | `Score n` under `Level n` in the same panel |
| Fruit | Five icons at the bottom right, each lit when its bit is set (`hud.c:468-487`). With all five, the icons turn into BONUS letters | Code | `Fruit n / 5` in a panel at the bottom right, where n counts the fruit set. No BONUS letters |
| Time | An hourglass and digits at the top centre (`hud.c:270-287`) | Code | `Time n` in its own panel at the top centre, no hourglass. See Level clock |

## Not copied

- The speed-up at the start of a roll.
- Look up and look down.
- The "hall of mirrors": in skybox themes the original does not clear the
  screen each frame (Code, `src/disp.c`). The engine clears every frame.
- The lens flare and the motion blur on fast turns.
- Fog.
- The long jump, the Bouncy pill, bounce pads and the boost.
- The pad rumble on a hit or a hard landing, and the screen shake of a
  landing at top fall speed (`player_movement.c:694, 740, 782-785`).
- Gold and silver coins. Hiro levels 1 to 3 hold only bronze coins.
- The hourglass in the HUD, the hourglass item, Timer pause faces and the
  time-out screen.
- Bonus levels, the fruit bowl and the HUD's BONUS letters.
- The fruit pickup's particle that flies to the HUD, and the 4 s that a
  fruit takes off the time-trial play time (`level_update3.c:244-252`).

## Sources

- https://github.com/dezgeg/kula-world-decomp
- https://wiki.kula.quest/
- https://speeddemosarchive.com/KulaWorld.html
- https://kulaquest.pinkgothic.com/storybehind.html
