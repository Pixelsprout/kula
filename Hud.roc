import pf.Vocabulary exposing [Element]
import pf.Image
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
		Err(NotEnded) => [bottom_row(model), fruit_corner(model), time(model)].concat(play_again(model))
	}
}

# Kula's addition: Won asks for the press that starts a fresh game. The
# prompt sits above the middle, because the play camera puts the ball below it.
play_again : Rules.Model -> List(Element)
play_again = |model|
	if model.phase == Won {
		[Panel({ ..Ui.panel(CenterCenter, { x: 0.0, y: -summary_drop }), pad: Ui.pad_all(16.0) }, [Text(Ui.label("Press Enter to play again"))])]
	} else {
		[]
	}

# As in the original, WELL DONE fades in at the top centre. The level score and
# the total count up together below the middle of the screen.
end_panels : Rules.Model, Ending.Ending -> List(Element)
end_panels = |model, ending| {
	counted = Ending.counted(ending)
	before = model.score.total - ending.banked
	shown = Ending.banner(ending)
	banner = Panel(
		{ ..top_centre, pad: Ui.pad_all(16.0), background: { r: 0.0, g: 0.0, b: 0.0, a: 0.5 * shown } },
		[Text({ ..Ui.label("WELL DONE"), size: 56.0, color: { r: 1.0, g: 0.85, b: 0.2, a: shown } })],
	)
	scores = Panel({ ..panel, direction: Col, gap: 4.0 }, [Text(Ui.label("Level ${counted.to_str()}")), Text(Ui.label("Score ${(before + counted).to_str()}"))])
	prompt = if Ending.finished(ending) {
		[Text(Ui.label("Press Space"))]
	} else {
		[]
	}
	summary = Panel(
		{ ..Ui.float_at(CenterCenter, { x: 0.0, y: summary_drop }), direction: Col, gap: 12.0, child_align: { x: Center, y: Center } },
		[scores].concat(prompt),
	)
	[banner, summary]
}

# The original draws the score summary from 12 to 75 pixels below the middle of its 256-pixel screen.
summary_drop : F32
summary_drop = 120.0

# As in the original, the WELL DONE banner and the Time panel sit at the top centre.
top_centre : Ui.PanelConfig
top_centre = Ui.panel(CenterTop, { x: 0.0, y: 16.0 })

time : Rules.Model -> Element
time = |model| {
	shown_seconds = Clock.panel_seconds({ steps_left: model.clock, start_seconds: model.level.time })
	shade = Clock.panel_shade({ seconds: shown_seconds })
	Panel(top_centre, [Text({ ..Ui.label("Time ${shown_seconds.to_str()}"), color: { r: shade, g: shade, b: shade, a: 1.0 } })])
}

# The original's screen is 320 pixels wide. It draws the keys at x 16 and the
# scores at x 100, so the keys take the first 30% of the row.
bottom_row : Rules.Model -> Element
bottom_row = |model| Panel(
	{ ..Ui.float_at(LeftBottom, { x: 0.0, y: 0.0 }), width: Grow({ min: 0.0, max: 0.0 }), pad: Ui.pad_all(16.0), gap: 16.0 },
	[Panel({ ..Ui.default_panel, width: Percent(keys_share) }, [keys(model)]), scores(model)],
)

keys_share : F32
keys_share = 0.3

# As in the original, one icon a key, lit when collected. The keys light in order.
keys : Rules.Model -> Element
keys = |model| {
	total = Level.keys(model.level)
	collected = total - model.keys_left
	# Id 0 draws the engine's checker, so the text shows until the kula pack loads.
	if model.icons.key == 0 {
		Panel(panel, [Text(Ui.label("Keys ${collected.to_str()} / ${total.to_str()}"))])
	} else {
		lit = model.level.items.keep_if(|entry| entry.item == Key).map_with_index(|_, i| i < collected)
		Panel({ ..panel, gap: icon_gap }, lit.map(|on| icon(model.icons.key, on)))
	}
}

# As in the original, the level score sits over the total.
scores : Rules.Model -> Element
scores = |model| Panel(
	{ ..panel, direction: Col, gap: 4.0 },
	[Text(Ui.label("Level ${model.score.level.to_str()}")), Text(Ui.label("Score ${model.score.total.to_str()}"))],
)

