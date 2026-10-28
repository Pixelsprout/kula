import linalg.Quat
import linalg.Vec3
import World
import Grid

Ball := [].{
	# bob is the phase of the idle bob, in turns from 0 to 1.
	Ball : { pose : World.Pose, motion : Motion, turn : Turn, rot : Quat.Quat, bob : F32, squish : Squish }

	# Seconds since the ball touched down, while the landing squish runs.
	Squish : [Settled, Squashing(F32)]

	# The pose commits when a move starts. from, offset, over and t only serve Ball.interpolated.
	# A jump from a roll starts offset cells along forward from from.cell.
	# A fall jumps to over, then drops straight down. Its seconds count from the jump start.
	# spin_rate is in radians a second. It plays the part of the original's rotX.
	# A bounce follows the jump arc toward to until it hits, then drops back onto over.
	# A bounce from a jump in place has `to` equal to `from`. Its seconds count from the jump start.
	Motion : [Still, Rolling({ from : World.Pose, t : F32 }), Jumping({ from : World.Pose, offset : F32, t : F32 }), JumpingInPlace({ t : F32 }), Falling({ from : World.Pose, offset : F32, over : World.Pose, drop : Drop, seconds : F32, spin_rate : F32 }), Bouncing(Bounce)]

	Bounce : { from : World.Pose, offset : F32, to : World.Pose, hit : Hit, over : World.Pose, drop : Drop, seconds : F32 }

	# The jump's t at the contact.
	Hit : [Wall(F32), Ceiling(F32)]

	# A wall is 1 or 2 cells ahead at the ball's level. A ceiling is a block above
	# the cell that many cells along forward.
	Obstacle : [Ceiling(I32), Wall(I32)]

	# Cells the ball drops below over. Off drops to 2 cells past the lowest block, then the level restarts.
	Drop : [Onto(I32), Off(I32)]

	# A turn runs while the ball is Still or JumpingInPlace, and can outlast the jump.
	# next holds a turn pressed during this one, as the original's startTurningLeftNextFrame.
	Turn : [Steady, Turning({ from : World.Pose, t : F32, next : NextTurn })]

	NextTurn : [Stay, TurnLeft, TurnRight]

	# Jump is a forward jump when Up is held or the ball rolls, else a jump in place.
	Action : [Roll, TurnLeft, TurnRight, Jump({ up_held : Bool })]

	# In cells. The original rests the ball centre 100 of 512 units above a face.
	radius : F32
	radius = 0.195

	start : World.Pose -> Ball.Ball
	start = |pose| { pose, motion: Still, turn: Steady, rot: Quat.identity, bob: 0.0, squish: Settled }

	# An edge roll needs an open end, as in the original.
	roll : Set(World.Cell), World.Pose -> Try(World.Pose, [ClosedEdge])
	roll = |blocks, pose| {
		ahead = Grid.add(pose.cell, pose.forward)
		standing_on = Grid.sub(pose.cell, pose.up)
		right = Grid.cross(pose.forward, pose.up)
		if Grid.has_block(blocks, ahead) {
			Ok({ cell: pose.cell, up: Grid.neg(pose.forward), forward: pose.up })
		} else if Grid.has_block(blocks, Grid.sub(ahead, pose.up)) {
			Ok({ ..pose, cell: ahead })
		} else if Grid.has_block(blocks, Grid.add(standing_on, right)) or Grid.has_block(blocks, Grid.sub(standing_on, right)) {
			Err(ClosedEdge)
		} else {
			Ok({ cell: Grid.sub(ahead, pose.up), up: pose.forward, forward: Grid.neg(pose.up) })
		}
	}

	RollKind : [Floor, Climb, Edge]

	roll_kind : World.Pose, World.Pose -> RollKind
	roll_kind = |from, to|
		if from.up == to.up {
			Floor
		} else if from.cell == to.cell {
			Climb
		} else {
			Edge
		}

	# The distance the ball centre travels. A climb rolls to the wall, then up it.
	# An edge roll adds a quarter circle round the edge.
	roll_length : RollKind -> F32
	roll_length = |kind| match kind {
		Floor => 1.0
		Climb => 2.0 * (0.5 - radius)
		Edge => 1.0 + quarter_turn * radius
	}

	turn_left : World.Pose -> World.Pose
	turn_left = |pose| { ..pose, forward: Grid.cross(pose.up, pose.forward) }

	turn_right : World.Pose -> World.Pose
	turn_right = |pose| { ..pose, forward: Grid.cross(pose.forward, pose.up) }

	# Always two cells ahead at the same level. A block in the path, or a block
	# above that the rising ball reaches, bounces the ball back. The jump starts
	# offset cells along forward from pose.cell.
	jump : Set(World.Cell), World.Pose, F32 -> [Land(World.Pose), Fall({ over : World.Pose, drop : Drop }), Bounce(List(Obstacle))]
	jump = |blocks, pose, offset| {
		ahead = Grid.add(pose.cell, pose.forward)
		two_ahead = Grid.add(ahead, pose.forward)
		ceiling = [-1, 0, 1, 2].keep_oks(
			|column| {
				above = Grid.add(Grid.add(pose.cell, Grid.scale(pose.forward, column)), pose.up)
				if Grid.has_block(blocks, above) {
					ceiling_contact(column, offset).map_ok(|_| Ceiling(column))
				} else {
					Err(Missed)
				}
			},
		)
		wall = if Grid.has_block(blocks, ahead) {
			[Wall(1)]
		} else if Grid.has_block(blocks, two_ahead) {
			[Wall(2)]
		} else {
			[]
		}
		obstacles = ceiling.concat(wall)
		if obstacles != [] {
			Bounce(obstacles)
		} else if Grid.has_block(blocks, Grid.sub(two_ahead, pose.up)) {
			Land({ ..pose, cell: two_ahead })
		} else {
			over = { ..pose, cell: two_ahead }
			lowest = lowest_along(blocks, pose.up, Grid.dot(two_ahead, pose.up))
			Fall({ over, drop: drop_below(blocks, over, 1, lowest) })
		}
	}

	jump_lift : F32 -> F32
	jump_lift = |t| 4.0 * jump_height * t * (1.0 - t)

	fall_stage : F32 -> [Arc(F32), Dropped(F32)]
	fall_stage = |seconds| if seconds < jump_seconds {
		Arc(seconds / jump_seconds)
	} else {
		Dropped(drop_distance(seconds - jump_seconds))
	}

	fell_off : Ball.Ball -> Bool
	fell_off = |ball| match ball.motion {
		Falling({ drop: Off(cells), seconds, .. }) => seconds >= fall_seconds(Off(cells))
		Bouncing(bouncing) => match bouncing.drop {
			Off(_) => bouncing.seconds >= bounce_seconds(bouncing)
			Onto(_) => False
		}
		_ => False
	}

	# The original tests for a landing only in the last 11 of the jump's 27 frames.
	can_land : F32, F32 -> Bool
	can_land = |t, lift| t >= 16.0 / 27.0 and lift <= 0.0

	# True when the ball touches down on a block between before and after.
	landed : Ball.Ball, Ball.Ball -> Bool
	landed = |before, after| can_touch_down(before.motion) and !can_touch_down(after.motion)

	# True when the ball hits a wall or a ceiling between before and after.
	# A bounce that ends in this step hit in this step too.
	hit : Ball.Ball, Ball.Ball -> Bool
	hit = |before, after| match (before.motion, after.motion) {
		(Bouncing(was), Bouncing(now)) => !past_contact(was) and past_contact(now)
		(Bouncing(was), _) => !past_contact(was)
		(_, Bouncing(now)) => past_contact(now)
		_ => False
	}

	# The landing squish as a part of the radius, which View adds to the idle bob.
	squash : Ball.Ball -> F32
	squash = |ball| match ball.squish {
		Settled => 0.0
		Squashing(seconds) => landing_squish(seconds)
	}

	# The pose whose face is under the ball centre. As in the original, a roll
	# reaches its new cell when the centre passes the half-cell line.
	standing : Ball.Ball -> Try(World.Pose, [InAir])
	standing = |ball| match ball.motion {
		Still => Ok(ball.pose)
		Rolling({ from, t }) => if t < 0.5 {
			Ok(from)
		} else {
			Ok(ball.pose)
		}
		_ => Err(InAir)
	}

	# A roll or a jump starts only from Still with no turn running. A floor roll,
	# or an edge roll before the edge, can also start a jump. A turn can start
	# during a jump in place.
	act : Set(World.Cell), Ball.Ball, Action -> Ball.Ball
	act = |blocks, ball, action| {
		from = ball.pose
		match (ball.motion, ball.turn, action) {
			(Still, Steady, Roll) => match roll(blocks, from) {
				Ok(pose) => { ..ball, pose, motion: Rolling({ from, t: 0.0 }) }
				Err(ClosedEdge) => ball
			}
			(Still, Steady, Jump({ up_held })) => if up_held {
				leap(blocks, ball, from, 0.0)
			} else {
				start_jump_in_place(blocks, ball)
			}
			# The jump starts from the cell the ball is nearest to.
			(Rolling({ from: roll_from, t }), _, Jump(_)) if roll_kind(roll_from, ball.pose) == Floor =>
				if t < 0.5 {
					leap(blocks, ball, roll_from, t)
				} else {
					leap(blocks, ball, ball.pose, t - 1.0)
				}
			# The original rolls up to the edge before it turns, so X still jumps there.
			(Rolling({ from: roll_from, t }), _, Jump(_)) if roll_kind(roll_from, ball.pose) == Edge and t * roll_length(Edge) < 0.5 =>
				leap(blocks, ball, roll_from, t * roll_length(Edge))
			(motion, _, TurnLeft) if can_turn(motion) => turn(ball, TurnLeft)
			(motion, _, TurnRight) if can_turn(motion) => turn(ball, TurnRight)
			_ => ball
		}
	}

	Placement : { pos : Vec3.Vec3, up : Vec3.Vec3, forward : Vec3.Vec3 }

	interpolated : Ball.Ball -> Placement
	interpolated = |ball| {
		placed = match ball.motion {
			Still => placement_of(ball.pose)
			Rolling({ from, t }) => between(from, ball.pose, t)
			Jumping({ from, offset, t }) => lifted(jump_placement(from, offset, ball.pose, t), Ball.jump_lift(t))
			JumpingInPlace({ t }) => lifted(placement_of(ball.pose), Ball.jump_lift(t))
			Falling({ from, offset, over, seconds, .. }) => match Ball.fall_stage(seconds) {
				Arc(t) => lifted(jump_placement(from, offset, over, t), Ball.jump_lift(t))
				Dropped(cells) => lifted(placement_of(over), -cells)
			}
			Bouncing(bouncing) => bounce_placement(bouncing)
		}
		match ball.turn {
			Steady => placed
			Turning({ from, t, .. }) => { ..placed, forward: between(from, ball.pose, t).forward }
		}
	}

	# The centre rests one radius above the face. Round an edge it follows the
	# original's path: half a cell to the edge, a quarter circle of one radius
	# about the edge line, then half a cell down the side. The idle bob does not move it.
	centre : Ball.Ball -> Vec3.Vec3
	centre = |ball| match ball.motion {
		Rolling({ from, t }) if Ball.roll_kind(from, ball.pose) == Edge => edge_centre(from, t)
		_ => {
			placed = Ball.interpolated(ball)
			Vec3.sub(placed.pos, Vec3.scale(placed.up, 0.5 - Ball.radius))
		}
	}

	advance : Ball.Ball, F32 -> Ball.Ball
	advance = |ball, dt| move(ball, dt, Released)

	# With Up held, a roll or jump that ends this step starts the next roll in the
	# same step. The next roll gets the time left over, so the ball keeps its speed.
	advance_up_held : Set(World.Cell), Ball.Ball, F32 -> Ball.Ball
	advance_up_held = |blocks, ball, dt| {
		moved = move(ball, dt, Held)
		match (moved.motion, moved.turn) {
			(Still, Steady) if ball.motion != Still => {
				# One roll at most, so a long step cannot chain rolls past a pickup.
				busy = seconds_left(ball)
				turning = turn_seconds_left(ball)
				left_over = dt - (
					if turning > busy {
						turning
					} else {
						busy
					}
				)
				if left_over > 0.0 {
					move(act(blocks, moved, Roll), left_over, Held)
				} else {
					act(blocks, moved, Roll)
				}
			}
			_ => moved
		}
	}
}

