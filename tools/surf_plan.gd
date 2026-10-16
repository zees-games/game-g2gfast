extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GSurfCourse := preload("../game/g2g_surf_course.gd")

## Plans a surf stage on the real motor, saves what it found as the map's surf cache, and
## measures the bot that rides from it. The planner and the pilot are dot-bot's
## ([DotBotSurfPlanner], [DotBotSurfPilot]), the simulator dot-player-controller's
## ([DotFpsSimulator]); the stage is [code]G2GSurfCourse[/code], read from the timer's zones.
##
##     godot --headless --fixed-fps 128 --path . tools/surf_plan.tscn -- surf_beginner 1
##     godot --headless --fixed-fps 128 --path . tools/surf_plan.tscn -- surf_beginner 1 --starts 6 --runs 50 --live 20
##     godot --headless --fixed-fps 128 --path . tools/surf_plan.tscn -- surf_beginner 1 --no-plan --runs 50
##
## [b]What it does, in order.[/b]
## 1. Checks the simulator: a simulated ride leaves the live player untouched, the same
##    inputs give the same end twice, and the live player given the same commands ends
##    where the simulation did.
## 2. `--starts M` (default 6): searches from M starts perturbed from the stage's own
##    arrival (sideways and along by up to [constant SIDE_UNITS] and
##    [constant ALONG_UNITS], an initial velocity of up to [constant SPEED_UNITS] in any
##    direction), each with [DotBotSurfPlanner], and writes every ride found to
##    `maps/routes/<id>.surf.json` under the stage's number. `--no-plan` keeps the file.
##    Then up to `--rounds R` (default 4) rounds of repair: the pilot rides from
##    `--repairs K` (default 24) further perturbed starts, and every ride that fails is
##    searched again from a second before it failed (see `DotBotSurfPlanner.build`).
## 3. `--runs N` (default 40): rides the stage N times in the simulator with the pilot,
##    from N other perturbed starts, reading the cache as it was saved.
## 4. `--live N` (default 10): rides it N times in the game itself -- the timer's zones,
##    its pits and its doors -- and counts a ride that the game sends into the next
##    stage's zone.
##
## Everything is seeded, so two runs print the same numbers. `--fixed-fps 128` lets the
## live rides run as fast as the machine can rather than in real time.

const SIDE_UNITS := 48.0
const ALONG_UNITS := 32.0
const SPEED_UNITS := 150.0
const RIDE_SECONDS := 20.0