# The original draws its five fruit icons at the bottom right, each lit when
# its fruit is collected. The corner keeps the bottom row's 16 pixels from the window edge.
fruit_corner : Rules.Model -> Element
fruit_corner = |model| {
	fruits = if model.icons.fruit == 0 {
		Panel(panel, [Text(Ui.label("Fruit ${Fruit.count(model.fruits).to_str()} / ${Fruit.kinds.len().to_str()}"))])
	} else {
		Panel({ ..panel, gap: icon_gap }, Fruit.kinds.map(|kind| icon(model.icons.fruit, model.fruits.now.contains(kind))))
	}
	Panel({ ..Ui.float_at(RightBottom, { x: 0.0, y: 0.0 }), pad: Ui.pad_all(16.0) }, [fruits])
}

# make_icons.py draws each icon at twice this size.
icon : U32, Bool -> Element
icon = |id, lit| {
	tint = if lit lit_tint else dim_tint
	Panel({ ..Ui.default_panel, width: Fixed(icon_size), height: Fixed(icon_size), image: Show({ ..Image.default, id, tint }, Fit) }, [])
}

icon_size : F32
icon_size = 32.0

icon_gap : F32
icon_gap = 4.0

lit_tint : Ui.Rgba
lit_tint = { r: 1.0, g: 1.0, b: 1.0, a: 1.0 }

dim_tint : Ui.Rgba
dim_tint = { r: 0.25, g: 0.25, b: 0.25, a: 0.6 }

# The bottom row places each panel, so a panel does not float.
panel : Ui.PanelConfig
panel = { ..Ui.panel(LeftTop, { x: 0.0, y: 0.0 }), floating: NoFloat }

# The ball stands on level 1's key, then collects it.
one_key : Rules.Model
one_key = {
	start = Rules.start(View.primitive_meshes, 1)
	Rules.collect({ ..start, ball: Ball.start({ ..start.ball.pose, cell: { x: 3, y: 1, z: 3 } }) })
}

texts : Element -> List(Str)
texts = |element| match element {
	Panel(_, children) => children.map(texts).join()
	Text(text) => [text.str]
}

icons_in : Element -> List({ id : U32, tint : Ui.Rgba })
icons_in = |element| match element {
	Panel(config, children) => {
		own = match config.image {
			Show(image, Fit) => [{ id: image.id, tint: image.tint }]
			_ => []
		}
		own.concat(children.map(icons_in).join())
	}
	Text(_) => []
}

loaded_icons : Rules.Model -> Rules.Model
loaded_icons = |model| { ..model, icons: { key: 7, fruit: 8 } }

# The one HUD root with a text that starts with prefix.
root_with : Rules.Model, Str -> Try(Element, [NoPanel])
root_with = |model, prefix| match Hud.ui(model).keep_if(|root| texts(root).any(|str| str.starts_with(prefix))) {
	[root] => Ok(root)
	_ => Err(NoPanel)
}

# The keys panel and the scores panel share one row along the bottom.
expect
	match root_with(Rules.start(View.primitive_meshes, 1), "Keys") {
		Ok(Panel(row, [Panel(_, [keys_panel]), scores_panel])) =>
			row.floating == Float({ to: Window, attach: LeftBottom, on: LeftBottom, offset: { x: 0.0, y: 0.0 } }) and texts(keys_panel) == ["Keys 0 / 1"] and texts(scores_panel) == ["Level 0", "Score 0"]
		_ => Bool.False
	}

expect root_with({ ..one_key, score: { ..one_key.score, total: 2500 } }, "Keys").map_ok(texts) == Ok(["Keys 1 / 1", "Level 1000", "Score 2500"])

# Once the icons load, the keys panel shows one icon a key in place of the text.
expect
	match root_with(loaded_icons(Rules.start(View.primitive_meshes, 1)), "Level") {
		Ok(Panel(_, [Panel(_, [keys_panel]), _])) => texts(keys_panel) == [] and icons_in(keys_panel) == [{ id: 7, tint: dim_tint }]
		_ => Bool.False
	}

expect root_with(loaded_icons(one_key), "Level").map_ok(icons_in) == Ok([{ id: 7, tint: lit_tint }])

# In a level with two keys and one collected, the first icon lights.
expect {
	start = loaded_icons(Rules.start(View.primitive_meshes, 1))
	level = { ..start.level, items: start.level.items.concat(start.level.items.keep_if(|entry| entry.item == Key)) }
	Level.keys(level) == 2 and root_with({ ..start, level, keys_left: 1 }, "Level").map_ok(icons_in) == Ok([{ id: 7, tint: lit_tint }, { id: 7, tint: dim_tint }])
}

time_panel : Rules.Model -> Try({ str : Str, shade : F32 }, [NoPanel])
time_panel = |model| match root_with(model, "Time ") {
	Ok(Panel(time_box, [Text(text)])) =>
		if time_box.floating == top_centre.floating and text.color.r == text.color.g and text.color.g == text.color.b and text.color.a == 1.0 {
			Ok({ str: text.str, shade: text.color.r })
		} else {
			Err(NoPanel)
		}
	_ => Err(NoPanel)
}