leap : Set(World.Cell), Ball.Ball, World.Pose, F32 -> Ball.Ball
leap = |blocks, ball, from, offset| match Ball.jump(blocks, from, offset) {
	Land(pose) => { ..ball, pose, motion: Jumping({ from, offset, t: 0.0 }) }
	Fall({ over, drop }) => { ..ball, pose: landing(over, drop), motion: Falling({ from, offset, over, drop, seconds: 0.0, spin_rate: top_spin }) }
	Bounce(obstacles) => {
		hits = obstacles.map(|obstacle| hit_of(obstacle, offset))
		first = hits.drop_first(1).fold(
			hits.first() ?? Ceiling(ceiling_t),
			|a, b| if hit_t(b) < hit_t(a) {
				b
			} else {
				a
			},
		)
		bounce(blocks, ball, from, offset, { ..from, cell: Grid.add(from.cell, Grid.scale(from.forward, 2)) }, first)
	}
}

# The ball centre touches a wall one radius before the wall's face.
hit_of : Ball.Obstacle, F32 -> Ball.Hit
hit_of = |obstacle, offset| match obstacle {
	# Ball.jump keeps only the ceilings that the ball reaches.
	Ceiling(column) => Ceiling(ceiling_contact(column, offset) ?? ceiling_t)
	Wall(cells) => Wall((cells.to_f32() - 0.5 - Ball.radius - offset) / (2.0 - offset))
}

# As in the original, a rising ball high enough to touch a ceiling hits a block
# above any cell that the ball reaches over the cell line. The jump's t at the
# first contact, from a jump that starts offset cells along forward.
ceiling_contact : I32, F32 -> Try(F32, [Missed])
ceiling_contact = |column, offset| {
	rate = 2.0 - offset
	enters = (column.to_f32() - 0.5 - Ball.radius - offset) / rate
	leaves = (column.to_f32() + 0.5 + Ball.radius - offset) / rate
	t = enters.max(ceiling_t)
	if t <= 0.5 and t < leaves {
		Ok(t)
	} else {
		Err(Missed)
	}
}

hit_t : Ball.Hit -> F32
hit_t = |hit| match hit {
	Wall(t) => t
	Ceiling(t) => t
}

# The ball drops onto the cell nearest the contact, which is less than 1.5
# cells ahead. From there it can fall further.
bounce : Set(World.Cell), Ball.Ball, World.Pose, F32, World.Pose, Ball.Hit -> Ball.Ball
bounce = |blocks, ball, from, offset, to, hit| {
	column = if reach_at(from, offset, to, hit_t(hit)) < 0.5 {
		0
	} else {
		1
	}
	over = { ..from, cell: Grid.add(from.cell, Grid.scale(from.forward, column)) }
	drop = if Grid.has_block(blocks, Grid.sub(over.cell, over.up)) {
		Onto(0)
	} else {
		drop_below(blocks, over, 1, lowest_along(blocks, over.up, Grid.dot(over.cell, over.up)))
	}
	{ ..ball, pose: landing(over, drop), motion: Bouncing({ from, offset, to, hit, over, drop, seconds: 0.0 }) }
}

# Cells along from.forward from from.cell, t into the jump arc toward to.
reach_at : World.Pose, F32, World.Pose, F32 -> F32
reach_at = |from, offset, to, t| offset * (1.0 - t) + Grid.dot(Grid.sub(to.cell, from.cell), from.forward).to_f32() * t

# From the contact, in cells and seconds. back is the speed back along forward.
Rebound : { at : F32, forward : F32, lift : F32, back : F32, speed : F32, seconds : F32 }

# As in the original, a wall hit jumps the ball back 2 frames of its forward
# speed and sends it back at that speed. A ceiling hit does the same down. A
# wall hit while rising starts the drop at 10 units a frame.
rebound : Ball.Bounce -> Rebound
rebound = |bouncing| {
	t = hit_t(bouncing.hit)
	forward = reach_at(bouncing.from, bouncing.offset, bouncing.to, t)
	forward_speed = reach_at(bouncing.from, bouncing.offset, bouncing.to, 1.0) - bouncing.offset
	rising_speed = 4.0 * jump_height * (1.0 - 2.0 * t) / jump_seconds
	depth = match bouncing.drop {
		Onto(cells) => cells.to_f32()
		Off(cells) => cells.to_f32()
	}
	at = t * jump_seconds
	match bouncing.hit {
		Wall(_) => {
			speed = if rising_speed > 0.0 {
				wall_drop_speed
			} else {
				0.0
			}
			back = forward_speed / jump_seconds
			{ at, forward: forward - snap_seconds * back, lift: Ball.jump_lift(t), back, speed, seconds: drop_time(speed, Ball.jump_lift(t) + depth) }
		}
		Ceiling(_) => {
			lift = Ball.jump_lift(t) - snap_seconds * rising_speed
			{ at, forward, lift, back: 0.0, speed: rising_speed, seconds: drop_time(rising_speed, lift + depth) }
		}
	}
}

bounce_seconds : Ball.Bounce -> F32
bounce_seconds = |bouncing| {
	r = rebound(bouncing)
	r.at + r.seconds
}

past_contact : Ball.Bounce -> Bool
past_contact = |bouncing| bouncing.seconds >= rebound(bouncing).at