var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0] if args.size() > 0 else "surf_beginner")
	var number := int(args[1]) if args.size() > 1 else 1
	var starts := _opt(args, "--starts", 6)
	var runs := _opt(args, "--runs", 40)
	var live := _opt(args, "--live", 10)
	var repairs := _opt(args, "--repairs", 24)
	var rounds := _opt(args, "--rounds", 4)
	var plan := not args.has("--no-plan")

	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = id
	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(240):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	if game.maps == null or game.maps.current == null or game.maps.current.id != id:
		print("[surf] %s did not load" % id)
		get_tree().quit(1)
		return
	if game.mechanics != null:
		game.mechanics.blocks.clear()

	var why: Array = []
	var course: DotBotSurfCourse = G2GSurfCourse.for_stage(game, number, why)
	if course == null:
		print("[surf] %s: %s" % [id, why[0]])
		get_tree().quit(1)
		return
	# `--guide "x,y,z;x,y,z"`: a polyline in genre units (Godot axes) after the start that
	# progress is measured along, for a stage that bends far from the straight line. Saved
	# with the stage so the pilot's veto scores futures along the same line.
	var guide_units: Array = []
	var guide_at := args.find("--guide")
	if guide_at >= 0 and guide_at + 1 < args.size():
		for part in args[guide_at + 1].split(";"):
			var xyz := part.split(",")
			guide_units.append([float(xyz[0]), float(xyz[1]), float(xyz[2])])
		course.guide = PackedVector3Array([course.start])
		for g: Array in guide_units:
			course.guide.append(G2GUnits.vector_to_metres(Vector3(g[0], g[1], g[2])))
	var bot := game.add_player(&"bot", "Bot", true)
	bot.sampler = null
	await get_tree().physics_frame
	bot.teleport(course.start, course.start_yaw)
	var base := bot.controller.state.duplicate_state()
	var sim: DotFpsSimulator = course.simulator_for(bot.controller, game.mechanics)
	print("[surf] %s stage %d: from %s u, %d goal zones, %d pits, aiming %s u" % [id, number,
		str(G2GUnits.vector_to_units(course.start).round()), course.goal_zones.size(), course.pit_zones.size(),
		str(G2GUnits.vector_to_units(course.goal_centre).round())])

	var checks: Array = await simulator_checks(game, bot, sim, base, course.reference_yaw(),
		first_ride_actions(_read(ProjectSettings.globalize_path(G2GSurfCourse.cache_path(id))).get("stages", {}).get(str(number), {})))
	var failed := 0
	for c: Array in checks:
		print("[surf]   %s  %s%s" % ["ok  " if c[0] else "FAIL", c[1], "" if c[2] == "" else "  (%s)" % c[2]])
		if not c[0]:
			failed += 1

	var path := ProjectSettings.globalize_path(G2GSurfCourse.cache_path(id))
	# `--trace`: one search from the stage's own arrival, the beam's best line printed every
	# half second, and nothing saved. How a stage that finds no ride is diagnosed: where the
	# best line dies says which guide (or which mechanic) it wants.
	if args.has("--trace"):
		var tracer := DotBotSurfPlanner.new()
		tracer.seconds = RIDE_SECONDS
		tracer.width = _opt(args, "--width", tracer.width)
		tracer.trace = func(depth: int, best: Dictionary) -> void:
			if depth % 4 == 0:
				var st: DotFpsState = best["state"]
				print("[surf]   %.1f s best %s u, velocity %s u/s, score %.1f" % [(depth + 1) * tracer.hold / 128.0,
					str(G2GUnits.vector_to_units(st.position).round()), str(G2GUnits.vector_to_units(st.velocity).round()), float(best["score"])])
		var found: Dictionary = tracer.search(base, course, sim)
		print("[surf] traced search: %s %s" % [found["found"], found["why"]])
		get_tree().quit(0)
		return
	if plan:
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + number
		var from_starts: Array = [base.duplicate_state()]
		for i in range(starts - 1):
			from_starts.append(perturbed(base, course, rng))
		var repair_rng := RandomNumberGenerator.new()
		repair_rng.seed = 3000 + number
		var repair_starts: Array = []
		for i in range(repairs):
			repair_starts.append(perturbed(base, course, repair_rng))
		var started := Time.get_ticks_msec()
		var steps_before: int = sim.steps
		var planner := DotBotSurfPlanner.new()
		planner.seconds = RIDE_SECONDS
		planner.width = _opt(args, "--width", planner.width)
		var repair_sim: DotFpsSimulator = course.simulator_for(bot.controller, game.mechanics)
		var repair_pilot := DotBotSurfPilot.new()
		repair_pilot.rolling = not args.has("--no-rolling")
		var resume := args.has("--resume")
		var keep: Dictionary = _read(path).get("stages", {}).get(str(number), {}) if resume else {}
		var built: Dictionary = _build_saving(planner, from_starts, repair_starts, rounds, course, sim, repair_sim,
			func(line: String) -> void: print("[surf]   " + line), repair_pilot, keep,
			func(snapshot: Dictionary) -> void:
				_save_stage(path, id, number, course, snapshot, guide_units if guide_at >= 0 else
					_read(path).get("stages", {}).get(str(number), {}).get("guide", []),
					{"starts": starts, "repairs": repairs, "rounds": snapshot["rounds"], "searches": snapshot["searches"],
					"seconds": snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)}))
		var rides: PackedFloat32Array = built["rides"]
		var seconds: Array = built["seconds"]
		var spent := (Time.get_ticks_msec() - started) / 1000.0
		var motor_ticks: int = sim.steps - steps_before + repair_sim.steps
		print("[surf]   planning: %d searches found %d rides, failures per repair round %s; %.1f s wall, %d motor ticks (%.1f us each), %d branches" % [
			built["searches"], built["found"], str(built["rounds"]), spent, motor_ticks,
			float(sim.usec + repair_sim.usec) / maxf(1.0, float(sim.steps + repair_sim.steps)), planner.expanded])
		if seconds.is_empty():
			get_tree().quit(1)
			return
		print("[surf]   saved %d entries to %s" % [rides.size() / DotBotSurfPilot.STRIDE, G2GSurfCourse.cache_path(id)])

	var data: Dictionary = _read(path).get("stages", {}).get(str(number), {})
	if data.is_empty():
		print("[surf] no cache for stage %d at %s" % [number, path])
		get_tree().quit(1)
		return
	var pilot := DotBotSurfPilot.new()
	pilot.load_stage(data, G2GUnits.METRES_PER_UNIT)
	pilot.sim = sim
	pilot.score = course.score
	# `--track`: track the remembered ride instead of taking the nearest entry's action;
	# `--no-veto`: no lookahead; `--no-rolling`: the lookahead run afresh every 24 ticks
	# instead of kept and extended. The pilot's parts, measured apart.
	pilot.tracking = args.has("--track")
	pilot.rolling = not args.has("--no-rolling")
	if args.has("--no-veto"):
		pilot.horizon = 0

	if runs > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = 5000 + number
		var ok := 0
		var times: Array[float] = []
		var steps_before: int = sim.steps
		var usec_before: int = sim.usec
		var ridden := 0
		var misses: Array[String] = []
		var ride_sim: DotFpsSimulator = course.simulator_for(bot.controller, game.mechanics)
		for i in range(runs):
			var r: Dictionary = pilot.ride(perturbed(base, course, rng), ride_sim, int(RIDE_SECONDS / sim.delta))
			ridden += int(r["ticks"])
			if int(r["event"]) == DotBotSurfCourse.EVENT_GOAL:
				ok += 1
				times.append(float(r["ticks"]) * sim.delta)
			elif misses.size() < 12:
				var last: DotFpsState = (r["trail"] as Array).back()
				misses.append("%s %.2f s near %s u" % ["fell" if int(r["event"]) != DotBotSurfCourse.EVENT_NONE else "stalled",
					float(r["ticks"]) * sim.delta, str(G2GUnits.vector_to_units(last.position).round())])
		var lookahead: int = sim.steps - steps_before
		print("[surf]   simulated rides: %d of %d reached the goal (%.0f%%), %s; lookahead %.2f motor ticks per ridden tick (%.0f us of motor per ridden tick); %d futures, %d vetoes, %d hopeless, %d resyncs" % [
			ok, runs, 100.0 * ok / maxf(1.0, runs), _spread(times),
			float(lookahead) / maxf(1.0, ridden), float(sim.usec - usec_before) / maxf(1.0, ridden),
			pilot.checks, pilot.vetoes, pilot.hopeless, pilot.resyncs])
		if not misses.is_empty():
			print("[surf]     misses: %s" % "; ".join(misses))

	if live > 0:
		var result: Dictionary = await ride_live(game, bot, course, pilot, base, live, 9000 + number)
		print("[surf]   live rides: %d of %d reached the next stage (%.0f%%), %s; %s" % [
			result["ok"], live, 100.0 * float(result["ok"]) / maxf(1.0, live), _spread(result["times"]),
			", ".join(result["failures"]) if not (result["failures"] as Array).is_empty() else "no failures"])
		if int(result["ok"]) == 0:
			failed += 1

	get_tree().quit(1 if failed > 0 else 0)


