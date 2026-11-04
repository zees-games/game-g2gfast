extends "bhop_g2g_stages_shapes.gd"
func _build() -> void:
	tier = 4
	G2GGeometry.sun(self)

	var course := _course()

	fallback_spawn_units = Vector3(0.0, FLOOR_Y + 8.0, START_Z - 96.0)

	# The start pad. Long, because this genre's runs begin with a prestrafe: a player
	# holding jump from a standstill creeps at the air cap for ever, so the pad has to
	# be long enough to walk up to speed on before crossing the line.
	var bodies: Array = [G2GGeometry.box(
		self, Vector3(0.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z),
		Vector3(BLOCK_WIDTH + 128.0, BLOCK_THICKNESS, 640.0),
		G2GGeometry.ROLE_START
	)]

	for block: Dictionary in course:
		bodies.append(G2GGeometry.box(
			self,
			Vector3(
				float(block["x"]),
				float(block["y"]) - BLOCK_THICKNESS * 0.5,
				float(block["z"])
			),
			Vector3(float(block["width"]), BLOCK_THICKNESS, BLOCK_LENGTH),
			# The last block of each stage is drawn in the finish colour, so a player
			# can SEE where the split is rather than only being told after crossing it.
			# A stage line the player cannot see is a split they cannot aim at.
			G2GGeometry.ROLE_END if bool(block["stage_end"]) else G2GGeometry.ROLE_PLATFORM,
			Basis(Vector3.UP, deg_to_rad(float(block["yaw"])))
		))

	var last: Dictionary = course[course.size() - 1]

	# The finish pad, from `_pad_centre` and not from an offset written out again here.
	#
	# [b]It was `last.z - 384`, and the course does not end heading -Z.[/b] The turn in
	# stage 2 leaves the cursor at yaw 90 and every stage after it inherits that, so the
	# last block heads -X — and a pad offset along world -Z landed 543 units off the
	# finish zone, which is drawn 384 units along the HEADING. The two boxes overlapped
	# by a 128 x 24 corner nothing lands on: the player ran onto a pad drawn in the
	# finish colour, stopped, and the timer went on counting for ever. Nothing errored,
	# because a run that has not finished is a legitimate thing for a run to be.
	#
	# One function now answers "where is the finish", and the geometry and the zone both
	# call it. That is this map's own rule -- `_course()` is the single source for the
	# blocks -- applied to the one place that was still doing the arithmetic twice.
	var end_at := _pad_centre(last)

	bodies.append(G2GGeometry.box(
		self,
		Vector3(end_at.x, end_at.y - BLOCK_THICKNESS * 0.5, end_at.z),
		Vector3(BLOCK_WIDTH + 128.0, BLOCK_THICKNESS, 512.0),
		G2GGeometry.ROLE_END,
		Basis(Vector3.UP, deg_to_rad(float(last["yaw"])))
	))

	# [b]One CHAIN, start pad to finish pad.[/b] Every stage's idea is a way of keeping
	# speed — "keep the speed", "strafe through it", "height costs speed" — and the
	# widest gaps in stages 1, 3 and 4 are past what a standing jump crosses, so the line
	# is sized for hops carried at course speed. `headless_run` also runs the chain from
	# every `!s<n>` destination, because a stage a player restarts from a standstill is
	# a chain that begins at run speed rather than at whatever the stages before it
	# built. The surf bonus declares nothing: it is a drop onto a bank, not a jump.
	add_course("main", DotTimerTrack.MAIN, G2GReach.Kind.CHAIN, bodies)

	_build_bonus()
	_build_ridge()
	_build_weave()
	_build_bend()