# After the contact the ball reaches over's centre just as it lands. A wall
# hit gets there on its slowing path back, a ceiling hit at an even pace.
bounce_placement : Ball.Bounce -> Ball.Placement
bounce_placement = |bouncing| {
	r = rebound(bouncing)
	if bouncing.seconds < r.at {
		t = bouncing.seconds / jump_seconds
		lifted(jump_placement(bouncing.from, bouncing.offset, bouncing.to, t), Ball.jump_lift(t))
	} else {
		since = bouncing.seconds - r.at
		share = if r.back > 0.0 {
			backed(r.back, since) / backed(r.back, r.seconds)
		} else {
			since / r.seconds
		}
		column = Grid.dot(Grid.sub(bouncing.over.cell, bouncing.from.cell), bouncing.from.forward).to_f32()
		placed = placement_of(bouncing.from)
		along = r.forward + (column - r.forward) * share
		lift = r.lift - fallen(r.speed, since)
		{ ..placed, pos: Vec3.add(placed.pos, Vec3.add(Vec3.scale(placed.forward, along), Vec3.scale(placed.up, lift))) }
	}
}

# Cells travelled back after the contact. The speed drops by 7 units a frame to 0.
backed : F32, F32 -> F32
backed = |speed, seconds| {
	stop = speed / back_slowing
	if seconds < stop {
		speed * seconds - 0.5 * back_slowing * seconds * seconds
	} else {
		speed * stop / 2.0
	}
}

# The original drops until it leaves its fixed grid. The clone stops 2 cells past the lowest block.
drop_below : Set(World.Cell), World.Pose, I32, I32 -> Ball.Drop
drop_below = |blocks, over, depth, lowest| {
	below = Grid.sub(over.cell, Grid.scale(over.up, depth + 1))
	if Grid.dot(below, over.up) < lowest {
		Off(Grid.dot(over.cell, over.up) - lowest + 2)
	} else if Grid.has_block(blocks, below) {
		Onto(depth)
	} else {
		drop_below(blocks, over, depth + 1, lowest)
	}
}

lowest_along : Set(World.Cell), World.Cell, I32 -> I32
lowest_along = |blocks, up, start| blocks.to_list().fold(
	start,
	|low, block| {
		along = Grid.dot(block, up)
		if along < low {
			along
		} else {
			low
		}
	},
)

landing : World.Pose, Ball.Drop -> World.Pose
landing = |over, drop| match drop {
	Onto(depth) => { ..over, cell: Grid.sub(over.cell, Grid.scale(over.up, depth)) }
	Off(_) => over
}

start_jump_in_place : Set(World.Cell), Ball.Ball -> Ball.Ball
start_jump_in_place = |blocks, ball|
	if Grid.has_block(blocks, Grid.add(ball.pose.cell, ball.pose.up)) {
		bounce(blocks, ball, ball.pose, 0.0, ball.pose, Ceiling(ceiling_t))
	} else {
		{ ..ball, motion: JumpingInPlace({ t: 0.0 }) }
	}

# A fall off the level never touches down. The level restarts instead.
can_touch_down : Ball.Motion -> Bool
can_touch_down = |motion| match motion {
	Jumping(_) => True
	JumpingInPlace(_) => True
	Falling({ drop: Onto(_), .. }) => True
	Bouncing({ drop: Onto(_), .. }) => True
	_ => False
}

can_turn : Ball.Motion -> Bool
can_turn = |motion| match motion {
	Still => True
	JumpingInPlace(_) => True
	_ => False
}

# A press during a turn waits for that turn to end.
turn : Ball.Ball, Ball.NextTurn -> Ball.Ball
turn = |ball, side| match ball.turn {
	Steady => start_turn(ball, side)
	Turning(turning) => { ..ball, turn: Turning({ ..turning, next: side }) }
}

start_turn : Ball.Ball, Ball.NextTurn -> Ball.Ball
start_turn = |ball, side| {
	from = ball.pose
	match side {
		Stay => { ..ball, turn: Steady }
		TurnLeft => { ..ball, pose: Ball.turn_left(from), turn: Turning({ from, t: 0.0, next: Stay }) }
		TurnRight => { ..ball, pose: Ball.turn_right(from), turn: Turning({ from, t: 0.0, next: Stay }) }
	}
}

advance_turn : Ball.Ball, F32 -> Ball.Ball
advance_turn = |ball, dt| match ball.turn {
	Steady => ball
	Turning(turning) => {
		next = progress(turning.t, dt, turn_seconds)
		if next < 1.0 {
			{ ..ball, turn: Turning({ ..turning, t: next }) }
		} else {
			start_turn(ball, turning.next)
		}
	}
}

move : Ball.Ball, F32, [Held, Released] -> Ball.Ball
move = |ball, dt, up| {
	moved = advance_turn(advance_motion(advance_bob(advance_squish(ball, dt), dt), dt, up), dt)
	if can_touch_down(ball.motion) and !can_touch_down(moved.motion) {
		{ ..moved, squish: Squashing(0.0) }
	} else {
		moved
	}
}

advance_squish : Ball.Ball, F32 -> Ball.Ball
advance_squish = |ball, dt| match ball.squish {
	Settled => ball
	Squashing(seconds) => {
		..ball,
		squish: if seconds + dt >= squish_seconds {
			Settled
		} else {
			Squashing(seconds + dt)
		},
	}
}

# The original's landing squish, in 4096ths, one value a PAL frame from the
# contact frame: it rises by 187 for 4 frames, then falls by 90, 80 and so on
# down to 20 a frame, until it is 0.
squish_frames : List(F32)
squish_frames = squish_rise(4, 0).concat(squish_fall(squish_peak, 100))

squish_rise : I32, I32 -> List(F32)
squish_rise = |frames, amount|
	if frames == 0 {
		[]
	} else {
		[(amount + 187).to_f32()].concat(squish_rise(frames - 1, amount + 187))
	}

squish_peak : I32
squish_peak = 4 * 187

squish_fall : I32, I32 -> List(F32)
squish_fall = |amount, damping| {
	next_damping = if damping - 10 < 20 {
		20
	} else {
		damping - 10
	}
	next = amount - next_damping
	if next <= 0 {
		[0.0]
	} else {
		[next.to_f32()].concat(squish_fall(next, next_damping))
	}
}

squish_seconds : F32
squish_seconds = (squish_frames.len() - 1).to_f32() * 0.02

# Linear between frames: each frame's amount weighs 1 at its frame and 0 one frame away.
landing_squish : F32 -> F32
landing_squish = |seconds| {
	frame = seconds / 0.02
	squish_frames.map_with_index(|amount, i| amount * hat(frame - i.to_f32())).fold(0.0, |sum, part| sum + part) / 4096.0
}

hat : F32 -> F32
hat = |x| if x.abs() < 1.0 {
	1.0 - x.abs()
} else {
	0.0
}

# The original holds the bob in a forward jump and while the ball wraps an
# edge. A fall starts with a forward jump.
advance_bob : Ball.Ball, F32 -> Ball.Ball
advance_bob = |ball, dt| match ball.motion {
	_ if ball.squish != Settled => ball
	Jumping(_) => ball
	Bouncing(bouncing) if bouncing.to != bouncing.from and !past_contact(bouncing) => ball
	Falling({ seconds, .. }) if seconds < jump_seconds => ball
	Rolling({ from, t }) if Ball.roll_kind(from, ball.pose) == Edge and wrapping(t * Ball.roll_length(Edge)) => ball
	_ => {
		next = ball.bob + bob_rate(full_clock) * dt
		{
			..ball,
			bob: if next >= 1.0 {
				next - 1.0
			} else {
				next
			},
		}
	}
}

advance_motion : Ball.Ball, F32, [Held, Released] -> Ball.Ball
advance_motion = |ball, dt, up| match ball.motion {
	Still => ball
	Rolling({ from, t }) => {
		kind = Ball.roll_kind(from, ball.pose)
		next = progress(t, dt, roll_seconds(kind))
		{
			..ball,
			rot: spin_about(from, (next - t) * Ball.roll_length(kind) / Ball.radius, ball.rot),
			motion: if next < 1.0 {
				Rolling({ from, t: next })
			} else {
				Still
			},
		}
	}
	# The landing cell always has a floor, so the ball lands back at rest height.
	Jumping(jumping) => {
		next = progress(jumping.t, dt, jump_seconds)
		rot = spin_about(jumping.from, (next - jumping.t) * jump_seconds * top_spin, ball.rot)
		{
			..ball,
			rot,
			motion: if Ball.can_land(next, Ball.jump_lift(next)) {
				Still
			} else {
				Jumping({ ..jumping, t: next })
			},
		}
	}
	JumpingInPlace({ t }) => {
		next = progress(t, dt, jump_seconds)
		{
			..ball,
			motion: if Ball.can_land(next, Ball.jump_lift(next)) {
				Still
			} else {
				JumpingInPlace({ t: next })
			},
		}
	}
	# An Off fall waits at its end for Rules to restart the level.
	Falling(falling) => {
		total = fall_seconds(falling.drop)
		next = if falling.seconds + dt > total {
			total
		} else {
			falling.seconds + dt
		}
		spun = fall_spin(falling.seconds, next, falling.spin_rate, up)
		rot = spin_about(falling.from, spun.angle, ball.rot)
		match falling.drop {
			Onto(_) if next >= total => { ..ball, rot, motion: Still }
			_ => { ..ball, rot, motion: Falling({ ..falling, seconds: next, spin_rate: spun.rate }) }
		}
	}
	# A forward jump spins at the top rate until the contact. The hit stops the spin.
	Bouncing(bouncing) => {
		total = bounce_seconds(bouncing)
		next = if bouncing.seconds + dt > total {
			total
		} else {
			bouncing.seconds + dt
		}
		at = rebound(bouncing).at
		spin = if bouncing.to == bouncing.from {
			0.0
		} else {
			top_spin * (min(next, at) - min(bouncing.seconds, at))
		}
		rot = spin_about(bouncing.from, spin, ball.rot)
		match bouncing.drop {
			Onto(_) if next >= total => { ..ball, rot, motion: Still }
			_ => { ..ball, rot, motion: Bouncing({ ..bouncing, seconds: next }) }
		}
	}
}

