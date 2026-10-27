import pf.Vocabulary exposing [Element]
import ui.Ui
import Rules
import View
import Ball
import Clock
import Fruit

Hud := [].{
	ui : Rules.Model -> List(Element)
	ui = |model| [bottom_row(model), fruit_corner(model)].concat(time(model))
}

# As in the original, the time shows at the top centre from 50 s and fades in from black.
time : Rules.Model -> List(Element)
time = |model| match Clock.brightness(model.clock) {
	Ok(shade) => [Box(Ui.panel(CenterTop, { x: 0.0, y: 16.0 }), [Text({ ..Ui.label("Time ${Clock.shown(model.clock).to_str()}"), color: { r: shade, g: shade, b: shade, a: 1.0 } })])]
	Err(Hidden) => []
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

# The original draws its five fruit icons at the bottom right. The corner
# keeps the bottom row's 16 pixels from the window edge.
fruit_corner : Rules.Model -> Element
fruit_corner = |model| Box(
	{ ..Ui.float_at(RightBottom, { x: 0.0, y: 0.0 }), pad: Ui.pad_all(16.0) },
	[Box(panel, [Text(Ui.label("Fruit ${Fruit.count(model.fruits).to_str()} / ${Fruit.kinds.len().to_str()}"))])],
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

# The HUD's first root is one row along the bottom: the keys panel, then the scores panel.
expect
	match Hud.ui(Rules.start(View.primitive_meshes, 1)) {
		[Box(row, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])]), _] =>
			row.floating == Float({ attach: LeftBottom, offset: { x: 0.0, y: 0.0 } }) and keys_text == Ui.label("Keys 0 / 2") and level.str == "Level 0" and total.str == "Score 0"
		_ => Bool.False
	}

expect
	match Hud.ui({ ..one_key, score: { ..one_key.score, total: 2500 } }) {
		[Box(_, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])]), _] => keys_text.str == "Keys 1 / 2" and level.str == "Level 1000" and total.str == "Score 2500"
		_ => Bool.False
	}

expect Hud.ui({ ..Rules.start(View.primitive_meshes, 1), clock: Clock.start(50) }).len() == 2

# At 45 s the Time panel is a third root at the top centre, a tenth of the way from black.
expect
	match Hud.ui({ ..Rules.start(View.primitive_meshes, 1), clock: Clock.start(45) - 1 }) {
		[_, _, Box(time_box, [Text(time_text)])] =>
			time_box.floating == Float({ attach: CenterTop, offset: { x: 0.0, y: 16.0 } }) and time_text.str == "Time 45" and time_text.color == { r: 0.1, g: 0.1, b: 0.1, a: 1.0 }
		_ => Bool.False
	}

fruit_text : Rules.Model -> Str
fruit_text = |model| match Hud.ui(model) {
	[_, Box(corner, [Box(_, [Text(text)])])] =>
		if corner.floating == Float({ attach: RightBottom, offset: { x: 0.0, y: 0.0 } }) {
			text.str
		} else {
			""
		}
	_ => ""
}

# The fruit panel sits at the bottom right and counts the fruit set out of five.
expect fruit_text(Rules.start(View.primitive_meshes, 1)) == "Fruit 0 / 5"
expect fruit_text({ ..one_key, fruits: { now: [Apple], saved: [] } }) == "Fruit 1 / 5"