## Bonus 2, `the ridge`. See [constant RIDGE_SECTIONS].
func _build_ridge() -> void:
	var bodies: Array = [G2GGeometry.box(
		self, Vector3(RIDGE_X, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z),
		Vector3(256.0, BLOCK_THICKNESS, RIDGE_PAD_LENGTH), G2GGeometry.ROLE_START
	)]

	for block: Dictionary in ridge_blocks():
		bodies.append(G2GGeometry.box(
			self,
			Vector3(RIDGE_X, float(block["y"]) - BLOCK_THICKNESS * 0.5,
				float(block["near"]) - BLOCK_LENGTH * 0.5),
			Vector3(float(block["width"]), BLOCK_THICKNESS, BLOCK_LENGTH),
			# The first block of each section after the first carries a stage line and is
			# drawn in the finish colour, as the main route's are: a split a player can see.
			G2GGeometry.ROLE_END if bool(block["stage_line"]) else G2GGeometry.ROLE_BONUS
		))

	var pad := ridge_pad()
	bodies.append(G2GGeometry.box(
		self, Vector3(RIDGE_X, pad.y - BLOCK_THICKNESS * 0.5, pad.z),
		Vector3(256.0, BLOCK_THICKNESS, 384.0), G2GGeometry.ROLE_END
	))

	# RUN: every gap is a jump from the lip at run speed, which is what the route
	# promises and what `headless_run` drives a bot along to prove it.
	add_course("the ridge", DotTimerTrack.of_bonus(2), G2GReach.Kind.RUN, bodies)


## Bonus 3, `the weave`. See [constant WEAVE_SECTIONS].
func _build_weave() -> void:
	var bodies: Array = [G2GGeometry.box(
		self, Vector3(WEAVE_X, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z),
		Vector3(256.0, BLOCK_THICKNESS, RIDGE_PAD_LENGTH), G2GGeometry.ROLE_START
	)]

	for block: Dictionary in weave_blocks():
		var centre: Vector3 = block["centre"]
		var extent: Vector2 = block["extent"]
		bodies.append(G2GGeometry.box(
			self, Vector3(centre.x, centre.y - BLOCK_THICKNESS * 0.5, centre.z),
			Vector3(extent.x, BLOCK_THICKNESS, extent.y),
			G2GGeometry.ROLE_END if bool(block["stage_line"]) else G2GGeometry.ROLE_BONUS
		))

	var pad := weave_pad()
	bodies.append(G2GGeometry.box(
		self, Vector3(pad.x, pad.y - BLOCK_THICKNESS * 0.5, pad.z),
		Vector3(256.0, BLOCK_THICKNESS, 384.0), G2GGeometry.ROLE_END
	))

	add_course("the weave", DotTimerTrack.of_bonus(3), G2GReach.Kind.RUN, bodies)


## Bonus 4, `the bend`. See [constant BEND_SECTIONS].
func _build_bend() -> void:
	var bodies: Array = [G2GGeometry.box(
		self, Vector3(BEND_X, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z),
		Vector3(256.0, BLOCK_THICKNESS, RIDGE_PAD_LENGTH), G2GGeometry.ROLE_START
	)]

	for block: Dictionary in bend_blocks():
		var centre: Vector3 = block["centre"]
		bodies.append(G2GGeometry.box(
			self, Vector3(centre.x, centre.y - BLOCK_THICKNESS * 0.5, centre.z),
			Vector3(float(block["width"]), BLOCK_THICKNESS, BEND_BLOCK_LENGTH),
			G2GGeometry.ROLE_END if bool(block["stage_line"]) else G2GGeometry.ROLE_BONUS,
			Basis(Vector3.UP, deg_to_rad(float(block["yaw"])))
		))

	var pad := bend_pad()
	bodies.append(G2GGeometry.box(
		self, Vector3(pad["centre"].x, pad["centre"].y - BLOCK_THICKNESS * 0.5, pad["centre"].z),
		Vector3(256.0, BLOCK_THICKNESS, 384.0), G2GGeometry.ROLE_END,
		Basis(Vector3.UP, deg_to_rad(float(pad["yaw"])))
	))

	add_course("the bend", DotTimerTrack.of_bonus(4), G2GReach.Kind.RUN, bodies)