min : F32, F32 -> F32
min = |a, b| if a < b {
	a
} else {
	b
}

spin_about : World.Pose, F32, Quat.Quat -> Quat.Quat
spin_about = |from, angle, rot| Quat.mul(Quat.from_axis_angle(Grid.to_vec3(Grid.cross(from.up, from.forward)), angle), rot)

# The arc keeps its spin. The drop builds it to top_spin with Up held, else runs it down to 0.
fall_spin : F32, F32, F32, [Held, Released] -> { rate : F32, angle : F32 }
fall_spin = |from_seconds, to_seconds, rate, up| {
	arc_end = if to_seconds < jump_seconds {
		to_seconds
	} else {
		jump_seconds
	}
	arc = if arc_end > from_seconds {
		arc_end - from_seconds
	} else {
		0.0
	}
	drop = to_seconds - from_seconds - arc
	dropped = match up {
		Held => spin_toward(rate, top_spin, spin_gain, drop)
		Released => spin_toward(rate, 0.0, spin_loss, drop)
	}
	{ rate: dropped.rate, angle: rate * arc + dropped.angle }
}

# The rate changes linearly and stops at target, so the angle does not depend on the step size.
spin_toward : F32, F32, F32, F32 -> { rate : F32, angle : F32 }
spin_toward = |rate, target, change, seconds| {
	to_target = (target - rate).abs() / change
	if seconds <= to_target {
		next = if target > rate {
			rate + change * seconds
		} else {
			rate - change * seconds
		}
		{ rate: next, angle: (rate + next) / 2.0 * seconds }
	} else {
		{ rate: target, angle: (rate + target) / 2.0 * to_target + target * (seconds - to_target) }
	}
}

turn_seconds_left : Ball.Ball -> F32
turn_seconds_left = |ball| match ball.turn {
	Steady => 0.0
	Turning({ t, .. }) => (1.0 - t) * turn_seconds
}

seconds_left : Ball.Ball -> F32
seconds_left = |ball| match ball.motion {
	Still => 0.0
	Rolling({ from, t }) => (1.0 - t) * roll_seconds(Ball.roll_kind(from, ball.pose))
	Jumping({ t, .. }) => (1.0 - t) * jump_seconds
	JumpingInPlace({ t }) => (1.0 - t) * jump_seconds
	Falling({ drop, seconds, .. }) => fall_seconds(drop) - seconds
	Bouncing(bouncing) => bounce_seconds(bouncing) - bouncing.seconds
}

# PAL frame counts from the original, at 0.02 s a frame. See SPEC.md.
# An edge roll is half a cell at top speed, the 4-frame wrap, then half a cell.
roll_seconds : Ball.RollKind -> F32
roll_seconds = |kind| match kind {
	Floor => 0.26
	Climb => 0.28
	Edge => 0.34
}

quarter_turn : F32
quarter_turn = 1.5707963

turn_seconds : F32
turn_seconds = 0.32

jump_seconds : F32
jump_seconds = 0.54

jump_height : F32
jump_height = 0.5

# The wrap is the quarter circle between the two half cells of an edge roll.
wrapping : F32 -> Bool
wrapping = |cells| cells >= 0.5 and cells < 0.5 + quarter_turn * Ball.radius

# The clone has no level clock yet, so the bob runs at the rate for a full one.
full_clock : F32
full_clock = 100.0

# Turns a second, for clock seconds left. Each frame the original adds 165 - 1.25 * clock, in 4096ths of a turn.
bob_rate : F32 -> F32
bob_rate = |clock| (165.0 - 1.25 * clock) / 4096.0 / 0.02

# Radians a second at the top roll speed.
top_spin : F32
top_spin = 1.0 / roll_seconds(Floor) / Ball.radius

# A fall adds 6 to rotX a frame with Up held, else takes 1 away. The top rotX is 40.
spin_gain : F32
spin_gain = top_spin * 6.0 / 40.0 / 0.02

spin_loss : F32
spin_loss = top_spin / 40.0 / 0.02

# The original adds 6 units a frame to the fall speed, up to 80 units a frame.
gravity : F32
gravity = 6.0 / 512.0 / (0.02 * 0.02)

top_fall_speed : F32
top_fall_speed = 80.0 / 512.0 / 0.02

# The drop starts at the speed the jump arc ends with.
drop_start_speed : F32
drop_start_speed = 4.0 * jump_height / jump_seconds

drop_distance : F32 -> F32
drop_distance = |seconds| fallen(drop_start_speed, seconds)

drop_seconds : F32 -> F32
drop_seconds = |cells| drop_time(drop_start_speed, cells)

# Cells fallen in seconds from a start speed below the top speed.
fallen : F32, F32 -> F32
fallen = |speed, seconds| {
	to_top = (top_fall_speed - speed) / gravity
	if seconds <= to_top {
		speed * seconds + 0.5 * gravity * seconds * seconds
	} else {
		(speed + top_fall_speed) / 2.0 * to_top + top_fall_speed * (seconds - to_top)
	}
}

drop_time : F32, F32 -> F32
drop_time = |speed, cells| {
	to_top = (top_fall_speed - speed) / gravity
	to_top_cells = (speed + top_fall_speed) / 2.0 * to_top
	if cells <= to_top_cells {
		((speed * speed + 2.0 * gravity * cells).sqrt() - speed) / gravity
	} else {
		to_top + (cells - to_top_cells) / top_fall_speed
	}
}

# A wall hit while rising drops at 10 units a frame, then gains gravity (`player_movement.c:438, 703-705`).
wall_drop_speed : F32
wall_drop_speed = 10.0 / 512.0 / 0.02

# The back speed after a wall hit drops by 7 units a frame (`:431-436`).
back_slowing : F32
back_slowing = 7.0 / 512.0 / (0.02 * 0.02)

# A hit first moves the ball back by 2 frames of its speed (`:699-701, 742-744`).
snap_seconds : F32
snap_seconds = 2.0 * 0.02

# Kula's arc peaks below the height at which the ball would touch a ceiling.
# It hits at the same part of its peak as the Roll Away jump: at 312 of 458 units.
ceiling_t : F32
ceiling_t = (1.0 - (1.0 - 312.0 / 458.0).sqrt()) / 2.0

fall_seconds : Ball.Drop -> F32
fall_seconds = |drop| {
	cells = match drop {
		Onto(depth) => depth
		Off(depth) => depth
	}
	jump_seconds + drop_seconds(cells.to_f32())
}

# Clamped to 1, so the last step of a roll spins only the remaining distance.
progress : F32, F32, F32 -> F32
progress = |t, dt, seconds| {
	next = t + dt / seconds
	if next > 1.0 {
		1.0
	} else {
		next
	}
}

edge_centre : World.Pose, F32 -> Vec3.Vec3
edge_centre = |from, t| {
	up = Grid.to_vec3(from.up)
	forward = Grid.to_vec3(from.forward)
	r = Ball.radius
	edge = Vec3.add(Grid.to_vec3(Grid.sub(from.cell, from.up)), Vec3.scale(Vec3.add(up, forward), 0.5))
	arc = quarter_turn * r
	s = t * Ball.roll_length(Edge)
	if s < 0.5 {
		Vec3.add(edge, Vec3.add(Vec3.scale(up, r), Vec3.scale(forward, s - 0.5)))
	} else if s < 0.5 + arc {
		a = (s - 0.5) / r
		Vec3.add(edge, Vec3.add(Vec3.scale(up, r * a.cos()), Vec3.scale(forward, r * a.sin())))
	} else {
		Vec3.sub(Vec3.add(edge, Vec3.scale(forward, r)), Vec3.scale(up, s - 0.5 - arc))
	}
}

