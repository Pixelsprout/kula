import World
import Level
import Ball
import Pickup
import Flash
import Score
import Clock
import Fruit
import Sounds
import Ending

Rules := [].{
	# Exiting holds the seconds left before the level ends, once the ball is on the
	# open exit. Ending runs the level end sequence. Cleared keeps it on screen
	# while the next level's Theme loads. Starting holds the seconds left before
	# the new level plays.
	Phase : [Playing, Exiting(F32), Ending(Ending.Ending), Cleared(Ending.Ending), Starting(F32), Won]

	# pickups holds the items not yet collected. The Level keeps every item.
	# Levels count from 1. unloads holds the packs the next step unloads.
	# clock holds the steps left.
	Model : { level_number : U64, level : World.Level, ball : Ball.Ball, meshes : World.Meshes, sounds : Sounds.Sounds, phase : Phase, keys_left : U64, pickups : List(Pickup.Pickup), score : Score.Score, fruits : Fruit.Fruits, flashes : List(Flash.Flash), clock : U64, unloads : List(Str) }

	start : World.Meshes, U64 -> Model
	start = |meshes, level_number| start_numbered(meshes, level_number, Fruit.none)

	restart : Model -> Model
	restart = |model| { ..start_numbered(model.meshes, model.level_number, Fruit.die(model.fruits)), sounds: model.sounds, score: Score.die(model.score, model.level_number) }

	start_pause : F32
	start_pause = 1.0

	next_level : Model -> Model
	next_level = |model| { ..start_numbered(model.meshes, model.level_number + 1, model.fruits), sounds: model.sounds, score: model.score, phase: Starting(start_pause) }

	count_down : F32 -> (Model -> Model)
	count_down = |dt| |model| match model.phase {
		Starting(seconds) => if seconds - dt > 0.0 {
			{ ..model, phase: Starting(seconds - dt) }
		} else {
			{ ..model, phase: Playing }
		}
		Exiting(seconds) => if seconds - dt > 0.0 {
			{ ..model, phase: Exiting(seconds - dt) }
		} else {
			end_level(model)
		}
		_ => model
	}

	# pressed is a press of Space or South in this step. Each level but the last goes on to Cleared.
	run_ending : Bool, F32 -> (Model -> Model)
	run_ending = |pressed, dt| |model| match model.phase {
		Ending(ending) => {
			later = Ending.advance(ending, dt)
			if pressed {
				match Ending.press(later) {
					Skip(skipped) => { ..model, phase: Ending(skipped) }
					Go => if model.level_number < Level.count {
						{ ..model, phase: Cleared(later) }
					} else {
						{ ..model, phase: Won }
					}
				}
			} else {
				{ ..model, phase: Ending(later) }
			}
		}
		Cleared(ending) => { ..model, phase: Cleared(Ending.advance(ending, dt)) }
		_ => model
	}

	# The level end sequence, from the level end until the next level starts.
	ending : Phase -> Try(Ending.Ending, [NotEnded])
	ending = |phase| match phase {
		Ending(sequence) => Ok(sequence)
		Cleared(sequence) => Ok(sequence)
		_ => Err(NotEnded)
	}

	cleared : Phase -> Bool
	cleared = |phase| match phase {
		Cleared(_) => True
		_ => False
	}

	move_pickups : F32 -> (Model -> Model)
	move_pickups = |dt| |model| { ..model, pickups: model.pickups.map(|pickup| Pickup.advance(pickup, dt)) }

	fade_flashes : F32 -> (Model -> Model)
	fade_flashes = |dt| |model| { ..model, flashes: Flash.advance(model.flashes, dt) }

	# As in the original, every step tests each pickup against the ball centre
	# while the player has control. So a pickup can happen at any point of a move.
	collect : Model -> Model
	collect = |model|
		if plays(model.phase) {
			centre = Ball.centre(model.ball)
			split = model.pickups.fold(
				{ taken: [], left: [] },
				|so_far, pickup|
					if Pickup.touches(pickup, centre) {
						{ ..so_far, taken: so_far.taken.append(pickup) }
					} else {
						{ ..so_far, left: so_far.left.append(pickup) }
					},
			)
			taken = split.taken
			points = taken.fold(0, |sum, pickup| sum + Pickup.points(pickup.kind))
			fruits = taken.fold(model.fruits, |so_far, pickup| Pickup.add_fruit(so_far, pickup.kind))
			{ ..model, pickups: split.left, keys_left: model.keys_left - taken.keep_if(|pickup| pickup.kind == Key).len(), score: Score.add(model.score, points), fruits, flashes: model.flashes.concat(taken.map(Flash.at_pickup)) }
		} else {
			model
		}

	exit_open : Model -> Bool
	exit_open = |model| model.keys_left == 0

	# As in the original, a landing on the open exit ends the level in the next
	# step. A roll ends it 5 PAL frames after the ball reaches the exit cell, and
	# the ball rolls on toward the cell centre.
	exit : Model -> Model
	exit = |model|
		if model.phase == Playing and exit_open(model) and on_exit(model) {
			{
				..model,
				phase: Exiting(
					if model.ball.motion == Still {
						0.0
					} else {
						exit_delay
					},
				),
			}
		} else {
			model
		}

	# As in the original, the clock runs only while the level plays. At 0 the
	# level ends as a death, the same as a fall.
	run_clock : Model -> Model
	run_clock = |model|
		if !plays(model.phase) {
			model
		} else if model.clock <= 1 {
			restart(model)
		} else {
			{ ..model, clock: model.clock - 1 }
		}

	fall : Model -> Model
	# After the level end, a restart would take back the banked score. In Cleared
	# it would also leave the next Theme's pack loaded with no level to take it.
	fall = |model| if Rules.ending(model.phase) == Err(NotEnded) and Ball.fell_off(model.ball) {
		restart(model)
	} else {
		model
	}
}