level_one_at : U64 -> Rules.Model
level_one_at = |clock| { ..Rules.start(View.primitive_meshes, 1), clock }

# The panel shows from the level start in white, also in the Starting wait before a level.
expect time_panel(Rules.start(View.primitive_meshes, 1)) == Ok({ str: "Time 99", shade: 1.0 })
expect time_panel({ ..Rules.start(View.primitive_meshes, 2), phase: Starting(1.0) }) == Ok({ str: "Time 99", shade: 1.0 })

# From 50 s the text dims to grey, then goes back to white by the last second.
expect time_panel(level_one_at(Clock.start(50))) == Ok({ str: "Time 51", shade: 1.0 })
expect time_panel(level_one_at(Clock.start(50) - 1)) == Ok({ str: "Time 50", shade: 1.0 })
expect time_panel(level_one_at(Clock.start(45) - 1)) == Ok({ str: "Time 45", shade: Clock.panel_shade({ seconds: 45 }) })
expect time_panel(level_one_at(Clock.start(25) - 1)) == Ok({ str: "Time 25", shade: Clock.panel_shade({ seconds: 25 }) })
expect time_panel(level_one_at(Clock.start(10) - 1)) == Ok({ str: "Time 10", shade: Clock.panel_shade({ seconds: 10 }) })
expect time_panel(level_one_at(1)) == Ok({ str: "Time 1", shade: Clock.panel_shade({ seconds: 1 }) })

fruit_text : Rules.Model -> Str
fruit_text = |model| match root_with(model, "Fruit") {
	Ok(Panel(corner, [Panel(_, [Text(text)])])) =>
		if corner.floating == Float({ to: Window, attach: RightBottom, on: RightBottom, offset: { x: 0.0, y: 0.0 } }) {
			text.str
		} else {
			""
		}
	_ => ""
}

# The fruit panel sits at the bottom right and counts the fruit set out of five.
expect fruit_text(Rules.start(View.primitive_meshes, 1)) == "Fruit 0 / 5"
expect fruit_text({ ..one_key, fruits: { now: [Apple], saved: [] } }) == "Fruit 1 / 5"

fruit_icons : Rules.Model -> List({ id : U32, tint : Ui.Rgba })
fruit_icons = |model| match Hud.ui(loaded_icons(model)) {
	[_, Panel(corner, [fruits]), ..] =>
		if corner.floating == Float({ to: Window, attach: RightBottom, on: RightBottom, offset: { x: 0.0, y: 0.0 } }) and texts(fruits) == [] {
			icons_in(fruits)
		} else {
			[]
		}
	_ => []
}

# Once the icons load, the corner shows five fruit icons, each lit when its fruit is collected.
expect fruit_icons(Rules.start(View.primitive_meshes, 1)) == List.repeat({ id: 8, tint: dim_tint }, 5)
expect fruit_icons({ ..one_key, fruits: { now: [Apple, Pumpkin], saved: [] } }) == [lit_tint, dim_tint, lit_tint, dim_tint, dim_tint].map(|tint| { id: 8, tint })

end_texts : Rules.Model -> List(Str)
end_texts = |model| match Hud.ui(model) {
	[Panel(_, [Text(banner)]), Panel(_, [Panel(_, [Text(level), Text(total)]), .. as rest])] =>
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
		[Panel(_, [Text(banner)]), _] => banner.color.a
		_ => -1.0
	}
	end_texts(half) == ["WELL DONE", "Level 2500", "Score 4500"] and alpha > 0.29 and alpha < 0.3
}

# Once the banner and the count finish, a prompt asks for the press. Cleared keeps the panel.
expect end_texts(ended(2.0)) == ["WELL DONE", "Level 3000", "Score 5000", "Press Space"]
expect end_texts({ ..ended(2.0), phase: Cleared({ ..Ending.start(3000), seconds: 2.0 }) }) == ["WELL DONE", "Level 3000", "Score 5000", "Press Space"]

# Won keeps the HUD and adds the play again prompt above the middle of the screen.
expect {
	won = { ..one_key, phase: Won }
	match Hud.ui(won) {
		[.. as hud, Panel(prompt, [Text(text)])] =>
			hud == Hud.ui({ ..won, phase: Playing }) and prompt.floating == Float({ to: Window, attach: CenterCenter, on: CenterCenter, offset: { x: 0.0, y: -summary_drop } }) and text.str == "Press Enter to play again"
		_ => Bool.False
	}
}
