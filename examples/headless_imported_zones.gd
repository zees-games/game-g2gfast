extends "headless_imported_base.gd"

## The zone, spawn and pit sections of headless_imported.



func _test_zones() -> void:
	_section("zones")
	var zones := game.timers.zones
	_check(zones != null, "the map produced a zone set")
	if zones == null:
		return
	_check(zones.problems().is_empty(), "which is well formed", ", ".join(zones.problems()))
	var respawns := zones.of_kind(DotTimerZone.Kind.RESPAWN).size()
	# A surf map's trigger_teleport volumes are its pit. Losing them means a player
	# who falls off falls for ever, which is the bug dot-timer's effect_requested was.
	if NO_PIT.has(_map_id):
		_check(respawns == 0, "has no pit, and still has none",
			"listed in NO_PIT; %d respawn zones" % respawns)
	else:
		_check(respawns > 0, "with the pit volumes carried across as RESPAWN zones",
			"%d respawn zones" % respawns)

	# Source sweeps its trigger tests; dot-timer samples a point per tick. A 16-unit plane pit, enough in Source,
	# is stepped clean over by a player falling at genre speed, who then falls for ever.
	var thin := zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate)
	_check(thin.is_empty(), "and no zone a 3500 u/s player passes through between ticks",
		"%d thin" % thin.size())

	# The two zones without which a map is scenery. Every one of these maps had them
	# in its entity lump or in maps/zones/ before it was offered as a level; a map
	# that reaches here without them is one the importer stopped reading.
	var tracks := zones.playable_tracks()

	if NOT_COURSES.has(_map_id):
		# Asserted the other way round. See [constant NOT_COURSES]: if this map has grown a
		# finish, the list is out of date and that is worth a failure, because the next
		# person to read it would believe it.
		_check(not tracks.has(DotTimerTrack.MAIN),
			"is not a course, and still is not",
			"listed in NOT_COURSES; runnable tracks: %s" % str(tracks))
	else:
		_check(tracks.has(DotTimerTrack.MAIN),
			"the main track has both a start line and a finish",
			"runnable tracks: %s" % str(tracks))

	# A track a player cannot be put on is a track nobody plays: `spawn_for` falls back to the main track's spawn,
	# so a bonus with no spawn silently starts at the map's start and looks like a bonus that does not work.
	var without := PackedStringArray()
	for track in tracks:
		if zones.first_of_kind(DotTimerZone.Kind.SPAWN, track) == null:
			without.append(DotTimerTrack.name_of(track))
	_check(without.is_empty(), "and every runnable track has somewhere to spawn",
		", ".join(without))

	# `[track-zone-1]`: every route, per track — a start, a finish, a spawn and a pit of
	# its own. See [constant BONUSES_WITHOUT_PITS] for the ones known not to have one.
	var expected := PackedStringArray()
	for track: int in BONUSES_WITHOUT_PITS.get(String(_map_id), []):
		expected.append("%s has no respawn zone" % DotTimerTrack.name_of(track))
	var reported := PackedStringArray()
	for problem in zones.route_problems():
		var cut := problem.find(",")
		reported.append(problem.substr(0, cut) if cut > 0 else problem)
	_check(reported == expected,
		"every route has a start, a finish, a spawn and a pit" if expected.is_empty()
			else "its bonuses without a pit are the ones listed, and only those",
		"reported %s, listed %s" % [reported, expected])
	_done()