## The bonus: a two-ramp surf descent onto a pad.
##
## [b]Surf on a bhop map, deliberately.[/b] A bonus track is a whole second route with
## its own records, and making it the same thing as the main route wastes it. It is
## also the cheapest proof that a track is a route and not a game mode: one map, one
## timer, one records table, and the two tracks are played completely differently.
func _build_bonus() -> void:
	# Far enough out that it is not in the main route's view.
	#
	# It was at 2048 and the screenshot is why it is not: a 1536-unit-tall surf ramp
	# that close fills a third of the screen from the start pad, so the first thing a
	# player on the MAIN track sees is the bonus. A bonus is a thing you go and find.
	var x := BONUS_X

	G2GGeometry.box(
		self, Vector3(x, FLOOR_Y + 1024.0 - BLOCK_THICKNESS * 0.5, START_Z),
		Vector3(512.0, BLOCK_THICKNESS, 512.0), G2GGeometry.ROLE_BONUS
	)

	# Two ramps facing each other, which is what a surf section is: a player rides the
	# face of one, crosses, and rides the other.
	for i in range(2):
		var side := 1.0 if i == 0 else -1.0
		G2GGeometry.ramp(
			self,
			Vector3(x + side * 384.0, FLOOR_Y + 320.0, START_Z - 1536.0),
			Vector3(64.0, 1536.0, 2560.0),
			# The box turns by this and its broad face then stands at 90 minus it: a pitch of 50
			# is a 40-degree turn (45 was both, which is how it came to be standable).
			side * (90.0 - BONUS_RAMP_PITCH),
			Vector3.FORWARD,
			G2GGeometry.ROLE_RAMP
		)

	G2GGeometry.box(
		self, Vector3(x, FLOOR_Y - 384.0 - BLOCK_THICKNESS * 0.5, START_Z - 3072.0),
		Vector3(768.0, BLOCK_THICKNESS, 768.0), G2GGeometry.ROLE_END
	)


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"bhop_g2g_stages"
	zones.meta["tier"] = 4
	zones.meta["author"] = "g2gfast"

	var main := DotTimerTrack.MAIN
	var course := _course()
	var last: Dictionary = course[course.size() - 1]

	zones.add(zone_box(DotTimerZone.Kind.START, main,
		Vector3(-192.0, FLOOR_Y, START_Z - 320.0),
		Vector3(192.0, FLOOR_Y + 192.0, START_Z + 320.0)))

	# The finish, on the pad past the last block. Axis-aligned even though the course
	# ends turned: a zone is an AABB, so a box drawn around a rotated pad is bigger than
	# the pad. That is correct here — a player can only arrive at it along the course —
	# and it is why the box is drawn from the pad's centre rather than its corners.
	var end_at := _pad_centre(last)
	zones.add(zone_box(DotTimerZone.Kind.END, main,
		end_at - Vector3(256.0, 0.0, 256.0),
		end_at + Vector3(256.0, 192.0, 256.0)))

	# One stage line per stage boundary, on the block the geometry drew in the finish
	# colour. There are STAGES.size() - 1 of them: the last stage ends at the FINISH,
	# not at a stage line, and a stage zone drawn on top of the finish would split the
	# run at the same instant it ended.
	for number in range(1, STAGES.size()):
		var block := stage_block(number)

		if block.is_empty():
			continue

		var at := Vector3(
			float(block["x"]), float(block["y"]), float(block["z"])
		)

		zones.add(zone_stage(
			main, number,
			at - Vector3(224.0, 0.0, 224.0),
			at + Vector3(224.0, 192.0, 224.0),
			at + Vector3(0.0, 16.0, 0.0),
			# The block's own heading, which is the way the course leaves it. It was
			# heading + 180, which faced a restarted player back up the course
			# (`[stage-yaw-1]`). A `!s` stops the run, so no record moves.
			float(block["yaw"])
		))

	# The pit. Everything below the course, which on a map that climbs and drops has to
	# be measured from the LOWEST block rather than from the floor — the drop section
	# ends below where it started, and a pit at y = 0 would be a ceiling under it.
	var lowest := FLOOR_Y

	for block: Dictionary in course:
		lowest = minf(lowest, float(block["y"]))

	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, main,
		Vector3(-16384.0, lowest - 4096.0, -16384.0),
		Vector3(16384.0, lowest - 256.0, 16384.0)))

	zones.add(zone_spawn(main, Vector3(0.0, FLOOR_Y + 8.0, START_Z + 128.0), 0.0))

	# The bonus: the surf descent.
	var bonus := DotTimerTrack.of_bonus(1)

	zones.add(zone_box(DotTimerZone.Kind.START, bonus,
		Vector3(BONUS_X - 256.0, FLOOR_Y + 1024.0, START_Z - 256.0),
		Vector3(BONUS_X + 256.0, FLOOR_Y + 1216.0, START_Z + 256.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, bonus,
		Vector3(BONUS_X - 384.0, FLOOR_Y - 384.0, START_Z - 3456.0),
		Vector3(BONUS_X + 384.0, FLOOR_Y - 128.0, START_Z - 2688.0)))
	zones.add(zone_spawn(
		bonus, Vector3(BONUS_X, FLOOR_Y + 1032.0, START_Z + 128.0), 0.0
	))

	# The bonus's own pit. A RESPAWN carries a track, and the main route's catches
	# nobody on this one: until `[track-zone-1]` asked every route on every map, a
	# player who came off either ramp fell for ever. Under the lowest thing on the
	# whole map -- the bonus's finish pad sits below the main course -- so neither
	# route's geometry is ever inside it.
	var bonus_floor := minf(lowest, FLOOR_Y - 384.0 - BLOCK_THICKNESS)
	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, bonus,
		Vector3(-16384.0, bonus_floor - 4096.0, -16384.0),
		Vector3(16384.0, bonus_floor - 256.0, 16384.0)))

	# Bonus 2, the ridge: a start, two stage splits, a finish, a spawn and a pit.
	var ridge := DotTimerTrack.of_bonus(2)
	var pad := ridge_pad()

	zones.add(zone_box(DotTimerZone.Kind.START, ridge,
		Vector3(RIDGE_X - 128.0, FLOOR_Y, START_Z - RIDGE_PAD_LENGTH * 0.5),
		Vector3(RIDGE_X + 128.0, FLOOR_Y + 192.0, START_Z + RIDGE_PAD_LENGTH * 0.5)))
	# The pad's last 320 units: it begins 64 in from the pad's near edge, so a player
	# has landed rather than grazed the lip when the clock stops.
	zones.add(zone_box(DotTimerZone.Kind.END, ridge,
		Vector3(RIDGE_X - 128.0, pad.y, pad.z - 192.0),
		Vector3(RIDGE_X + 128.0, pad.y + 192.0, pad.z + 128.0)))

	for block: Dictionary in ridge_blocks():
		if not bool(block["stage_line"]):
			continue
		var half := float(block["width"]) * 0.5
		zones.add(zone_stage(
			ridge, int(block["stage"]),
			Vector3(RIDGE_X - half, float(block["y"]), float(block["far"])),
			Vector3(RIDGE_X + half, float(block["y"]) + 192.0, float(block["near"])),
			Vector3(RIDGE_X, float(block["y"]) + 16.0, float(block["near"]) - BLOCK_LENGTH * 0.5),
			# Facing down the route: yaw 0 is -Z here, as the spawn zones use.
			0.0
		))

	zones.add(zone_spawn(ridge, Vector3(RIDGE_X, FLOOR_Y + 8.0, START_Z + 128.0), 0.0))
	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, ridge,
		Vector3(-16384.0, bonus_floor - 4096.0, -16384.0),
		Vector3(16384.0, pad.y - BLOCK_THICKNESS - 256.0, 16384.0)))

	# Bonus 3, the weave: the ridge's shape of zone set, read off `weave_blocks`.
	var weave := DotTimerTrack.of_bonus(3)
	var weave_end := weave_pad()

	zones.add(zone_box(DotTimerZone.Kind.START, weave,
		Vector3(WEAVE_X - 128.0, FLOOR_Y, START_Z - RIDGE_PAD_LENGTH * 0.5),
		Vector3(WEAVE_X + 128.0, FLOOR_Y + 192.0, START_Z + RIDGE_PAD_LENGTH * 0.5)))
	zones.add(zone_box(DotTimerZone.Kind.END, weave,
		Vector3(WEAVE_X - 128.0, weave_end.y, weave_end.z - 192.0),
		Vector3(WEAVE_X + 128.0, weave_end.y + 192.0, weave_end.z + 128.0)))

	for block: Dictionary in weave_blocks():
		if not bool(block["stage_line"]):
			continue
		var centre: Vector3 = block["centre"]
		var half: Vector2 = (block["extent"] as Vector2) * 0.5
		zones.add(zone_stage(
			weave, int(block["stage"]),
			Vector3(centre.x - half.x, centre.y, centre.z - half.y),
			Vector3(centre.x + half.x, centre.y + 192.0, centre.z + half.y),
			centre + Vector3(0.0, 16.0, 0.0),
			0.0
		))

	zones.add(zone_spawn(weave, Vector3(WEAVE_X, FLOOR_Y + 8.0, START_Z + 128.0), 0.0))
	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, weave,
		Vector3(-16384.0, bonus_floor - 4096.0, -16384.0),
		Vector3(16384.0, weave_end.y - BLOCK_THICKNESS - 256.0, 16384.0)))

	# Bonus 4, the bend: the weave's shape of zone set, read off `bend_blocks`. Its blocks
	# are turned, and a zone is a box, so each stage line and the finish are boxes inside
	# the block's footprint (the largest square any yaw keeps inside it), not around it.
	var bend := DotTimerTrack.of_bonus(4)
	var bend_end := bend_pad()
	var end_centre: Vector3 = bend_end["centre"]

	zones.add(zone_box(DotTimerZone.Kind.START, bend,
		Vector3(BEND_X - 128.0, FLOOR_Y, START_Z - RIDGE_PAD_LENGTH * 0.5),
		Vector3(BEND_X + 128.0, FLOOR_Y + 192.0, START_Z + RIDGE_PAD_LENGTH * 0.5)))
	zones.add(zone_box(DotTimerZone.Kind.END, bend,
		Vector3(end_centre.x - 88.0, end_centre.y, end_centre.z - 88.0),
		Vector3(end_centre.x + 88.0, end_centre.y + 192.0, end_centre.z + 88.0)))

	for block: Dictionary in bend_blocks():
		if not bool(block["stage_line"]):
			continue
		var centre: Vector3 = block["centre"]
		var half := float(block["width"]) * 0.5 / sqrt(2.0)
		zones.add(zone_stage(
			bend, int(block["stage"]),
			Vector3(centre.x - half, centre.y, centre.z - half),
			Vector3(centre.x + half, centre.y + 192.0, centre.z + half),
			centre + Vector3(0.0, 16.0, 0.0),
			# Facing on round the arc, the way the route leaves the block.
			float(block["yaw"])
		))

	zones.add(zone_spawn(bend, Vector3(BEND_X, FLOOR_Y + 8.0, START_Z + 128.0), 0.0))
	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, bend,
		Vector3(-16384.0, bonus_floor - 4096.0, -16384.0),
		Vector3(16384.0, end_centre.y - BLOCK_THICKNESS - 256.0, 16384.0)))

	return zones
