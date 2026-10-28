import pf.Vocabulary exposing [Element]
import ui.Ui
import Rules
import View
import Ball
import Clock
import Fruit
import Level
import Ending

Hud := [].{
	# As in the original, the HUD hides once the level ends, and the level end panel shows.
	ui : Rules.Model -> List(Element)
	ui = |model| match Rules.ending(model.phase) {
		Ok(ending) => end_panels(model, ending)
		Err(NotEnded) => [bottom_row(model), fruit_corner(model)].concat(time(model))
	}
}

# As in the original, WELL DONE fades in at the top centre. The level score and
# the total count up together below the middle of the screen.
end_panels : Rules.Model, Ending.Ending -> List(Element)
end_panels = |model, ending| {
	counted = Ending.counted(ending)
	before = model.score.total - ending.banked
	shown = Ending.banner(ending)
	banner = Box(
		{ ..Ui.panel(CenterTop, { x: 0.0, y: 16.0 }), pad: Ui.pad_all(16.0), background: { r: 0.0, g: 0.0, b: 0.0, a: 0.5 * shown } },
		[Text({ ..Ui.label("WELL DONE"), size: 56.0, color: { r: 1.0, g: 0.85, b: 0.2, a: shown } })],
	)
	scores = Box({ ..panel, direction: Col, gap: 4.0 }, [Text(Ui.label("Level ${counted.to_str()}")), Text(Ui.label("Score ${(before + counted).to_str()}"))])
	prompt = if Ending.finished(ending) {
		[Text(Ui.label("Press Space"))]
	} else {
		[]
	}
	summary = Box(
		{ ..Ui.float_at(CenterCenter, { x: 0.0, y: summary_drop }), direction: Col, gap: 12.0, child_align: { x: Center, y: Center } },
		[scores].concat(prompt),
	)
	[banner, summary]
}

# The original draws the score summary from 12 to 75 pixels below the middle of its 256-pixel screen.
summary_drop : F32
summary_drop = 120.0

# As in the original, the Time panel sits at the top centre.
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
	total = Level.keys(model.level)
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

# The ball stands on level 1's key, then collects it.
one_key : Rules.Model
one_key = {
	start = Rules.start(View.primitive_meshes, 1)
	Rules.collect({ ..start, ball: Ball.start({ ..start.ball.pose, cell: { x: 3, y: 1, z: 3 } }) })
}

# The HUD's first root is one row along the bottom: the keys panel, then the scores panel.
expect
	match Hud.ui(Rules.start(View.primitive_meshes, 1)) {
		[Box(row, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])]), _] =>
			row.floating == Float({ attach: LeftBottom, offset: { x: 0.0, y: 0.0 } }) and keys_text == Ui.label("Keys 0 / 1") and level.str == "Level 0" and total.str == "Score 0"
		_ => Bool.False
	}

expect
	match Hud.ui({ ..one_key, score: { ..one_key.score, total: 2500 } }) {
		[Box(_, [Box(_, [Box(_, [Text(keys_text)])]), Box(_, [Text(level), Text(total)])]), _] => keys_text.str == "Keys 1 / 1" and level.str == "Level 1000" and total.str == "Score 2500"
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

end_texts : Rules.Model -> List(Str)
end_texts = |model| match Hud.ui(model) {
	[Box(_, [Text(banner)]), Box(_, [Box(_, [Text(level), Text(total)]), .. as rest])] =>
		[banner.str, level.str, total.str].concat(
			rest.map(
				|element| match element {
					Text(text) => text.str
					_ => ""
				},
			),
		)
	_ => []
}

# Level 1's level end, seconds after it starts, with 3000 points banked.
ended : F32 -> Rules.Model
ended = |seconds| {
	start = Rules.start(View.primitive_meshes, 1)
	{ ..start, score: { level: 0, total: 5000 }, phase: Ending({ ..Ending.start(3000), seconds }) }
}

# The level end panel replaces the HUD. Its count starts at the old total.
expect end_texts(ended(0.0)) == ["WELL DONE", "Level 0", "Score 2000"]

# After 0.5 s the count has reached 2500, and the banner is under a third of the way in.
expect {
	half = ended(0.5)
	alpha = match Hud.ui(half) {
		[Box(_, [Text(banner)]), _] => banner.color.a
		_ => -1.0
	}
	end_texts(half) == ["WELL DONE", "Level 2500", "Score 4500"] and alpha > 0.29 and alpha < 0.3
}

# Once the banner and the count finish, a prompt asks for the press. Cleared keeps the panel.
expect end_texts(ended(2.0)) == ["WELL DONE", "Level 3000", "Score 5000", "Press Space"]
expect end_texts({ ..ended(2.0), phase: Cleared({ ..Ending.start(3000), seconds: 2.0 }) }) == ["WELL DONE", "Level 3000", "Score 5000", "Press Space"]
