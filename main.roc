app [init, launch, loaded, step, view] { linalg: "https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/linalg-4N62Pw77Sky6ba8RiBfvULjHuAQeQiqHbUor7qSeor7F.tar.zst", mesh: "https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/mesh-5Fmg6uFHADmSBmZxNWDg25VStK6mU7YqhkWEXHjMEGNP.tar.zst", pf: platform "https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/platform-DovzqwbAVit5yFpSzvKzqgwS8dpakvq2mdQJH3qcAHkb.tar.zst", roc: "nightly-2026-10-11-7d256b9", ui: "https://github.com/Pixelsprout/rocco-engine/releases/download/v0.6.0-rc.1/ui-5msrKWjNRwuEBomX2R1CBFRycCCjrQCPjhEvJXtwWbU6.tar.zst" }

import linalg.Vec3
import pf.Vocabulary exposing [Command, Config, Manifest, Rgb]
import pf.Button
import pf.Draw
import pf.Input
import pf.Key
import pf.Launch
import pf.Light
import pf.QueryResults
import pf.Scene
import pf.Sound
import World
import Grid
import Ball
import Rules
import View
import Theme
import Hud
import Pickup
import Flash
import Level
import Clock
import Fruit
import Sounds

Model : Rules.Model

launch : Config -> Vocabulary.Launch
launch = |_config| { ..Launch.default, step_hz: Clock.step_hz }

init : Config -> { model : Model, commands : List(Command) }
init = |_config| {
	model = Rules.start(View.primitive_meshes, 1)
	{ model, commands: [Load({ pack: kula_pack, assets: View.assets.concat(Sounds.assets) }), load_theme(1)] }
}

# The kula pack holds what every Theme shares. It stays loaded for the whole game.
kula_pack : Str
kula_pack = "kula"

load_theme : U64 -> Command
load_theme = |level_number| {
	theme = Theme.of_level(level_number)
	Load({ pack: theme.pack, assets: theme.assets })
}

# The next level starts only when its Theme has loaded, so no level draws with the old Theme's ids.
loaded : Model, Str, Manifest -> Model
loaded = |model, pack, manifest| {
	current = Theme.of_level(model.level_number)
	next_theme = Theme.of_level(model.level_number + 1)
	if pack == kula_pack {
		{ ..model, meshes: View.kula_meshes(model.meshes, manifest), sounds: Sounds.resolve(manifest) }
	} else if model.phase == Cleared and pack == next_theme.pack {
		next = Rules.next_level({ ..model, meshes: View.theme_meshes(model.meshes, manifest, next_theme.face, next_theme.sky) })
		{ ..next, unloads: [current.pack] }
	} else if model.phase != Cleared and pack == current.pack {
		{ ..model, meshes: View.theme_meshes(model.meshes, manifest, current.face, current.sky) }
	} else {
		model
	}
}

step : Model, Vocabulary.Input, Vocabulary.QueryResults, F32 -> { model : Model, commands : List(Command) }
step = |model, input, _results, dt| {
	controls = read_controls(input)
	stages = [start_same_theme, Rules.count_down(dt), Rules.run_clock, read_input(controls), move_ball(controls, dt), Rules.move_pickups(dt), Rules.fade_flashes(dt), Rules.collect, Rules.exit, Rules.fall]
	after = stages.fold(model, |m, stage| stage(m))
	quit = if controls.quit {
		[Quit]
	} else {
		[]
	}
	load = if model.phase != Cleared and after.phase == Cleared and !keeps_theme(after.level_number) {
		[load_theme(after.level_number + 1)]
	} else {
		[]
	}
	unloads = model.unloads.map(|pack| Unload(pack))
	{ model: { ..after, unloads: [] }, commands: quit.concat(load).concat(unloads).concat(bounce(model, after)).concat(pickup_sounds(model, after)).concat(tick(model, after)) }
}

# The host ignores a Load for a pack that is already loaded, and no loaded
# would come. So a level whose next level keeps its Theme sends no Load.
keeps_theme : U64 -> Bool
keeps_theme = |level_number| Theme.of_level(level_number + 1).pack == Theme.of_level(level_number).pack

# In the step after such a level is Cleared, the next level starts with the Theme's ids.
start_same_theme : Model -> Model
start_same_theme = |model|
	if model.phase == Cleared and keeps_theme(model.level_number) {
		Rules.next_level(model)
	} else {
		model
	}

# One chime for each coin and one jingle for each fruit the step collected.
# In a step, only a pickup takes an item out of the pickups: a restart puts
# them all back. A new level has its own pickups, and no pickup happens in its first step.
pickup_sounds : Model, Model -> List(Command)
pickup_sounds = |before, after| before.pickups
	.keep_if(|pickup| before.level_number == after.level_number and !after.pickups.any(|left| left.id == pickup.id))
	.join_map(
		|pickup| match pickup.kind {
			Coin => [Sound.play(after.sounds.chime)]
			Fruit(_) => [Sound.play(after.sounds.jingle)]
			Key => []
		},
	)

