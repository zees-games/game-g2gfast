extends "headless_imported_zones.gd"
func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — imported map")
	print("")

	# Every map under maps/imported/, not one this file names. A suite with its own
	# copy of the list is the bug the discovery in G2GGame exists to avoid.
	var ids := _imported_ids()
	if ids.is_empty():
		print("nothing in maps/imported/ — nothing to check")
		print("  tools/bsp_import.py <a .bsp> maps/imported --id <name>")
		get_tree().quit(0)
		return

	for id in ids:
		_map_id = id
		_expected += CHECKS_PER_MAP
		print("=== %s" % id)
		await _test_loads("res://maps/imported/%s/%s.json" % [id, id])
		await _test_geometry()
		await _test_lighting()
		_test_zones()
		_test_runnable()
		await _test_stands_on_it()
		await _test_stands_where_it_sends_you()
		_test_arrivals_miss_the_pits()
		_test_a_door_keeps_the_run()
		await _test_pits_land_at_their_destination()
		await _test_runs_its_route()
		await _test_follows_its_recording()
		await _test_surfs_from_its_cache()
		if game != null:
			game.queue_free()
			game = null
			await get_tree().process_frame

	print("")
	if _passed + _failed != _expected:
		_failed += 1
		_failures.append("the suite ran %d checks and should run %d — one aborted"
			% [_passed + _failed, _expected])
	_report_sections(_entered, _completed, SECTIONS_PER_MAP * ids.size())


func _test_loads(manifest_path: String) -> void:
	_section("loading")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = _map_id

	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps != null and game.maps.current != null and game.maps.current.id == _map_id,
		"the imported map is in the catalogue and loads")
	# Discovery, not a list. If this fails the map was located by name.
	_check(FileAccess.file_exists(manifest_path), "its manifest is beside it")
	_done()


