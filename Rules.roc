import World
import Level
import Ball
import Pickup
import Flash
import View
import Score
import Clock

Rules := [].{
	# Cleared waits for the next level's Theme to load. Starting holds the seconds left before the new level plays.
	Phase : [Playing, Cleared, Starting(F32), Won]

	# pickups holds the items not yet collected. The Level keeps every item.
	# Levels count from 1. unloads holds the packs the next step unloads.
	# bounce, chime and tick are Sound ids, 0 until the kula pack loads. clock holds the steps left.
	Model : { level_number : U64, level : World.Level, ball : Ball.Ball, meshes : World.Meshes, bounce : U32, chime : U32, tick : U32, phase : Phase, keys_left : U64, pickups : List(Pickup.Pickup), score : Score.Score, flashes : List(Flash.Flash), clock : U64, unloads : List(Str) }

	start : World.Meshes, U64 -> Model
	start = |meshes, level_number| start_on(meshes, level_number, parse_or_crash(Level.text(level_number)))

	restart : Model -> Model
	restart = |model| { ..start(model.meshes, model.level_number), bounce: model.bounce, chime: model.chime, tick: model.tick, score: Score.die(model.score, model.level_number) }

	start_pause : F32
	start_pause = 1.0

	next_level : Model -> Model
	next_level = |model| { ..start(model.meshes, model.level_number + 1), bounce: model.bounce, chime: model.chime, tick: model.tick, score: model.score, phase: Starting(start_pause) }

	count_down : F32 -> (Model -> Model)
	count_down = |dt| |model| match model.phase {
		Starting(seconds) => if seconds - dt > 0.0 {
			{ ..model, phase: Starting(seconds - dt) }
		} else {
			{ ..model, phase: Playing }
		}
		_ => model
	}

	move_pickups : F32 -> (Model -> Model)
	move_pickups = |dt| |model| { ..model, pickups: model.pickups.map(|pickup| Pickup.advance(pickup, dt)) }

	fade_flashes : F32 -> (Model -> Model)
	fade_flashes = |dt| |model| { ..model, flashes: Flash.advance(model.flashes, dt) }

	# As in the original, every step tests each pickup against the ball centre
	# while the player has control. So a pickup can happen at any point of a move.
	collect : Model -> Model
	collect = |model|
		if model.phase == Playing {
			centre = View.centre(model.ball)
			taken = model.pickups.keep_if(|pickup| Pickup.touches(pickup, centre))
			keys = taken.keep_if(|pickup| pickup.kind == Key).len()
			points = taken.fold(0, |sum, pickup| sum + Pickup.points(pickup.kind))
			{ ..model, pickups: model.pickups.keep_if(|pickup| !Pickup.touches(pickup, centre)), keys_left: model.keys_left - keys, score: Score.add(model.score, points), flashes: model.flashes.concat(taken.map(Flash.at_pickup)) }
		} else {
			model
		}

	exit_open : Model -> Bool
	exit_open = |model| model.keys_left == 0

	exit : Model -> Model
	exit = |model|
		if model.phase == Playing and exit_open(model) and has_item(model.level, model.ball.pose, Exit) {
			{
				..model,
				score: Score.bank(model.score),
				phase: if model.level_number < Level.count {
					Cleared
				} else {
					Won
				},
			}
		} else {
			model
		}

	# As in the original, the clock runs only while the player has control. At 0
	# the level ends as a death, the same as a fall.
	run_clock : Model -> Model
	run_clock = |model|
		if model.phase != Playing {
			model
		} else if model.clock <= 1 {
			restart(model)
		} else {
			{ ..model, clock: model.clock - 1 }
		}

	fall : Model -> Model
	# A restart in Cleared would leave the next Theme's pack loaded with no level to take it.
	fall = |model| if model.phase != Cleared and Ball.fell_off(model.ball) {
		restart(model)
	} else {
		model
	}
}