# As in the original, the ball bounces only while the player has control, which Kula has only in Playing.
bounce : Model, Model -> List(Command)
bounce = |before, after|
	if before.phase == Playing and Ball.landed(before.ball, after.ball) {
		[Sound.play(after.sounds.bounce)]
	} else {
		[]
	}

tick : Model, Model -> List(Command)
tick = |before, after| match Clock.tick(before.clock, after.clock) {
	Ok(gain) => [Play({ sound: after.sounds.tick, gain, pitch: 1.0, at: Here })]
	Err(NoTick) => []
}

# forward is held; the others are pressed in this step.
Controls : { forward : Bool, jump : Bool, left : Bool, right : Bool, quit : Bool }

# The keys and every connected pad drive the one ball.
read_controls : Vocabulary.Input -> Controls
read_controls = |input| {
	forward: Key.held(input, Up) or Button.held_any(input, DpadUp) or input.gamepads.any(|pad| pad.left_stick.y > stick_forward),
	jump: Key.pressed(input, Space) or Button.pressed_any(input, South),
	left: Key.pressed(input, Left) or Button.pressed_any(input, DpadLeft),
	right: Key.pressed(input, Right) or Button.pressed_any(input, DpadRight),
	quit: Key.pressed(input, Escape) or Button.pressed_any(input, Start),
}

# The stick must pass half its travel, so a light touch does not roll the ball.
stick_forward : F32
stick_forward = 0.5

# Input is read before the ball moves. Ball.act ignores a control that cannot act on the current move.
read_input : Controls -> (Model -> Model)
read_input = |controls| |model| match (model.phase, action(controls)) {
	(Playing, Ok(act)) => { ..model, ball: Ball.act(model.level.blocks, model.ball, act) }
	_ => model
}

move_ball : Controls, F32 -> (Model -> Model)
move_ball = |controls, dt| |model|
	if controls.forward {
		{ ..model, ball: Ball.advance_up_held(model.level.blocks, model.ball, dt) }
	} else {
		{ ..model, ball: Ball.advance(model.ball, dt) }
	}

# Tank controls. Forward rolls while held; the others act on press only. A jump
# with forward held is a forward jump.
action : Controls -> Try(Ball.Action, [NoAction])
action = |controls|
	if controls.jump {
		Ok(Jump({ up_held: controls.forward }))
	} else if controls.left {
		Ok(TurnLeft)
	} else if controls.right {
		Ok(TurnRight)
	} else if controls.forward {
		Ok(Roll)
	} else {
		Err(NoAction)
	}

view : Model -> Vocabulary.Scene
view = |model| {
	theme = Theme.of_level(model.level_number)
	exits = model.level.items.keep_if(|entry| entry.item == Exit).map(|entry| Grid.sub(entry.cell, entry.up))
	exit_tint = if Rules.exit_open(model) {
		open_exit_tint
	} else {
		closed_exit_tint
	}
	camera = View.camera(model.ball)
	# Ids come before the near-plane filter, so a face keeps its id while others drop out.
	blocks = View.faces(model.level.blocks)
		.map_with_index(|face, i| { face, id: 1 + i.to_u64() })
		.keep_if(|entry| !View.cut_by_near_plane(entry.face, camera))
		.map(
			|entry| {
				tint = if exits.contains(entry.face.block) {
					exit_tint
				} else {
					face_tint
				}
				View.face_draw(entry.id, model.meshes.face, entry.face, tint)
			},
		)
	pickups = model.pickups.map(|pickup| pickup_draw(model.meshes, pickup))
	ball_tint = if model.phase == Won {
		won_ball_tint
	} else {
		playing_ball_tint
	}
	ball = View.ball_draw(model.ball, model.meshes.ball, ball_tint)
	lights = theme.lights.concat(Flash.lights(model.flashes, theme.lights)).map(|light| Light(light))
	draws = blocks.concat(pickups).append(ball).map(|draw| Draw(draw))
	{ ..Scene.empty, camera, nodes: lights.concat(draws), sky: model.meshes.sky, ui: Hud.ui(model) }
}

# Face draw ids count up from 1, so the pickup ids start well past any level's faces.
pickup_ids : U64
pickup_ids = 100_000

closed_exit_tint : Rgb
closed_exit_tint = { r: 0.6, g: 0.15, b: 0.15 }

open_exit_tint : Rgb
open_exit_tint = { r: 1.0, g: 0.35, b: 0.3 }

# Each Theme's face texture carries its colour.
face_tint : Rgb
face_tint = { r: 1.0, g: 1.0, b: 1.0 }

key_tint : Rgb
key_tint = { r: 1.0, g: 0.787, b: 0.033 }

