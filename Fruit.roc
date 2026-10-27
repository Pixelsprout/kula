# The original's five fruits. A game collects at most one of each.
Fruit := [].{
	Kind : [Apple, Watermelon, Pumpkin, Banana, Strawberry]

	# now holds the fruit collected so far, in the order of `kinds`. saved
	# holds the set at the last exit, which a death brings back.
	Fruits : { now : List(Fruit.Kind), saved : List(Fruit.Kind) }

	none : Fruit.Fruits
	none = { now: [], saved: [] }

	# The order in which the levels show the fruits.
	kinds : List(Fruit.Kind)
	kinds = [Apple, Watermelon, Pumpkin, Banana, Strawberry]

	# A level shows the first fruit not yet collected. With all five, the
	# original shows the fruit its level file names. Kula's level files name
	# no fruit, so Kula shows the last one.
	next : Fruit.Fruits -> Fruit.Kind
	next = |fruits| kinds.find_first(|kind| !fruits.now.contains(kind)) ?? Strawberry

	collect : Fruit.Fruits, Fruit.Kind -> Fruit.Fruits
	collect = |fruits, kind|
		if fruits.now.contains(kind) {
			fruits
		} else {
			{ ..fruits, now: kinds.keep_if(|k| k == kind or fruits.now.contains(k)) }
		}

	bank : Fruit.Fruits -> Fruit.Fruits
	bank = |fruits| { now: fruits.now, saved: fruits.now }

	die : Fruit.Fruits -> Fruit.Fruits
	die = |fruits| { now: fruits.saved, saved: fruits.saved }

	count : Fruit.Fruits -> U64
	count = |fruits| fruits.now.len()
}

expect Fruit.next(Fruit.none) == Apple

# Each fruit collected moves the level's fruit on by one, in the original's order.
expect {
	shown = Fruit.kinds.fold(
		{ fruits: Fruit.none, shown: [] },
		|so_far, _| {
			kind = Fruit.next(so_far.fruits)
			{ fruits: Fruit.collect(so_far.fruits, kind), shown: so_far.shown.append(kind) }
		},
	)
	shown.shown == Fruit.kinds and Fruit.count(shown.fruits) == 5 and Fruit.next(shown.fruits) == Strawberry
}

# A gap in the set shows first: with only the watermelon, the next fruit is the apple.
expect Fruit.next(Fruit.collect(Fruit.none, Watermelon)) == Apple

expect Fruit.collect(Fruit.collect(Fruit.none, Apple), Apple) == { now: [Apple], saved: [] }

# A death keeps only the fruit that an exit saved.
expect {
	banked = Fruit.bank(Fruit.collect(Fruit.none, Apple))
	lost = Fruit.die(Fruit.collect(banked, Watermelon))
	banked == { now: [Apple], saved: [Apple] } and lost == banked and Fruit.next(lost) == Watermelon
}