func _test_runnable() -> void:
	_section("runnable")
	var zones := game.timers.zones
	if zones == null:
		_check(false, "a run can be started, split and finished")
		_check(false, "and its stages come out in order")
		return

	# Drive the timer over the map's own zones and see a time come out: the only check about the zones adding up to a run.
	# A start with no reachable finish, a stage past the end, a finish inside the start all pass `problems()`.
	var timer := DotTimer.new()
	timer.bind(zones, game.tick_rate)
	var finished: Array[DotTimerRun] = []
	timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))

	var start := zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)

	if NOT_COURSES.has(_map_id):
		# Both checks still run and still count; what changes is what the right answer is.
		# See [constant NOT_COURSES] — a map listed there that grows a finish is a list that
		# has gone stale, and the failure is how anybody finds out.
		_check(start == null or finish == null,
			"has no run to time, as documented",
			"listed in NOT_COURSES")
		_check(true, "and no stages to order")
		_done()
		return

	if start == null or finish == null:
		_check(false, "a run can be started, split and finished", "no start or no end")
		_check(false, "and its stages come out in order")
		return

	# A tick outside every zone, between the start and everything after it. The run begins on the tick the player LEAVES
	# the start line, after that tick's zone handling, so stepping straight into the first stage arrives while the run is
	# IDLE and the split is dropped. An artifact of stepping a timer by hand rather than walking a map.
	var bounds: Dictionary = (game.current_map_node() as G2GBspMap).manifest.get("bounds", {})
	var away := G2GUnits.vector_to_metres(Vector3(
		float((bounds.get("max", [0, 0, 0]) as Array)[0]),
		float((bounds.get("max", [0, 0, 0]) as Array)[1]),
		float((bounds.get("max", [0, 0, 0]) as Array)[2]))) + Vector3(0.0, 128.0, 0.0)

	# From stage 2, because stage 1 IS the start line on every map that numbers its
	# own stages -- and stepping back into the start zone mid-route makes the timer do
	# what it should: treat leaving it again as a new attempt, wiping the splits.
	var route: Array[Vector3] = [start.centre(), start.centre(), away]
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		var stage := zones.stage_zone(DotTimerTrack.MAIN, n)
		if stage != null:
			route.append(stage.centre())
	route.append(finish.centre())

	var sample := DotTimerSample.new()
	for point in route:
		sample.previous_position = sample.position
		sample.position = point
		sample.grounded = true
		timer.tick(sample)

	_check(finished.size() == 1, "a run can be started, split and finished",
		"%d finishes" % finished.size())
	if finished.is_empty():
		_check(false, "and its stages come out in order")
		return

	# Stage 1 is the start line, and a run begins by LEAVING it -- so its split is the
	# one that legitimately never arrives. Every stage after it must.
	var wanted := maxi(0, zones.stage_count(DotTimerTrack.MAIN) - 1)

	var got := 0
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		if finished[0].splits.has(n):
			got += 1
	_check(got == wanted, "and its stages come out in order",
		"%d of %d splits" % [got, wanted])
	_done()