jump_placement : World.Pose, F32, World.Pose, F32 -> Ball.Placement
jump_placement = |from, offset, to, t| {
	placed = between(from, to, t)
	{ ..placed, pos: Vec3.add(placed.pos, Vec3.scale(placed.forward, offset * (1.0 - t))) }
}

lifted : Ball.Placement, F32 -> Ball.Placement
lifted = |placed, lift| { ..placed, pos: Vec3.add(placed.pos, Vec3.scale(placed.up, lift)) }

placement_of : World.Pose -> Ball.Placement
placement_of = |pose| { pos: Grid.to_vec3(pose.cell), up: Grid.to_vec3(pose.up), forward: Grid.to_vec3(pose.forward) }

between : World.Pose, World.Pose, F32 -> Ball.Placement
between = |from, to, t| {
	a = placement_of(from)
	b = placement_of(to)
	{ pos: Vec3.lerp(a.pos, b.pos, t), up: Vec3.normalize(Vec3.lerp(a.up, b.up, t)), forward: Vec3.normalize(Vec3.lerp(a.forward, b.forward, t)) }
}

cell : I32, I32, I32 -> World.Cell
cell = |x, y, z| { x, y, z }

y_up : World.Cell
y_up = cell(0, 1, 0)

north : World.Cell
north = cell(0, 0, -1)

# The ball stands on the block at the origin, facing -z.
on_origin : World.Pose
on_origin = { cell: y_up, up: y_up, forward: north }

blocks : List(World.Cell) -> Set(World.Cell)
blocks = |cells| Set.from_list(cells)

expect Ball.roll(blocks([cell(0, 0, 0), cell(0, 1, -1)]), on_origin) == Ok({ cell: y_up, up: cell(0, 0, 1), forward: y_up })
expect Ball.roll(blocks([cell(0, 0, 0), cell(0, 0, -1)]), on_origin) == Ok({ cell: cell(0, 1, -1), up: y_up, forward: north })

# Over the edge onto the block's -z side, then on round under it.
expect {
	floor = blocks([cell(0, 0, 0)])
	side = Ball.roll(floor, on_origin) ?? on_origin
	under = Ball.roll(floor, side) ?? side
	side == { cell: cell(0, 0, -1), up: north, forward: cell(0, -1, 0) } and under == { cell: cell(0, -1, 0), up: cell(0, -1, 0), forward: cell(0, 0, 1) }
}

# An edge roll needs an open end: no block beside the one the ball stands on.
expect Ball.roll(blocks([cell(0, 0, 0), cell(1, 0, 0)]), on_origin) == Err(ClosedEdge)
expect Ball.roll(blocks([cell(0, 0, 0), cell(-1, 0, 0)]), on_origin) == Err(ClosedEdge)

expect Ball.turn_left(on_origin) == { ..on_origin, forward: cell(-1, 0, 0) }
expect Ball.turn_right(on_origin) == { ..on_origin, forward: cell(1, 0, 0) }

expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 0, -2)]), on_origin, 0.0) == Land({ ..on_origin, cell: cell(0, 1, -2) })
expect Ball.jump(blocks([cell(0, 0, 0)]), on_origin, 0.0) == Fall({ over: { ..on_origin, cell: cell(0, 1, -2) }, drop: Off(3) })

# A jump with no floor two ahead falls onto the first block below the target.
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, -1, -2)]), on_origin, 0.0) == Fall({ over: { ..on_origin, cell: cell(0, 1, -2) }, drop: Onto(1) })

# On a wall the search runs along -x.
expect {
	on_wall = { cell: cell(1, 0, 0), up: cell(1, 0, 0), forward: north }
	over = { ..on_wall, cell: cell(1, 0, -2) }
	Ball.jump(blocks([cell(0, 0, 0), cell(-1, 0, -2)]), on_wall, 0.0) == Fall({ over, drop: Onto(1) }) and Ball.jump(blocks([cell(0, 0, 0)]), on_wall, 0.0) == Fall({ over, drop: Off(3) })
}
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 1, -1), cell(0, 0, -2)]), on_origin, 0.0) == Bounce([Wall(1)])
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 1, -2), cell(0, 0, -2)]), on_origin, 0.0) == Bounce([Wall(2)])
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, 0)]), on_origin, 0.0) == Bounce([Ceiling(0)])

# At ceiling height the ball already reaches over the line to the next cell, so a block above that cell bounces it too.
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, -1)]), on_origin, 0.0) == Bounce([Ceiling(1)])

# A block above the cell behind counts only for a ball that starts far enough back.
expect {
	behind = blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, 1)])
	Ball.jump(behind, on_origin, 0.0) == Land({ ..on_origin, cell: cell(0, 1, -2) }) and Ball.jump(behind, on_origin, -1.0) == Bounce([Ceiling(-1)])
}

# A jump late in a roll has left the start cell's column by the time it is high enough.
expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, 0)]), on_origin, 0.45) == Land({ ..on_origin, cell: cell(0, 1, -2) })

floor_ahead : Set(World.Cell)
floor_ahead = blocks([cell(0, 0, 0), cell(0, 0, -1), cell(0, 0, -2)])

still : Ball.Ball
still = Ball.start(on_origin)

forward_jump : Ball.Action
forward_jump = Jump({ up_held: True })

near_quat : Quat.Quat, Quat.Quat -> Bool
near_quat = |a, b| (a.x - b.x).abs() < 0.0001 and (a.y - b.y).abs() < 0.0001 and (a.z - b.z).abs() < 0.0001 and (a.w - b.w).abs() < 0.0001

expect {
	ball = Ball.act(floor_ahead, still, Roll)
	ball.pose.cell == cell(0, 1, -1) and ball.motion == Rolling({ from: on_origin, t: 0.0 })
}

expect Ball.act(blocks([cell(0, 0, 0), cell(1, 0, 0)]), still, Roll) == still
expect Ball.act(floor_ahead, still, TurnLeft).turn == Turning({ from: on_origin, t: 0.0, next: Stay })
expect Ball.act(floor_ahead, still, forward_jump) == { ..still, pose: { ..on_origin, cell: cell(0, 1, -2) }, motion: Jumping({ from: on_origin, offset: 0.0, t: 0.0 }) }
expect Ball.act(blocks([cell(0, 0, 0)]), still, forward_jump) == { ..still, pose: { ..on_origin, cell: cell(0, 1, -2) }, motion: Falling({ from: on_origin, offset: 0.0, over: { ..on_origin, cell: cell(0, 1, -2) }, drop: Off(3), seconds: 0.0, spin_rate: top_spin }) }
expect {
	two_ahead = { ..on_origin, cell: cell(0, 1, -2) }
	jumped = Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -1)]), still, forward_jump)
	jumped.pose == on_origin and match jumped.motion {
		Bouncing({ from, offset, to, hit: Wall(t), over, drop, seconds }) => from == on_origin and offset == 0.0 and to == two_ahead and near(t, (0.5 - Ball.radius) / 2.0) and over == on_origin and drop == Onto(0) and seconds == 0.0
		_ => False
	}
}

# Input is read only when Still.
expect {
	rolling = Ball.act(floor_ahead, still, Roll)
	Ball.act(floor_ahead, rolling, TurnLeft) == rolling
}

expect Ball.advance(Ball.act(floor_ahead, still, Roll), 0.13).motion == Rolling({ from: on_origin, t: 0.5 })
expect Ball.advance(Ball.act(floor_ahead, still, Roll), 0.26).motion == Still
expect Ball.advance(Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -1)]), still, Roll), 0.14).motion == Rolling({ from: on_origin, t: 0.5 })
expect Ball.advance(Ball.act(blocks([cell(0, 0, 0)]), still, Roll), 0.17).motion == Rolling({ from: on_origin, t: 0.5 })
expect Ball.advance(Ball.act(floor_ahead, still, TurnRight), 0.16).turn == Turning({ from: on_origin, t: 0.5, next: Stay })
expect Ball.advance(Ball.act(floor_ahead, still, TurnRight), 0.32).turn == Steady
expect Ball.advance(Ball.act(floor_ahead, still, forward_jump), 0.27).motion == Jumping({ from: on_origin, offset: 0.0, t: 0.5 })
expect Ball.advance(Ball.act(floor_ahead, still, forward_jump), 0.54).motion == Still
expect { ..Ball.advance(still, 1.0), bob: 0.0 } == still

# A 1-cell drop lands between 0.70 and 0.71 s after the jump starts.
expect {
	falling = Ball.act(blocks([cell(0, 0, 0), cell(0, -1, -2)]), still, forward_jump)
	landed = Ball.advance(falling, 0.71)
	falling.pose.cell == cell(0, 0, -2) and Ball.advance(falling, 0.70).motion != Still and landed.motion == Still and landed.pose.cell == cell(0, 0, -2)
}