## A pit sends the player where its trigger_teleport aims, with the run kept (nightly fgr-g2g-teleports-1).
## Puts a running player INTO a main-track pit and lets the game's own tick fire it, so importer, zone index and `_on_effect_requested` are all in the line.
## Only pits that carry a destination are sampled, each must land exactly and keep the run. Then the finish: on a map with gates, one must land inside the finish zone.
func _test_pits_land_at_their_destination() -> void:
	_section("pits")
	var zones := game.timers.zones
	var start := zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	if start == null or finish == null:
		_check(true, "a sampled pit lands at its destination with the run kept", "no run to time")
		_check(true, "a listed gated course is finished by walking its gates", "no run to time")
		_done()
		return
	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	var timer := bot.timer
	var pits: Array[DotTimerZone] = []
	for pit in zones.of_kind(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN):
		if pit.payload.has(G2GBspMap.SENDS_TO):
			pits.append(pit)
	var landed: Array = []
	var hook := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			landed.append([zone, bot.global_position, bot.timer.run.is_active()])
	game.timers.effect_requested.connect(hook)

	var reasons: Array = []
	var on_stop := func(_r: DotTimerRun, why: StringName) -> void:
		reasons.append(why)
	timer.run_stopped.connect(on_stop)
	var bad: Array[String] = []
	var step := maxi(1, pits.size() / PIT_SAMPLES)
	var sampled := 0
	for i in range(0, pits.size(), step):
		var pit := pits[i]
		timer.stop()
		_run_up(timer, start)
		landed.clear()
		reasons.clear()
		# The host moved the player on purpose; without this the timer takes the jump
		# from the spawn for a cheat and stops the run before the pit is even entered.
		timer.expect_teleport()
		bot.teleport(pit.centre(), INF, true)
		for _f in range(4):
			await get_tree().physics_frame
			if not landed.is_empty():
				break
		# A pit whose middle lies in another pit's volume fires whichever the index finds first; that overlap is the map's,
		# so the sample says only that SOME destination-carrying pit took the player exactly where it aims.
		if landed.is_empty() or landed[0][0] != pit:
			if landed.is_empty() or not (landed[0][0] as DotTimerZone).payload.has(G2GBspMap.SENDS_TO):
				continue
		sampled += 1
		var why := ""
		if (landed[0][1] as Vector3).distance_to((landed[0][0] as DotTimerZone).destination) > 0.05:
			why = "landed %s" % str(landed[0][1])
		elif landed[0][0] == pit and not landed[0][2] and not reasons.has(DotTimer.REASON_RESET) \
				and not start.contains(pit.destination + Vector3(0, 0.46, 0)):
			# (A pit that sends back into the start line stops the run in any engine, and a
			# RESET beside it is another zone's respawn in the same tick: bhop_sqee's pit
			# sits in a volume that sends to the spawn, so the run was ended by that one.)
			var held: Array[String] = []
			for z2 in zones.of_kind(DotTimerZone.Kind.START):
				if z2.contains(pit.centre()) or z2.contains(pit.destination + Vector3(0, 0.46, 0)):
					held.append("start %d" % z2.track)
			why = "stopped the run %s %s" % [held, reasons]
		if why != "":
			bad.append("%s -> %s: %s" % [str(G2GUnits.vector_to_units(pit.centre()).round()),
				str(G2GUnits.vector_to_units(pit.destination).round()), why])
	timer.run_stopped.disconnect(on_stop)
	_check(bad.is_empty(), "a sampled pit lands at its destination with the run kept",
		"%d of %d: %s" % [bad.size(), sampled, "; ".join(bad.slice(0, 3))])


	# The gates, in order, to the finish (nightly fgr-g2g-teleports-1): bhop_eazy's rooms are joined by gates and a gate that
	# fell back to the spawn is a run nobody finishes. Each gate landing inside the next stage (or the finish) is walked into
	# in stage order with the run going, and the run must come out finished.
	var finishes: Array[float] = []
	var on_finish := func(run: DotTimerRun) -> void:
		finishes.append(run.time())
	timer.run_finished.connect(on_finish)
	timer.stop()
	_run_up(timer, start)
	var hops := 0
	var targets: Array[DotTimerZone] = []
	for k in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		var sz := zones.stage_zone(DotTimerTrack.MAIN, k)
		if sz != null:
			targets.append(sz)
	targets.append(finish)
	for tz in targets:
		var gate: DotTimerZone = null
		for pit in pits:
			if tz.contains(pit.destination) or tz.contains(pit.destination + Vector3(0, 0.46, 0)):
				gate = pit
				break
		if gate == null:
			continue
		landed.clear()
		timer.expect_teleport()
		bot.teleport(gate.centre(), INF, true)
		for _f in range(4):
			await get_tree().physics_frame
			if not landed.is_empty():
				break
		# The timer sees the landing on the tick after it, and a finish on the one after.
		for _f in range(4):
			await get_tree().physics_frame
		hops += 1
	timer.run_finished.disconnect(on_finish)
	var gated := GATED_COURSES.has(_map_id)
	_check(not gated or (finishes.size() == 1 and hops == targets.size()), "a listed gated course is finished by walking its gates",
		"%d of %d gates walked, %d finishes" % [hops, targets.size(), finishes.size()])
	game.timers.effect_requested.disconnect(hook)
	timer.stop()
	_done()


## Starts a run for the timer without walking: stand in the start, leave it. See
## [method _test_runnable] for why this is done inside one frame.
func _run_up(timer: DotTimer, start: DotTimerZone) -> void:
	var sample := DotTimerSample.new()
	sample.grounded = true
	var away := start.centre() + Vector3(0.0, start.size().y + 8.0, 0.0)
	for point in [start.centre(), start.centre(), away]:
		sample.previous_position = sample.position
		sample.position = point
		timer.tick(sample)


## Longest a route may take, in simulated seconds, before the bot is said not to finish.
const ROUTE_SECONDS := 300.0


