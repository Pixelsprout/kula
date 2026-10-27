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

Model : Rules.Model

launch : Config -> Vocabulary.Launch
launch = |_config| Launch.default

init : Config -> { model : Model, commands : List(Command) }
init = |_config| {
	model = Rules.start(View.primitive_meshes, 1)
	{ model, commands: [Load({ pack: kula_pack, assets: View.assets.append(bounce_sound) }), load_theme(1)] }
}

# The kula pack holds what every Theme shares. It stays loaded for the whole game.
kula_pack : Str
kula_pack = "kula"

# assets/source/make_sounds.py writes it.
bounce_sound : Str
bounce_sound = "sound/bounce"

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
		{ ..model, meshes: View.kula_meshes(model.meshes, manifest), bounce: Sound.resolve(manifest, bounce_sound) }
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
	stages = [Rules.count_down(dt), read_input(controls), move_ball(controls, dt), Rules.move_pickups(dt), Rules.fade_flashes(dt), Rules.collect, Rules.exit, Rules.fall]
	after = stages.fold(model, |m, stage| stage(m))
	quit = if controls.quit {
		[Quit]
	} else {
		[]
	}
	load = if model.phase != Cleared and after.phase == Cleared {
		[load_theme(after.level_number + 1)]
	} else {
		[]
	}
	unloads = model.unloads.map(|pack| Unload(pack))
	{ model: { ..after, unloads: [] }, commands: quit.concat(load).concat(unloads).concat(bounce(model, after)) }
}

# As in the original, the ball bounces only while the player has control, which Kula has only in Playing.
bounce : Model, Model -> List(Command)
bounce = |before, after|
	if before.phase == Playing and Ball.landed(before.ball, after.ball) {
		[Sound.play(after.bounce)]
	} else {
		[]
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

pickup_draw : World.Meshes, Pickup.Pickup -> Vocabulary.Draw
pickup_draw = |meshes, pickup| {
	look = match pickup.kind {
		Key => { mesh: meshes.cube, size: key_size, tint: key_tint }
	}
	{ ..Draw.default, id: pickup_ids + pickup.id, mesh: look.mesh, pos: Pickup.centre(pickup), rot: Pickup.rot(pickup), scale: Vec3.scale(Vec3.one, look.size), tint: look.tint }
}

manifest : List((Str, U32)) -> Manifest
manifest = |entries| entries.map(|(name, id)| { name, id, duration: 0.0, clips: [] })

# The Model after init and both of its loads, as the first view sees it.
started : Model
started = {
	booted = init({ seed: 0, args: [], assets: ["ball", "haze_face", "sky/haze", "sound/bounce"] }).model
	loaded(loaded(booted, "kula", manifest([("ball", 4), ("sound/bounce", bounce_id)])), "haze", manifest([("haze_face", 5), ("sky/haze", 1)]))
}

bounce_id : U32
bounce_id = 65537

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

expect init({ seed: 0, args: [], assets: [] }).commands == [Load({ pack: "kula", assets: ["ball", "sound/bounce"] }), Load({ pack: "haze", assets: ["haze_face", "sky/haze"] })]
expect init({ seed: 0, args: [], assets: [] }).model.meshes == { cube: 1, face: 0, ball: 0, sky: 0 }
expect init({ seed: 0, args: [], assets: [] }).model.bounce == 0 and started.bounce == bounce_id
expect started.meshes == { cube: 1, face: 5, ball: 4, sky: 1 }
expect view(started).sky == 1
expect started.ball == Ball.start(started.level.start)
expect started.level_number == 1 and started.phase == Playing

up_held : Vocabulary.Input
up_held = { ..idle, held: [Key.code(Up)] }

expect step(started, up_held, QueryResults.empty, 0.13).model.ball.motion == Rolling({ from: started.level.start, t: 0.5 })
expect step(started, { ..idle, pressed: [Key.code(Left)] }, QueryResults.empty, 0.16).model.ball.turn == Turning({ from: started.level.start, t: 0.5, next: Stay })
expect step(started, { ..idle, held: [Key.code(Left)] }, QueryResults.empty, 0.16).model.ball.turn == Steady

expect {
	model = [0.13, 0.13, 0.13, 0.13].fold(started, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
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
	draws = draws_in(view(started))
	draws.len() == 49
}

expect {
	draws = draws_in(view(started))
	exit_faces = draws.keep_if(|d| d.tint == closed_exit_tint)
	exit_faces.len() == 5 and exit_faces.all(|d| Vec3.length(d.pos) == 0.5)
}

# Each key bobs 120 to 160 units above its face.
expect {
	keys = draws_in(view(started)).keep_if(|d| d.tint == key_tint)
	above = |d, face_y| d.pos.y - face_y >= 120.0 / 512.0 and d.pos.y - face_y <= 160.0 / 512.0
	match keys {
		[first, second] => first.pos.z == 7.0 and above(first, 0.5) and second.pos.z == 5.0 and above(second, 1.5) and keys.all(|d| d.pos.x == 0.0 and d.scale.x == key_size)
		_ => False
	}
}

# A key moves between steps.
expect {
	keys_at = |model| draws_in(view(model)).keep_if(|d| d.tint == key_tint)
	later = step(started, idle, QueryResults.empty, 0.1).model
	keys_at(later).map(|d| d.id) == keys_at(started).map(|d| d.id) and keys_at(later).map(|d| d.pos) != keys_at(started).map(|d| d.pos) and keys_at(later).map(|d| d.rot) != keys_at(started).map(|d| d.rot)
}

expect {
	model = started
	ball = draws_in(view(model)).keep_if(|d| d.mesh == model.meshes.ball)
	ball.map(|d| d.pos) == [{ x: 0.0, y: 0.695, z: 9.0 }]
}

# In the climb at the level1 wall, the eye passes down through the old floor.
# Only as it passes does that face drop out, and the rest keep their ids.
expect {
	rest = draws_in(view(started))
	at_wall = [0.13, 0.13, 0.13, 0.13].fold(started, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	faces_at = |dt| {
		climbing = step(at_wall, up_held, QueryResults.empty, dt).model
		draws_in(view(climbing)).keep_if(|d| d.mesh == climbing.meshes.face)
	}
	passing = faces_at(0.152)
	faces_at(0.14).len() == 46 and passing.len() < 46 and passing.all(|d| rest.any(|r| r.id == d.id and r.pos == d.pos))
}

# Rolling from S over the first key collects it.
expect {
	model = [0.13, 0.13, 0.13, 0.13].fold(started, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	model.keys_left == 1 and model.pickups.map(|pickup| pickup.id) == [1]
}

# The key collects in the roll onto its cell, before the roll ends.
expect {
	before_key = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 8 } })
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
	before_key = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 8 } })
	rolling = step(before_key, up_held, QueryResults.empty, 0.01).model
	picked = step(step(rolling, idle, QueryResults.empty, 0.1).model, idle, QueryResults.empty, 0.1).model
	peak = step(picked, idle, QueryResults.empty, 0.1).model
	faded = step(peak, idle, QueryResults.empty, 0.56).model
	flash_pos = { x: 0.0, y: 1.5, z: 7.0 }
	picked.keys_left == 1
		and point_lights(view(picked)) == [Light.point(flash_pos, Flash.colour(0.0), 2.0)]
			and point_lights(view(peak)) == [Light.point(flash_pos, Flash.colour(0.1), 2.0)]
				and Flash.colour(0.1).b > Flash.colour(0.1).r
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

