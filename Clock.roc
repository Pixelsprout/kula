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

	# The Time panel shows from 50 s. Its text goes from black at 50 s to nearly full at 1 s.
	brightness : U64 -> Try(F32, [Hidden])
	brightness = |steps| {
		seconds = shown(steps)
		if seconds > fade_from {
			Err(Hidden)
		} else {
			Ok((fade_from - seconds).to_f32() / fade_from.to_f32())
		}
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

fade_from : U64
fade_from = 50

tick_from : U64
tick_from = 20

# The original plays the tick at 8000 - 10 x (frames - 250) when 50k - 1 frames
# are left, and the bounce at 7000. Kula plays the bounce at gain 1.
tick_gain : U64 -> F32
tick_gain = |seconds| (10510.0 - 500.0 * seconds.to_f32()) / 7000.0

expect Clock.start(Clock.default_seconds) == 11880

expect Clock.shown(Clock.start(99)) == 100 and Clock.shown(Clock.start(99) - 1) == 99 and Clock.shown(1) == 1 and Clock.shown(0) == 1

expect Clock.brightness(Clock.start(50)) == Err(Hidden)
expect Clock.brightness(Clock.start(50) - 1) == Ok(0.0)
expect Clock.brightness(Clock.start(45) - 1) == Ok(0.1)
expect Clock.brightness(0) == Ok(0.98)

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
