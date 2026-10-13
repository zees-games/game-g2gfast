extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GSurfSim := preload("../game/g2g_surf_sim.gd")
const G2GSurfCourse := preload("../game/g2g_surf_course.gd")
const G2GSurfPlanner := preload("../game/g2g_surf_planner.gd")
const G2GSurfPilot := preload("../game/g2g_surf_pilot.gd")

## Plans a surf stage on the real motor, saves what it found as the map's surf cache, and
## measures the bot that rides from it.
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
##    direction), each with [code]G2GSurfPlanner[/code], and writes every ride found to
##    `maps/routes/<id>.surf.json` under the stage's number. `--no-plan` keeps the file.
##    Then up to `--rounds R` (default 4) rounds of repair: the pilot rides from
##    `--repairs K` (default 24) further perturbed starts, and every ride that fails is
##    searched again from a second before it failed (see `G2GSurfPlanner.build`).
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
	var course: RefCounted = G2GSurfCourse.for_stage(game, number, why)
	if course == null:
		print("[surf] %s: %s" % [id, why[0]])
		get_tree().quit(1)
		return
	var bot := game.add_player(&"bot", "Bot", true)
	bot.sampler = null
	await get_tree().physics_frame
	bot.teleport(course.start, course.start_yaw)
	var base := bot.controller.state.duplicate_state()
	var sim: RefCounted = G2GSurfSim.for_controller(bot.controller, bot, game.tick_rate)
	sim.oracle = course.event_at
	sim.mechanics = game.mechanics
	print("[surf] %s stage %d: from %s u, %d goal zones, %d pits, aiming %s u" % [id, number,
		str(G2GUnits.vector_to_units(course.start).round()), course.goals.size(), course.pits.size(),
		str(G2GUnits.vector_to_units(course.goal_centre).round())])

	var checks: Array = await simulator_checks(game, bot, sim, base, course.reference_yaw(),
		first_ride_actions(_read(ProjectSettings.globalize_path(G2GSurfCourse.cache_path(id))).get("stages", {}).get(str(number), {})))
	var failed := 0
	for c: Array in checks:
		print("[surf]   %s  %s%s" % ["ok  " if c[0] else "FAIL", c[1], "" if c[2] == "" else "  (%s)" % c[2]])
		if not c[0]:
			failed += 1

	var path := ProjectSettings.globalize_path(G2GSurfCourse.cache_path(id))
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
		var planner := G2GSurfPlanner.new()
		planner.seconds = RIDE_SECONDS
		var repair_sim: RefCounted = G2GSurfSim.for_controller(bot.controller, bot, game.tick_rate)
		repair_sim.oracle = course.event_at
		repair_sim.mechanics = game.mechanics
		var built: Dictionary = planner.build(from_starts, repair_starts, rounds, course, sim, repair_sim,
			func(line: String) -> void: print("[surf]   " + line))
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
		var cache := _read(path)
		var stages: Dictionary = cache.get("stages", {})
		stages[str(number)] = {
			"reference_yaw": snappedf(course.reference_yaw(), 0.01),
			"start": _units(course.start),
			"rides": seconds,
			"lengths": Array(built["lengths"]),
			"planned": {"starts": starts, "repairs": repairs, "rounds": built["rounds"],
				"searches": built["searches"], "seconds": snappedf(spent, 0.1), "motor_ticks": motor_ticks},
			"entries": G2GSurfPilot.entries_to_rows(rides),
		}
		cache["id"] = String(id)
		cache["note"] = "Written by tools/surf_plan.gd: per stage, every tick of every ride the planner found on the real motor, as [x, y, z, vx, vy, vz, action] in genre units (Godot axes). The pilot (game/g2g_surf_pilot.gd) takes the action of the nearest entry. Regenerate after a movement or collision change."
		cache["stages"] = stages
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(cache, "", false))
		f.close()
		print("[surf]   saved %d entries to %s" % [rides.size() / G2GSurfPilot.STRIDE, G2GSurfCourse.cache_path(id)])

	var data: Dictionary = _read(path).get("stages", {}).get(str(number), {})
	if data.is_empty():
		print("[surf] no cache for stage %d at %s" % [number, path])
		get_tree().quit(1)
		return
	var pilot := G2GSurfPilot.new()
	pilot.load_stage(data)
	pilot.sim = sim
	pilot.score = course.score
	# `--track`: track the remembered ride instead of taking the nearest entry's action;
	# `--no-veto`: no lookahead. The pilot's parts, measured apart.
	pilot.tracking = args.has("--track")
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
		var ride_sim: RefCounted = G2GSurfSim.for_controller(bot.controller, bot, game.tick_rate)
		ride_sim.oracle = course.event_at
		ride_sim.mechanics = game.mechanics
		for i in range(runs):
			var r: Dictionary = pilot.ride(perturbed(base, course, rng), ride_sim, int(RIDE_SECONDS / sim.delta))
			ridden += int(r["ticks"])
			if int(r["event"]) == G2GSurfSim.Event.GOAL:
				ok += 1
				times.append(float(r["ticks"]) * sim.delta)
			elif misses.size() < 12:
				var last: DotFpsState = (r["trail"] as Array).back()
				misses.append("%s %.2f s near %s u" % ["fell" if int(r["event"]) != G2GSurfSim.Event.NONE else "stalled",
					float(r["ticks"]) * sim.delta, str(G2GUnits.vector_to_units(last.position).round())])
		var lookahead: int = sim.steps - steps_before
		print("[surf]   simulated rides: %d of %d reached the goal (%.0f%%), %s; lookahead %.1f motor ticks per ridden tick (%.0f us of motor per ridden tick); %d checks, %d vetoes, %d hopeless" % [
			ok, runs, 100.0 * ok / maxf(1.0, runs), _spread(times),
			float(lookahead) / maxf(1.0, ridden), float(sim.usec - usec_before) / maxf(1.0, ridden),
			pilot.checks, pilot.vetoes, pilot.hopeless])
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