## [method DotBotSurfPlanner.build], saving as it goes. The addon's returns only when every
## round is done, and a stage that takes an hour to plan lost all of it to the tool's own timeout
## (surf_beginner stage 2); here the cache on disk grows with each ride found, and
## [code]--resume[/code] ([param keep]) continues from what an interrupted run left. Same
## search and same repair rounds, so what is found is what the addon would have found.
func _build_saving(planner: DotBotSurfPlanner, starts: Array, repairs: Array, rounds: int, course: DotBotSurfCourse,
		sim: DotFpsSimulator, ride_sim: DotFpsSimulator, say: Callable, pilot: DotBotSurfPilot, keep: Dictionary,
		save: Callable) -> Dictionary:
	var rides := PackedFloat32Array()
	var lengths := PackedInt32Array()
	var ride_seconds: Array = []
	# A lambda captures a number by value, so the counters the snapshot reads live in one array.
	var counts: Array[int] = [0, 0]
	var per_round: Array = []
	var delta: float = sim.delta
	var snapshot := func() -> Dictionary:
		return {"rides": rides, "lengths": lengths, "seconds": ride_seconds, "searches": counts[0],
			"found": counts[1], "rounds": per_round}
	if not keep.is_empty():
		for row: Array in keep.get("entries", []):
			rides.append_array([float(row[0]) * G2GUnits.METRES_PER_UNIT, float(row[1]) * G2GUnits.METRES_PER_UNIT,
				float(row[2]) * G2GUnits.METRES_PER_UNIT, float(row[3]) * G2GUnits.METRES_PER_UNIT,
				float(row[4]) * G2GUnits.METRES_PER_UNIT, float(row[5]) * G2GUnits.METRES_PER_UNIT, float(row[6])])
		for n: Variant in keep.get("lengths", []):
			lengths.append(int(n))
		ride_seconds.append_array(keep.get("rides", []))
		say.call("resumed with %d rides" % lengths.size())
	else:
		for i in range(starts.size()):
			counts[0] += 1
			var t0 := Time.get_ticks_msec()
			var ride: Dictionary = planner._search_ride(starts[i], course, sim)
			if ride.is_empty():
				say.call("start %d: no ride, %.1f s searching" % [i, (Time.get_ticks_msec() - t0) / 1000.0])
				continue
			counts[1] += 1
			rides.append_array(ride["entries"])
			lengths.append(int(ride["ticks"]))
			ride_seconds.append(snappedf(float(ride["ticks"]) * delta, 0.01))
			say.call("start %d: a ride of %.2f s, %.1f s searching" % [i, float(ride["ticks"]) * delta, (Time.get_ticks_msec() - t0) / 1000.0])
			save.call(snapshot.call())
	var max_ticks := int(planner.seconds / delta)
	for round in range(rounds):
		if lengths.is_empty():
			break
		pilot.load_entries(rides, lengths, course.reference_yaw())
		pilot.sim = sim
		pilot.score = course.score
		var failures := 0
		for j in range(repairs.size()):
			var r := pilot.ride(repairs[j], ride_sim, max_ticks)
			if int(r["event"]) == DotBotSurfCourse.EVENT_GOAL:
				continue
			failures += 1
			var trail: Array = r["trail"]
			var at := trail.size() - 1
			for back in [planner.repair_back, planner.repair_back * 2, 1 << 30]:
				var k := maxi(0, at - back / 16)
				counts[0] += 1
				var t0 := Time.get_ticks_msec()
				var ride: Dictionary = planner._search_ride(trail[k], course, sim)
				if ride.is_empty():
					if k == 0:
						say.call("round %d, ride %d: failed and no ride from its start either" % [round, j])
						break
					continue
				counts[1] += 1
				rides.append_array(ride["entries"])
				lengths.append(int(ride["ticks"]))
				ride_seconds.append(snappedf(float(ride["ticks"]) * delta, 0.01))
				pilot.load_entries(rides, lengths, course.reference_yaw())
				say.call("round %d, ride %d: %s at %.2f s; a ride of %.2f s from %.2f s in, %.1f s searching" % [
					round, j, "fell" if int(r["event"]) != DotBotSurfCourse.EVENT_NONE else "stalled",
					float(r["ticks"]) * delta, float(ride["ticks"]) * delta, float(k * 16) * delta,
					(Time.get_ticks_msec() - t0) / 1000.0])
				save.call(snapshot.call())
				break
		per_round.append(failures)
		say.call("round %d: %d of %d rides failed; the cache has %d entries" % [round, failures, repairs.size(), rides.size() / DotBotSurfPilot.STRIDE])
		if failures == 0:
			break
	return snapshot.call()


