import "levels/level1.txt" as level1 : Str
import "levels/level2.txt" as level2 : Str
import "levels/level3.txt" as level3 : Str
import World
import Grid

Level := [].{
	count : U64
	count = texts.len()

	# Levels count from 1. A number past the last level gives empty text, which does not parse.
	text : U64 -> Str
	text = |number| texts.get(number - 1) ?? ""

	# Layers run bottom first, with a blank line between. Row index is z,
	# column index is x and layer index is y. A line with a space is an entry:
	# `x y z face item` or `start x y z face forward`, where x y z is a block.
	# RaggedRow, BadEntry and NoBlock carry the line number, counted from 1.
	parse : Str -> Try(World.Level, [RaggedRow(U64), UnknownChar(Str), NoStart, TwoStarts, BadEntry(U64), NoBlock(U64)])
	parse = |source| {
		var $blocks = Set.empty()
		var $items = []
		var $starts = []
		var $entries = []
		var $width = 0
		var $line_number = 0
		var $y = 0
		var $z = 0
		for raw in Str.split_on(source, "\n") {
			line = Str.drop_suffix(raw, "\r")
			$line_number = $line_number + 1
			bytes = Str.to_utf8(line)
			if line == "" {
				if $z > 0 {
					$y = $y + 1
					$z = 0
				}
			} else if bytes.contains(' ') {
				match entry(line) {
					Ok(e) => {
						$entries = $entries.append({ line: $line_number, entry: e })
					}
					Err(Bad) => return Err(BadEntry($line_number))
				}
			} else {
				if $width == 0 {
					$width = bytes.len()
				} else if bytes.len() != $width {
					return Err(RaggedRow($line_number))
				}
				var $x = 0
				for byte in bytes {
					block = { x: $x, y: $y, z: $z }
					above = Grid.add(block, up)
					match tile(byte) {
						Ok(Empty) => {}
						Ok(Block) => {
							$blocks = $blocks.insert(block)
						}
						Ok(Start) => {
							$blocks = $blocks.insert(block)
							$starts = $starts.append({ cell: above, up, forward: { x: 0, y: 0, z: -1 } })
						}
						Ok(OnTop(item)) => {
							$blocks = $blocks.insert(block)
							$items = $items.append({ cell: above, up, item })
						}
						Err(Unknown) => return Err(UnknownChar(Str.from_utf8([byte]) ?? "?"))
					}
					$x = $x + 1
				}
				$z = $z + 1
			}
		}
		for numbered in $entries {
			match numbered.entry {
				Item({ block, face, item }) => {
					if !$blocks.contains(block) {
						return Err(NoBlock(numbered.line))
					}
					$items = $items.append({ cell: Grid.add(block, face), up: face, item })
				}
				Start({ block, face, forward }) => {
					if !$blocks.contains(block) {
						return Err(NoBlock(numbered.line))
					}
					$starts = $starts.append({ cell: Grid.add(block, face), up: face, forward })
				}
			}
		}
		match $starts {
			[] => Err(NoStart)
			[start] => Ok({ blocks: $blocks, items: $items, start })
			_ => Err(TwoStarts)
		}
	}
}

texts : List(Str)
texts = [level1, level2, level3]

up : World.Cell
up = { x: 0, y: 1, z: 0 }

tile : U8 -> Try([Empty, Block, Start, OnTop(World.Item)], [Unknown])
tile = |byte| match byte {
	'.' => Ok(Empty)
	'#' => Ok(Block)
	'S' => Ok(Start)
	'K' => Ok(OnTop(Key))
	'E' => Ok(OnTop(Exit))
	_ => Err(Unknown)
}

Entry : [
	Item({ block : World.Cell, face : World.Cell, item : World.Item }),
	Start({ block : World.Cell, face : World.Cell, forward : World.Cell }),
]

