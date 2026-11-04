extends "../game/g2g_map.gd"

## The constants and block shapes of bhop_g2g_stages.

const G2GGeometry := preload("../game/g2g_geometry.gd")
const G2GReach := preload("../game/g2g_reach.gd")

## `bhop_g2g_stages` — five stages, two bonuses, and a different idea in each stage.
##
## Bonus 1 is a surf descent; bonus 2, `the ridge`, is a staged RUN line — see
## [constant RIDGE_SECTIONS]; bonus 3, `the weave`, is a RUN line that never goes
## straight — see [constant WEAVE_SECTIONS]; bonus 4, `the bend`, is a RUN line that
## never stops turning — see [constant BEND_SECTIONS].
##
## [b]Why this map exists.[/b] `bhop_g2g_intro` is sixteen blocks in a straight line
## over a flat plane. It proves the movement and it is not a map: there is one thing to
## do, once, and a player who can do it has seen everything. It is also the wrong shape
## to exercise this platform, because every interesting thing dot-timer can do —
## stages, splits, a stage restart, a per-stage comparison, a bonus on its own track —
## needs a map with more than one section in it.
##
## This is the timer community's staged-map shape: a course divided into numbered sections
## with a line between each, so a run has a split at every line, a player can practise
## one section with [code]!s3[/code], and the HUD has something to say between the start
## and the finish. Each stage is one idea, so a player who fails knows which idea they
## failed:
##
## [codeblock]
## 1  straight       blocks in a line, gaps growing.      Keep the speed.
## 2  the turn       the course bends 90 degrees.         Strafe through it.
## 3  the climb      blocks rising 24 units each.         Height costs speed.
## 4  the drop       a descent onto narrow blocks.        Do not overshoot.
## 5  the zigzag     blocks alternating left and right.   Both directions.
## [/codeblock]
##
## [b]Everything is derived from a cursor.[/b] `_course()` walks a position and a
## heading and returns every block; the geometry and the zones both read that one list,
## so a stage line cannot drift from the block it is drawn on. That is `G2GMap`'s rule
## and it matters more here than on a straight course — a hand-placed line on a map that
## turns is a leaderboard nobody can compare.

## Units per block along the direction of travel.
const BLOCK_LENGTH := 160.0

## How wide a block is across the direction of travel.
const BLOCK_WIDTH := 176.0

## How wide the narrow blocks in stage 4 are. A 176-unit block is forgiving; 96 is
## about a hull and a half and is where a player starts having to aim the landing.
const NARROW_WIDTH := 96.0

const BLOCK_THICKNESS := 32.0

## How high a stage-3 block sits above the one before it.
##
## 24 units, because a bhop jump gains about 57 and a player who is climbing is
## spending part of every jump on the climb rather than on the gap. Anything past about
## 32 stops being a climb and becomes a wall.
const CLIMB_STEP := 24.0

## How far a stage-4 block sits below the one before it.
const DROP_STEP := 48.0

## How far a zigzag block is offset sideways from the centre line.
const ZIGZAG_OFFSET := 128.0

const FLOOR_Y := 0.0

## How far to the side the bonus sits. See `_build_bonus`.
const BONUS_X := 6144.0

## How steep the surf bonus's two slabs' faces stand, in degrees. Past 45.57, the steepest floor a
## player can stand on, or the bonus is two slopes a player lands on and stops (it was 45,
## `[stages-slabs-1]`): Christian decided it is surf. Map data, so a fork that wants the old
## slopes changes one number; the zones do not depend on it.
const BONUS_RAMP_PITCH := 50.0

## Bonus 2, `the ridge`: up a stair, along a narrowing crest, down the other side. Half
## way between the main course (which never leaves x <= 176) and the surf bonus (whose
## ramps start at 5,760), so neither is in the other's view from a start pad.
const RIDGE_X := 3072.0