expect step(at_pose(started, before_exit), up_held, QueryResults.empty, 0.1).model.phase == Playing

# In Won the ball ignores input, and Escape still quits.
expect {
	won = { ..started, phase: Won }
	after = step(won, up_held, QueryResults.empty, 0.1)
	{ ..after.model.ball, bob: won.ball.bob } == won.ball and step(won, { ..idle, pressed: [Key.code(Escape)] }, QueryResults.empty, 0.1).commands == [Quit]
}

# A jump off the side from S falls, then the level restarts.
expect {
	space = { ..idle, held: [Key.code(Up)], pressed: [Key.code(Space)] }
	facing_out = { ..at_pose(started, { ..started.level.start, forward: { x: -1, y: 0, z: 0 } }), keys_left: 1 }
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
	collected = [0.13, 0.13, 0.13, 0.13].fold(started, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	keys = draws_in(view(collected)).keep_if(|d| d.tint == key_tint)
	keys.map(|d| d.pos.z) == [5.0] and keys.map(|d| d.id) == [pickup_ids + 1]
}

expect {
	draws = draws_in(view({ ..started, keys_left: 0 }))
	draws.keep_if(|d| d.tint == open_exit_tint).len() == 5 and !draws.any(|d| d.tint == closed_exit_tint)
}

expect {
	won = { ..started, phase: Won }
	draws_in(view(won)).keep_if(|d| d.mesh == won.meshes.ball).map(|d| d.tint) == [won_ball_tint]
}

space : Vocabulary.Input
space = { ..idle, pressed: [Key.code(Space)] }

expect step(started, space, QueryResults.empty, 0.27).model.ball.motion == JumpingInPlace({ t: 0.5 })

# Up and Space jump the level1 gap from the cell before it.
expect {
	before_gap = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumped = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and jumped.ball.motion == Jumping({ from: before_gap.ball.pose, offset: 0.0, t: 0.1 / 0.54 })
}

# South with the pad's forward held jumps the gap too.
expect {
	before_gap = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 4 } })
	jump_forward = { ..stick_at(1.0), pressed: [Button.code(South)] }
	jumped = step(before_gap, with_pads([jump_forward]), QueryResults.empty, 0.1).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and jumped.ball.motion == Jumping({ from: before_gap.ball.pose, offset: 0.0, t: 0.1 / 0.54 })
}