parse_or_crash : Str -> World.Level
parse_or_crash = |text| match Level.parse(text) {
	Ok(level) => level
	Err(err) => crash "The level does not parse: ${Str.inspect(err)}"
}

start_on : World.Meshes, U64, World.Level -> Rules.Model
start_on = |meshes, level_number, level| {
	pickups = Pickup.from_level(level)
	keys = pickups.keep_if(|pickup| pickup.kind == Key).len()
	{ level_number, level, ball: Ball.start(level.start), meshes, bounce: 0, chime: 0, tick: 0, phase: Playing, keys_left: keys, pickups, score: Score.zero, flashes: [], clock: Clock.start(level.time), unloads: [] }
}

# An item counts only for a ball on its face: two items can share a cell on different faces.
has_item : World.Level, World.Pose, World.Item -> Bool
has_item = |level, pose, item| level.items.any(|entry| entry.cell == pose.cell and entry.up == pose.up and entry.item == item)

meshes : World.Meshes
meshes = { cube: 1, face: 5, ball: 4, coin: 6, sky: 1 }

cell : I32, I32, I32 -> World.Cell
cell = |x, y, z| { x, y, z }

at : Rules.Model, World.Cell -> Rules.Model
at = |model, c| { ..model, ball: Ball.start({ ..model.ball.pose, cell: c }) }

first_key : World.Cell
first_key = cell(0, 1, 7)

second_key : World.Cell
second_key = cell(0, 2, 5)

exit_cell : World.Cell
exit_cell = cell(0, 1, 0)

expect {
	model = Rules.start(meshes, 1)
	model.keys_left == 2 and model.phase == Playing and model.pickups.len() == 2 and !Rules.exit_open(model)
}

expect {
	model = Rules.collect(at(Rules.start(meshes, 1), first_key))
	model.keys_left == 1 and model.pickups.map(|pickup| pickup.cell) == [second_key]
}

# A pickup starts a flash one cell above its face.
expect Rules.collect(at(Rules.start(meshes, 1), first_key)).flashes == [{ pos: { x: 0.0, y: 1.5, z: 7.0 }, age: 0.0 }]

# Standing on a collected key does not count it twice.
expect Rules.collect(Rules.collect(at(Rules.start(meshes, 1), first_key))).keys_left == 1

expect Rules.collect(Rules.start(meshes, 1)) == Rules.start(meshes, 1)

expect {
	both = Rules.collect(at(Rules.collect(at(Rules.start(meshes, 1), first_key)), second_key))
	both.keys_left == 0 and Rules.exit_open(both)
}

expect Rules.exit(at(Rules.start(meshes, 1), exit_cell)).phase == Playing

expect {
	model = at(Rules.start(meshes, 1), first_key)
	ball = { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 0.5, spin_rate: 0.0 }) }
	Rules.fall({ ..model, ball }) == { ..model, ball }
}

expect {
	dirty = { ..Rules.collect(at(Rules.start(meshes, 1), first_key)), phase: Won }
	ball = { ..dirty.ball, motion: Falling({ from: dirty.level.start, offset: 0.0, over: dirty.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) }
	Rules.fall({ ..dirty, ball }) == Rules.start(meshes, 1)
}

expect Ok(Rules.start(meshes, 2).level) == Level.parse(Level.text(2))
expect Rules.start(meshes, 3).keys_left == 2 and Rules.start(meshes, 3).level_number == 3

# The exit of a level before the last clears it. The last level's exit wins.
expect {
	open = { ..Rules.start(meshes, 1), keys_left: 0 }
	Rules.exit(at(open, exit_cell)).phase == Cleared
}

expect {
	last = Rules.start(meshes, 3)
	open = { ..last, keys_left: 0 }
	Rules.exit(at(open, exit_cell)).phase == Won and Rules.exit(open).phase == Playing
}

# The next level starts with the ball still for a short pause.
expect {
	next = Rules.next_level({ ..Rules.start(meshes, 1), phase: Cleared })
	next.level_number == 2 and next.phase == Starting(Rules.start_pause) and next.ball == Ball.start(next.level.start) and next.keys_left == 2
}

expect Rules.count_down(0.4)({ ..Rules.start(meshes, 2), phase: Starting(1.0) }).phase == Starting(0.6)
expect Rules.count_down(1.0)({ ..Rules.start(meshes, 2), phase: Starting(1.0) }).phase == Playing
expect Rules.count_down(1.0)(Rules.start(meshes, 2)).phase == Playing

# A fall restarts the level the ball is on.
expect {
	model = Rules.start(meshes, 2)
	ball = { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) }
	Rules.fall({ ..model, ball }) == model
}