## The ridge's three sections, in order. One list, read by the geometry, the zones and
## `headless_run`'s bot, for the reason [constant STAGES] is one list. `rise` is per
## block; a section's first gap is the gap onto its first block.
##
## [b]Every gap is a RUN gap, sized with [G2GReach] under the shipped cvars[/b] — a jump
## from the lip at 250 u/s clears 189 flat, 166 onto +24 and 222 down 48 — and each is at
## least 29 units inside it, so a player who lands anywhere on a block can run to its
## edge and still make the next one. That is the route's whole promise: it is the
## stages map's practice line, for a player who can jump but cannot yet chain, and it
## asks three things a straight line of level blocks does not — judge a climb, hold a
## line on a crest that narrows from 176 to 80, and not overshoot a drop.
const RIDGE_SECTIONS: Array = [
	{"kind": "climb", "blocks": 5, "rise": 24.0, "first_gap": 96.0, "last_gap": 128.0,
		"first_width": 176.0, "last_width": 176.0},
	{"kind": "crest", "blocks": 4, "rise": 0.0, "first_gap": 128.0, "last_gap": 160.0,
		"first_width": 176.0, "last_width": 80.0},
	{"kind": "descent", "blocks": 5, "rise": -48.0, "first_gap": 128.0, "last_gap": 192.0,
		"first_width": 128.0, "last_width": 128.0},
]

## Bonus 3, `the weave`: every block is off to one side of the one before, so every jump
## is a diagonal and a player has to AIM each one. The main route's zigzag stage asks
## it at chaining speed; this asks it alone, at run speed, for the player the ridge was
## for. East of the surf bonus, whose ramps end near 6,600, and clear of everything else.
const WEAVE_X := 9216.0

## The weave's three sections. `offset` is how far each block's centre sits from the
## line, alternating sides; a block reaches `offset - width / 2` past the line toward
## the other side, so neighbours overlap across the line by `2 * offset - width`
## (negative) and a runner who follows the blocks' centres swings 2 * offset every block.
##
## [b]The route is a zigzag and its line is not.[/b] Each block's inner edge reaches
## the centre line or just short of it, so the fast way through is nearly straight,
## clipping the inner corner of every block, and a player who runs the zigzag the
## blocks draw covers more ground and has to turn on every one. That is the question:
## see the line. Every gap is a RUN gap (96 to 160 along, 0 to 16 across the line), at
## least 61 units inside a jump from the lip at 250 u/s (189 flat, 166 onto +24, 222
## down 48).
##
## [b]Measured, not guessed, in three drafts.[/b] With the centres 192 apart and the
## inner edges 32 either side of the line, a runner had to swing about 75 degrees on a
## 160-unit block, and the driven bot came down 20 units wide of the second block
## every time; at 160 apart on 192-unit blocks it reached block 4. Only once the inner
## edges met the line did a runner that aims at the next block get to the end.
const WEAVE_SECTIONS: Array = [
	{"kind": "weave", "blocks": 6, "rise": 0.0, "offset": 64.0,
		"first_gap": 96.0, "last_gap": 128.0, "first_width": 128.0, "last_width": 128.0},
	{"kind": "climb", "blocks": 4, "rise": 24.0, "offset": 64.0,
		"first_gap": 96.0, "last_gap": 104.0, "first_width": 128.0, "last_width": 112.0},
	{"kind": "descent", "blocks": 4, "rise": -48.0, "offset": 56.0,
		"first_gap": 128.0, "last_gap": 160.0, "first_width": 112.0, "last_width": 96.0},
]

## Bonus 4, `the bend`: the start pad's centre line, east of the weave and clear of it.
const BEND_X := 12288.0

## The radius of the bend's arc, from its centre to each block's middle, in units.
const BEND_RADIUS := 640.0

## A bend block's length along the arc and its width across it, as the main route's.
const BEND_BLOCK_LENGTH := 160.0

