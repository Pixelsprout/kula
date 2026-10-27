import pf.Vocabulary exposing [Element]
import ui.Ui
import Rules
import View
import Ball

Hud := [].{
	ui : Rules.Model -> List(Element)
	ui = |model| [bottom_row(model)]
}

# The original's screen is 320 pixels wide. It draws the keys at x 16 and the
# scores at x 100, so the keys take the first 30% of the row.
bottom_row : Rules.Model -> Element
bottom_row = |model| Box(
	{ ..Ui.float_at(LeftBottom, { x: 0.0, y: 0.0 }), width: Grow({ min: 0.0, max: 0.0 }), pad: Ui.pad_all(16.0), gap: 16.0 },
	[Box({ ..Ui.default_box, width: Percent(keys_share) }, [keys(model)]), scores(model)],
)

keys_share : F32
keys_share = 0.3

keys : Rules.Model -> Element
keys = |model| {
	total = model.level.items.keep_if(|entry| entry.item == Key).len()
	collected = total - model.keys_left
	Box(panel, [Text(Ui.label("Keys ${collected.to_str()} / ${total.to_str()}"))])
}

# As in the original, the level score sits over the total.
scores : Rules.Model -> Element
scores = |model| Box(
	{ ..panel, direction: Col, gap: 4.0 },
	[Text(Ui.label("Level ${model.score.level.to_str()}")), Text(Ui.label("Score ${model.score.total.to_str()}"))],
)

# The bottom row places each panel, so a panel does not float.
panel : Ui.BoxConfig
panel = { ..Ui.panel(LeftTop, { x: 0.0, y: 0.0 }), floating: NoFloat }

# The ball stands on level 1's first key, then collects it.
one_key : Rules.Model
one_key = {
	start = Rules.start(View.primitive_meshes, 1)
	Rules.collect({ ..start, ball: Ball.start({ ..start.ball.pose, cell: { x: 0, y: 1, z: 7 } }) })
}

# The HUD is one row along the bottom: the keys panel, then the scores panel.
expect
	match Hud.ui(Rules.start(View.primitive_meshes, 1)) {
		[Box(row, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])])] =>
			row.floating == Float({ attach: LeftBottom, offset: { x: 0.0, y: 0.0 } }) and keys_text == Ui.label("Keys 0 / 2") and level.str == "Level 0" and total.str == "Score 0"
		_ => Bool.False
	}

expect
	match Hud.ui({ ..one_key, score: { ..one_key.score, total: 2500 } }) {
		[Box(_, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])])] => keys_text.str == "Keys 1 / 2" and level.str == "Level 1000" and total.str == "Score 2500"
		_ => Bool.False
	}