entry : Str -> Try(Entry, [Bad])
entry = |line| {
	parts = Str.split_on(line, " ").keep_if(|part| part != "")
	match parts {
		["start", x, y, z, face, forward] => {
			block = cell_of(x, y, z)?
			f = axis(face)?
			fwd = axis(forward)?
			if Grid.dot(f, fwd) == 0 {
				Ok(Start({ block, face: f, forward: fwd }))
			} else {
				Err(Bad)
			}
		}
		[x, y, z, face, name] => {
			block = cell_of(x, y, z)?
			f = axis(face)?
			item = match name {
				"key" => Ok(Key)
				"exit" => Ok(Exit)
				_ => Err(Bad)
			}?
			Ok(Item({ block, face: f, item }))
		}
		_ => Err(Bad)
	}
}

cell_of : Str, Str, Str -> Try(World.Cell, [Bad])
cell_of = |x, y, z| Ok({ x: number(x)?, y: number(y)?, z: number(z)? })

axis : Str -> Try(World.Cell, [Bad])
axis = |name| match name {
	"+x" => Ok({ x: 1, y: 0, z: 0 })
	"-x" => Ok({ x: -1, y: 0, z: 0 })
	"+y" => Ok({ x: 0, y: 1, z: 0 })
	"-y" => Ok({ x: 0, y: -1, z: 0 })
	"+z" => Ok({ x: 0, y: 0, z: 1 })
	"-z" => Ok({ x: 0, y: 0, z: -1 })
	_ => Err(Bad)
}

# A cell index: decimal digits with an optional leading minus.
number : Str -> Try(I32, [Bad])
number = |text| {
	bytes = Str.to_utf8(text)
	digits = if bytes.first() == Ok('-') {
		bytes.drop_first(1)
	} else {
		bytes
	}
	if digits.is_empty() or digits.len() > 6 {
		return Err(Bad)
	}
	var $value = 0
	for byte in digits {
		if byte < '0' or byte > '9' {
			return Err(Bad)
		}
		$value = $value * 10 + (byte - '0').to_i32()
	}
	if bytes.first() == Ok('-') {
		Ok(0 - $value)
	} else {
		Ok($value)
	}
}

cell : I32, I32, I32 -> World.Cell
cell = |x, y, z| { x, y, z }

# The route through level1, from S at the bottom of the file towards E at the top:
# 1. Roll straight along -z from S over the first key.
# 2. Climb the wall of the upper layer and roll onto its top.
# 3. Collect the second key, then roll over the far edge onto the side of the block.
# 4. Climb straight back onto the lower layer.
# 5. Jump the gap two cells ahead.
# 6. Roll on to the exit.
expect {
	level = Level.parse(Level.text(1))
	level.map_ok(|l| l.start) == Ok({ cell: cell(0, 1, 9), up: cell(0, 1, 0), forward: cell(0, 0, -1) })
}

expect {
	level = Level.parse(Level.text(1))
	level.map_ok(|l| l.items) == Ok([
		{ cell: cell(0, 1, 0), up: cell(0, 1, 0), item: Exit },
		{ cell: cell(0, 1, 7), up: cell(0, 1, 0), item: Key },
		{ cell: cell(0, 2, 5), up: cell(0, 1, 0), item: Key },
	])
}

expect {
	level = Level.parse(Level.text(1))
	level.map_ok(|l| l.blocks.len()) == Ok(11)
}

expect {
	blocks = Level.parse(Level.text(1)).map_ok(|l| l.blocks) ?? Set.empty()
	Grid.has_block(blocks, cell(0, 0, 9)) and Grid.has_block(blocks, cell(0, 1, 6)) and !Grid.has_block(blocks, cell(0, 0, 3)) and !Grid.has_block(blocks, cell(0, 1, 7))
}

expect Level.parse("#S\n##\n\n..\n.") == Err(RaggedRow(5))
expect Level.parse("#S\n#x") == Err(UnknownChar("x"))
expect Level.parse("##\n##") == Err(NoStart)
expect Level.parse("#S\nS#") == Err(TwoStarts)
expect Level.parse("..\n\nS.\n") == Ok({ blocks: Set.from_list([cell(0, 1, 0)]), items: [], start: { cell: cell(0, 2, 0), up: cell(0, 1, 0), forward: cell(0, 0, -1) } })