## The bend's three sections, every block one step further round a left-hand arc.
##
## [b]The question is the turn, on every jump.[/b] The hairpin turns twice, at two
## corners, with straight runs between; the weave zigzags round a straight line. Here
## there is no straight: each block is `step` degrees further round a 640-unit arc than
## the last, so every take-off is aimed somewhere the last landing was not facing, and
## 277 degrees later the finish faces across the way the run started. Four level, three
## climbing 24, three dropping 48 onto narrowing blocks, then a 48 drop onto the finish.
##
## [b]The drops are spaced wider, and that was measured.[/b] With every block 22.5
## degrees on (centres 250 apart, 85-unit gaps), a jump down 48 at the speed the climb
## leaves a runner with carried about 230 units and landed on the last 10-20 units of a
## 160-unit block, and the next take-off, from its very edge and turned 22.5 degrees, went
## off the side of the last block. At 30 degrees the drop's gap is the length its longer
## flight wants. Every gap is a RUN gap inside `G2GReach` (`headless_run`'s reach sweep).
const BEND_SECTIONS: Array = [
	{"kind": "bend", "blocks": 4, "rise": 0.0, "step": 22.5,
		"first_width": 160.0, "last_width": 160.0},
	{"kind": "climb", "blocks": 3, "rise": 24.0, "step": 22.5,
		"first_width": 160.0, "last_width": 144.0},
	{"kind": "descent", "blocks": 3, "rise": -48.0, "step": 30.0,
		"first_width": 144.0, "last_width": 112.0},
]

## The gap from the start pad's far edge to the first block, along the arc.
const BEND_FIRST_GAP := 96.0

## A weave block's length along the run: longer than the main route's 160, because the
## turn onto the next diagonal is made on it.
const WEAVE_BLOCK_LENGTH := 192.0

## The ridge's start pad: its centre is at START_Z, like the main route's.
const RIDGE_PAD_LENGTH := 512.0

## Where a player stands to start, behind the start line.
const START_Z := 512.0

## How many stages, and how many blocks each one is.
##
## Read by the geometry, by the zones and by the suite. One list, because two lists is
## the bug the one list exists to prevent — and this repository's own tooling has been
## the third copy of a list twice.
const STAGES: Array = [
	{"kind": "straight", "blocks": 8, "first_gap": 96.0, "last_gap": 224.0},
	{"kind": "turn", "blocks": 8, "first_gap": 128.0, "last_gap": 208.0},
	{"kind": "climb", "blocks": 7, "first_gap": 128.0, "last_gap": 192.0},
	{"kind": "drop", "blocks": 7, "first_gap": 160.0, "last_gap": 288.0},
	{"kind": "zigzag", "blocks": 9, "first_gap": 128.0, "last_gap": 240.0},
]


## Every block of the ridge in order: `near` and `far` are the Z of its two edges
## (near > far, the route runs toward -Z), `y` its top, `stage_line` whether a stage
## split is drawn across it and `stage` which number that split is.
##
## [b]Static, and the only place the ridge's arithmetic is done[/b] — the geometry, the
## zones and the suite's bot all read it, so a gap changed here moves the block, the
## split on it and the bot's jump together.
static func ridge_blocks() -> Array:
	var out: Array = []
	var near := START_Z - RIDGE_PAD_LENGTH * 0.5
	var y := FLOOR_Y

	for section_index in range(RIDGE_SECTIONS.size()):
		var section: Dictionary = RIDGE_SECTIONS[section_index]
		var blocks := int(section["blocks"])

		for i in range(blocks):
			var t := float(i) / float(maxi(blocks - 1, 1))
			near -= lerpf(float(section["first_gap"]), float(section["last_gap"]), t)
			y += float(section["rise"])

			out.append({
				"near": near,
				"far": near - BLOCK_LENGTH,
				"y": y,
				"width": lerpf(float(section["first_width"]), float(section["last_width"]), t),
				"stage_line": section_index > 0 and i == 0,
				"stage": section_index,
			})
			near -= BLOCK_LENGTH

	return out