## Writes [param snapshot] ([method _build_saving]'s) as stage [param number] of the map's cache.
static func _save_stage(path: String, id: StringName, number: int, course: DotBotSurfCourse, snapshot: Dictionary,
		guide_units: Array, planned: Dictionary) -> void:
	var cache := _read(path)
	var stages: Dictionary = cache.get("stages", {})
	stages[str(number)] = {
		"reference_yaw": snappedf(course.reference_yaw(), 0.01),
		"start": _units(course.start),
		"rides": snapshot["seconds"],
		"lengths": Array(snapshot["lengths"]),
		"planned": planned,
		"guide": guide_units,
		"entries": DotBotSurfPilot.entries_to_rows(snapshot["rides"], G2GUnits.METRES_PER_UNIT),
	}
	cache["id"] = String(id)
	cache["note"] = "Written by tools/surf_plan.gd: per stage, every tick of every ride the planner found on the real motor, as [x, y, z, vx, vy, vz, action] in genre units (Godot axes). The pilot (dot-bot's DotBotSurfPilot) takes the action of the nearest entry. Regenerate after a movement or collision change."
	cache["stages"] = stages
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(cache, "", false))
	f.close()


## The checks the simulator stands on. Each is `[ok, what, detail]`.
##
## [param actions] is the ride to compare along, one action a tick: a cached ride's own
## (from its start, stopped short of the door that would teleport the live player), so
## the comparison covers the drop, the ramp and the flight, not just a deck. Empty, a
## fixed run-and-strafe of 256 ticks.
static func simulator_checks(p_game: Node, bot: G2GPlayer, sim: DotFpsSimulator, base: DotFpsState,
		reference: float, actions: PackedInt32Array = PackedInt32Array()) -> Array:
	var out: Array = []
	var tree := bot.get_tree()
	var plan: Array[int] = []
	for a: int in actions:
		plan.append(a)
	if plan.is_empty():
		for t in range(256):
			plan.append(4 if t < 96 else (1 if t < 176 else 7))
	var live_before := bot.controller.state.duplicate_state()
	var motor_before := bot.controller.motor.ticks_simulated
	var a := base.duplicate_state()
	for action in plan:
		var _e: int = sim.step(a, DotBotSurfPilot.command_for(sim, action, a, reference))
	out.append([bot.controller.state.equals(live_before) and bot.controller.motor.ticks_simulated == motor_before
		and bot.controller.state.position == live_before.position,
		"a simulated ride leaves the live player and its motor untouched", ""])
	var b := base.duplicate_state()
	for action in plan:
		var _e: int = sim.step(b, DotBotSurfPilot.command_for(sim, action, b, reference))
	out.append([a.equals(b, 0.0), "the same start and inputs end in the same state",
		"" if a.equals(b, 0.0) else "%.6f m apart" % a.divergence(b)])
	# The live player, from the same start, given the same commands.
	bot.teleport(base.position, base.yaw)
	bot.controller.state.copy_from(base)
	for action in plan:
		bot.controller.apply_command(DotBotSurfPilot.command_for(sim, action, bot.controller.state, reference))
		await tree.physics_frame
	var apart := bot.controller.state.position.distance_to(a.position)
	out.append([apart < 0.001, "the live player given the same commands ends where the simulation did",
		"%.4f m apart after %d ticks, at %s u" % [apart, plan.size(), str(G2GUnits.vector_to_units(a.position).round())]])
	return out