# ball.glb carries its own colours.
playing_ball_tint : Rgb
playing_ball_tint = { r: 1.0, g: 1.0, b: 1.0 }

won_ball_tint : Rgb
won_ball_tint = { r: 1.0, g: 0.85, b: 0.2 }

key_size : F32
key_size = 0.3

# coin.glb and the fruit meshes carry their own size and colour.
mesh_colour : Rgb
mesh_colour = { r: 1.0, g: 1.0, b: 1.0 }

# Kula's levels never show a banana or a strawberry, so they have no mesh.
spare_fruit_size : F32
spare_fruit_size = 0.35

banana_tint : Rgb
banana_tint = { r: 0.95, g: 0.8, b: 0.15 }

strawberry_tint : Rgb
strawberry_tint = { r: 0.85, g: 0.05, b: 0.1 }

pickup_draw : World.Meshes, Pickup.Pickup -> Vocabulary.Draw
pickup_draw = |meshes, pickup| {
	look = match pickup.kind {
		Key => { mesh: meshes.cube, size: key_size, tint: key_tint }
		Coin => { mesh: meshes.coin, size: 1.0, tint: mesh_colour }
		Fruit(Apple) => { mesh: meshes.apple, size: 1.0, tint: mesh_colour }
		Fruit(Watermelon) => { mesh: meshes.watermelon, size: 1.0, tint: mesh_colour }
		Fruit(Pumpkin) => { mesh: meshes.pumpkin, size: 1.0, tint: mesh_colour }
		Fruit(Banana) => { mesh: meshes.sphere, size: spare_fruit_size, tint: banana_tint }
		Fruit(Strawberry) => { mesh: meshes.sphere, size: spare_fruit_size, tint: strawberry_tint }
	}
	{ ..Draw.default, id: pickup_ids + pickup.id, mesh: look.mesh, pos: Pickup.centre(pickup), rot: Pickup.rot(pickup), scale: Vec3.scale(Vec3.one, look.size), tint: look.tint }
}

manifest : List((Str, U32)) -> Manifest
manifest = |entries| entries.map(|(name, id)| { name, id, duration: 0.0, clips: [] })

# The Model after init and both of its loads, as the first view sees it.
started : Model
started = {
	booted = init({ seed: 0, args: [], assets: ["ball", "coin", "apple", "watermelon", "pumpkin", "haze_face", "sky/haze", "sound/bounce", "sound/chime", "sound/tick", "sound/jingle"] }).model
	kula = manifest([("ball", 4), ("coin", 6), ("apple", 7), ("watermelon", 8), ("pumpkin", 9), ("sound/bounce", bounce_id), ("sound/chime", chime_id), ("sound/tick", tick_id), ("sound/jingle", jingle_id)])
	loaded(loaded(booted, "kula", kula), "haze", manifest([("haze_face", 5), ("sky/haze", 1)]))
}

bounce_id : U32
bounce_id = 65537

chime_id : U32
chime_id = 65538

tick_id : U32
tick_id = 65539

jingle_id : U32
jingle_id = 65540

idle : Vocabulary.Input
idle = Input.empty

draws_in : Vocabulary.Scene -> List(Vocabulary.Draw)
draws_in = |scene| scene.nodes.join_map(
	|node| match node {
		Draw(draw) => [draw]
		_ => []
	},
)

lights_in : Vocabulary.Scene -> List(Vocabulary.Light)
lights_in = |scene| scene.nodes.join_map(
	|node| match node {
		Light(light) => [light]
		_ => []
	},
)

expect init({ seed: 0, args: [], assets: [] }).commands == [Load({ pack: "kula", assets: ["ball", "coin", "apple", "watermelon", "pumpkin", "sound/bounce", "sound/chime", "sound/tick", "sound/jingle"] }), Load({ pack: "haze", assets: ["haze_face", "sky/haze"] })]
expect init({ seed: 0, args: [], assets: [] }).model.meshes == { cube: 1, sphere: 2, face: 0, ball: 0, coin: 0, apple: 0, watermelon: 0, pumpkin: 0, sky: 0 }
expect init({ seed: 0, args: [], assets: [] }).model.sounds == Sounds.none and started.sounds == { bounce: bounce_id, chime: chime_id, tick: tick_id, jingle: jingle_id }
expect started.meshes == { cube: 1, sphere: 2, face: 5, ball: 4, coin: 6, apple: 7, watermelon: 8, pumpkin: 9, sky: 1 }
expect view(started).sky == 1
expect started.ball == Ball.start(started.level.start)
expect started.level_number == 1 and started.phase == Playing

up_held : Vocabulary.Input
up_held = { ..idle, held: [Key.code(Up)] }