## The centre of the ridge's finish pad (top face): 384 units long, one more
## descent step below the last block and a 160-unit gap past it.
static func ridge_pad() -> Vector3:
	var blocks := ridge_blocks()
	var last: Dictionary = blocks[blocks.size() - 1]
	return Vector3(RIDGE_X, float(last["y"]) - 48.0, float(last["far"]) - 160.0 - 192.0)


## Every block of the weave in order: `centre` (its top face's middle), `extent` (X, Z),
## `stage_line` and `stage`, as [method ridge_blocks]. Static and the only place the
## weave's arithmetic is done: the geometry, the zones and the suite's bot read it.
static func weave_blocks() -> Array:
	var out: Array = []
	var near := START_Z - RIDGE_PAD_LENGTH * 0.5
	var y := FLOOR_Y
	var side := 1.0

	for section_index in range(WEAVE_SECTIONS.size()):
		var section: Dictionary = WEAVE_SECTIONS[section_index]
		var blocks := int(section["blocks"])

		for i in range(blocks):
			var t := float(i) / float(maxi(blocks - 1, 1))
			near -= lerpf(float(section["first_gap"]), float(section["last_gap"]), t)
			y += float(section["rise"])
			var width := lerpf(float(section["first_width"]), float(section["last_width"]), t)
			out.append({
				"centre": Vector3(WEAVE_X + side * float(section["offset"]), y,
					near - WEAVE_BLOCK_LENGTH * 0.5),
				"extent": Vector2(width, WEAVE_BLOCK_LENGTH),
				"stage_line": section_index > 0 and i == 0,
				"stage": section_index,
			})
			near -= WEAVE_BLOCK_LENGTH
			side = -side

	return out


## The middle of the weave's finish pad's top face: on the line, one more descent step
## below the last block and a 160-unit gap past it, 384 long.
static func weave_pad() -> Vector3:
	var blocks := weave_blocks()
	var last: Dictionary = blocks[blocks.size() - 1]
	var centre: Vector3 = last["centre"]
	return Vector3(WEAVE_X, centre.y - 48.0, centre.z - WEAVE_BLOCK_LENGTH * 0.5 - 160.0 - 192.0)


## The point [param degrees] round the bend's arc and the heading there (yaw 0 is -Z, as
## the spawn zones use; positive turns toward -X). Degree 0 is the start pad's far edge.
static func bend_at(degrees: float) -> Dictionary:
	var centre := Vector2(BEND_X - BEND_RADIUS, START_Z - RIDGE_PAD_LENGTH * 0.5)
	var phi := deg_to_rad(degrees)
	return {
		"x": centre.x + BEND_RADIUS * cos(phi),
		"z": centre.y - BEND_RADIUS * sin(phi),
		"yaw": degrees,
	}


## Every block of the bend in order: `centre` (its top face's middle), `yaw`, `width`,
## `stage_line` and `stage`. Static and the only place the bend's arithmetic is done:
## the geometry, the zones and the suite's bot all read it.
static func bend_blocks() -> Array:
	var out: Array = []
	var degrees := rad_to_deg((BEND_FIRST_GAP + BEND_BLOCK_LENGTH * 0.5) / BEND_RADIUS)
	var y := FLOOR_Y

	for section_index in range(BEND_SECTIONS.size()):
		var section: Dictionary = BEND_SECTIONS[section_index]
		var blocks := int(section["blocks"])

		for i in range(blocks):
			var t := float(i) / float(maxi(blocks - 1, 1))
			if not out.is_empty():
				degrees += float(section["step"])
			y += float(section["rise"])
			var at := bend_at(degrees)
			out.append({
				"centre": Vector3(float(at["x"]), y, float(at["z"])),
				"yaw": degrees,
				"width": lerpf(float(section["first_width"]), float(section["last_width"]), t),
				"stage_line": section_index > 0 and i == 0,
				"stage": section_index,
			})

	return out