expect {
	model = { ..Rules.start(meshes, 1), phase: Cleared }
	ball = { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) }
	Rules.fall({ ..model, ball }).phase == Cleared
}

# The cell (0, 1, 0) holds a key on the +y face of block (0, 0, 0) and an item on the -x face of block (1, 1, 0).
two_faces : Str -> Rules.Model
two_faces = |item| start_on(meshes, 1, parse_or_crash("##\n\n.#\n\n0 0 0 +y key\n1 1 0 -x ${item}\nstart 1 1 0 +y -z\n"))

on_face : Rules.Model, World.Cell -> Rules.Model
on_face = |model, up| { ..model, ball: Ball.start({ cell: cell(0, 1, 0), up, forward: cell(0, 0, -1) }) }

expect {
	floor = Rules.collect(on_face(two_faces("key"), cell(0, 1, 0)))
	both = Rules.collect(on_face(floor, cell(-1, 0, 0)))
	floor.keys_left == 1 and both.keys_left == 0 and both.pickups.len() == 0 and Rules.collect(on_face(both, cell(0, 1, 0))).keys_left == 0
}

expect {
	open = Rules.collect(on_face(two_faces("exit"), cell(0, 1, 0)))
	open.keys_left == 0 and Rules.exit(open).phase == Playing and Rules.exit(on_face(open, cell(-1, 0, 0))).phase == Cleared
}

expect Rules.collect(on_face(two_faces("exit"), cell(-1, 0, 0))).keys_left == 1

# Without control the ball collects nothing.
expect {
	on_key = at(Rules.start(meshes, 1), first_key)
	[Cleared, Starting(0.5), Won].all(|phase| Rules.collect({ ..on_key, phase }).keys_left == 2)
}

# A forward jump from z 2 to z 0, with a key on the wall beside z 1 or on the floor of z 1.
jump_past : Str -> Rules.Model
jump_past = |key| start_on(meshes, 1, parse_or_crash("#.\n#.\n#.\n\n..\n.#\n..\n\n${key}\nstart 0 0 2 +y -z\n"))

jump : Rules.Model -> Rules.Model
jump = |model| { ..model, ball: Ball.act(model.level.blocks, model.ball, Jump({ up_held: True })) }

# The ball passes the wall key at the top of the jump and collects it in the air.
expect {
	model = jump(jump_past("1 1 1 -x key"))
	top = Rules.collect({ ..model, ball: Ball.advance(model.ball, 0.27) })
	top.keys_left == 0 and match top.ball.motion {
		Jumping(_) => True
		_ => False
	}
}

# The ball passes half a cell over the floor key, out of its reach, so the key stays.
expect {
	model = jump(jump_past("0 0 1 +y key"))
	landed = List.repeat(0.01, 60).fold(model, |m, dt| Rules.collect({ ..m, ball: Ball.advance(m.ball, dt) }))
	landed.ball.motion == Still and landed.ball.pose.cell == cell(0, 1, 0) and landed.keys_left == 1
}

