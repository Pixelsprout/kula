import linalg.Quat
import linalg.Vec3
import World
import Grid

# An item that the ball collects by touch. A new kind adds a Kind tag and a row in look.
Pickup := [].{
	Kind : [Key]

	# spin, tilt and bob are phases in turns from 0 to 1, as the original keeps three angles for each item.
	# id is the place among the level's pickups, so a pickup keeps it after a restart.
	Pickup : { id : U64, cell : World.Cell, up : World.Cell, kind : Kind, spin : F32, tilt : F32, bob : F32 }

	from_level : World.Level -> List(Pickup.Pickup)
	from_level = |level| level.items
		.join_map(
			|entry| match entry.item {
				Key => [{ cell: entry.cell, up: entry.up, kind: Key }]
				Exit => []
			},
		)
		.map_with_index(
			|found, i| {
				id = i.to_u64()
				{ id, cell: found.cell, up: found.up, kind: found.kind, spin: start_phase(id, 0), tilt: start_phase(id, 1), bob: start_phase(id, 2) }
			},
		)

	advance : Pickup.Pickup, F32 -> Pickup.Pickup
	advance = |pickup, dt| {
		l = look(pickup.kind)
		{
			..pickup,
			spin: wrap(pickup.spin + per_second(l.spin) * dt),
			tilt: wrap(pickup.tilt + per_second(l.tilt) * dt),
			bob: wrap(pickup.bob + per_second(l.bob) * dt),
		}
	}

	# The centre includes the bob, and the touch test uses it, as in the original.
	centre : Pickup.Pickup -> Vec3.Vec3
	centre = |pickup| {
		l = look(pickup.kind)
		lift = cells(l.lift + bob_offset + bob_size * (tau * pickup.bob).sin())
		Vec3.add(Grid.to_vec3(pickup.cell), Vec3.scale(Grid.to_vec3(pickup.up), lift - 0.5))
	}

	# The spin turns about the face normal. The tilt turns about an axis in the face that spins with the item.
	rot : Pickup.Pickup -> Quat.Quat
	rot = |pickup| {
		l = look(pickup.kind)
		on_face = Quat.between(y_axis, Grid.to_vec3(pickup.up))
		spin = Quat.from_axis_angle(y_axis, tau * pickup.spin)
		tilt = Quat.from_axis_angle(x_axis, tau * l.tilt_size / 4096.0 * (tau * pickup.tilt).sin())
		Quat.mul(on_face, Quat.mul(spin, tilt))
	}

	touches : Pickup.Pickup, Vec3.Vec3 -> Bool
	touches = |pickup, ball_centre| {
		gap = Vec3.sub(centre(pickup), ball_centre)
		Vec3.dot(gap, gap) < reach_squared(pickup.kind)
	}

	reach_squared : Kind -> F32
	reach_squared = |kind| cells(cells(look(kind).touch + ball_touch))
}

# In the original's units, so each row copies the decomp: 512 a block,
# 4096 a turn and one PAL frame. lift is the height of the centre above the
# face before the bob. touch is the item's collisionDistance. spin, tilt and
# bob are each phase's change a frame. tilt_size is the peak tilt.
Look : { lift : F32, touch : F32, spin : F32, tilt : F32, tilt_size : F32, bob : F32 }

look : Pickup.Kind -> Look
look = |kind| match kind {
	Key => { lift: 130.0, touch: 22500.0, spin: -90.0, tilt: 0.0, tilt_size: 0.0, bob: -70.0 }
}

# The original adds 10000 for the ball to every item's collisionDistance.
ball_touch : F32
ball_touch = 10000.0

# The bob moves the centre 10 + 20 sin(bob) units along up.
bob_offset : F32
bob_offset = 10.0

bob_size : F32
bob_size = 20.0

cells : F32 -> F32
cells = |units| units / 512.0

per_second : F32 -> F32
per_second = |per_frame| per_frame / 4096.0 / 0.02

# The original starts each phase at random. Kula spreads them by the golden
# ratio instead, so a restart looks the same.
start_phase : U64, U64 -> F32
start_phase = |id, which| wrap((3 * id + which).to_f32() * 0.618034)

