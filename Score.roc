# The original keeps two scores. level holds the points of the current try at
# a level. total holds the points the exits have banked.
Score := [].{
	Score : { level : U64, total : U64 }

	zero : Score.Score
	zero = { level: 0, total: 0 }

	add : Score.Score, U64 -> Score.Score
	add = |score, points| { ..score, level: score.level + points }

	# The exit moves the level points to the total, so a later death cannot take them twice.
	bank : Score.Score -> Score.Score
	bank = |score| { level: 0, total: score.total + score.level }

	# A death takes the level points and a penalty off the total. The original
	# ends the game below 0. Kula has no game over, so the total stops at 0.
	die : Score.Score, U64 -> Score.Score
	die = |score, level_number| {
		loss = score.level + penalty(level_number)
		total = if loss > score.total {
			0
		} else {
			score.total - loss
		}
		{ level: 0, total }
	}

	# The original's level index counts from 0 and adds 1. Kula's level number already counts from 1.
	penalty : U64 -> U64
	penalty = |level_number| {
		points = level_number * 50
		if points > max_penalty {
			max_penalty
		} else {
			points
		}
	}
}

max_penalty : U64
max_penalty = 5000

expect Score.add(Score.zero, 1000) == { level: 1000, total: 0 }

expect Score.bank({ level: 1000, total: 2500 }) == { level: 0, total: 3500 }

expect Score.die({ level: 1000, total: 5000 }, 2) == { level: 0, total: 3900 }

expect Score.die({ level: 1000, total: 1000 }, 1) == { level: 0, total: 0 }

expect Score.die(Score.zero, 1) == Score.zero

expect Score.penalty(1) == 50 and Score.penalty(100) == 5000 and Score.penalty(150) == 5000