# As in the original, the level keeps playing in the frames before an exit ends
# it: the clock runs and the ball collects. Only the input stops.
plays : Rules.Phase -> Bool
plays = |phase| match phase {
	Playing => True
	Exiting(_) => True
	_ => False
}

on_exit : Rules.Model -> Bool
on_exit = |model| match Ball.standing(model.ball) {
	Ok(pose) => has_item(model.level, pose, Exit)
	Err(InAir) => False
}

exit_delay : F32
exit_delay = 0.1

# As in the original, the score and the fruit bank when the level ends, not when the ball reaches the exit.
end_level : Rules.Model -> Rules.Model
end_level = |model| { ..model, score: Score.bank(model.score), fruits: Fruit.bank(model.fruits), phase: Ending(Ending.start(model.score.level)) }

parse_or_crash : Str -> World.Level
parse_or_crash = |text| match Level.parse(text) {
	Ok(level) => level
	Err(err) => crash "The level does not parse: ${Str.inspect(err)}"
}

start_numbered : World.Meshes, U64, Fruit.Fruits -> Rules.Model
start_numbered = |meshes, level_number, fruits| start_parsed(meshes, level_number, parse_or_crash(Level.text(level_number)), fruits)

# Tests pass in a level parsed from their own text. The level shows the first fruit not in fruits.
start_parsed : World.Meshes, U64, World.Level, Fruit.Fruits -> Rules.Model
start_parsed = |meshes, level_number, level, fruits| {
	pickups = Pickup.from_level(level, Fruit.next(fruits))
	{ level_number, level, ball: Ball.start(level.start), meshes, sounds: Sounds.none, phase: Playing, keys_left: Level.keys(level), pickups, score: Score.zero, fruits, flashes: [], clock: Clock.start(level.time), unloads: [] }
}

# An item counts only for a ball on its face: two items can share a cell on different faces.
has_item : World.Level, World.Pose, World.Item -> Bool
has_item = |level, pose, item| level.items.any(|entry| entry.cell == pose.cell and entry.up == pose.up and entry.item == item)

meshes : World.Meshes
meshes = { cube: 1, sphere: 2, face: 5, ball: 4, coin: 6, apple: 7, watermelon: 8, pumpkin: 9, sky: 1 }

cell : I32, I32, I32 -> World.Cell
cell = |x, y, z| { x, y, z }

at : Rules.Model, World.Cell -> Rules.Model
at = |model, c| { ..model, ball: Ball.start({ ..model.ball.pose, cell: c }) }

key_cell : World.Cell
key_cell = cell(3, 1, 3)

exit_cell : World.Cell
exit_cell = cell(0, 1, 0)

last_exit_cell : World.Cell
last_exit_cell = cell(7, 1, 6)