expect step(started, up_held, QueryResults.empty, 0.13).model.ball.motion == Rolling({ from: started.level.start, t: 0.5 })
expect step(started, { ..idle, pressed: [Key.code(Left)] }, QueryResults.empty, 0.16).model.ball.turn == Turning({ from: started.level.start, t: 0.5, next: Stay })
expect step(started, { ..idle, held: [Key.code(Left)] }, QueryResults.empty, 0.16).model.ball.turn == Steady

# Kula's first level before the Hiro levels: one column with a wall, a raised
# block and a gap. The tests of moves and drawing play on it. A fall from it
# restarts the real level 1.
column : Model
column = {
	level = Level.parse("E\n#\n#\n.\n#\n#\n#\nK\n#\nS\n\n.\n.\n.\n.\n.\nK\n#\n.\n.\n.\n") ?? started.level
	{ ..started, level, ball: Ball.start(level.start), pickups: Pickup.from_level(level, Apple), keys_left: 2 }
}

expect {
	model = [0.13, 0.13, 0.13, 0.13].fold(column, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	model.ball.pose.cell == { x: 0, y: 1, z: 7 }
}
expect step(started, { ..idle, pressed: [Key.code(Escape)] }, QueryResults.empty, 0.1).commands == [Quit]
expect step(started, idle, QueryResults.empty, 0.1).commands == []

with_pads : List(Vocabulary.Gamepad) -> Vocabulary.Input
with_pads = |pads| { ..Input.empty, gamepads: pads }

pad_holding : Button -> Vocabulary.Gamepad
pad_holding = |button| { ..Input.idle_gamepad, held: [Button.code(button)] }

pad_pressing : Button -> Vocabulary.Gamepad
pad_pressing = |button| { ..Input.idle_gamepad, pressed: [Button.code(button)] }

stick_at : F32 -> Vocabulary.Gamepad
stick_at = |y| { ..Input.idle_gamepad, left_stick: { x: 0.0, y } }

expect step(started, with_pads([pad_holding(DpadUp)]), QueryResults.empty, 0.13).model.ball.motion == Rolling({ from: started.level.start, t: 0.5 })
expect step(started, with_pads([stick_at(0.6)]), QueryResults.empty, 0.13).model.ball.motion == Rolling({ from: started.level.start, t: 0.5 })
expect step(started, with_pads([stick_at(0.5)]), QueryResults.empty, 0.13).model.ball.motion == Still

# Any pad drives the ball, here the pad in slot 2.
expect step(started, with_pads([Input.idle_gamepad, { ..pad_holding(DpadUp), slot: 2 }]), QueryResults.empty, 0.13).model.ball.motion == Rolling({ from: started.level.start, t: 0.5 })

expect step(started, with_pads([pad_pressing(DpadLeft)]), QueryResults.empty, 0.16).model.ball.turn == Turning({ from: started.level.start, t: 0.5, next: Stay })
expect step(started, with_pads([pad_holding(DpadLeft)]), QueryResults.empty, 0.16).model.ball.turn == Steady

expect {
	turned = step(started, with_pads([pad_pressing(DpadRight)]), QueryResults.empty, 0.32).model
	turned.ball.pose.forward == { x: 1, y: 0, z: 0 }
}

expect step(started, with_pads([pad_pressing(South)]), QueryResults.empty, 0.27).model.ball.motion == JumpingInPlace({ t: 0.5 })
expect step(started, with_pads([pad_pressing(Start)]), QueryResults.empty, 0.1).commands == [Quit]
expect step(started, with_pads([Input.idle_gamepad]), QueryResults.empty, 0.1) == step(started, idle, QueryResults.empty, 0.1)

expect {
	draws = draws_in(view(column))
	draws.len() == 49
}

expect {
	draws = draws_in(view(column))
	exit_faces = draws.keep_if(|d| d.tint == closed_exit_tint)
	exit_faces.len() == 5 and exit_faces.all(|d| Vec3.length(d.pos) == 0.5)
}

# Each key bobs 120 to 160 units above its face.
expect {
	keys = draws_in(view(column)).keep_if(|d| d.tint == key_tint)
	above = |d, face_y| d.pos.y - face_y >= 120.0 / 512.0 and d.pos.y - face_y <= 160.0 / 512.0
	match keys {
		[first, second] => first.pos.z == 7.0 and above(first, 0.5) and second.pos.z == 5.0 and above(second, 1.5) and keys.all(|d| d.pos.x == 0.0 and d.scale.x == key_size)
		_ => False
	}
}

# A key moves between steps.
expect {
	keys_at = |model| draws_in(view(model)).keep_if(|d| d.tint == key_tint)
	later = step(column, idle, QueryResults.empty, 0.1).model
	keys_at(later).map(|d| d.id) == keys_at(column).map(|d| d.id) and keys_at(later).map(|d| d.pos) != keys_at(column).map(|d| d.pos) and keys_at(later).map(|d| d.rot) != keys_at(column).map(|d| d.rot)
}

expect {
	model = column
	ball = draws_in(view(model)).keep_if(|d| d.mesh == model.meshes.ball)
	ball.map(|d| d.pos) == [{ x: 0.0, y: 0.695, z: 9.0 }]
}

# In the climb at the level1 wall, the eye passes down through the old floor.
# Only as it passes does that face drop out, and the rest keep their ids.
expect {
	rest = draws_in(view(column))
	at_wall = [0.13, 0.13, 0.13, 0.13].fold(column, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	faces_at = |dt| {
		climbing = step(at_wall, up_held, QueryResults.empty, dt).model
		draws_in(view(climbing)).keep_if(|d| d.mesh == climbing.meshes.face)
	}
	passing = faces_at(0.152)
	faces_at(0.14).len() == 46 and passing.len() < 46 and passing.all(|d| rest.any(|r| r.id == d.id and r.pos == d.pos))
}

# Rolling from S over the first key collects it.
expect {
	model = [0.13, 0.13, 0.13, 0.13].fold(column, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	model.keys_left == 1 and model.pickups.map(|pickup| pickup.id) == [1]
}

# The key collects in the roll onto its cell, before the roll ends.
expect {
	before_key = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 8 } })
	rolling = step(before_key, up_held, QueryResults.empty, 0.01).model
	near = step(rolling, idle, QueryResults.empty, 0.1).model
	nearer = step(near, idle, QueryResults.empty, 0.1).model
	near.keys_left == 2 and nearer.keys_left == 1 and match nearer.ball.motion {
		Rolling(_) => True
		_ => False
	}
}