## Rides the stage [param count] times in the game from perturbed starts. Returns
## `{"ok": int, "times": Array[float], "failures": Array[String]}`.
## The first ride is from [param base] itself when [param exact_first] is true.
static func ride_live(p_game: Node, bot: G2GPlayer, course: DotBotSurfCourse, pilot: DotBotSurfPilot,
		base: DotFpsState, count: int, seed_value: int, exact_first: bool = false) -> Dictionary:
	var tree := bot.get_tree()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var arrived: Array[bool] = [false]
	var put_back: Array[bool] = [false]
	# Where it was on the tick the pit took it: by the time the effect is heard the game
	# has already sent it back to the stage's start.
	var fell_at: Array[Vector3] = [Vector3.ZERO]
	var on_effect := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid != bot.player_id:
			return
		match zone.kind:
			DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
				put_back[0] = true
			DotTimerZone.Kind.TELEPORT:
				if course.goal_zones.has(zone):
					arrived[0] = true
				else:
					put_back[0] = true
	p_game.timers.effect_requested.connect(on_effect)
	var ok := 0
	var times: Array[float] = []
	var failures: Array[String] = []
	var rate: int = p_game.tick_rate
	for i in range(count):
		var s := base.duplicate_state() if exact_first and i == 0 else perturbed(base, course, rng)
		bot.teleport(s.position, s.yaw)
		bot.controller.state.velocity = s.velocity
		pilot.reset()
		arrived[0] = false
		put_back[0] = false
		var t := 0
		while t < int(RIDE_SECONDS * rate) and not arrived[0] and not put_back[0]:
			bot.controller.apply_command(pilot.command(bot.controller.state))
			fell_at[0] = bot.controller.state.position
			await tree.physics_frame
			t += 1
			if course.event_at(bot.controller.state) == DotBotSurfCourse.EVENT_GOAL:
				arrived[0] = true
		if arrived[0]:
			ok += 1
			times.append(float(t) / float(rate))
		else:
			failures.append("ride %d %s at %s u" % [i, "fell" if put_back[0] else "timed out",
				str(G2GUnits.vector_to_units(fell_at[0] if put_back[0] else bot.controller.state.position).round())])
	p_game.timers.effect_requested.disconnect(on_effect)
	return {"ok": ok, "times": times, "failures": failures}