expect {
	model = Rules.start(meshes, 1)
	model.keys_left == 1 and model.phase == Playing and model.pickups.map(|pickup| pickup.kind) == [Coin, Coin, Fruit(Apple), Key] and !Rules.exit_open(model)
}

expect {
	model = Rules.collect(at(Rules.start(meshes, 1), key_cell))
	model.keys_left == 0 and Rules.exit_open(model) and model.pickups.map(|pickup| pickup.kind) == [Coin, Coin, Fruit(Apple)]
}

# A pickup starts a flash one cell above its face.
expect Rules.collect(at(Rules.start(meshes, 1), key_cell)).flashes == [{ pos: { x: 3.0, y: 1.5, z: 3.0 }, age: 0.0, kind: Key }]

# Standing on a collected key does not count it twice.
expect Rules.collect(Rules.collect(at(Rules.start(meshes, 1), key_cell))).keys_left == 0

expect Rules.collect(Rules.start(meshes, 1)) == Rules.start(meshes, 1)

expect Rules.exit(at(Rules.start(meshes, 1), exit_cell)).phase == Playing

expect {
	model = at(Rules.start(meshes, 1), key_cell)
	ball = { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 0.5, spin_rate: 0.0 }) }
	Rules.fall({ ..model, ball }) == { ..model, ball }
}

