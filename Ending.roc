# The level end sequence, as the original shows it after an exit. The banner
# fades in while the level score counts up. A press finishes both, and the
# next press goes on.
Ending := [].{
	# seconds counts from the level end. banked is the level score that the exit added to the total.
	Ending : { seconds : F32, banked : U64, skipped : Bool }

	start : U64 -> Ending.Ending
	start = |banked| { seconds: 0.0, banked, skipped: False }

	advance : Ending.Ending, F32 -> Ending.Ending
	advance = |ending, dt| { ..ending, seconds: ending.seconds + dt }

	# As in the original, a press before the banner and the count finish only finishes them.
	press : Ending.Ending -> [Skip(Ending.Ending), Go]
	press = |ending|
		if Ending.finished(ending) {
			Go
		} else {
			Skip({ ..ending, skipped: True })
		}

	finished : Ending.Ending -> Bool
	finished = |ending| Ending.banner(ending) >= 1.0 and Ending.counted(ending) == ending.banked

	# The banner's alpha, from 0 to 1.
	banner : Ending.Ending -> F32
	banner = |ending|
		if ending.skipped or ending.seconds >= banner_seconds {
			1.0
		} else {
			ending.seconds / banner_seconds
		}

	# The part of the banked level score shown so far. It rises by 100 a PAL frame.
	counted : Ending.Ending -> U64
	counted = |ending| {
		frames = (ending.seconds / pal_frame).to_u64_try() ?? 0
		shown = frames * count_rate
		if ending.skipped or shown >= ending.banked {
			ending.banked
		} else {
			shown
		}
	}
}

pal_frame : F32
pal_frame = 0.02

# The original adds 3 a frame to the banner's fade, up to 256.
banner_seconds : F32
banner_seconds = 256.0 / 3.0 * pal_frame

count_rate : U64
count_rate = 100

expect Ending.banner(Ending.start(0)) == 0.0 and Ending.counted(Ending.start(4000)) == 0

# The banner is half in after 0.85 s. 4000 points take 40 frames, 0.8 s.
expect {
	half = Ending.advance(Ending.start(4000), 0.5 * banner_seconds)
	counting = Ending.advance(Ending.start(4000), 0.5)
	half.seconds == 0.5 * banner_seconds and Ending.banner(half) == 0.5 and Ending.counted(counting) == 2500 and Ending.counted(Ending.advance(counting, 0.4)) == 4000
}

expect !Ending.finished(Ending.advance(Ending.start(4000), 1.7)) and Ending.finished(Ending.advance(Ending.start(4000), 1.71))

# A long count outlasts the banner.
expect !Ending.finished(Ending.advance(Ending.start(10_000), 1.8)) and Ending.finished(Ending.advance(Ending.start(10_000), 2.0))

# The first press finishes the banner and the count. Only a press after that goes on.
expect {
	early = Ending.advance(Ending.start(4000), 0.3)
	match Ending.press(early) {
		Skip(skipped) => Ending.banner(skipped) == 1.0 and Ending.counted(skipped) == 4000 and skipped.seconds == early.seconds and Ending.press(skipped) == Go
		Go => False
	}
}

expect Ending.press(Ending.advance(Ending.start(0), 2.0)) == Go