## The bend's finish pad: `centre` (its top face's middle) and `yaw`, one more 48 drop
## below the last block, a 128-unit gap further round the arc, 384 long.
static func bend_pad() -> Dictionary:
	var blocks := bend_blocks()
	var last: Dictionary = blocks[blocks.size() - 1]
	var degrees := float(last["yaw"]) + rad_to_deg((BEND_BLOCK_LENGTH * 0.5 + 128.0 + 192.0) / BEND_RADIUS)
	var at := bend_at(degrees)
	return {
		"centre": Vector3(float(at["x"]), (last["centre"] as Vector3).y - 48.0, float(at["z"])),
		"yaw": degrees,
	}


## Every block on the main course, in order, as plain dictionaries.
##
## [b]Static, and the single source of truth for both the geometry and the zones.[/b]
## `_build` places a mesh at each entry and `build_zones` draws a stage line across the
## last block of each stage — both from this. A map that computed the two separately is
## a map whose stage lines drift off their blocks the first time somebody changes a gap,
## and nothing anywhere reports it: the run still finishes, the splits are just taken
## somewhere else.
static func _course() -> Array:
	var out: Array = []

	# The cursor: where the next block goes, and which way the course is heading.
	# Heading is a yaw in degrees, 0 being -Z, which is the direction the start pad
	# faces.
	var x := 0.0
	var y := FLOOR_Y
	var z := START_Z - 320.0
	var yaw := 0.0

	for stage_index in range(STAGES.size()):
		var stage: Dictionary = STAGES[stage_index]
		var blocks := int(stage["blocks"])
		var kind := String(stage["kind"])

		for i in range(blocks):
			var t := float(i) / float(maxi(blocks - 1, 1))
			var gap := lerpf(float(stage["first_gap"]), float(stage["last_gap"]), t)
			var width := BLOCK_WIDTH
			var offset := 0.0

			match kind:
				"turn":
					# 90 degrees over the stage. Spread across every block rather than
					# taken in one, because a bhop turn is made by strafing THROUGH it:
					# a single right angle is a wall a player hits at 300 u/s.
					yaw = lerpf(0.0, 90.0, t)
				"climb":
					y += CLIMB_STEP
				"drop":
					y -= DROP_STEP
					width = NARROW_WIDTH
				"zigzag":
					offset = ZIGZAG_OFFSET * (1.0 if i % 2 == 0 else -1.0)
				_:
					pass

			# Step the cursor along the heading, then place the block. The sideways
			# offset is applied across the heading, so a zigzag on a turned section
			# still zigzags across the course rather than across the world.
			var forward := Vector3(
				-sin(deg_to_rad(yaw)), 0.0, -cos(deg_to_rad(yaw))
			)
			var across := Vector3(
				cos(deg_to_rad(yaw)), 0.0, -sin(deg_to_rad(yaw))
			)

			var step := BLOCK_LENGTH + gap if i > 0 else BLOCK_LENGTH
			x += forward.x * step
			z += forward.z * step

			var at := Vector3(x, y, z) + across * offset

			out.append({
				"stage": stage_index + 1,
				"kind": kind,
				"x": at.x,
				"y": at.y,
				"z": at.z,
				"yaw": yaw,
				"width": width,
				"stage_end": i == blocks - 1,
			})

	return out


## The last block of stage [param number], counted from 1.
static func stage_block(number: int) -> Dictionary:
	var course := _course()

	for block: Dictionary in course:
		if int(block["stage"]) == number and bool(block["stage_end"]):
			return block

	return {}


## The centre of the finish pad, which sits 384 units past the last block along its
## own heading.
static func _pad_centre(last: Dictionary) -> Vector3:
	var yaw := float(last["yaw"])
	var forward := Vector3(-sin(deg_to_rad(yaw)), 0.0, -cos(deg_to_rad(yaw)))

	return Vector3(
		float(last["x"]), float(last["y"]), float(last["z"])
	) + forward * 384.0