expect {
	dirty = { ..Rules.collect(at(Rules.start(meshes, 1), key_cell)), phase: Won }
	ball = { ..dirty.ball, motion: Falling({ from: dirty.level.start, offset: 0.0, over: dirty.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) }
	Rules.fall({ ..dirty, ball }) == Rules.start(meshes, 1)
}

expect Ok(Rules.start(meshes, 2).level) == Level.parse(Level.text(2))
expect Rules.start(meshes, 3).keys_left == 1 and Rules.start(meshes, 3).level_number == 3

# The ball still on the open exit ends the level in the next step.
expect {
	open = { ..Rules.start(meshes, 1), keys_left: 0 }
	reached = Rules.exit(at(open, exit_cell))
	reached.phase == Exiting(0.0) and Rules.count_down(0.01)(reached).phase == Ending(Ending.start(0))
}

expect {
	last = Rules.start(meshes, 3)
	open = { ..last, keys_left: 0 }
	Rules.exit(at(open, last_exit_cell)).phase == Exiting(0.0) and Rules.exit(open).phase == Playing
}

# A roll from (0, 1, 1) onto the open exit at roll progress t.
rolling_onto_exit : F32 -> Rules.Model
rolling_onto_exit = |t| {
	open = { ..at(Rules.start(meshes, 1), exit_cell), keys_left: 0 }
	{ ..open, ball: { ..open.ball, motion: Rolling({ from: { ..open.ball.pose, cell: cell(0, 1, 1) }, t }) } }
}

# A roll reaches the exit half way, then the level ends 0.1 s later.
expect {
	reached = Rules.exit(rolling_onto_exit(0.5))
	waiting = Rules.count_down(0.05)(reached)
	Rules.exit(rolling_onto_exit(0.45)).phase == Playing
		and reached.phase == Exiting(0.1)
			and waiting.phase == Exiting(0.05)
				and Rules.count_down(0.05)(waiting).phase == Ending(Ending.start(0))
}

# Finishes a level whose ball stands on the open exit.
finish : Rules.Model -> Rules.Model
finish = |model| Rules.count_down(0.01)(Rules.exit(model))

# In Ending the first press finishes the banner and the count. The next press
# goes on: to Cleared before the last level, to Won after it.
expect {
	ended = finish({ ..at(Rules.start(meshes, 1), exit_cell), keys_left: 0, score: { level: 3000, total: 0 } })
	skipped = Rules.run_ending(True, 0.01)(ended)
	cleared = Rules.run_ending(True, 0.01)(skipped)
	last = finish({ ..at(Rules.start(meshes, 3), last_exit_cell), keys_left: 0 })
	skipped.phase == Ending({ seconds: 0.01, banked: 3000, skipped: True })
		and cleared.phase == Cleared({ seconds: 0.02, banked: 3000, skipped: True })
			and Rules.run_ending(False, 0.5)(cleared).phase == Cleared({ seconds: 0.52, banked: 3000, skipped: True })
				and Rules.run_ending(True, 0.01)(Rules.run_ending(True, 0.01)(last)).phase == Won
}

# With no press the sequence runs on and waits.
expect {
	ended = finish({ ..at(Rules.start(meshes, 1), exit_cell), keys_left: 0 })
	waited = Rules.run_ending(False, 3.0)(ended)
	waited.phase == Ending({ seconds: 3.0, banked: 0, skipped: False }) and Rules.run_ending(True, 0.01)(waited).phase == Cleared({ seconds: 3.01, banked: 0, skipped: False })
}

# The next level starts with the ball still for a short pause.
expect {
	next = Rules.next_level({ ..Rules.start(meshes, 1), phase: Cleared(Ending.start(0)) })
	next.level_number == 2 and next.phase == Starting(Rules.start_pause) and next.ball == Ball.start(next.level.start) and next.keys_left == 1
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
	model = Rules.start(meshes, 1)
	ball = { ..model.ball, motion: Falling({ from: model.level.start, offset: 0.0, over: model.level.start, drop: Off(3), seconds: 1.0, spin_rate: 0.0 }) }
	[Ending(Ending.start(0)), Cleared(Ending.start(0))].all(|phase| Rules.fall({ ..model, ball, phase }).phase == phase)
}

# The cell (0, 1, 0) holds a key on the +y face of block (0, 0, 0) and an item on the -x face of block (1, 1, 0).
two_faces : Str -> Rules.Model
two_faces = |item| start_parsed(meshes, 1, parse_or_crash("##\n\n.#\n\n0 0 0 +y key\n1 1 0 -x ${item}\nstart 1 1 0 +y -z\n"), Fruit.none)

on_face : Rules.Model, World.Cell -> Rules.Model
on_face = |model, up| { ..model, ball: Ball.start({ cell: cell(0, 1, 0), up, forward: cell(0, 0, -1) }) }

expect {
	floor = Rules.collect(on_face(two_faces("key"), cell(0, 1, 0)))
	both = Rules.collect(on_face(floor, cell(-1, 0, 0)))
	floor.keys_left == 1 and both.keys_left == 0 and both.pickups.len() == 0 and Rules.collect(on_face(both, cell(0, 1, 0))).keys_left == 0
}

expect {
	open = Rules.collect(on_face(two_faces("exit"), cell(0, 1, 0)))
	open.keys_left == 0 and Rules.exit(open).phase == Playing and Rules.exit(on_face(open, cell(-1, 0, 0))).phase == Exiting(0.0)
}

expect Rules.collect(on_face(two_faces("exit"), cell(-1, 0, 0))).keys_left == 1

# Without control the ball collects nothing. In the frames before an exit ends the level, it still collects.
expect {
	on_key = at(Rules.start(meshes, 1), key_cell)
	[Ending(Ending.start(0)), Cleared(Ending.start(0)), Starting(0.5), Won].all(|phase| Rules.collect({ ..on_key, phase }).keys_left == 1)
		and Rules.collect({ ..on_key, phase: Exiting(0.1) }).keys_left == 0
}

# A forward jump from z 2 to z 0, with a key on the wall beside z 1 or on the floor of z 1.
jump_past : Str -> Rules.Model
jump_past = |key| start_parsed(meshes, 1, parse_or_crash("#.\n#.\n#.\n\n..\n.#\n..\n\n${key}\nstart 0 0 2 +y -z\n"), Fruit.none)

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

# The jump collects a coin only near the top of its bob.
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
expect Rules.collect(at(Rules.start(meshes, 1), key_cell)).score == { level: 1000, total: 0 }

# The level end banks the level score, and the next level starts from the banked total.
expect {
	open = { ..at(Rules.start(meshes, 1), exit_cell), keys_left: 0, score: { level: 2000, total: 500 } }
	ended = finish(open)
	Rules.exit(open).score == open.score and ended.score == { level: 0, total: 2500 } and ended.phase == Ending(Ending.start(2000)) and Rules.next_level(ended).score == { level: 0, total: 2500 }
}

expect {
	last = { ..at(Rules.start(meshes, 3), last_exit_cell), keys_left: 0, score: { level: 1000, total: 0 } }
	finish(last).score == { level: 0, total: 1000 }
}

# A death on level 2 loses the level score and a penalty of 100.
expect Rules.fall(off_the_level({ ..Rules.start(meshes, 2), score: { level: 1000, total: 5000 } })).score == { level: 0, total: 3900 }

# A death with too little banked leaves the total at 0.
expect {
	first_try = Rules.collect(at(Rules.start(meshes, 1), key_cell))
	Rules.fall(off_the_level(first_try)).score == Score.zero
}

expect Rules.start(meshes, 1).clock == Clock.start(Clock.default_seconds)
expect start_parsed(meshes, 1, parse_or_crash("S\n\ntime 45\n"), Fruit.none).clock == Clock.start(45)

# The clock counts one step a step, only in Playing.
expect Rules.run_clock(Rules.start(meshes, 1)).clock == Clock.start(Clock.default_seconds) - 1
expect {
	model = Rules.start(meshes, 1)
	[Ending(Ending.start(0)), Cleared(Ending.start(0)), Starting(0.5), Won].all(|phase| Rules.run_clock({ ..model, phase }) == { ..model, phase })
		and Rules.run_clock({ ..model, phase: Exiting(0.1) }).clock == Clock.start(Clock.default_seconds) - 1
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
	sounds = { bounce: 3, chime: 6, tick: 4, jingle: 5 }
	model = { ..Rules.start(meshes, 1), sounds, clock: 1 }
	restarted = Rules.run_clock(model)
	next = Rules.next_level({ ..model, phase: Cleared(Ending.start(0)) })
	restarted.sounds == sounds and next.sounds == sounds and next.clock == Clock.start(Clock.default_seconds)
}

# The exit sits on the +y face of block (0, 0, 0) and a fruit on the -x face of block (1, 1, 0). The level has no keys.
fruit_level : Fruit.Fruits -> Rules.Model
fruit_level = |fruits| start_parsed(meshes, 1, parse_or_crash("##\n\n.#\n\n0 0 0 +y exit\n1 1 0 -x fruit\nstart 1 1 0 +y -z\n"), fruits)

on_fruit : Rules.Model -> Rules.Model
on_fruit = |model| on_face(model, cell(-1, 0, 0))

# A fresh game shows an apple. The apple adds 2500 to the level score and joins the fruit set.
expect {
	picked = Rules.collect(on_fruit(fruit_level(Fruit.none)))
	fruit_level(Fruit.none).pickups.map(|pickup| pickup.kind) == [Fruit(Apple)]
		and picked.pickups == []
			and picked.score == { level: 2500, total: 0 }
				and picked.fruits == { now: [Apple], saved: [] }
					and picked.flashes.map(|flash| flash.kind) == [Fruit(Apple)]
}

# Each level shows the first fruit the set lacks: an apple, then a watermelon, then a pumpkin.
expect {
	shown = |kinds| fruit_level(Fruit.bank(kinds.fold(Fruit.none, Fruit.collect))).pickups.map(|pickup| pickup.kind)
	shown([Apple]) == [Fruit(Watermelon)] and shown([Apple, Watermelon]) == [Fruit(Pumpkin)] and shown([Watermelon]) == [Fruit(Apple)]
}

# The exit keeps the fruit for the next level. A later fall does not take it back.
expect {
	picked = Rules.collect(on_fruit(fruit_level(Fruit.none)))
	cleared = finish(on_face(picked, cell(0, 1, 0)))
	next = Rules.next_level(cleared)
	cleared.phase == Ending(Ending.start(2500)) and cleared.fruits == { now: [Apple], saved: [Apple] } and next.fruits == cleared.fruits and Rules.fall(off_the_level(next)).fruits == cleared.fruits
}

# A fall loses the fruit of the try, as it loses the level score.
expect {
	picked = Rules.collect(on_fruit(fruit_level(Fruit.none)))
	fell = Rules.fall(off_the_level(picked))
	fell.fruits == Fruit.none and fell.score == Score.zero
}

# A fall keeps the fruit that an earlier exit saved and loses the one collected since.
expect {
	picked = Rules.collect(on_fruit(fruit_level(Fruit.bank(Fruit.collect(Fruit.none, Apple)))))
	picked.fruits.now == [Apple, Watermelon] and Rules.fall(off_the_level(picked)).fruits == { now: [Apple], saved: [Apple] }
}

# At 0 the level restarts with the fruit set of the last exit, as a fall does.
expect {
	picked = { ..Rules.collect(on_fruit(fruit_level(Fruit.bank(Fruit.collect(Fruit.none, Apple))))), clock: 1 }
	Rules.run_clock(picked).fruits == { now: [Apple], saved: [Apple] }
}