# The key pickup lights a Point light one cell above the key's face. It peaks
# in pale blue and is gone 0.66 s after the pickup.
expect {
	before_key = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 8 } })
	rolling = step(before_key, up_held, QueryResults.empty, 0.01).model
	picked = step(step(rolling, idle, QueryResults.empty, 0.1).model, idle, QueryResults.empty, 0.1).model
	peak = step(picked, idle, QueryResults.empty, 0.1).model
	faded = step(peak, idle, QueryResults.empty, 0.56).model
	flash_pos = { x: 0.0, y: 1.5, z: 7.0 }
	picked.keys_left == 1
		and point_lights(view(picked)) == [Light.point(flash_pos, Flash.colour(Key, 0.0), 2.0)]
			and point_lights(view(peak)) == [Light.point(flash_pos, Flash.colour(Key, 0.1), 2.0)]
				and Flash.colour(Key, 0.1).b > Flash.colour(Key, 0.1).r
					and point_lights(view(faded)) == []
						and lights_in(view(faded)) == Theme.of_level(1).lights
}

point_lights : Vocabulary.Scene -> List(Vocabulary.Light)
point_lights = |scene| lights_in(scene).keep_if(
	|light| match light {
		Point(_) => True
		_ => False
	},
)

at_pose : Model, World.Pose -> Model
at_pose = |model, pose| { ..model, ball: Ball.start(pose) }

before_exit : World.Pose
before_exit = { cell: { x: 0, y: 1, z: 1 }, up: { x: 0, y: 1, z: 0 }, forward: { x: 0, y: 0, z: -1 } }

expect step(at_pose(column, before_exit), up_held, QueryResults.empty, 0.1).model.phase == Playing

# In Won the ball ignores input, and Escape still quits.
expect {
	won = { ..column, phase: Won }
	after = step(won, up_held, QueryResults.empty, 0.1)
	{ ..after.model.ball, bob: won.ball.bob } == won.ball and step(won, { ..idle, pressed: [Key.code(Escape)] }, QueryResults.empty, 0.1).commands == [Quit]
}

# A jump off the side from S falls, then the level restarts.
expect {
	space = { ..idle, held: [Key.code(Up)], pressed: [Key.code(Space)] }
	facing_out = { ..at_pose(column, { ..column.level.start, forward: { x: -1, y: 0, z: 0 } }), keys_left: 1 }
	jumped = step(facing_out, space, QueryResults.empty, 0.25).model
	still_falling = step(jumped, idle, QueryResults.empty, 0.25).model
	landed = step(still_falling, idle, QueryResults.empty, 0.5).model
	fell = match jumped.ball.motion {
		Falling({ from, offset, over, drop, seconds, .. }) => from == facing_out.ball.pose and offset == 0.0 and over == { ..facing_out.ball.pose, cell: { x: -2, y: 1, z: 9 } } and drop == Off(3) and seconds == 0.25
		_ => False
	}
	fell and still_falling.ball.pose == jumped.ball.pose and landed == started
}

