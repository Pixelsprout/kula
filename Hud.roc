import pf.Vocabulary exposing [Element]
import ui.Ui
import Rules
import View
import Ball

Hud := [].{
	ui : Rules.Model -> List(Element)
	ui = |model| {
		total = model.level.items.keep_if(|entry| entry.item == Key).len()
		collected = total - model.keys_left
		[Box(Ui.panel(LeftTop, { x: 16.0, y: 16.0 }), [Text(Ui.label("Keys ${collected.to_str()} / ${total.to_str()}"))])]
	}
}

# The ball stands on level 1's first key, then collects it.
one_key : Rules.Model
one_key = {
	start = Rules.start(View.primitive_meshes, 1)
	Rules.collect({ ..start, ball: Ball.start({ ..start.ball.pose, cell: { x: 0, y: 1, z: 7 } }) })
}

# The HUD is one panel in the top-left corner that holds one Text.
expect
	match Hud.ui(Rules.start(View.primitive_meshes, 1)) {
		[Box(config, [Text(keys)])] => config == Ui.panel(LeftTop, { x: 16.0, y: 16.0 }) and keys == Ui.label("Keys 0 / 2")
		_ => Bool.False
	}

expect
	match Hud.ui(one_key) {
		[Box(_, [Text(keys)])] => keys.str == "Keys 1 / 2"
		_ => Bool.False
	}