# The same jump over a floor coin, with the coin's bob held at one phase.
over_coin : F32 -> Rules.Model
over_coin = |bob| {
	model = jump(jump_past("0 0 1 +y coin"))
	held = { ..model, pickups: model.pickups.map(|pickup| { ..pickup, bob }) }
	List.repeat(0.01, 60).fold(held, |m, dt| Rules.collect({ ..m, ball: Ball.advance(m.ball, dt) }))
}

# A coin sits 20 units higher than a key and reaches 9 units further. So the
# jump collects it near the top of its bob, 180 units up, and not near the
# bottom, 140 units up.
expect {
	high = over_coin(0.25)
	low = over_coin(0.75)
	high.pickups == [] and high.score.level == 250 and low.pickups.len() == 1 and low.score.level == 0 and low.ball.pose.cell == cell(0, 1, 0)
}

# A coin adds 250 to the level score and leaves the keys as they were.
expect {
	coin = Rules.collect(on_face(two_faces("coin"), cell(-1, 0, 0)))
	coin.score == { level: 250, total: 0 } and coin.keys_left == 1 and coin.pickups.map(|pickup| pickup.kind) == [Key] and coin.flashes.len() == 1
}

off_the_level : Rules.Model -> Rules.Model
off_the_level = |model| { ..model, ball: { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) } }

# A key adds 1000 to the level score and nothing to the total.
expect Rules.collect(at(Rules.start(meshes, 1), first_key)).score == { level: 1000, total: 0 }

# The exit banks the level score, and the next level starts from the banked total.
expect {
	open = { ..at(Rules.start(meshes, 1), exit_cell), keys_left: 0, score: { level: 2000, total: 500 } }
	cleared = Rules.exit(open)
	cleared.score == { level: 0, total: 2500 } and Rules.next_level(cleared).score == { level: 0, total: 2500 }
}

expect {
	last = { ..at(Rules.start(meshes, 3), exit_cell), keys_left: 0, score: { level: 1000, total: 0 } }
	Rules.exit(last).score == { level: 0, total: 1000 }
}

# A death on level 2 loses the level score and a penalty of 100.
expect Rules.fall(off_the_level({ ..Rules.start(meshes, 2), score: { level: 1000, total: 5000 } })).score == { level: 0, total: 3900 }

# A death with too little banked leaves the total at 0.
expect {
	first_try = Rules.collect(at(Rules.start(meshes, 1), first_key))
	Rules.fall(off_the_level(first_try)).score == Score.zero
}

expect Rules.start(meshes, 1).clock == Clock.start(Clock.default_seconds)
expect start_on(meshes, 1, parse_or_crash("S\n\ntime 45\n")).clock == Clock.start(45)

# The clock counts one step a step, only in Playing.
expect Rules.run_clock(Rules.start(meshes, 1)).clock == Clock.start(Clock.default_seconds) - 1
expect {
	model = Rules.start(meshes, 1)
	[Cleared, Starting(0.5), Won].all(|phase| Rules.run_clock({ ..model, phase }) == { ..model, phase })
}

# At 0 the level restarts with a full clock and the death penalty, as a fall does.
expect {
	model = { ..Rules.start(meshes, 2), score: { level: 1000, total: 5000 }, clock: 1 }
	timed_out = Rules.run_clock(model)
	timed_out == { ..Rules.start(meshes, 2), score: { level: 0, total: 3900 } } and timed_out == Rules.fall(off_the_level(model))
}

expect {
	model = { ..Rules.start(meshes, 1), clock: 2 }
	Rules.run_clock(model).clock == 1 and Rules.run_clock(Rules.run_clock(model)).clock == Clock.start(Clock.default_seconds)
}

# The sound ids survive a restart and a new level.
expect {
	model = { ..Rules.start(meshes, 1), bounce: 3, tick: 4, clock: 1 }
	restarted = Rules.run_clock(model)
	next = Rules.next_level({ ..model, phase: Cleared })
	restarted.tick == 4 and restarted.bounce == 3 and next.tick == 4 and next.clock == Clock.start(Clock.default_seconds)
}