expect {
	collected = [0.13, 0.13, 0.13, 0.13].fold(column, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	keys = draws_in(view(collected)).keep_if(|d| d.tint == key_tint)
	keys.map(|d| d.pos.z) == [5.0] and keys.map(|d| d.id) == [pickup_ids + 1]
}

expect {
	draws = draws_in(view({ ..column, keys_left: 0 }))
	draws.keep_if(|d| d.tint == open_exit_tint).len() == 5 and !draws.any(|d| d.tint == closed_exit_tint)
}

expect {
	won = { ..column, phase: Won }
	draws_in(view(won)).keep_if(|d| d.mesh == won.meshes.ball).map(|d| d.tint) == [won_ball_tint]
}

space : Vocabulary.Input
space = { ..idle, pressed: [Key.code(Space)] }

expect step(column, space, QueryResults.empty, 0.27).model.ball.motion == JumpingInPlace({ t: 0.5 })

# Up and Space jump the level1 gap from the cell before it.
expect {
	before_gap = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumped = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and jumped.ball.motion == Jumping({ from: before_gap.ball.pose, offset: 0.0, t: 0.1 / 0.54 })
}

# South with the pad's forward held jumps the gap too.
expect {
	before_gap = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 4 } })
	jump_forward = { ..stick_at(1.0), pressed: [Button.code(South)] }
	jumped = step(before_gap, with_pads([jump_forward]), QueryResults.empty, 0.1).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and jumped.ball.motion == Jumping({ from: before_gap.ball.pose, offset: 0.0, t: 0.1 / 0.54 })
}

# A jump just after a roll starts passes high over the key in the roll's target cell, so the key stays.
expect {
	on_layer1 = at_pose(column, { ..column.level.start, cell: { x: 0, y: 2, z: 6 } })
	rolling = step(on_layer1, up_held, QueryResults.empty, 0.05).model
	jumped = step(rolling, space, QueryResults.empty, 0.01).model
	landed = List.repeat(0.01, 100).fold(jumped, |m, dt| step(m, idle, QueryResults.empty, dt).model)
	landed.ball.motion == Still and landed.keys_left == 2 and match jumped.ball.motion {
		Falling({ from, .. }) => from.cell == { x: 0, y: 2, z: 6 }
		_ => False
	}
}

# The jump from the raised block lands on the floor one cell below its target.
expect {
	on_layer1 = at_pose(column, { ..column.level.start, cell: { x: 0, y: 2, z: 6 } })
	rolling = step(on_layer1, up_held, QueryResults.empty, 0.05).model
	jumped = step(rolling, space, QueryResults.empty, 0.01).model
	landed = step(jumped, idle, QueryResults.empty, 1.0).model
	landed.ball.motion == Still and landed.ball.pose.cell == { x: 0, y: 1, z: 4 }
}

# The bounce plays in the step a forward jump lands, and in no step before it.
expect {
	before_gap = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumping = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1)
	in_air = step(jumping.model, idle, QueryResults.empty, 0.3)
	landing = step(in_air.model, idle, QueryResults.empty, 0.3)
	jumping.commands == [] and in_air.commands == [] and landing.model.ball.motion == Still and landing.commands == [Sound.play(bounce_id)]
}

# A fall onto a lower block plays the bounce too.
expect {
	on_layer1 = at_pose(column, { ..column.level.start, cell: { x: 0, y: 2, z: 6 } })
	rolling = step(on_layer1, up_held, QueryResults.empty, 0.05).model
	jumped = step(rolling, space, QueryResults.empty, 0.01).model
	step(jumped, idle, QueryResults.empty, 1.0).commands == [Sound.play(bounce_id)]
}

# A jump in place does not bounce, and a fall off the level restarts it with no bounce.
expect {
	jumping_in_place = step(column, space, QueryResults.empty, 0.27).model
	facing_out = at_pose(column, { ..column.level.start, forward: { x: -1, y: 0, z: 0 } })
	falling = step(facing_out, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.25).model
	restarted = step(falling, idle, QueryResults.empty, 2.0)
	step(jumping_in_place, idle, QueryResults.empty, 0.3).commands == [] and restarted.model.ball == started.ball and restarted.commands == []
}

# With no control, in Cleared or Won, a landing is silent, as in the original.
expect {
	before_gap = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumping = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1).model
	[Cleared, Won].all(|phase| step({ ..jumping, phase }, idle, QueryResults.empty, 0.6).commands == [])
}