func _test_stands_on_it() -> void:
	_section("collision")
	var node := game.current_map_node()
	# Anywhere under the map, not under the MeshInstance3D: the solid is built from the .bsp's brushes and belongs to the map,
	# but a pre-collision manifest falls back to the old `create_trimesh_collision()` shape, so this finds both.
	var body: Node = null
	for c in node.find_children("*", "StaticBody3D", true, false):
		body = c
		break
	_check(body is StaticBody3D, "the world has a static body")
	var shape_count := 0
	if body != null:
		for c in body.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
				shape_count += 1
	_check(shape_count > 0, "with a collision shape on it", "%d shapes" % shape_count)

	# dot-core's collision audit, REPORT ONLY: an imported map's drawing is the .bsp's faces and
	# its solids the brushes, so triggers, clips-as-drawn and sky show up. Count and worst
	# offenders (by kind) are printed; nothing fails on them.
	var audit := DotCollisionAudit.audit(node, true)
	if audit.ok:
		var report: DotCollisionAudit = audit.value
		var kinds := {}
		for f: Dictionary in report.findings:
			kinds[f["kind"]] = int(kinds.get(f["kind"], 0)) + 1
		print("    collision audit: %d without a shape near them of %d examined (%d opted out) %s" % [
			report.count(), report.examined, report.opted_out, str(kinds)])
		for line in report.describe_lines().slice(1, 4):
			print("      %s" % line)

	var bot := game.add_player(&"bot", "Bot", true)
	_check(bot != null, "a player joins")
	if bot == null:
		return
	bot.sampler = null

	var start := node.spawn_for(0)
	await get_tree().physics_frame
	_check(bot.global_position.distance_to(start) < 2.0, "at the map's own spawn",
		"%.1f m away" % bot.global_position.distance_to(start))

	# Let it fall. On a map whose collision never got built this is the only check in
	# the file that fails, and it fails by hundreds of metres rather than marginally.
	var floor_y := start.y
	# Watching for the pits while it falls: a sealed black spawn room whose floor is the teleport out sent the player back to the
	# spawn for ever, and "still standing three seconds later" passed because the spawn is where it was put. A main-track pit
	# touched at any tick is that, or a spawn over a hole. It does not see a pit the feet never enter; the spawn view below is the other half.
	var pits: Array[DotTimerZone] = game.timers.zones.of_kind(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN) \
		if game.timers.zones != null else ([] as Array[DotTimerZone])
	var in_pit := 0
	for _i in range(180):
		await get_tree().physics_frame
		for pit in pits:
			if pit.contains(bot.controller.state.position):
				in_pit += 1
				break
	var drop := floor_y - bot.global_position.y
	_check(drop < 8.0, "and is still standing on the map three seconds later",
		"fell %.1f m" % drop)
	_check(in_pit == 0, "and never touches a pit on the way down",
		"inside a main-track pit on %d of 180 ticks" % in_pit)

	# And where it came to rest is inside the start zone. The timer asks the zone about the player's own position every tick;
	# a start box that stops short of the floor contains the spawn in mid-air and not the player under it (surf_arcade's
	# stood 240 units over the pad), so the run starts as they fall out of it.
	var start_zone := game.timers.zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN) \
		if game.timers.zones != null else null
	if start_zone == null:
		_check(NOT_COURSES.has(_map_id), "and comes to rest inside the start zone",
			"no start zone on the main track")
	elif SPAWNS_IN_A_PUSH.has(String(_map_id)):
		var at := bot.controller.state.position
		_check(not start_zone.contains(at) and at.y > start.y,
			"and is carried up off its spawn by the push it stands in (SPAWNS_IN_A_PUSH)",
			"at %s" % [at / G2GUnits.METRES_PER_UNIT])
	else:
		var at := bot.controller.state.position
		_check(start_zone.contains(at), "and comes to rest inside the start zone",
			"at %s, zone %s..%s" % [at / G2GUnits.METRES_PER_UNIT,
				start_zone.from / G2GUnits.METRES_PER_UNIT, start_zone.to / G2GUnits.METRES_PER_UNIT])

	# And it is not shut in: sixteen rays at waist height from where it came to rest, and one has to run 5 m before it meets
	# anything. 5 and not more because a start room a mapper leaves by a teleport is a closed room too (the smallest here are
	# kz_bhop_badg3s's 6.9 m and bhop_tesquo_v2's 7.4 m). Armed by taking surf_year3000's "remove" out of its zones file.
	var space := bot.get_world_3d().direct_space_state
	var waist := bot.global_position + Vector3.UP * 0.9
	var longest := 0.0
	for k in range(16):
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 16.0)
		var ray := PhysicsRayQueryParameters3D.create(waist, waist + dir * 5.0)
		var hit := space.intersect_ray(ray)
		longest = maxf(longest, 5.0 if hit.is_empty() else waist.distance_to(hit["position"]))
	_check(longest >= 5.0, "and is not shut in where it stands",
		"the longest of 16 rays from the spawn runs %.1f m" % longest)

	var bounds: Dictionary = (node as G2GBspMap).manifest.get("bounds", {})
	var min_y: float = float((bounds.get("min", [0, -16384, 0]) as Array)[1]) * G2GUnits.METRES_PER_UNIT
	_check(bot.global_position.y > min_y, "and has not left the world",
		"y=%.1f, world floor %.1f" % [bot.global_position.y, min_y])
	_done()


