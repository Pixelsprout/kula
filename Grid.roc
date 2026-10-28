import linalg.Vec3
import World

Grid := [].{
	add : World.Cell, World.Cell -> World.Cell
	add = |a, b| { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }

	sub : World.Cell, World.Cell -> World.Cell
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }

	neg : World.Cell -> World.Cell
	neg = |a| { x: -a.x, y: -a.y, z: -a.z }

	cross : World.Cell, World.Cell -> World.Cell
	cross = |a, b| {
		x: a.y * b.z - a.z * b.y,
		y: a.z * b.x - a.x * b.z,
		z: a.x * b.y - a.y * b.x,
	}

	dot : World.Cell, World.Cell -> I32
	dot = |a, b| a.x * b.x + a.y * b.y + a.z * b.z

	scale : World.Cell, I32 -> World.Cell
	scale = |a, s| { x: a.x * s, y: a.y * s, z: a.z * s }

	to_vec3 : World.Cell -> { x : F32, y : F32, z : F32 }
	to_vec3 = |c| { x: c.x.to_f32(), y: c.y.to_f32(), z: c.z.to_f32() }

	# The point height cells out along up from the face under cell, the face of the block at cell - up.
	over_face : World.Cell, World.Cell, F32 -> Vec3.Vec3
	over_face = |cell, up, height| Vec3.add(to_vec3(cell), Vec3.scale(to_vec3(up), height - 0.5))

	has_block : Set(World.Cell), World.Cell -> Bool
	has_block = |blocks, cell| blocks.contains(cell)
}

expect Grid.add({ x: 1, y: 2, z: 3 }, { x: 0, y: -1, z: 4 }) == { x: 1, y: 1, z: 7 }
expect Grid.sub({ x: 1, y: 2, z: 3 }, { x: 0, y: -1, z: 4 }) == { x: 1, y: 3, z: -1 }
expect Grid.neg({ x: 1, y: 0, z: -1 }) == { x: -1, y: 0, z: 1 }
# Right-handed: +x cross +y is +z, and +y cross -z is -x.
expect Grid.cross({ x: 1, y: 0, z: 0 }, { x: 0, y: 1, z: 0 }) == { x: 0, y: 0, z: 1 }
expect Grid.cross({ x: 0, y: 1, z: 0 }, { x: 0, y: 0, z: -1 }) == { x: -1, y: 0, z: 0 }
expect Grid.dot({ x: 1, y: -2, z: 3 }, { x: 0, y: 1, z: 0 }) == -2
expect Grid.scale({ x: 0, y: 0, z: -1 }, 2) == { x: 0, y: 0, z: -2 }
expect Grid.to_vec3({ x: 1, y: -2, z: 3 }) == { x: 1.0, y: -2.0, z: 3.0 }
expect Grid.over_face({ x: 1, y: 2, z: 3 }, { x: -1, y: 0, z: 0 }, 0.25) == { x: 1.25, y: 2.0, z: 3.0 }
expect Grid.has_block(Set.from_list([{ x: 1, y: 0, z: 2 }]), { x: 1, y: 0, z: 2 })
expect !Grid.has_block(Set.from_list([{ x: 1, y: 0, z: 2 }]), { x: 1, y: 1, z: 2 })
