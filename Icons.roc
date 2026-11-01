import pf.Vocabulary exposing [Manifest]
import pf.Image

# The kula pack's HUD icons, which assets/source/make_icons.py draws.
Icons := [].{
	Icons : { key : U32, fruit : U32 }

	assets : List(Str)
	assets = ["image/key", "image/fruit"]

	resolve : Manifest -> Icons.Icons
	resolve = |manifest| { key: Image.resolve(manifest, "image/key"), fruit: Image.resolve(manifest, "image/fruit") }

	# Every id is 0 until the kula pack loads.
	none : Icons.Icons
	none = resolve([])
}

expect {
	icons = Icons.resolve(Icons.assets.map_with_index(|name, i| { name, id: 1 + i.to_u32_wrap(), duration: 0.0, size: { w: 64, h: 64 }, clips: [] }))
	icons == { key: 1, fruit: 2 }
}

expect Icons.none == { key: 0, fruit: 0 }