## A bot runs the map from its main spawn to its finish on the imported collision, following the route in `maps/routes/<id>.json` (`g2g-maps-1`).
## The one check about the whole way: the zone checks can pass with a block missing, a gap nobody can clear, or a solid not where it is drawn.
## No put-back by a pit on the way; a map with no route file says so and passes (see game/g2g_route_bot.gd and `tools/route_plan.py`).
func _test_runs_its_route() -> void:
	_section("route")
	# The route bot lands on a block and runs to its lip, and the recording is that bot's: a sinking block (a door, or a
	# map's anti-standing trap, 0.09 s on bhop_grove) sends a player who does that straight back. `headless_mechanics` asks the blocks.
	if game.mechanics != null:
		game.mechanics.blocks.clear()
	var why: Array = []
	var points := RouteBot.load_points(_map_id, why)
	var zones := game.timers.zones if game != null else null
	var finish: DotTimerZone = null
	if zones != null:
		for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.END):
			if zone.track == DotTimerTrack.MAIN:
				finish = zone
	if points.is_empty():
		_check(true, "a bot runs it start to finish on its route", why[0] if not why.is_empty() else "no route")
		_done()
		return
	if finish == null:
		_check(false, "a bot runs it start to finish on its route", "it has a route and no finish")
		_done()
		return

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	var node := game.current_map_node()
	var router := RouteBot.new(points, finish.centre())
	var put_back: Array[String] = []
	var finished: Array[float] = []
	var on_effect := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid != &"bot":
			return
		match zone.kind:
			DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
				if put_back.is_empty():
					put_back.append(str(G2GUnits.vector_to_units(bot.global_position).round()))
			DotTimerZone.Kind.TELEPORT:
				router.teleported.call_deferred()
	var on_finish := func(run: DotTimerRun) -> void:
		finished.append(run.time())
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finish)
	bot.timer.stop()
	bot.teleport(node.spawn_for(DotTimerTrack.MAIN), node.spawn_yaw_for(DotTimerTrack.MAIN))
	await get_tree().physics_frame

	var delta := 1.0 / float(game.tick_rate)
	var space := node.get_world_3d().direct_space_state
	var ticks := int(ROUTE_SECONDS * float(game.tick_rate))
	var t := 0
	while t < ticks and finished.is_empty() and put_back.is_empty():
		bot.controller.apply_command(router.command(bot.controller.state, space, bot.controller.tunables, delta))
		await get_tree().physics_frame
		t += 1
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finish)

	var at := str(G2GUnits.vector_to_units(bot.controller.state.position).round())
	if not finished.is_empty():
		print("        finished in %.2f s over %d points, %d ticks surfing" % [finished[0], points.size(), router.surfed])
	_check(not finished.is_empty() and put_back.is_empty(), "a bot runs it start to finish on its route",
		("finished in %.2f s over %d points" % [finished[0], points.size()]) if not finished.is_empty()
		else ("put back by a pit (sent to %s u), aiming at point %d of %d" % [put_back[0], router.index + 1, points.size()])
			if not put_back.is_empty()
		else ("not finished after %.0f s at %s u, aiming at point %d of %d" % [ROUTE_SECONDS, at, router.index + 1, points.size()]))
	bot.timer.stop()
	_done()


## The frame a recording is lifted off the map from, in the check that a run which cannot
## be followed is reported where it stops being followable.
const LIFT_FROM_FRAME := 2000
const LIFT_UNITS := 200.0


## A bot drives the REAL movement along the run recorded for the map (`maps/routes/<id>.replay`) and the game's own timer finishes it (`g2gfast-route-bot-1`); see replay_follow.gd.
## A recording is the way one run went tick by tick, so following it checks the collision is still the one it was made on; a failure names a place ("left the recorded line at frame N").
## The second check proves that report on a copy lifted off the map from [constant LIFT_FROM_FRAME]. A map with no recording passes both and says so.
func _test_follows_its_recording() -> void:
	_section("recording")
	# The route bot lands on a block and runs to its lip, and the recording is that bot's: a sinking block (a door, or a
	# map's anti-standing trap, 0.09 s on bhop_grove) sends a player who does that straight back. `headless_mechanics` asks the blocks.
	if game.mechanics != null:
		game.mechanics.blocks.clear()
	var why: Array = []
	var replay := ReplayFollow.load_for(_map_id, why)
	if replay == null:
		_check(true, "a bot follows its recorded run start to finish", why[0])
		_check(true, "and a recording it cannot follow is reported where it leaves the line", why[0])
		_done()
		return
	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null

	var result: Dictionary = await ReplayFollow.drive(game, bot, replay, replay.duration() * 1.2)
	print("        %s" % ReplayFollow.summary(result))
	_check(float(result["finished"]) >= 0.0, "a bot follows its recorded run start to finish",
		ReplayFollow.summary(result))

	var lifted := DotTimerReplay.from_bytes(replay.to_bytes()).value as DotTimerReplay
	for i in range(LIFT_FROM_FRAME, lifted.frames.size()):
		lifted.frames[i].position.y += G2GUnits.to_metres(LIFT_UNITS)
	var off: Dictionary = await ReplayFollow.drive(game, bot, lifted, replay.duration() * 1.2)
	var left: Dictionary = off["left_at"]
	print("        lifted from frame %d: %s" % [LIFT_FROM_FRAME, ReplayFollow.summary(off)])
	_check(not left.is_empty() and int(left["frame"]) >= LIFT_FROM_FRAME - ReplayFollow.SEARCH_BEHIND
			and int(left["frame"]) < LIFT_FROM_FRAME + ReplayFollow.LEAD_FRAMES * 4,
		"and a recording it cannot follow is reported where it leaves the line",
		ReplayFollow.summary(off))
	bot.timer.stop()
	_done()


