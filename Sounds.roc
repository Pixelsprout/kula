import pf.Vocabulary exposing [Manifest]
import pf.Sound

# The kula pack's sounds, which assets/source/make_sounds.py writes. A new
# sound adds a field to Sounds, a name to assets and a row to resolve.
Sounds := [].{
	Sounds : { bounce : U32, chime : U32, tick : U32, jingle : U32 }

	assets : List(Str)
	assets = ["sound/bounce", "sound/chime", "sound/tick", "sound/jingle"]

	resolve : Manifest -> Sounds.Sounds
	resolve = |manifest| {
		id = |name| Sound.resolve(manifest, name)
		{ bounce: id("sound/bounce"), chime: id("sound/chime"), tick: id("sound/tick"), jingle: id("sound/jingle") }
	}

	# Every id is 0, which plays nothing, until the kula pack loads.
	none : Sounds.Sounds
	none = resolve([])
}

# Each asset resolves to its own field.
expect {
	sounds = Sounds.resolve(Sounds.assets.map_with_index(|name, i| { name, id: 1 + i.to_u32_wrap(), duration: 0.0, clips: [] }))
	[sounds.bounce, sounds.chime, sounds.tick, sounds.jingle] == [1, 2, 3, 4]
}

expect Sounds.none == { bounce: 0, chime: 0, tick: 0, jingle: 0 }