## The checks the simulator stands on. Each is `[ok, what, detail]`.
##
## [param actions] is the ride to compare along, one action a tick: a cached ride's own
## (from its start, stopped short of the door that would teleport the live player), so
## the comparison covers the drop, the ramp and the flight, not just a deck. Empty, a
## fixed run-and-strafe of 256 ticks.
static func simulator_checks(p_game: Node, bot: G2GPlayer, sim: RefCounted, base: DotFpsState,
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
		var _e: int = sim.step(a, G2GSurfSim.command_for(action, a, reference))
	out.append([bot.controller.state.equals(live_before) and bot.controller.motor.ticks_simulated == motor_before
		and bot.controller.state.position == live_before.position,
		"a simulated ride leaves the live player and its motor untouched", ""])
	var b := base.duplicate_state()
	for action in plan:
		var _e: int = sim.step(b, G2GSurfSim.command_for(action, b, reference))
	out.append([a.equals(b, 0.0), "the same start and inputs end in the same state",
		"" if a.equals(b, 0.0) else "%.6f m apart" % a.divergence(b)])
	# The live player, from the same start, given the same commands.
	bot.teleport(base.position, base.yaw)
	bot.controller.state.copy_from(base)
	for action in plan:
		bot.controller.apply_command(G2GSurfSim.command_for(action, bot.controller.state, reference))
		await tree.physics_frame
	var apart := bot.controller.state.position.distance_to(a.position)
	out.append([apart < 0.001, "the live player given the same commands ends where the simulation did",
		"%.4f m apart after %d ticks, at %s u" % [apart, plan.size(), str(G2GUnits.vector_to_units(a.position).round())]])
	return out


## Rides the stage [param count] times in the game from perturbed starts. Returns
## `{"ok": int, "times": Array[float], "failures": Array[String]}`.
## The first ride is from [param base] itself when [param exact_first] is true.
static func ride_live(p_game: Node, bot: G2GPlayer, course: RefCounted, pilot: RefCounted,
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
				if course.goals.has(zone):
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
			if course.event_at(bot.controller.state.position) == G2GSurfSim.Event.GOAL:
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
static func perturbed(base: DotFpsState, course: RefCounted, rng: RandomNumberGenerator) -> DotFpsState:
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
