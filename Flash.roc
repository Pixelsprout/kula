import linalg.Vec3
import pf.Vocabulary exposing [Rgb]
import pf.Light
import Grid
import Pickup
import Clock

# The light that marks a pickup, as the original's light effect does.
Flash := [].{
	# age is the seconds since the pickup. kind is the item collected, which picks the colours. A list of flashes runs oldest first.
	Flash : { pos : Vec3.Vec3, age : F32, kind : Pickup.Kind }

	at_pickup : Pickup.Pickup -> Flash.Flash
	at_pickup = |pickup| { pos: Grid.over_face(pickup.cell, pickup.up, height), age: 0.0, kind: pickup.kind }

	# A flash ends when its light has faded to black.
	advance : List(Flash.Flash), F32 -> List(Flash.Flash)
	advance = |flashes, dt| flashes.map(|flash| { ..flash, age: flash.age + dt }).keep_if(|flash| flash.age < lifetime(flash.kind))

	light : Flash.Flash -> Vocabulary.Light
	light = |flash| Light.point(flash.pos, colour(flash.kind, flash.age), range)

	colour : Pickup.Kind, F32 -> Rgb
	colour = |kind, age| {
		sampled = sample(Pickup.glow(kind), age / Clock.pal_frame)
		{ r: sampled.r * strength, g: sampled.g * strength, b: sampled.b * strength }
	}

	# The host drops each Directional or Point light past the first 8, so the
	# flashes take the slots the Theme leaves free, newest first.
	lights : List(Flash.Flash), List(Vocabulary.Light) -> List(Vocabulary.Light)
	lights = |flashes, theme_lights| {
		used = theme_lights.keep_if(|l| !is_ambient(l)).len()
		free = if used < host_lights {
			host_lights - used
		} else {
			0
		}
		newest = if flashes.len() > free {
			flashes.drop_first(flashes.len() - free)
		} else {
			flashes
		}
		newest.map(light)
	}

	lifetime : Pickup.Kind -> F32
	lifetime = |kind| match Pickup.glow(kind).last() {
		Ok(end) => end.frame * Clock.pal_frame
		Err(_) => 0.0
	}
}

# The glow points run oldest first, and the last one is black.
sample : List(Pickup.Glow), F32 -> Rgb
sample = |glows, frame| match glows {
	[a, b, ..] =>
		if frame <= b.frame {
			t = (frame - a.frame) / (b.frame - a.frame)
			{ r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t }
		} else {
			sample(glows.drop_first(1), frame)
		}
	_ => black
}

# The original lights the item's face fully and each face beside it less
# toward its far edge, to nothing 1.5 cells out. A point light falls off
# faster than that near its centre, so the flash sits one cell above the face
# and reaches 2 cells. On the face it then lights out to 1.73 cells.
height : F32
height = 1.0

range : F32
range = 2.0

# Light that a Point light of colour 1 sends to the face right under it, before the BRDF's 1/pi.
centre_irradiance : F32
centre_irradiance = {
	k = 1.0 - height * height / (range * range)
	k * k / (height * height)
}

# The light effect gives each corner of the item's face weight 2
# (light_effect.c). Kula takes that as twice the PS1 colour on the face
# right under the flash, where a PS1 colour of 128 is a light of 1.
strength : F32
strength = 2.0 / 128.0 * pi / centre_irradiance

pi : F32
pi = 3.14159265

host_lights : U64
host_lights = 8

is_ambient : Vocabulary.Light -> Bool
is_ambient = |l| match l {
	Ambient(_) => True
	_ => False
}

black : Rgb
black = { r: 0.0, g: 0.0, b: 0.0 }

near : F32, F32 -> Bool
near = |a, b| (a - b).abs() < 0.0001

near_rgb : Rgb, Rgb -> Bool
near_rgb = |a, b| near(a.r, b.r) and near(a.g, b.g) and near(a.b, b.b)

ps1 : F32, F32, F32 -> Rgb
ps1 = |r, g, b| { r: r * strength, g: g * strength, b: b * strength }