# Entries put items and the start on any face, with any forward.
expect {
	source = "##\n\n#.\n\n0 0 0 -x key\n1 0 0 +y exit\n0 1 0 +z key\nstart 1 0 0 +x +y\n"
	Level.parse(source)
		== Ok({
			blocks: Set.from_list([cell(0, 0, 0), cell(1, 0, 0), cell(0, 1, 0)]),
			items: [
				{ cell: cell(-1, 0, 0), up: cell(-1, 0, 0), item: Key },
				{ cell: cell(1, 1, 0), up: cell(0, 1, 0), item: Exit },
				{ cell: cell(0, 1, 1), up: cell(0, 0, 1), item: Key },
			],
			start: { cell: cell(2, 0, 0), up: cell(1, 0, 0), forward: cell(0, 1, 0) },
		})
}

# scripts/test_convert_level.py expects the converter to write this text for its synthetic level.
expect {
	source = "#..\n###\n###\n\n2 0 2 +y exit\n1 0 2 +y key\n2 0 2 +x key\nstart 0 0 2 +y -z\n"
	counts = Level.parse(source).map_ok(|l| { blocks: l.blocks.len(), keys: l.items.keep_if(|e| e.item == Key).len(), exits: l.items.keep_if(|e| e.item == Exit).len(), start: l.start })
	counts == Ok({ blocks: 7, keys: 2, exits: 1, start: { cell: cell(0, 1, 2), up: cell(0, 1, 0), forward: cell(0, 0, -1) } })
}

# The shortcuts and the entries mix: S is the start and K and E sit with the entry items.
expect {
	level = Level.parse("SK\n\n1 0 0 -z exit\n")
	level.map_ok(|l| { start: l.start.cell, items: l.items.map(|e| { cell: e.cell, item: e.item }) })
		== Ok({ start: cell(0, 1, 0), items: [{ cell: cell(1, 1, 0), item: Key }, { cell: cell(1, 0, -1), item: Exit }] })
}

expect Level.parse("#S\n\nstart 0 0 0 +y -z\n") == Err(TwoStarts)
expect Level.parse("##\n\nstart 0 0 0 +y +y\n") == Err(BadEntry(3))
expect Level.parse("##\n\n0 0 0 +w key\nstart 0 0 0 +y -z\n") == Err(BadEntry(3))
expect Level.parse("##\n\n0 0 0 +y coin\n") == Err(BadEntry(3))
expect Level.parse("##\n\n0 0 x +y key\n") == Err(BadEntry(3))
expect Level.parse("##\n\n0 0 0 +y key extra\n") == Err(BadEntry(3))
expect Level.parse("##\n\n5 0 0 +y key\nstart 0 0 0 +y -z\n") == Err(NoBlock(3))
expect Level.parse("##\n\nstart 0 -1 0 +y -z\n") == Err(NoBlock(3))
expect number("-12") == Ok(-12) and number("034") == Ok(34) and number("-") == Err(Bad) and number("") == Err(Bad)

expect Level.count == 3
expect Level.parse(Level.text(4)) == Err(NoStart)

# level2 turns twice and jumps a gap.
expect {
	level = Level.parse(Level.text(2))
	level.map_ok(|l| { start: l.start.cell, keys: l.items.keep_if(|e| e.item == Key).len(), blocks: l.blocks.len() }) == Ok({ start: cell(0, 1, 7), keys: 2, blocks: 11 })
}

# level3 climbs a tower two blocks high.
expect {
	level = Level.parse(Level.text(3))
	level.map_ok(|l| { start: l.start.cell, keys: l.items.keep_if(|e| e.item == Key).map(|e| e.cell), blocks: l.blocks.len() }) == Ok({ start: cell(0, 1, 9), keys: [cell(0, 2, 5), cell(0, 3, 6)], blocks: 12 })
}