wrap : F32 -> F32
wrap = |turns| {
	part = turns % 1.0
	if part < 0.0 {
		part + 1.0
	} else {
		part
	}
}

tau : F32
tau = 6.2831853

x_axis : Vec3.Vec3
x_axis = { x: 1.0, y: 0.0, z: 0.0 }

y_axis : Vec3.Vec3
y_axis = { x: 0.0, y: 1.0, z: 0.0 }

near : F32, F32 -> Bool
near = |a, b| (a - b).abs() < 0.0001

key_on : World.Cell, World.Cell -> Pickup.Pickup
key_on = |cell, up| { id: 0, cell, up, kind: Key, spin: 0.0, tilt: 0.0, bob: 0.0 }

floor_key : Pickup.Pickup
floor_key = key_on({ x: 0, y: 1, z: 0 }, { x: 0, y: 1, z: 0 })

# A key's reach is 180 units, 0.35 cell.
expect near(Pickup.reach_squared(Key), 32500.0 / 512.0 / 512.0)

# At bob phase 0 the centre is 140 units above the face.
expect {
	c = Pickup.centre(floor_key)
	near(c.x, 0.0) and near(c.y, 0.5 + 140.0 / 512.0) and near(c.z, 0.0)
}

# A quarter of the bob lifts the centre 20 units more.
expect near(Pickup.centre({ ..floor_key, bob: 0.25 }).y, 0.5 + 160.0 / 512.0)

# On a -x face the centre lifts along -x.
expect {
	c = Pickup.centre(key_on({ x: 0, y: 1, z: 0 }, { x: -1, y: 0, z: 0 }))
	near(c.x, 0.5 - 140.0 / 512.0) and near(c.y, 1.0)
}

# A key spins 90/4096 of a turn back each frame and its bob 70/4096 back.
expect {
	moved = Pickup.advance({ ..floor_key, spin: 0.5, bob: 0.5 }, 0.02)
	near(moved.spin, 0.5 - 90.0 / 4096.0) and near(moved.bob, 0.5 - 70.0 / 4096.0) and moved.tilt == 0.0
}

# Phases stay in 0 to 1, in either direction and past a whole turn.
expect {
	moved = Pickup.advance(floor_key, 1.0)
	moved.spin >= 0.0 and moved.spin < 1.0 and moved.bob >= 0.0 and moved.bob < 1.0
}

expect near(wrap(1.25), 0.25) and near(wrap(-0.25), 0.75) and near(wrap(-1.75), 0.25)

# A ball resting on the key's face touches it. A ball one cell over does not.
expect {
	resting = { x: 0.0, y: 0.695, z: 0.0 }
	Pickup.touches(floor_key, resting) and !Pickup.touches(floor_key, { ..resting, z: -1.0 })
}

# A ball at a forward jump's peak, 0.5 cell up, is out of a floor key's reach.
expect !Pickup.touches({ ..floor_key, bob: 0.25 }, { x: 0.0, y: 1.195, z: 0.0 })

expect {
	pickups = Pickup.from_level({ blocks: Set.empty(), items: [{ cell: { x: 0, y: 1, z: 0 }, up: { x: 0, y: 1, z: 0 }, item: Exit }, { cell: { x: 0, y: 1, z: 3 }, up: { x: 0, y: 1, z: 0 }, item: Key }, { cell: { x: 0, y: 1, z: 5 }, up: { x: 0, y: 1, z: 0 }, item: Key }], start: { cell: { x: 0, y: 1, z: 9 }, up: { x: 0, y: 1, z: 0 }, forward: { x: 0, y: 0, z: -1 } } })
	pickups.map(|p| p.id) == [0, 1] and pickups.map(|p| p.cell.z) == [3, 5] and pickups.all(|p| p.kind == Key)
}

# The rot turns the item's +y to its face's up, whatever the spin.
expect {
	on_wall = { ..key_on({ x: 0, y: 1, z: 0 }, { x: -1, y: 0, z: 0 }), spin: 0.3 }
	turned = Quat.rotate(y_axis, Pickup.rot(on_wall))
	near(turned.x, -1.0) and near(turned.y, 0.0) and near(turned.z, 0.0)
}