# Held Up rolls on through the cell with no step at rest.
expect {
	model = [0.13, 0.13].fold(column, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	model.ball.pose.cell == { x: 0, y: 1, z: 7 } and model.ball.motion != Still
}

# Held Up runs the ball to the level1 gap. Space on the approach to the edge clears it.
expect {
	two_before = at_pose(column, { ..column.level.start, cell: { x: 0, y: 1, z: 5 } })
	at_edge = step(two_before, up_held, QueryResults.empty, 0.26).model
	jumped = step(at_edge, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.06).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and match jumped.ball.motion {
		Jumping({ from, .. }) => from.cell == { x: 0, y: 1, z: 4 }
		_ => False
	}
}

# Levels 1 and 2 share the haze Theme. The step after the exit starts level 2
# with the Theme's ids and sends no Load and no Unload.
expect {
	open = { ..at_pose(column, before_exit), keys_left: 0 }
	finished = step(open, up_held, QueryResults.empty, 0.1)
	next = step(finished.model, idle, QueryResults.empty, 0.1)
	finished.commands == []
		and finished.model.phase == Cleared
			and next.commands == []
				and next.model.level_number == 2
					and next.model.phase == Starting(Rules.start_pause - 0.1)
						and next.model.meshes == started.meshes
							and next.model.sounds == started.sounds
								and step(next.model, idle, QueryResults.empty, 0.1).commands == []
}

# The first step of a new level plays no chime for the coins left on the old
# one, even when the new level has no pickups with their ids.
expect {
	cleared = { ..at_pose(started, before_exit), keys_left: 0, phase: Cleared, pickups: started.pickups.map(|pickup| { ..pickup, id: pickup.id + 50 }) }
	next = step(cleared, idle, QueryResults.empty, 0.01)
	next.model.level_number == 2 and next.commands == []
}

# A loaded for a pack Kula did not ask for changes nothing.
expect loaded(started, "inca", manifest([("inca_face", 7)])) == started

# During the pause the ball ignores input. After it, the level plays.
expect {
	starting = { ..on_level(2), phase: Starting(1.0) }
	paused = step(starting, up_held, QueryResults.empty, 0.5).model
	playing = step(paused, idle, QueryResults.empty, 0.6).model
	paused.ball.motion == Still and playing.phase == Playing and step(playing, up_held, QueryResults.empty, 0.1).model.ball.motion != Still
}

expect lights_in(view(on_level(2))) == Theme.of_level(2).lights

Move : [Roll, Left, Right, Leap]

# Each move starts with a short step that presses its keys. A long idle step then finishes it.
play : Model, List(Move) -> Model
play = |model, moves| moves.fold(
	model,
	|m, move| {
		keys = match move {
			Roll => { ..idle, held: [Key.code(Up)] }
			Left => { ..idle, pressed: [Key.code(Left)] }
			Right => { ..idle, pressed: [Key.code(Right)] }
			Leap => { ..idle, held: [Key.code(Up)], pressed: [Key.code(Space)] }
		}
		step(step(m, keys, QueryResults.empty, 0.01).model, idle, QueryResults.empty, 1.0).model
	},
)

on_level : U64 -> Model
on_level = |number| Rules.start(started.meshes, number)

# Each route collects the key, every coin and the fruit, then takes the exit.
# The exit banks 1000 for the key, 250 for each coin and 2500 for the fruit.
expect {
	played = play(on_level(1), [Roll, Roll, Roll, Right, Roll, Roll, Roll, Right, Roll, Roll, Roll, Right, Right, Roll, Roll, Roll, Roll, Roll, Roll, Left, Roll, Roll, Roll])
	played.level_number == 2 and played.score.total == 1000 + 2 * 250 + 2500
}

# The route jumps each gap between the rings.
expect {
	played = play(on_level(2), [Roll, Roll, Roll, Leap, Roll, Roll, Roll, Right, Roll, Roll, Roll, Right, Roll, Roll, Roll, Left, Leap, Left, Roll, Right, Roll, Roll, Roll, Right, Roll, Roll, Roll, Roll, Right, Roll, Roll, Roll, Right, Roll, Left, Leap])
	played.level_number == 3 and played.score.total == 1000 + 6 * 250 + 2500
}

# The route climbs a pillar onto the side of the bridge, rolls along it past
# the key and climbs down the other pillar.
expect {
	played = play(on_level(3), [Roll, Roll, Roll, Right, Roll, Roll, Roll, Left, Roll, Roll, Roll, Roll, Roll, Left, Roll, Roll, Roll, Roll, Roll, Roll, Roll, Left, Roll, Roll, Roll, Roll, Roll, Left, Roll, Roll, Roll, Roll, Roll, Roll, Roll, Right, Roll, Roll, Roll])
	played.phase == Won and played.score.total == 1000 + 10 * 250 + 2500
}

before_last_exit : World.Pose
before_last_exit = { cell: { x: 7, y: 1, z: 5 }, up: { x: 0, y: 1, z: 0 }, forward: { x: 0, y: 0, z: 1 } }

expect {
	open = { ..at_pose(on_level(3), before_last_exit), keys_left: 0 }
	finished = step(open, up_held, QueryResults.empty, 0.1)
	finished.model.phase == Won and finished.commands == []
}

# Three blocks in a row with a coin on the middle one. The ball starts on the last, facing it.
coin_run : Model
coin_run = {
	level = Level.parse("#\n#\n#\n\n0 0 1 +y coin\nstart 0 0 2 +y -z\n") ?? started.level
	{ ..started, level, ball: Ball.start(level.start), pickups: Pickup.from_level(level, Apple), keys_left: 0 }
}

# A coin draws coin.glb unscaled, bobbing 140 to 180 units above its face.
expect {
	coins = draws_in(view(coin_run)).keep_if(|d| d.mesh == coin_run.meshes.coin)
	match coins {
		[coin] => coin.id == pickup_ids and coin.pos.z == 1.0 and coin.pos.y - 0.5 >= 140.0 / 512.0 and coin.pos.y - 0.5 <= 180.0 / 512.0 and coin.scale == Vec3.one and coin.tint == mesh_colour
		_ => False
	}
}

# A roll onto the coin collects it, plays the chime once and adds 250 to the level score.
expect {
	rolling = step(coin_run, up_held, QueryResults.empty, 0.01)
	run = List.repeat(0.01, 60).fold(
		{ model: rolling.model, chimes: rolling.commands.keep_if(|c| c == Sound.play(chime_id)).len() },
		|so_far, dt| {
			next = step(so_far.model, idle, QueryResults.empty, dt)
			{ model: next.model, chimes: so_far.chimes + next.commands.keep_if(|c| c == Sound.play(chime_id)).len() }
		},
	)
	run.chimes == 1 and run.model.pickups == [] and run.model.score.level == 250 and run.model.ball.pose.cell == { x: 0, y: 1, z: 1 }
}

expect launch({ seed: 0, args: [], assets: [] }).step_hz == 120

# In the last 20 s the clock ticks once a second, louder each time.
expect {
	first = step({ ..started, clock: Clock.start(20) + 1 }, idle, QueryResults.empty, 0.01)
	second = step(first.model, idle, QueryResults.empty, 0.01)
	first.commands == [] and second.commands == [Play({ sound: tick_id, gain: 510.0 / 7000.0, pitch: 1.0, at: Here })]
}

# The clock stops at the exit, so the tick stops too.
expect {
	open = { ..at_pose(started, before_exit), keys_left: 0, clock: Clock.start(5) + 1 }
	finished = step(open, up_held, QueryResults.empty, 0.1).model
	finished.phase == Cleared and finished.clock == Clock.start(5) and step(finished, idle, QueryResults.empty, 0.1).commands == []
}

# At 0 the level restarts with a full clock and no tick. The rest of that step plays on the restarted level.
expect {
	last_step = step({ ..started, clock: 1 }, up_held, QueryResults.empty, 0.01)
	fresh = step(started, up_held, QueryResults.empty, 0.01).model
	last_step.model == { ..fresh, clock: Clock.start(Clock.default_seconds) } and last_step.commands == []
}

# The coin run with a fruit in place of the coin.
fruit_run : Fruit.Fruits -> Model
fruit_run = |fruits| {
	level = Level.parse("#\n#\n#\n\n0 0 1 +y fruit\nstart 0 0 2 +y -z\n") ?? started.level
	{ ..coin_run, level, pickups: Pickup.from_level(level, Fruit.next(fruits)), fruits }
}

# Each fruit draws its own mesh unscaled. Its centre bobs 120 to 160 units above its face.
expect {
	fruit_mesh = |fruits| draws_in(view(fruit_run(fruits))).keep_if(|d| d.id == pickup_ids)
	apple = fruit_mesh(Fruit.none)
	watermelon = fruit_mesh(Fruit.collect(Fruit.none, Apple))
	pumpkin = fruit_mesh(Fruit.collect(Fruit.collect(Fruit.none, Apple), Watermelon))
	match (apple, watermelon, pumpkin) {
		([a], [w], [p]) => a.mesh == started.meshes.apple and w.mesh == started.meshes.watermelon and p.mesh == started.meshes.pumpkin and a.scale == Vec3.one and a.pos.y - 0.5 >= 120.0 / 512.0 and a.pos.y - 0.5 <= 160.0 / 512.0
		_ => False
	}
}

# A roll onto the apple collects it, plays the jingle once, adds 2500 to the level score and lights a fruit flash.
expect {
	rolling = step(fruit_run(Fruit.none), up_held, QueryResults.empty, 0.01)
	run = List.repeat(0.01, 60).fold(
		{ model: rolling.model, sounds: rolling.commands },
		|so_far, dt| {
			next = step(so_far.model, idle, QueryResults.empty, dt)
			{ model: next.model, sounds: so_far.sounds.concat(next.commands) }
		},
	)
	run.sounds == [Sound.play(jingle_id)] and run.model.pickups == [] and run.model.score.level == 2500 and run.model.fruits.now == [Apple] and run.model.flashes.all(|flash| flash.kind == Fruit(Apple))
}