floor_key : Pickup.Pickup
floor_key = { id: 0, cell: { x: 0, y: 1, z: 7 }, up: { x: 0, y: 1, z: 0 }, kind: Key, spin: 0.0, tilt: 0.0, bob: 0.0 }

floor_fruit : Pickup.Pickup
floor_fruit = { ..floor_key, kind: Fruit(Apple) }

# The flash sits one cell above the item's face, along the face's up.
expect Flash.at_pickup(floor_key) == { pos: { x: 0.0, y: 1.5, z: 7.0 }, age: 0.0, kind: Key }
expect Flash.at_pickup({ ..floor_key, up: { x: -1, y: 0, z: 0 } }).pos == { x: -0.5, y: 1.0, z: 7.0 }

# The colour copies the original's frames: black at the pickup, a pale blue
# from 0.08 s to 0.18 s, grey at 0.46 s and black again at 0.66 s.
expect near_rgb(Flash.colour(Key, 0.0), black)
expect near_rgb(Flash.colour(Key, 0.04), ps1(12.5, 12.5, 22.5))
expect near_rgb(Flash.colour(Key, 0.08), ps1(25.0, 25.0, 45.0)) and near_rgb(Flash.colour(Key, 0.18), ps1(25.0, 25.0, 45.0))
expect near_rgb(Flash.colour(Key, 0.32), ps1(22.0, 22.0, 32.0))
expect near_rgb(Flash.colour(Key, 0.46), ps1(19.0, 19.0, 19.0))
expect near_rgb(Flash.colour(Key, 0.66), black) and near_rgb(Flash.colour(Key, 1.0), black)

# The face under the flash at its peak gets twice the PS1 colour over 128, before the BRDF's 1/pi.
expect near(Flash.colour(Key, 0.1).r * centre_irradiance / pi, 50.0 / 128.0)

expect Flash.light({ pos: { x: 1.0, y: 2.0, z: 3.0 }, age: 0.1, kind: Key }) == Light.point({ x: 1.0, y: 2.0, z: 3.0 }, Flash.colour(Key, 0.1), 2.0)

# A flash ages each step and ends after 33 PAL frames.
expect {
	flash = Flash.at_pickup(floor_key)
	aged = Flash.advance([flash], 0.5)
	aged.map(|f| f.age) == [0.5] and Flash.advance(aged, 0.17) == []
}

# A fruit's flash peaks in pale violet from 0.16 s to 0.22 s and is black at 0.48 s.
expect near_rgb(Flash.colour(Fruit(Apple), 0.0), black) and near_rgb(Flash.colour(Fruit(Pumpkin), 0.16), ps1(41.0, 30.0, 41.0)) and near_rgb(Flash.colour(Fruit(Apple), 0.22), ps1(41.0, 30.0, 41.0))
expect near_rgb(Flash.colour(Fruit(Apple), 0.48), black) and near_rgb(Flash.colour(Fruit(Apple), 1.0), black)

# A fruit's flash ends after 24 PAL frames.
expect {
	aged = Flash.advance([Flash.at_pickup(floor_fruit)], 0.47)
	aged.map(|f| f.kind) == [Fruit(Apple)] and Flash.advance(aged, 0.02) == []
}

theme_lights : List(Vocabulary.Light)
theme_lights = [Light.ambient(black), Light.sun({ x: 0.0, y: -1.0, z: 0.0 }, black), Light.directional({ x: 0.0, y: 1.0, z: 0.0 }, black)]

flashes_at : List(F32) -> List(Flash.Flash)
flashes_at = |zs| zs.map(|z| { pos: { x: 0.0, y: 1.5, z }, age: 0.1, kind: Key })

# With a sun and a fill, 6 of the host's 8 lights are free. Past 6 the newest flashes keep their lights.
expect Flash.lights(flashes_at([1.0, 2.0]), theme_lights).len() == 2
expect {
	lit = Flash.lights(flashes_at([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]), theme_lights)
	lit == flashes_at([3.0, 4.0, 5.0, 6.0, 7.0, 8.0]).map(Flash.light)
}
expect Flash.lights(flashes_at([1.0]), List.repeat(Light.directional({ x: 0.0, y: -1.0, z: 0.0 }, black), 9)) == []