# Rolling along -z on +y turns about -x, one cell over the radius, however the steps fall.
expect {
	rolling = Ball.act(floor_ahead, still, Roll)
	ball = [0.06, 0.07, 0.06, 0.07, 0.05].fold(rolling, |b, dt| Ball.advance(b, dt))
	ball.motion == Still and near_quat(ball.rot, x_axis_spin(1.0 / Ball.radius))
}

x_axis_spin : F32 -> Quat.Quat
x_axis_spin = |angle| Quat.from_axis_angle({ x: -1.0, y: 0.0, z: 0.0 }, angle)

# A forward jump spins at the top roll rate from its first frame.
expect near_quat(Ball.advance(Ball.act(floor_ahead, still, forward_jump), 0.27).rot, x_axis_spin(0.27 * top_spin))
expect near_quat(Ball.advance(Ball.act(floor_ahead, still, forward_jump), 0.54).rot, x_axis_spin(0.54 * top_spin))

# The spin carries on into the next roll with no jump in angle.
expect {
	jumping = Ball.act(long_floor, still, forward_jump)
	ball = Ball.advance_up_held(long_floor, jumping, 0.67)
	near_quat(ball.rot, x_axis_spin(0.54 * top_spin + 0.5 / Ball.radius))
}

# 13 cells to fall, so the ball is still falling after 2 s.
deep_drop : Set(World.Cell)
deep_drop = blocks([cell(0, 0, 0), cell(5, -10, 5)])

fall_spin_rate : Ball.Ball -> F32
fall_spin_rate = |ball| match ball.motion {
	Falling({ spin_rate, .. }) => spin_rate
	_ => -1.0
}

expect Ball.act(deep_drop, still, forward_jump).motion == Falling({ from: on_origin, offset: 0.0, over: { ..on_origin, cell: cell(0, 1, -2) }, drop: Off(13), seconds: 0.0, spin_rate: top_spin })

# The arc keeps the top rate. Without Up, the drop then stops the spin in 0.8 s.
expect {
	falling = Ball.act(deep_drop, still, forward_jump)
	ball = Ball.advance(falling, 2.0)
	near(fall_spin_rate(Ball.advance(falling, 0.94)), 0.5 * top_spin) and fall_spin_rate(ball) == 0.0 and near_quat(ball.rot, x_axis_spin((0.54 + 0.4) * top_spin))
}

# With Up held, the drop keeps the top rate.
expect {
	falling = Ball.act(deep_drop, still, forward_jump)
	near_quat(Ball.advance_up_held(deep_drop, falling, 1.54).rot, x_axis_spin(1.54 * top_spin))
}

# With Up held again, the rate climbs back to the top.
expect {
	slowed = Ball.advance(Ball.act(deep_drop, still, forward_jump), 0.94)
	near(fall_spin_rate(Ball.advance_up_held(deep_drop, slowed, 0.04)), 0.8 * top_spin) and fall_spin_rate(Ball.advance_up_held(deep_drop, slowed, 0.1)) == top_spin
}

# The fall spin does not depend on how the steps fall, also across the arc's end.
expect {
	falling = Ball.act(deep_drop, still, forward_jump)
	stepped = [0.3, 0.3, 0.3, 0.3, 0.34].fold(falling, |b, dt| Ball.advance(b, dt))
	near_quat(stepped.rot, Ball.advance(falling, 1.54).rot)
}

# A ball that lands from a fall keeps the angle it spun to.
expect {
	landed = Ball.advance(Ball.act(blocks([cell(0, 0, 0), cell(0, -1, -2)]), still, forward_jump), 0.71)
	drop = drop_seconds(1.0)
	landed.motion == Still and near_quat(landed.rot, x_axis_spin(top_spin * (0.54 + drop - 0.5 * 1.25 * drop * drop)))
}

in_place : Ball.Action
in_place = Jump({ up_held: False })

long_floor : Set(World.Cell)
long_floor = blocks([cell(0, 0, 0), cell(0, 0, -1), cell(0, 0, -2), cell(0, 0, -3)])

rolling_at : F32 -> Ball.Ball
rolling_at = |t| { ..Ball.act(long_floor, still, Roll), motion: Rolling({ from: on_origin, t }) }

# A jump from a roll spins at the top rate too.
expect near_quat(Ball.advance(Ball.act(long_floor, rolling_at(0.25), forward_jump), 0.27).rot, x_axis_spin(0.27 * top_spin))

expect Ball.act(floor_ahead, still, in_place) == { ..still, motion: JumpingInPlace({ t: 0.0 }) }
expect Ball.advance(Ball.act(floor_ahead, still, in_place), 0.27).motion == JumpingInPlace({ t: 0.5 })
expect { ..Ball.advance(Ball.act(floor_ahead, still, in_place), 0.54), bob: 0.0 } == { ..still, squish: Squashing(0.0) }

# A jump in place does not spin.
expect Ball.advance(Ball.act(floor_ahead, still, in_place), 0.27).rot == Quat.identity

# Only a block above bounces a jump in place. A block ahead does not.
expect Ball.act(blocks([cell(0, 0, 0), cell(0, 2, 0)]), still, in_place) == { ..still, motion: Bouncing({ from: on_origin, offset: 0.0, to: on_origin, hit: Ceiling(ceiling_t), over: on_origin, drop: Onto(0), seconds: 0.0 }) }
expect Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -1)]), still, in_place).motion == JumpingInPlace({ t: 0.0 })

# A jump from a roll lands two cells past the cell the ball is nearest to.
expect Ball.act(long_floor, rolling_at(0.25), in_place) == { ..still, pose: { ..on_origin, cell: cell(0, 1, -2) }, motion: Jumping({ from: on_origin, offset: 0.25, t: 0.0 }) }
expect Ball.act(long_floor, rolling_at(0.75), in_place) == { ..still, pose: { ..on_origin, cell: cell(0, 1, -3) }, motion: Jumping({ from: { ..on_origin, cell: cell(0, 1, -1) }, offset: -0.25, t: 0.0 }) }

# A block in the path bounces a jump from a roll. The ball drops back onto the cell before the wall.
expect {
	jumped = Ball.act(blocks([cell(0, 0, 0), cell(0, 0, -1), cell(0, 0, -2), cell(0, 1, -2)]), rolling_at(0.25), in_place)
	jumped.pose.cell == cell(0, 1, -1) and match jumped.motion {
		Bouncing({ from, offset, hit: Wall(_), drop, .. }) => from == on_origin and offset == 0.25 and drop == Onto(0)
		_ => False
	}
}

# Climbs and turns cannot start a jump. An edge roll can, until the ball reaches the edge.
expect {
	climbing = { ..Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -1)]), still, Roll), motion: Rolling({ from: on_origin, t: 0.75 }) }
	Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -1)]), climbing, forward_jump) == climbing
}
expect {
	gap = blocks([cell(0, 0, 0), cell(0, 0, -2)])
	approaching = { ..Ball.act(gap, still, Roll), motion: Rolling({ from: on_origin, t: 0.2 }) }
	jumped = Ball.act(gap, approaching, in_place)
	jumped.pose == { ..on_origin, cell: cell(0, 1, -2) } and match jumped.motion {
		Jumping({ from, offset, t }) => from == on_origin and near(offset, 0.2 * Ball.roll_length(Edge)) and t == 0.0
		_ => False
	}
}
expect {
	gap = blocks([cell(0, 0, 0), cell(0, 0, -2)])
	on_wrap = { ..Ball.act(gap, still, Roll), motion: Rolling({ from: on_origin, t: 0.5 }) }
	Ball.act(gap, on_wrap, forward_jump) == on_wrap
}
expect {
	turning = Ball.act(floor_ahead, still, TurnLeft)
	Ball.act(floor_ahead, turning, forward_jump) == turning and Ball.act(floor_ahead, turning, in_place) == turning
}

# No input acts during a forward jump.
expect {
	jumping = Ball.act(floor_ahead, still, forward_jump)
	[TurnLeft, TurnRight, Roll, forward_jump, in_place].all(|action| Ball.act(floor_ahead, jumping, action) == jumping)
}

# During a jump in place, Left and Right turn the ball. The turn can outlast the jump.
expect {
	jumping_in_place = Ball.advance(Ball.act(floor_ahead, still, in_place), 0.4)
	turning = Ball.act(floor_ahead, jumping_in_place, TurnLeft)
	landed = Ball.advance(turning, 0.2)
	turning.motion == JumpingInPlace({ t: 0.4 / 0.54 }) and turning.turn == Turning({ from: on_origin, t: 0.0, next: Stay }) and landed.motion == Still and landed.turn != Steady
}

# A turn pressed during a turn starts when the current one ends.
expect {
	turning = Ball.act(floor_ahead, Ball.act(floor_ahead, still, in_place), TurnLeft)
	queued = Ball.act(floor_ahead, turning, TurnLeft)
	after = Ball.advance(queued, 0.32)
	queued.pose == turning.pose and after.turn == Turning({ from: Ball.turn_left(on_origin), t: 0.0, next: Stay }) and after.pose == Ball.turn_left(Ball.turn_left(on_origin))
}