## Every place the map can put a player: each track's spawn, and each `!s<n>`.
## A destination is the one field nothing else checks: `DotTimerManager` resolves "go to stage 3" to a zone's
## [member DotTimerZone.destination], and one in the sky, a wall, or at the origin succeeds at every step. Standing on it for a second is the test.
func _test_stands_where_it_sends_you() -> void:
	_section("destinations")
	var node := game.current_map_node()
	var zones := game.timers.zones
	var spots: Array = []
	var splits: Array[int] = []
	if zones != null:
		for track in zones.playable_tracks():
			var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
			if spawn != null:
				spots.append([DotTimerTrack.short_name_of(track) + " spawn", spawn.destination, spawn.destination_yaw])
			for n in range(1, zones.stage_count(track) + 1):
				var stage := zones.stage_zone(track, n)
				if stage == null:
					continue
				if stage.payload.has(G2GBspMap.NO_RESTART):
					# A split with no restart has no spot; what is asserted is that
					# nobody is sent to it. Main track only: that is the bot's.
					if track == DotTimerTrack.MAIN:
						splits.append(n)
					continue
				spots.append(["stage %d" % n, stage.destination, stage.destination_yaw])
	_expected += spots.size() + splits.size() * 2

	# A stage faces a player the way the map's own door into it does. Built `around` a destination, a stage faced yaw 0,
	# so on surf_kitsune every `!s<n>` faced a wall side-on while the door faced down it. Where a door (a TELEPORT on the
	# track) lands inside a stage's volume, the stage must agree with one within ten degrees. Armed by re-importing without `around_yaw`.
	var facings := 0
	var disagree: Array[String] = []
	if zones != null:
		for track in zones.playable_tracks():
			for n in range(1, zones.stage_count(track) + 1):
				var stage := zones.stage_zone(track, n)
				if stage == null or stage.payload.has(G2GBspMap.NO_RESTART):
					continue
				# Agreeing with ONE door is enough: a map built for two teams mirrors its
				# arrivals (surf_year3000's start room takes both teams' booths, facing
				# opposite ways), and a stage can face only one of them.
				var door_yaws: Array[float] = []
				for door: DotTimerZone in zones.of_kind(DotTimerZone.Kind.TELEPORT, track):
					if stage.contains(door.destination + Vector3.UP * 0.1):
						door_yaws.append(door.destination_yaw)
				if door_yaws.is_empty():
					continue
				facings += 1
				var agrees := false
				for y in door_yaws:
					agrees = agrees or absf(wrapf(stage.destination_yaw - y, -180.0, 180.0)) <= 10.0
				if not agrees:
					disagree.append("stage %d %.0f vs doors %s" % [n, stage.destination_yaw, door_yaws])
	_check(disagree.is_empty(),
		"every stage faces a player the way the map's own door into it does (%d compared)" % facings,
		", ".join(disagree))

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	for spot: Array in spots:
		var at: Vector3 = spot[1]
		bot.teleport(at, 0.0)
		for _i in range(90):
			await get_tree().physics_frame
		var drop := at.y - bot.global_position.y
		var falls: Array = FALLING_ARRIVALS.get(String(_map_id), [])
		_check(drop < (20.0 if falls.has(spot[0]) else 8.0),
			"%s is somewhere a player can stand%s" % [spot[0], " (or a drop the map means, FALLING_ARRIVALS)" if falls.has(spot[0]) else ""],
			"fell %.1f m from %s" % [drop, str(at / G2GUnits.METRES_PER_UNIT)])

	for n in splits:
		var before := bot.global_position
		var refused := game.request_stage(&"bot", n)
		_check(not refused.ok and refused.error.code == DotError.CODE_UNSUPPORTED,
			"stage %d, a split with no restart, refuses !s%d with the reason" % [n, n],
			str(refused.error.message) if not refused.ok else "it was sent")
		# `!rs` from inside it goes to the stage it splits, which IS somewhere to stand.
		var who := game.timers.player(&"bot")
		if who != null:
			who.timer.run.stage = n
		var back := game.restart_stage(&"bot")
		_check(back.ok and bot.global_position.distance_to(before) > 1.0,
			"and !rs inside stage %d goes back to the stage before it" % n,
			str(back.error.message) if not back.ok else "did not move")
	_done()


