import linalg.Vec3
import pf.Vocabulary exposing [Rgb]
import pf.Light
import Level

# The look of one level. Each Theme is a pack of its face mesh and its sky, so
# the next level's Theme loads while the current one still draws.
Theme := [].{
	Theme : { pack : Str, face : Str, sky : Str, assets : List(Str), sun : Vec3.Vec3, lights : List(Vocabulary.Light) }

	# Levels count from 1. A number past the last level gets the last Theme.
	of_level : U64 -> Theme.Theme
	of_level = |number| by_level.get(number - 1) ?? hiro

	count : U64
	count = by_level.len()
}

# The original loads one look for each world, so all the levels of a world share it.
# Kula's levels are Hiro levels 1 to 3.
by_level : List(Theme.Theme)
by_level = [hiro, hiro, hiro]

# No level uses haze, inca or arctic yet. They wait for levels from other worlds.
themes : List(Theme.Theme)
themes = [hiro, haze, inca, arctic]

# HIRO.TGI draws the original's Y+ faces (Kula's +z) light and its Y- faces dark, so the sun comes from +z.
# The light colours reuse its block colours, which the original only fades far faces toward.
# The scales bring the faces near the original's tile colours.
hiro : Theme.Theme
hiro = theme("hiro", { x: -2.0 / 7.0, y: -3.0 / 7.0, z: -6.0 / 7.0 }, block_colour(1.7, 140, 128, 102), block_colour(0.2, 76, 102, 179), block_colour(0.78, 128, 128, 140))

haze : Theme.Theme
haze = theme("haze", { x: -2.0 / 7.0, y: -6.0 / 7.0, z: -3.0 / 7.0 }, grey(1.6), grey(0.3), { r: 0.14, g: 0.15, b: 0.17 })

inca : Theme.Theme
inca = theme("inca", { x: 3.0 / 7.0, y: -6.0 / 7.0, z: -2.0 / 7.0 }, { r: 1.9, g: 1.55, b: 1.1 }, grey(0.3), { r: 0.18, g: 0.14, b: 0.1 })

arctic : Theme.Theme
arctic = theme("arctic", { x: -3.0 / 7.0, y: -6.0 / 7.0, z: 2.0 / 7.0 }, { r: 1.0, g: 1.1, b: 1.3 }, grey(0.3), { r: 0.13, g: 0.16, b: 0.2 })

# No two axes of a sun's dir share a size, so each face direction gets its own shade.
# The BRDF divides diffuse light by pi, so a sun of 1.6 lights a white surface facing it to 1.6.
# The fill lights the faces turned away from the sun. The ambient takes the sky's hue.
# make_skies.py paints the sun where this light comes from.
theme : Str, Vec3.Vec3, Rgb, Rgb, Rgb -> Theme.Theme
theme = |pack, sun, sun_rgb, fill, ambient| {
	face = "${pack}_face"
	sky = "sky/${pack}"
	{
		pack,
		face,
		sky,
		assets: [face, sky],
		sun,
		lights: [
			Light.ambient(ambient),
			Light.sun(sun, times_pi(sun_rgb)),
			Light.directional(Vec3.neg(sun), times_pi(fill)),
		],
	}
}

grey : F32 -> Rgb
grey = |v| { r: v, g: v, b: v }

# A TGI colour, where 128 is full, times a scale.
block_colour : F32, F32, F32, F32 -> Rgb
block_colour = |scale, r, g, b| { r: scale * r / 128.0, g: scale * g / 128.0, b: scale * b / 128.0 }

times_pi : Rgb -> Rgb
times_pi = |c| { r: c.r * pi, g: c.g * pi, b: c.b * pi }

pi : F32
pi = 3.14159265

# The sum of all lights on a face with this normal, over the three channels.
shade : List(Vocabulary.Light), Vec3.Vec3 -> F32
shade = |lights, normal| lights.fold(
	0.0,
	|sum, light| match light {
		Ambient(c) => sum + c.r + c.g + c.b
		Directional({ dir, color, shadow: _ }) => {
			facing = Vec3.dot(normal, Vec3.neg(dir))
			if facing > 0.0 {
				sum + (color.r + color.g + color.b) * facing
			} else {
				sum
			}
		}
		Point(_) => sum
	},
)

normals : List(Vec3.Vec3)
normals = [{ x: 1.0, y: 0.0, z: 0.0 }, { x: -1.0, y: 0.0, z: 0.0 }, { x: 0.0, y: 1.0, z: 0.0 }, { x: 0.0, y: -1.0, z: 0.0 }, { x: 0.0, y: 0.0, z: 1.0 }, { x: 0.0, y: 0.0, z: -1.0 }]

expect Theme.count == Level.count
expect themes.map(|t| t.pack) == ["hiro", "haze", "inca", "arctic"]
expect [1, 2, 3, 4].map(|n| Theme.of_level(n).pack) == ["hiro", "hiro", "hiro", "hiro"]

expect themes.all(
	|t| {
		shades = normals.map(|n| shade(t.lights, n))
		shades.all(|a| shades.keep_if(|b| (a - b).abs() < 0.06).len() == 1)
	},
)

expect themes.all(|a| themes.keep_if(|b| b.sun == a.sun).len() == 1)
expect themes.all(|t| t.assets == [t.face, t.sky])
expect themes.map(|t| t.assets) == [["hiro_face", "sky/hiro"], ["haze_face", "sky/haze"], ["inca_face", "sky/inca"], ["arctic_face", "sky/arctic"]]