## Perturbed starts the surf section rides besides the stage's own arrival, and how many must arrive.
## Not all: the pilot arrives from 72 to 80% of them (50 simulated and 20 live rides, game-dev/docs/surf-bots-study.md); the stage's own arrival must. Seeded.
const SURF_PERTURBED := 4
const SURF_PERTURBED_ARRIVING := 3


## A surf bot rides the first stage in the map's surf cache (`maps/routes/<id>.surf/<stage>.json`, from `tools/surf_plan.gd`) from the stage's own arrival and [constant SURF_PERTURBED] perturbed starts
## (`fpt-arena-surf-bots-1`). First the simulator is checked to be the motor: a simulated ride leaves the live player untouched, repeats exactly, and ends where the live player does.
## A map with no cache passes both; a failure after a movement or collision change is a stale cache: re-run `tools/surf_plan.gd`.
func _test_surfs_from_its_cache() -> void:
	_section("surf bot")
	var path := G2GSurfCourse.cache_dir(_map_id)
	if not G2GSurfCourse.has_cache(_map_id):
		_check(true, "the surf simulator is the motor", "no surf cache")
		_check(true, "a surf bot rides a stage from its cache into the next", "no surf cache")
		_done()
		return
	var stages: Dictionary = G2GSurfCourse.read_cache(_map_id).get("stages", {})
	var numbers: Array = stages.keys().map(func(k: String) -> int: return int(k))
	numbers.sort()
	if numbers.is_empty():
		_check(false, "the surf simulator is the motor", "%s has no stages" % path)
		_check(false, "a surf bot rides a stage from its cache into the next", "%s has no stages" % path)
		_done()
		return
	var number: int = numbers[0]
	var data: Dictionary = stages[str(number)]
	var why: Array = []
	var course: DotBotSurfCourse = G2GSurfCourse.for_stage(game, number, why)
	if course == null:
		_check(false, "the surf simulator is the motor", why[0])
		_check(false, "a surf bot rides a stage from its cache into the next", why[0])
		_done()
		return
	if game.mechanics != null:
		game.mechanics.blocks.clear()
	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
		await get_tree().physics_frame
	bot.teleport(course.start, course.start_yaw)
	var base := bot.controller.state.duplicate_state()
	var sim: DotFpsSimulator = course.simulator_for(bot.controller, game.mechanics)
	var checks: Array = await SurfPlan.simulator_checks(game, bot, sim, base, course.reference_yaw(),
		SurfPlan.first_ride_actions(data))
	var bad: Array = checks.filter(func(c: Array) -> bool: return not c[0])
	for c: Array in checks:
		print("        %s %s%s" % ["ok" if c[0] else "NOT", c[1], "" if c[2] == "" else " (%s)" % c[2]])
	_check(bad.is_empty(), "the surf simulator is the motor",
		"" if bad.is_empty() else "; ".join(bad.map(func(c: Array) -> String: return "%s %s" % [c[1], c[2]])))

	var pilot := DotBotSurfPilot.new()
	pilot.load_stage(data, G2GUnits.METRES_PER_UNIT)
	pilot.sim = sim
	pilot.score = course.score
	var result: Dictionary = await SurfPlan.ride_live(game, bot, course, pilot, base, 1 + SURF_PERTURBED, 7000 + number, true)
	var times: Array = result["times"]
	print("        stage %d: %d of %d rides arrived (%s); %s" % [number, result["ok"], 1 + SURF_PERTURBED,
		", ".join(times.map(func(t: float) -> String: return "%.2f s" % t)),
		", ".join(result["failures"]) if not (result["failures"] as Array).is_empty() else "no failures"])
	var own_arrived := not (result["failures"] as Array).any(func(f: String) -> bool: return f.begins_with("ride 0 "))
	_check(own_arrived and int(result["ok"]) >= 1 + SURF_PERTURBED_ARRIVING,
		"a surf bot rides a stage from its cache into the next",
		"stage %d: %d of %d arrived (the stage's own arrival %s, and %d of the perturbed starts needed); %s" % [
			number, result["ok"], 1 + SURF_PERTURBED, "did" if own_arrived else "did NOT",
			SURF_PERTURBED_ARRIVING, ", ".join(result["failures"])])
	bot.timer.stop()
	_done()