# The original tests for a landing only in the last 11 of 27 frames.
expect !Ball.can_land(15.0 / 27.0, 0.0) and Ball.can_land(16.0 / 27.0, 0.0) and !Ball.can_land(0.9, 0.01)
expect {
	jumping = Ball.act(floor_ahead, still, forward_jump)
	Ball.advance(jumping, 0.53).motion != Still and Ball.advance(jumping, 0.54).motion == Still
}

near : F32, F32 -> Bool
near = |a, b| (a - b).abs() < 0.0001

# With Up held, the next roll starts in the step the last one ends, with the time left over.
expect {
	ball = Ball.advance_up_held(long_floor, rolling_at(0.5), 0.26)
	ball.pose.cell == cell(0, 1, -2) and match ball.motion {
		Rolling({ from, t }) => from.cell == cell(0, 1, -1) and near(t, 0.5)
		_ => False
	}
}

expect {
	jumping = Ball.act(long_floor, still, forward_jump)
	ball = Ball.advance_up_held(long_floor, jumping, 0.54)
	ball.pose.cell == cell(0, 1, -3) and match ball.motion {
		Rolling({ t, .. }) => near(t, 0.0)
		_ => False
	}
}

# A turn that outlasts the jump in place holds the roll back.
expect {
	turning = Ball.act(floor_ahead, Ball.advance(Ball.act(floor_ahead, still, in_place), 0.4), TurnLeft)
	Ball.advance_up_held(floor_ahead, turning, 0.2).motion == Still
}

expect Ball.advance(rolling_at(0.5), 0.26).motion == Still

# A block above bounces a forward jump too. A block two ahead does not bounce a jump in place.
expect Ball.act(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, 0)]), still, forward_jump) == { ..still, motion: Bouncing({ from: on_origin, offset: 0.0, to: { ..on_origin, cell: cell(0, 1, -2) }, hit: Ceiling(ceiling_t), over: on_origin, drop: Onto(0), seconds: 0.0 }) }
expect Ball.act(blocks([cell(0, 0, 0), cell(0, 1, -2)]), still, in_place).motion == JumpingInPlace({ t: 0.0 })

# The next roll gets the time after the later of the jump's end and the turn's end.
expect {
	west = blocks([cell(0, 0, 0), cell(-1, 0, 0)])
	turning = Ball.act(west, Ball.advance(Ball.act(west, still, in_place), 0.4), TurnLeft)
	ball = Ball.advance_up_held(west, turning, 0.52)
	ball.pose.cell == cell(-1, 1, 0) and match ball.motion {
		Rolling({ t, .. }) => near(t, 0.2 / roll_seconds(Floor))
		_ => False
	}
}

expect near(Ball.advance(still, 0.512).bob, 0.25)
expect near(Ball.advance(Ball.advance(still, 1.0), 1.048).bob, 0.0)

# The bob runs in a roll and a jump in place.
expect Ball.advance(Ball.act(floor_ahead, still, Roll), 0.1).bob > 0.0
expect Ball.advance(Ball.act(floor_ahead, still, Jump({ up_held: False })), 0.1).bob > 0.0

# A forward jump holds the bob, as does the arc of a fall.
expect {
	bobbing = { ..still, bob: 0.3 }
	Ball.advance(Ball.act(floor_ahead, bobbing, forward_jump), 0.27).bob == 0.3
}

expect {
	bobbing = { ..still, bob: 0.3 }
	falling = Ball.act(blocks([cell(0, 0, 0), cell(0, -3, -2)]), bobbing, forward_jump)
	in_arc = Ball.advance(falling, 0.5)
	in_arc.bob == 0.3 and Ball.advance(Ball.advance(in_arc, 0.1), 0.1).bob > 0.3
}

# The bob holds while the ball wraps an edge, and runs on the way to it.
expect {
	rolling = Ball.act(blocks([cell(0, 0, 0)]), still, Roll)
	on_wrap = Ball.advance(rolling, 0.14)
	Ball.advance(rolling, 0.02).bob > 0.0 and Ball.advance(on_wrap, 0.02).bob == on_wrap.bob
}

# A forward jump lands in the step it ends, also when Up held starts the next roll in that step.
expect {
	jumping = Ball.act(long_floor, still, forward_jump)
	!Ball.landed(jumping, Ball.advance(jumping, 0.53)) and Ball.landed(jumping, Ball.advance(jumping, 0.54)) and Ball.landed(jumping, Ball.advance_up_held(long_floor, jumping, 0.6))
}

# A fall onto a block lands. A fall off the level does not, though the restart leaves the ball Still.
expect {
	onto = Ball.act(blocks([cell(0, 0, 0), cell(0, -1, -2)]), still, forward_jump)
	off = Ball.advance(Ball.act(blocks([cell(0, 0, 0)]), still, forward_jump), 5.0)
	!Ball.landed(onto, Ball.advance(onto, 0.70)) and Ball.landed(onto, Ball.advance(onto, 0.71)) and !Ball.landed(off, still)
}

# As in the original, a jump in place lands and a roll does not.
expect {
	jumping_in_place = Ball.act(floor_ahead, still, in_place)
	rolling = Ball.act(floor_ahead, still, Roll)
	!Ball.landed(jumping_in_place, Ball.advance(jumping_in_place, 0.53)) and Ball.landed(jumping_in_place, Ball.advance(jumping_in_place, 0.54)) and !Ball.landed(rolling, Ball.advance(rolling, 0.26)) and !Ball.landed(still, still)
}

near_vec3 : Vec3.Vec3, Vec3.Vec3 -> Bool
near_vec3 = |a, c| Vec3.length(Vec3.sub(a, c)) < 0.0001

expect Ball.interpolated(Ball.start(on_origin)) == { pos: { x: 0.0, y: 1.0, z: 0.0 }, up: { x: 0.0, y: 1.0, z: 0.0 }, forward: { x: 0.0, y: 0.0, z: -1.0 } }

expect {
	half = Ball.advance(Ball.act(floor_ahead, Ball.start(on_origin), Roll), 0.13)
	Ball.interpolated(half).pos == { x: 0.0, y: 1.0, z: -0.5 }
}

# Halfway round an edge, up and forward are each a unit diagonal.
expect {
	edge = blocks([cell(0, 0, 0)])
	placed = Ball.interpolated(Ball.advance(Ball.act(edge, Ball.start(on_origin), Roll), 0.17))
	s = 0.70710678
	near_vec3(placed.pos, { x: 0.0, y: 0.5, z: -0.5 }) and near_vec3(placed.up, { x: 0.0, y: s, z: -s }) and near_vec3(placed.forward, { x: 0.0, y: -s, z: -s })
}

# A jump peaks half a cell above the straight line at its midpoint.
expect {
	placed = Ball.interpolated(Ball.advance(Ball.act(floor_ahead, Ball.start(on_origin), Jump({ up_held: True })), 0.27))
	near_vec3(placed.pos, { x: 0.0, y: 1.5, z: -1.0 })
}

# A jump into nothing drops to 2 cells below the lowest block.
expect {
	falling = Ball.act(blocks([cell(0, 0, 0)]), Ball.start(on_origin), Jump({ up_held: True }))
	near_vec3(Ball.interpolated(Ball.advance(falling, 2.0)).pos, { x: 0.0, y: -2.0, z: -2.0 })
}

# The drop starts where the jump arc ends, and ends on the floor below.
expect {
	falling = Ball.act(Set.from_list([cell(0, 0, 0), cell(0, -1, -2)]), Ball.start(on_origin), Jump({ up_held: True }))
	at_arc_end = Ball.interpolated(Ball.advance(falling, 0.539)).pos
	dropping = Ball.interpolated(Ball.advance(falling, 0.541)).pos
	near_arc_end = Vec3.length(Vec3.sub(at_arc_end, { x: 0.0, y: 1.0, z: -2.0 })) < 0.01 and Vec3.length(Vec3.sub(dropping, { x: 0.0, y: 1.0, z: -2.0 })) < 0.01
	near_arc_end and dropping.y < 1.0 and Ball.interpolated(Ball.advance(falling, 1.0)).pos == { x: 0.0, y: 0.0, z: -2.0 }
}

# A jump in place rises half a cell and comes down on the same cell.
expect {
	jumping_in_place = Ball.act(floor_ahead, Ball.start(on_origin), Jump({ up_held: False }))
	near_vec3(Ball.interpolated(Ball.advance(jumping_in_place, 0.27)).pos, { x: 0.0, y: 1.5, z: 0.0 }) and Ball.interpolated(Ball.advance(jumping_in_place, 0.54)).pos == { x: 0.0, y: 1.0, z: 0.0 }
}