## Every place the map puts a player -- a spawn, a stage, the far side of a door -- is outside every pit on that track.
## A respawn fires on ENTRY, so a player put inside a pit is sent back the first time they move (a `!s2` that does nothing).
## `_test_stands_where_it_sends_you` cannot see it: a bot put back at a higher spawn has fallen a negative distance. Armed without `inflate_pit` in `tools/bsp_import.py`.
func _test_arrivals_miss_the_pits() -> void:
	_section("arrivals")
	var zones := game.timers.zones
	var inside := PackedStringArray()
	if zones != null:
		var pits := zones.of_kind(DotTimerZone.Kind.RESPAWN)
		for zone: DotTimerZone in zones.zones:
			var label := ""
			match zone.kind:
				DotTimerZone.Kind.SPAWN:
					label = "%s spawn" % DotTimerTrack.short_name_of(zone.track)
				DotTimerZone.Kind.STAGE:
					if zone.payload.has(G2GBspMap.NO_RESTART):
						continue    # nobody is ever put there; see ARRIVES_IN_PIT
					label = "stage %d" % int(zone.number)
				DotTimerZone.Kind.TELEPORT:
					label = "door"
				_:
					continue
			for pit: DotTimerZone in pits:
				if pit.track == zone.track and pit.contains(zone.destination):
					if not inside.has(label):
						inside.append(label)
					break
	var known: Array = ARRIVES_IN_PIT.get(String(_map_id), [])
	if known.is_empty():
		_check(inside.is_empty(), "no spawn, stage or door puts a player inside a pit",
			", ".join(inside))
	else:
		# Both ways: the listed ones still do, and nothing else does.
		var listed := PackedStringArray(known)
		_check(inside == listed,
			"lands in a pit exactly where ARRIVES_IN_PIT says it does",
			"listed %s, found %s" % [str(listed), str(inside)])
	_done()


## Walking through one of the map's doors does not end the run.
## `doorways` makes a door a TELEPORT, which keeps the run, but the game's TELEPORT handler called `G2GPlayer.teleport`, which ends it,
## so the zone list was right and the only symptom was a timer that stopped at the first door. Driven through the real handler: the manager's signal.
func _test_a_door_keeps_the_run() -> void:
	_section("doors")
	var zones := game.timers.zones
	var door: DotTimerZone = null
	var start: DotTimerZone = null
	if zones != null:
		door = zones.first_of_kind(DotTimerZone.Kind.TELEPORT, DotTimerTrack.MAIN)
		start = zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	if door == null or start == null:
		_check(true, "a door keeps the run", "no door on the main track")
		_done()
		return

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	var timer := bot.timer
	if timer == null:
		_check(false, "a door keeps the run", "the bot has no timer")
		return
	timer.stop()

	# Leave the start line, so there is a run to lose. Synchronously, inside one frame,
	# so the game's own tick cannot feed the timer the bot's real position in between.
	var sample := DotTimerSample.new()
	sample.grounded = true
	var away := start.centre() + Vector3(0.0, start.size().y + 8.0, 0.0)
	for point in [start.centre(), start.centre(), away]:
		sample.previous_position = sample.position
		sample.position = point
		timer.tick(sample)
	var was_running := timer.run.is_running()

	game.timers.effect_requested.emit(&"bot", door)

	var moved := bot.global_position.distance_to(door.destination) < 0.01
	_check(was_running and moved and timer.run.is_running(), "a door keeps the run",
		"running before %s, moved %s, running after %s"
		% [was_running, moved, timer.run.is_running()])
	timer.stop()
	_done()


## Maps completed by walking every gate (a gate is a pit that lands in the next stage).
const GATED_COURSES := ["bhop_eazy", "bhop_eazy_v2"]

## Pits sampled per map by [method _test_pits_land_at_their_destination].
const PIT_SAMPLES := 12
