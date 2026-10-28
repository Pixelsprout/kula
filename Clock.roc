# The level clock counts whole steps left, so it does not drift as a sum of dt would.
Clock := [].{
	# main.roc launches with this rate, so a step is always 1 / step_hz seconds.
	step_hz : U32
	step_hz = 120

	# One frame of the original, which runs at 50 frames a second on PAL.
	pal_frame : F32
	pal_frame = 0.02

	# The original's 4950 frames, for a level with no settings record.
	default_seconds : U64
	default_seconds = 99

	start : U64 -> U64
	start = |seconds| seconds * step_hz.to_u64()

	# As in the original, the clock shows 1 more than the whole seconds left, so it reads 1 in the last second.
	shown : U64 -> U64
	shown = |steps| 1 + steps // step_hz.to_u64()

	# A change from the original: the Time panel shows for the whole level. It shows at most
	# the start time, so it does not read 1 more than the start time before the clock runs.
	panel_seconds : { steps_left : U64, start_seconds : U64 } -> U64
	panel_seconds = |{ steps_left, start_seconds }| shown(steps_left).min(start_seconds)

	# A change from the original, which turns the digits black at 50 s and fades them in.
	# Kula dims the white text to grey and back over the last 50 s, so it does not flash.
	panel_shade : { seconds : U64 } -> F32
	panel_shade = |{ seconds }| if seconds >= dim_from {
		1.0
	} else {
		from_grey = if seconds > grey_at {
			seconds - grey_at
		} else {
			grey_at - seconds
		}
		grey + (1.0 - grey) * from_grey.to_f32() / grey_at.to_f32()
	}

	# A tick plays each time the shown seconds drop to 20 or less, down to 1.
	# Its gain rises as the time runs out. A restart sets the clock back up, so it does not tick.
	tick : U64, U64 -> Try(F32, [NoTick])
	tick = |before, after| {
		seconds = shown(after)
		if after > 0 and after < before and seconds < shown(before) and seconds <= tick_from {
			Ok(tick_gain(seconds))
		} else {
			Err(NoTick)
		}
	}
}

dim_from : U64
dim_from = 50

grey_at : U64
grey_at = dim_from // 2

# Dark enough to see the change, light enough to read over the half-black panel on the Hiro sky.
grey : F32
grey = 0.6

tick_from : U64
tick_from = 20

# The original plays the tick at 8000 - 10 x (frames - 250) when 50k - 1 frames
# are left, and the bounce at 7000. Kula plays the bounce at gain 1.
tick_gain : U64 -> F32
tick_gain = |seconds| (10510.0 - 500.0 * seconds.to_f32()) / 7000.0

expect Clock.start(Clock.default_seconds) == 11880

expect Clock.shown(Clock.start(99)) == 100 and Clock.shown(Clock.start(99) - 1) == 99 and Clock.shown(1) == 1 and Clock.shown(0) == 1

expect Clock.panel_seconds({ steps_left: Clock.start(99), start_seconds: 99 }) == 99
expect Clock.panel_seconds({ steps_left: Clock.start(98), start_seconds: 99 }) == 99 and Clock.panel_seconds({ steps_left: Clock.start(98) - 1, start_seconds: 99 }) == 98
expect Clock.panel_seconds({ steps_left: Clock.start(45), start_seconds: 45 }) == 45 and Clock.panel_seconds({ steps_left: 1, start_seconds: 99 }) == 1

near : F32, F32 -> Bool
near = |a, b| (a - b).abs() < 0.0001

expect Clock.panel_shade({ seconds: 99 }) == 1.0 and Clock.panel_shade({ seconds: 51 }) == 1.0 and Clock.panel_shade({ seconds: 50 }) == 1.0
expect near(Clock.panel_shade({ seconds: 45 }), 0.92) and near(Clock.panel_shade({ seconds: 25 }), 0.6) and near(Clock.panel_shade({ seconds: 10 }), 0.84)
expect near(Clock.panel_shade({ seconds: 1 }), 0.984)

# The shade never jumps from one second to the next.
expect {
	shades = List.repeat(0, 60).map_with_index(|_, i| Clock.panel_shade({ seconds: i.to_u64() }))
	steps = shades.drop_first(1).map_with_index(|shade, i| (shade - shades.get(i).ok_or(0.0)).abs())
	steps.all(|step| step < 0.017)
}

expect Clock.tick(Clock.start(21), Clock.start(21) - 1) == Err(NoTick)
expect Clock.tick(Clock.start(20), Clock.start(20) - 1) == Ok(510.0 / 7000.0)
expect Clock.tick(Clock.start(20) - 1, Clock.start(20) - 2) == Err(NoTick)
expect Clock.tick(Clock.start(1), Clock.start(1) - 1) == Ok(10010.0 / 7000.0)
expect Clock.tick(1, 0) == Err(NoTick)
expect Clock.tick(Clock.start(5), Clock.start(99)) == Err(NoTick)

# One tick a second in the last 20 s, each louder than the one before.
expect {
	gains = List.repeat(0, Clock.start(30)).map_with_index(|_, i| i.to_u64() + 1).keep_oks(|steps| Clock.tick(steps, steps - 1))
	gains.len() == 20 and gains.first() == Ok(10010.0 / 7000.0) and gains.last() == Ok(510.0 / 7000.0)
}