func _test_geometry() -> void:
	_section("geometry")
	var node := game.current_map_node()
	_check(node is G2GBspMap, "the map node is a G2GBspMap")
	var mi := node.get_node_or_null("World") as MeshInstance3D
	_check(mi != null and mi.mesh != null, "it built a mesh")
	if mi == null or mi.mesh == null:
		return
	var mesh := mi.mesh
	_check(mesh.get_surface_count() > 1, "with a surface per material",
		"%d surfaces" % mesh.get_surface_count())

	# Every surface the manifest lists is drawn, across however many instances it took.
	# A mesh holds 256 and `bhop_monster_jam` has 311: the last 55 were refused by the engine and
	# the map drew with holes while collision (built from brushes) still passed.
	var drawn := 0
	for child in node.get_children():
		if child is MeshInstance3D and (String(child.name).begins_with("World")
				or String(child.name).begins_with("Props")
				or String(child.name).begins_with("Sky")) \
				and (child as MeshInstance3D).mesh != null:
			drawn += (child as MeshInstance3D).mesh.get_surface_count()
	var listed: int = (node as G2GBspMap).manifest.get("surfaces", []).size()
	_check(drawn == listed, "and every surface the manifest lists is drawn",
		"%d of %d" % [drawn, listed])
	_geometry_floors(node)
	_geometry_props_and_sky(node)
	_geometry_size(mi, mesh)
	_done()


func _geometry_floors(node: Node) -> void:
	# A floor is drawn from above: on every PLATFORM surface most triangles must be front-facing from above.
	# Wound inside out, a floor shows its slab's underside, every other check still passes (a culled triangle is still a triangle),
	# and Godot's front face is clockwise from the viewer, a cross product pointing AWAY from them.
	var upside_down := PackedStringArray()
	var world_surfaces: Array[Dictionary] = []
	for s: Dictionary in (node as G2GBspMap).manifest.get("surfaces", []):
		if G2GBspMap._family(s) == "World" and int(s.get("index_count", 0)) > 0 \
				and int(s.get("vertex_count", 0)) > 0:
			world_surfaces.append(s)
	var at := 0
	for child in node.get_children():
		if not (child is MeshInstance3D and String(child.name).begins_with("World")):
			continue
		var m := (child as MeshInstance3D).mesh
		for i in range(m.get_surface_count()):
			var s: Dictionary = world_surfaces[at] if at < world_surfaces.size() else {}
			at += 1
			if str(s.get("role", "")) != "PLATFORM":
				continue
			var arrays := m.surface_get_arrays(i)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var up := 0
			var down := 0
			for t in range(0, idx.size() - 2, 3):
				var a := pos[idx[t]]
				var y := (pos[idx[t + 1]] - a).cross(pos[idx[t + 2]] - a).y
				if y < -1e-6:
					up += 1
				elif y > 1e-6:
					down += 1
			if down > up:
				upside_down.append("%s (%d of %d)" % [s.get("material", "?"), down, up + down])
	_check(upside_down.is_empty(), "and a floor is drawn from the side a player stands on",
		", ".join(upside_down))