# A jump just after a roll starts passes high over the key in the roll's target cell, so the key stays.
expect {
	on_layer1 = at_pose(started, { ..started.level.start, cell: { x: 0, y: 2, z: 6 } })
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
	on_layer1 = at_pose(started, { ..started.level.start, cell: { x: 0, y: 2, z: 6 } })
	rolling = step(on_layer1, up_held, QueryResults.empty, 0.05).model
	jumped = step(rolling, space, QueryResults.empty, 0.01).model
	landed = step(jumped, idle, QueryResults.empty, 1.0).model
	landed.ball.motion == Still and landed.ball.pose.cell == { x: 0, y: 1, z: 4 }
}

# The bounce plays in the step a forward jump lands, and in no step before it.
expect {
	before_gap = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumping = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1)
	in_air = step(jumping.model, idle, QueryResults.empty, 0.3)
	landing = step(in_air.model, idle, QueryResults.empty, 0.3)
	jumping.commands == [] and in_air.commands == [] and landing.model.ball.motion == Still and landing.commands == [Sound.play(bounce_id)]
}

# A fall onto a lower block plays the bounce too.
expect {
	on_layer1 = at_pose(started, { ..started.level.start, cell: { x: 0, y: 2, z: 6 } })
	rolling = step(on_layer1, up_held, QueryResults.empty, 0.05).model
	jumped = step(rolling, space, QueryResults.empty, 0.01).model
	step(jumped, idle, QueryResults.empty, 1.0).commands == [Sound.play(bounce_id)]
}

# A jump in place does not bounce, and a fall off the level restarts it with no bounce.
expect {
	jumping_in_place = step(started, space, QueryResults.empty, 0.27).model
	facing_out = at_pose(started, { ..started.level.start, forward: { x: -1, y: 0, z: 0 } })
	falling = step(facing_out, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.25).model
	restarted = step(falling, idle, QueryResults.empty, 2.0)
	step(jumping_in_place, idle, QueryResults.empty, 0.3).commands == [] and restarted.model.ball == started.ball and restarted.commands == []
}

# With no control, in Cleared or Won, a landing is silent, as in the original.
expect {
	before_gap = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 4 } })
	jumping = step(before_gap, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.1).model
	[Cleared, Won].all(|phase| step({ ..jumping, phase }, idle, QueryResults.empty, 0.6).commands == [])
}

# Held Up rolls on through the cell with no step at rest.
expect {
	model = [0.13, 0.13].fold(started, |m, dt| step(m, up_held, QueryResults.empty, dt).model)
	model.ball.pose.cell == { x: 0, y: 1, z: 7 } and model.ball.motion != Still
}

# Held Up runs the ball to the level1 gap. Space on the approach to the edge clears it.
expect {
	two_before = at_pose(started, { ..started.level.start, cell: { x: 0, y: 1, z: 5 } })
	at_edge = step(two_before, up_held, QueryResults.empty, 0.26).model
	jumped = step(at_edge, { ..space, held: [Key.code(Up)] }, QueryResults.empty, 0.06).model
	jumped.ball.pose.cell == { x: 0, y: 1, z: 2 } and match jumped.ball.motion {
		Jumping({ from, .. }) => from.cell == { x: 0, y: 1, z: 4 }
		_ => False
	}
}

expect {
	open = { ..at_pose(started, before_exit), keys_left: 0 }
	finished = step(open, up_held, QueryResults.empty, 0.1)
	switched = loaded(finished.model, "inca", manifest([("inca_face", 7), ("sky/inca", 2)]))
	after = step(switched, idle, QueryResults.empty, 0.1)
	finished.commands == [Load({ pack: "inca", assets: ["inca_face", "sky/inca"] })]
		and finished.model.phase == Cleared
			and switched.meshes == { cube: 1, face: 7, ball: 4, sky: 2 }
				and switched.bounce == bounce_id
					and switched.level_number == 2
						and switched.phase == Starting(Rules.start_pause)
							and after.commands == [Unload("haze")]
								and step(after.model, idle, QueryResults.empty, 0.1).commands == []
}

# A Cleared level sends its Load once.
expect {
	open = { ..at_pose(started, before_exit), keys_left: 0 }
	finished = step(open, up_held, QueryResults.empty, 0.1).model
	step(finished, idle, QueryResults.empty, 0.1).commands == []
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

expect {
	played = play(on_level(2), [Roll, Roll, Right, Roll, Roll, Roll, Roll, Left, Leap, Roll, Roll, Roll])
	played.keys_left == 0 and played.phase == Cleared
}

expect {
	played = play(on_level(3), [Roll, Roll, Roll, Roll, Roll, Roll, Roll, Roll, Roll, Leap, Roll, Roll])
	played.keys_left == 0 and played.phase == Won
}

expect {
	open = { ..at_pose(on_level(3), before_exit), keys_left: 0 }
	finished = step(open, up_held, QueryResults.empty, 0.1)
	finished.model.phase == Won and finished.commands == []
}