# A jump from a roll starts where the ball is and ends on the landing cell.
expect {
	long = Set.from_list([cell(0, 0, 0), cell(0, 0, -1), cell(0, 0, -2), cell(0, 0, -3)])
	rolling = Ball.advance(Ball.act(long, Ball.start(on_origin), Roll), 0.195)
	jumping = Ball.act(long, rolling, Jump({ up_held: False }))
	near_vec3(Ball.interpolated(jumping).pos, Ball.interpolated(rolling).pos) and near_vec3(Ball.interpolated(Ball.advance(jumping, 0.54)).pos, { x: 0.0, y: 1.0, z: -3.0 })
}

# Halfway through a turn during a jump in place, the ball faces between the two directions.
expect {
	jumping_in_place = Ball.act(floor_ahead, Ball.start(on_origin), Jump({ up_held: False }))
	placed = Ball.interpolated(Ball.advance(Ball.act(floor_ahead, jumping_in_place, TurnLeft), 0.16))
	s = 0.70710678
	placed.pos.y > 1.0 and near_vec3(placed.forward, { x: -s, y: 0.0, z: -s })
}

expect Ball.jump(blocks([cell(0, 0, 0), cell(0, 2, 0), cell(0, 1, -1)]), on_origin, 0.0) == Bounce([Ceiling(0), Wall(1)])

wall_ahead : Set(World.Cell)
wall_ahead = blocks([cell(0, 0, 0), cell(0, 1, -1)])

# Distance the ball centre has moved along -z.
along : Ball.Ball -> F32
along = |ball| -Ball.centre(ball).z

# The ball hits a wall one ahead 0.082 s into the jump, when its front reaches the wall face.
expect {
	jumping = Ball.act(wall_ahead, still, forward_jump)
	before = Ball.advance(jumping, 0.08)
	after = Ball.advance(jumping, 0.085)
	!Ball.hit(jumping, before) and Ball.hit(before, after) and !Ball.hit(after, Ball.advance(after, 0.01)) and along(before) > 0.29 and along(before) < 0.5 - Ball.radius
}

# The hit throws the ball back 2 frames of its speed, then it slows, drops and lands
# on its own cell 0.186 s into the jump. It never enters the wall.
expect {
	jumping = Ball.act(wall_ahead, still, forward_jump)
	path = List.repeat(0.005, 40).fold([jumping], |balls, dt| balls.append(Ball.advance(balls.last() ?? jumping, dt)))
	thrown = Ball.advance(jumping, 0.085)
	landed = Ball.advance(jumping, 0.19)
	path.all(|ball| along(ball) <= 0.5 - Ball.radius + 0.0001)
		and along(thrown) < 0.2
			and Ball.advance(jumping, 0.18).motion != Still
				and landed.motion == Still
					and landed.pose == on_origin
						and Ball.landed(Ball.advance(jumping, 0.18), landed)
							and near_vec3(Ball.centre(landed), { x: 0.0, y: 0.695, z: 0.0 })
}

# A forward jump hit while rising keeps no spin past the contact.
expect {
	jumping = Ball.act(wall_ahead, still, forward_jump)
	Ball.advance(jumping, 0.1).rot == Ball.advance(jumping, 0.18).rot and Ball.advance(jumping, 0.1).rot != Quat.identity
}

# A wall two ahead throws the ball back onto the middle cell, 0.53 s into the jump.
expect {
	gap_floor = blocks([cell(0, 0, 0), cell(0, 0, -1), cell(0, 1, -2)])
	jumping = Ball.act(gap_floor, still, forward_jump)
	landed = Ball.advance(jumping, 0.53)
	jumping.pose.cell == cell(0, 1, -1) and Ball.advance(jumping, 0.52).motion != Still and landed.motion == Still and near_vec3(Ball.centre(landed), { x: 0.0, y: 0.695, z: -1.0 })
}

# With no floor under the middle cell, the ball drops onto the block below it, or off the level.
expect {
	ledge = blocks([cell(0, 0, 0), cell(0, -1, -1), cell(0, 1, -2)])
	edge = blocks([cell(0, 0, 0), cell(0, 1, -2)])
	onto = Ball.act(ledge, still, forward_jump)
	off = Ball.act(edge, still, forward_jump)
	onto.pose.cell == cell(0, 0, -1) and Ball.advance(onto, 2.0).motion == Still and !Ball.fell_off(Ball.advance(off, 0.6)) and Ball.fell_off(Ball.advance(off, 2.0))
}

# A jump in place under a block hits the ceiling 0.118 s in and lands 0.197 s in.
expect {
	ceiling = blocks([cell(0, 0, 0), cell(0, 2, 0)])
	jumping = Ball.act(ceiling, still, in_place)
	before = Ball.advance(jumping, 0.115)
	after = Ball.advance(jumping, 0.12)
	landed = Ball.advance(jumping, 0.2)
	top = Ball.centre(before).y
	Ball.hit(before, after) and Ball.centre(after).y < top - 0.08 and top < 1.5 - Ball.radius and Ball.advance(jumping, 0.19).motion != Still and landed.motion == Still and landed.pose == on_origin
}

# A forward jump under a block hits the ceiling, then drops back onto its own cell.
expect {
	jumping = Ball.act(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, 0)]), still, forward_jump)
	landed = Ball.advance(jumping, 0.2)
	Ball.hit(jumping, Ball.advance(jumping, 0.12)) and landed.motion == Still and landed.pose == on_origin and near_vec3(Ball.centre(landed), { x: 0.0, y: 0.695, z: 0.0 })
}

# A forward jump with a block above the next cell hits it, then drops back onto its own cell.
expect {
	jumping = Ball.act(blocks([cell(0, 0, 0), cell(0, 0, -2), cell(0, 2, -1)]), still, forward_jump)
	landed = Ball.advance(jumping, 0.2)
	Ball.hit(jumping, Ball.advance(jumping, 0.12)) and landed.motion == Still and landed.pose == on_origin
}

# A jump past half way through a roll starts behind the roll's end cell. It
# reaches the next cell's column only after ceiling height, and hits there then.
expect {
	ceiling = blocks([cell(0, 0, 0), cell(0, 0, -1), cell(0, 0, -3), cell(0, 2, -2)])
	rolling = Ball.advance(Ball.act(ceiling, still, Roll), 0.156)
	match Ball.act(ceiling, rolling, forward_jump).motion {
		Bouncing({ from, offset, hit: Ceiling(t), over, .. }) => from.cell == cell(0, 1, -1) and over == from and t > ceiling_t and near(t, (0.5 - Ball.radius - offset) / (2.0 - offset))
		_ => False
	}
}

# No input acts during a bounce.
expect {
	bouncing = Ball.act(wall_ahead, still, forward_jump)
	[TurnLeft, TurnRight, Roll, forward_jump, in_place].all(|action| Ball.act(wall_ahead, bouncing, action) == bouncing)
}

# The original's landing squish rises to 748 in 4 frames, then falls to 0 by frame 27.
expect squish_frames.len() == 28 and squish_frames.take_first(5) == [187.0, 374.0, 561.0, 748.0, 658.0] and squish_frames.last() == Ok(0.0)

expect near(landing_squish(0.0), 187.0 / 4096.0) and near(landing_squish(0.06), 748.0 / 4096.0) and near(landing_squish(0.07), 703.0 / 4096.0) and landing_squish(0.54) == 0.0

# A landing starts the squish, which runs out 0.54 s later. The bob holds meanwhile.
expect {
	jumping = { ..Ball.act(floor_ahead, still, forward_jump), bob: 0.3 }
	landed = Ball.advance(jumping, 0.54)
	squashing = Ball.advance(landed, 0.06)
	settled = Ball.advance(landed, 0.55)
	landed.squish == Squashing(0.0) and near(Ball.squash(squashing), 748.0 / 4096.0) and squashing.bob == 0.3 and settled.squish == Settled and Ball.squash(settled) == 0.0 and settled.bob > 0.3
}

# With Up held, the squish runs on into the next roll.
expect {
	landed = Ball.advance_up_held(long_floor, Ball.act(long_floor, still, forward_jump), 0.6)
	match (landed.motion, landed.squish) {
		(Rolling(_), Squashing(seconds)) => near(seconds, 0.06)
		_ => False
	}
}

# A bounce squishes as it lands. A roll and a fall off the level do not.
expect {
	bounced = Ball.advance(Ball.act(wall_ahead, still, forward_jump), 0.19)
	rolled = Ball.advance(Ball.act(floor_ahead, still, Roll), 0.26)
	bounced.squish == Squashing(0.0) and rolled.squish == Settled
}

# A roll stands on its new cell from half way. A jump stands on no cell.
expect {
	rolling = Ball.act(floor_ahead, still, Roll)
	Ball.standing(still) == Ok(on_origin) and Ball.standing(Ball.advance(rolling, 0.12)) == Ok(on_origin) and Ball.standing(Ball.advance(rolling, 0.13)) == Ok(rolling.pose) and Ball.standing(Ball.act(floor_ahead, still, forward_jump)) == Err(InAir)
}