func _geometry_props_and_sky(node: Node) -> void:
	# Static props are drawn: 17 of the 26 maps place them. The count DRAWN is from the models read,
	# the count PLACED from the lump; props placed and none drawn is an importer that stopped reading them.
	var manifest_props: Dictionary = (node as G2GBspMap).manifest.get("static_props", {})
	var carried := int(manifest_props.get("placed", 0)) - int(manifest_props.get("stock_models", 0))
	var prop_surfaces := 0
	for child in node.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Props") \
				and (child as MeshInstance3D).mesh != null:
			prop_surfaces += (child as MeshInstance3D).mesh.get_surface_count()
	_check(carried <= 0 or (int(manifest_props.get("drawn", 0)) > 0 and prop_surfaces > 0),
		"and the static props its pakfile carried are drawn",
		"%s; %d prop surfaces drawn" % [manifest_props, prop_surfaces])

	# [b]A stock-model prop with a written stand-in is drawn as its box.[/b]
	# `stock_standins` is how many the importer boxed, out of the same lump `drawn` counts;
	# a map that boxed some and drew fewer props than that, or no prop surface, lost them.
	var boxed := int(manifest_props.get("stock_standins", 0))
	_check(boxed == 0 or (int(manifest_props.get("drawn", 0)) >= boxed and prop_surfaces > 0),
		"and its stock-model stand-in boxes are drawn",
		"%s; %d prop surfaces drawn" % [manifest_props, prop_surfaces])

	# [b]And a 3D skybox is a backdrop, not a miniature.[/b] Ten maps have one;
	# its faces were drawn at a sixteenth of their size where they were compiled and no
	# backdrop at all. Drawn, they are their own `Sky` instances, scaled about the camera.
	var sky: Variant = (node as G2GBspMap).manifest.get("skybox", null)
	var sky_node := node.get_node_or_null("Sky") as MeshInstance3D
	# "Has one" is read from the lighting block's sky_camera, a second code path, so a
	# skybox the importer stopped handling at all is a failure and not a map without one.
	var has_camera := ((node as G2GBspMap).manifest.get("lighting", {}) as Dictionary) \
		.has("sky_camera")
	var told_off := sky is Dictionary and (not bool((sky as Dictionary).get("drawn", true))
		or int((sky as Dictionary).get("faces", 0)) == 0)
	var wants_sky := has_camera and not told_off
	_check(sky_node != null if wants_sky else sky_node == null,
		"and its 3D skybox is drawn as a backdrop exactly when it has one to draw",
		"skybox %s, Sky node %s" % [sky, sky_node != null])

	# [b]And a 3D skybox has something in it.[/b] bhop_pandora2_fix and
	# bhop_supernova build theirs from `prop_dynamic`s alone, and a static-props-only
	# importer found the room and drew nothing in it: faces 0, props 0, an empty sky.
	var sky_things := 0
	if sky is Dictionary:
		sky_things = int((sky as Dictionary).get("faces", 0)) + int((sky as Dictionary).get("props", 0))
	_check(not (sky is Dictionary and bool((sky as Dictionary).get("drawn", true))) or sky_things > 0,
		"and a 3D skybox it draws has faces or props in it", str(sky))

	# And it is in front of the camera's far plane (4000 m). Drawn at the sky camera's own 512, the nearest
	# asteroid was 5 km out: imported and invisible. The nearest of the sky (`reach_units`) must be visible, and a drawn scale may be smaller than the mapper's but never larger.
	var visible := true
	var reach_detail := "no 3D skybox drawn"
	if sky is Dictionary and bool((sky as Dictionary).get("drawn", true)) and sky_things > 0:
		var reach: Array = (sky as Dictionary).get("reach_units", [])
		var drawn_scale := float((sky as Dictionary).get("drawn_scale", INF))
		visible = reach.size() == 2 and G2GUnits.to_metres(float(reach[0])) <= 4000.0 \
			and drawn_scale <= float((sky as Dictionary).get("scale", 0.0))
		reach_detail = "reach %s u at %s x (the mapper's %s)" % [
			str(reach), str(drawn_scale), str((sky as Dictionary).get("scale"))]
	_check(visible, "and its 3D skybox is drawn in front of the camera's far plane", reach_detail)


func _geometry_size(mi: MeshInstance3D, mesh: Mesh) -> void:
	var verts := 0
	var has_uv2 := true
	for i in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(i)
		verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if arrays[Mesh.ARRAY_TEX_UV2] == null:
			has_uv2 = false
	_check(verts > 1000, "and real geometry", "%d verts" % verts)
	# UV2 is the whole reason this is not a glTF import. If it is gone the map is lit
	# by whatever texel the atlas happens to have at (0,0).
	_check(has_uv2, "and a second UV set on every surface, for the baked lighting")

	var aabb := mi.get_aabb()
	var units := aabb.size / G2GUnits.METRES_PER_UNIT
	# Source's limit is +/-16384 units, so a map is at most 32768 across; ten times that means the unit
	# ratio was applied twice or not at all. The LONGEST side, not x: bhop_grove is one corridor 704
	# across and 32,192 long.
	var longest := maxf(units.x, maxf(units.y, units.z))
	_check(longest > 1000.0 and longest < 40000.0,
		"and is the size a Source map can be", "%.0f x %.0f x %.0f units" % [units.x, units.y, units.z])