## [param base] moved sideways and along the course and given a small velocity.
static func perturbed(base: DotFpsState, course: DotBotSurfCourse, rng: RandomNumberGenerator) -> DotFpsState:
	var s := base.duplicate_state()
	var forward := DotFpsMotor.forward_for(course.reference_yaw())
	var side := Vector3(-forward.z, 0.0, forward.x)
	s.position += side * G2GUnits.to_metres(rng.randf_range(-SIDE_UNITS, SIDE_UNITS))
	s.position += forward * G2GUnits.to_metres(rng.randf_range(-ALONG_UNITS, ALONG_UNITS))
	var angle := rng.randf_range(0.0, TAU)
	s.velocity = Vector3(cos(angle), 0.0, sin(angle)) * G2GUnits.to_metres(rng.randf_range(0.0, SPEED_UNITS))
	return s


## The actions of a cache stage's first ride, a tick each, less the last
## [constant SHORT_OF_DOOR] ticks (the door at its end would teleport the live player).
static func first_ride_actions(data: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lengths: Array = data.get("lengths", [])
	var rows: Array = data.get("entries", [])
	if lengths.is_empty():
		return out
	for i in range(mini(int(lengths[0]) - SHORT_OF_DOOR, rows.size())):
		out.append(int(rows[i][6]))
	return out


const SHORT_OF_DOOR := 32


static func _spread(times: Array) -> String:
	if times.is_empty():
		return "no times"
	var sorted := times.duplicate()
	sorted.sort()
	var total := 0.0
	for t: float in sorted:
		total += t
	return "time %.2f s best, %.2f s median, %.2f s mean" % [sorted[0], sorted[sorted.size() / 2], total / sorted.size()]


static func _units(v: Vector3) -> Array:
	var u := G2GUnits.vector_to_units(v)
	return [snappedf(u.x, 0.1), snappedf(u.y, 0.1), snappedf(u.z, 0.1)]


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func _opt(args: PackedStringArray, flag: String, fallback: int) -> int:
	var i := args.find(flag)
	return int(args[i + 1]) if i >= 0 and i + 1 < args.size() else fallback
