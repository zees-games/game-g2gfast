extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const RouteBot := preload("../game/g2g_route_bot.gd")

## Rides a stage of a map from where `!s<n>` puts a player, and says where it got to.
##
## [b]Every other check on a destination stops at "a player can stand there".[/b]
## `headless_imported` teleports a bot to each `!s<n>` and watches it not fall; that is
## the whole question for a spawn and half of it for a stage, because a deck a player
## can stand on and cannot leave is a stage nobody can finish. The other half is
## riding it, which is what this does: the real game, the real zones and pits, a player
## sent by the timer's own `request_stage`, and a surf bot driving until it crosses the
## next stage line or the finish, is put back by a pit, or runs out of time.
##
##     godot --headless --path . tools/stage_ride.tscn -- surf_summit 3
##     godot --headless --path . tools/stage_ride.tscn -- surf_summit 3 20
##     godot --headless --path . tools/stage_ride.tscn -- surf_summit 3 20 2448 -200 0 90
##     godot --headless --path . tools/stage_ride.tscn -- bhop_eazy 0 120   # the whole run
##     RIDE_SAVE_REPLAY=maps/routes/bhop_grove.replay godot --headless --fixed-fps 128 \
##         --path . tools/stage_ride.tscn -- bhop_grove 0 200   # and keep its replay
##
## Stage 0 is the whole run, from the main spawn to the finish, on a map with or without
## stages; off a ramp the bot then heads straight for the finish.
## The third argument is seconds (default 30). Four more are a candidate destination in
## the manifest's units (Godot axes: x, up, z) and a yaw, which replaces the stage's own
## for this ride only -- so a new destination can be tried before it is written into a
## zones file and re-imported.
##
## [b]The bot surfs.[/b] Each tick it traces under and beside itself; over a face too
## steep to stand on it looks along the face in the direction it is already moving and
## holds strafe into it, which is what a player does and the whole of surfing. Over
## anything else it holds forward along its own heading and jumps when grounded, so it
## walks off a deck and hops a flat. That is crude, and "crude bot fails" is not "the
## route is impossible" -- but "crude bot arrives" is proof that it is not.

const SECONDS := 30.0
const TRACE_UNITS := 160.0
const LOG_EVERY := 64


var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0] if args.size() > 0 else "surf_summit")
	var number := int(args[1]) if args.size() > 1 else 1
	var seconds := float(args[2]) if args.size() > 2 else SECONDS
	var override := args.size() >= 7

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
		print("[ride] %s did not load" % id)
		get_tree().quit(1)
		return

	var zones := game.timers.zones
	var bot := game.add_player(&"bot", "Bot", true)
	bot.sampler = null
	await get_tree().physics_frame

	var track := DotTimerTrack.MAIN
	var total := zones.stage_count(track)
	# Stage 0 is the whole run: from the main spawn, with the finish as the only goal, so
	# the bot has to cross every stage line and every door on the way (`g2g-maps-1`).
	var whole := number == 0
	var from: DotTimerZone = null if whole else zones.stage_zone(track, number)
	if from == null and not whole:
		print("[ride] %s has no stage %d on main (1..%d)" % [id, number, total])
		get_tree().quit(1)
		return

	# The stage zone's own destination and yaw: what `DotTimerManager.request_stage`
	# hands to whoever moves the player. Moved here directly, because nothing in this
	# game listens to `stage_requested` (see the report of 2026-09-27).
	var map := game.current_map_node()
	var arrival: Vector3 = map.spawn_for(track) if whole else from.destination
	var arrival_yaw: float = map.spawn_yaw_for(track) if whole else from.destination_yaw
	if override:
		arrival = G2GUnits.vector_to_metres(
			Vector3(float(args[3]), float(args[4]), float(args[5])))
		arrival_yaw = float(args[6])
	bot.teleport(arrival, arrival_yaw)
	await get_tree().physics_frame
	print("[ride] %s !s%d: arrives at %s u facing yaw %.0f%s" % [
		id, number,
		str(G2GUnits.vector_to_units(bot.global_position).round()), bot.controller.state.yaw,
		" (a candidate, not the zone's)" if override else ""])

	# What counts as getting somewhere: the next stage's line, or the finish.
	var goals: Array = []
	for n in range(number + 1, total + 1):
		if not whole:
			goals.append(["stage %d" % n, zones.stage_zone(track, n)])
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.END):
		if zone.track == track:
			goals.append(["the finish", zone])

	var events: Array[String] = []
	var put_back: Array[bool] = [false]
	var finish: Vector3 = arrival
	for goal: Array in goals:
		if goal[0] == "the finish":
			finish = (goal[1] as DotTimerZone).centre()
	# Off a ramp the whole-run bot heads for the finish rather than along its own track:
	# a bhop corridor's line is the straight one, and a door moves it closer.
	var aim_at_finish := whole and finish != arrival
	# The whole run follows the map's route (`maps/routes/<id>.json`, see game/g2g_route_bot.gd)
	# when it has one, and otherwise its stage lines in order and then the finish.
	var router: RouteBot = null
	if whole:
		var why: Array = []
		var route := RouteBot.load_points(id, why)
		if route.is_empty():
			for n in range(1, total + 1):
				route.append({"at": zones.stage_zone(track, n).centre(),
					"radius": G2GUnits.to_metres(RouteBot.DEFAULT_RADIUS), "max": 0.0, "walk": false, "hop": false, "land": false, "door": false})
			print("[ride] %s: %s; following its %d stage lines" % [id, why[0], route.size()])
		else:
			print("[ride] %s: following its route, %d points" % [id, route.size()])
		router = RouteBot.new(route, finish)
	var finished: Array[float] = []
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run.time()))
	var on_effect := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid != &"bot":
			return
		match zone.kind:
			DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
				put_back[0] = true
			DotTimerZone.Kind.TELEPORT:
				if router != null:
					router.teleported.call_deferred()
				events.append("a door at %s u -> %s u" % [
					str(G2GUnits.vector_to_units(bot.global_position).round()),
					str(G2GUnits.vector_to_units(zone.destination).round())])
	game.timers.effect_requested.connect(on_effect)
	# Taken on the finish rather than read after it: the manager drops `last_replay` once
	# it learns nothing will keep the run, and with no store (this tool has none) that is
	# straight after `player_finished`. Read afterwards, RIDE_SAVE_REPLAY saved nothing.
	var finished_replay: Array[DotTimerReplay] = [null]
	var on_finished := func(pid: StringName, _run) -> void:
		var p := game.timers.player(pid)
		if pid == &"bot" and p != null and p.last_replay != null:
			finished_replay[0] = p.last_replay
	game.timers.player_finished.connect(on_finished)

	var start := bot.global_position
	var limit := bot.controller.tunables.max_slope_angle
	var heading := arrival_yaw
	var reached := ""
	var ticks := int(seconds * float(game.tick_rate))
	var top := 0.0
	var lowest := start.y
	var surfed := 0
	var grounded := 0
	var at_tick := 0
	# `RIDE_LOG_EVERY=8` for a finer trace of the part that went wrong.
	var log_every := int(OS.get_environment("RIDE_LOG_EVERY")) if OS.has_environment("RIDE_LOG_EVERY") else LOG_EVERY

	for t in range(ticks):
		at_tick = t
		var state := bot.controller.state
		var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
		if flat.length() > G2GUnits.to_metres(60.0):
			heading = rad_to_deg(atan2(-flat.x, -flat.z))

		var c := DotFpsCommand.new()
		var ramp := Vector3.ZERO if router != null else _ramp_under(bot, flat, limit)
		if router != null:
			c = router.command(state, get_world_3d().direct_space_state, bot.controller.tunables, 1.0 / float(game.tick_rate))
		elif ramp != Vector3.ZERO:
			# Along the face, in the direction already moving (or the heading at a
			# standstill), and strafe INTO it.
			var inward := Vector3(-ramp.x, 0.0, -ramp.z).normalized()
			var along := Vector3(inward.z, 0.0, -inward.x)
			# The way the route goes, not the way the bot happens to be moving: a
			# landing deflects a rider sideways, and following that climbs the face.
			var going := flat if G2GUnits.to_units(flat.length()) > 300.0 \
				else DotFpsMotor.forward_for(heading)
			if along.dot(going) < 0.0:
				along = -along
			c.yaw = rad_to_deg(atan2(-along.x, -along.z))
			var right := Vector3(cos(deg_to_rad(c.yaw)), 0.0, -sin(deg_to_rad(c.yaw)))
			c.move = Vector2(signf(right.dot(inward)), 0.0)
			surfed += 1
		else:
			if aim_at_finish:
				var to := finish - state.position
				heading = rad_to_deg(atan2(-to.x, -to.z))
			c.yaw = heading
			c.move = Vector2(0.0, 1.0)
			# A jump from a standstill creeps at the air cap for ever (headless_run's
			# `_prestrafe`), so only once walking has built the speed.
			c.set_button(DotFpsCommand.BUTTON_JUMP,
				state.is_grounded() and G2GUnits.to_units(flat.length()) > 230.0)
		if state.is_grounded():
			grounded += 1
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var at := bot.controller.state.position
		top = maxf(top, bot.speed())
		lowest = minf(lowest, at.y)
		if t % log_every == 0:
			print("[ride]   t %5.2f s  at %s u  %4.0f u/s  %s" % [
				float(t) / float(game.tick_rate), str(G2GUnits.vector_to_units(at).round()),
				G2GUnits.to_units(bot.speed()),
				("surfing, face %s" % str(ramp.snapped(Vector3.ONE * 0.01))) if ramp != Vector3.ZERO else ("grounded" if bot.controller.state.is_grounded() else "air")])
		if router != null and t % log_every == 0:
			print("[ride]            -> point %d/%d at %s u" % [router.index + 1, router.points.size(),
				str(G2GUnits.vector_to_units(router.target()).round())])
		if not finished.is_empty():
			reached = "FINISHED the run in %.2f s at %s u" % [finished[0], str(G2GUnits.vector_to_units(at).round())]
			break
		if put_back[0]:
			reached = "PUT BACK by a pit at %s u" % str(G2GUnits.vector_to_units(at).round())
			break
		for goal: Array in goals:
			if (goal[1] as DotTimerZone).contains(at):
				reached = "REACHED %s at %s u" % [goal[0], str(G2GUnits.vector_to_units(at).round())]
				break
		if reached != "":
			break

	game.timers.effect_requested.disconnect(on_effect)
	game.timers.player_finished.disconnect(on_finished)
	# `RIDE_SAVE_REPLAY=maps/routes/<id>.replay` keeps the finished run's dot-timer replay:
	# what `tools/follow_replay.tscn` and `headless_imported`'s *follows a recorded run*
	# drive the real movement along. A person's own record is the better line to keep
	# (G2GReplays writes it beside the records); this is the one a bot can make.
	var save_to := OS.get_environment("RIDE_SAVE_REPLAY")
	if save_to != "" and not finished.is_empty():
		var replay: DotTimerReplay = finished_replay[0]
		if replay == null:
			print("[ride] no replay to save: the timer kept none")
		else:
			replay.map_id = id
			replay.player_name = "route bot"
			var saved := replay.save(ProjectSettings.globalize_path("res://" + save_to) if not save_to.is_absolute_path() else save_to)
			print("[ride] saved the run's replay (%d frames, run %d..%d) to %s%s" % [
				replay.frames.size(), replay.start_frame, replay.run_end_frame(), save_to,
				"" if saved.ok else ": FAILED, " + saved.error.message])
	for line in events:
		print("[ride]   %s" % line)
	var end := bot.controller.state.position
	print("[ride] %s after %.2f s: %s; %.0f u from the arrival, %.0f u lower at the deepest, top %.0f u/s, %d ticks surfing, %d grounded" % [
		id, float(at_tick + 1) / float(game.tick_rate),
		reached if reached != "" else "nowhere, time ran out at %s u" % str(G2GUnits.vector_to_units(end).round()),
		G2GUnits.to_units(end.distance_to(start)), G2GUnits.to_units(start.y - lowest),
		G2GUnits.to_units(top), surfed, grounded])
	get_tree().quit(0 if reached.begins_with("REACHED") or reached.begins_with("FINISHED") else 2)


## The normal of a surf face under or beside the player, or ZERO. Traced straight down
## and down-and-out to either side of the direction of travel, because a rider on a
## face is beside it as much as over it.
func _ramp_under(bot: G2GPlayer, flat: Vector3, limit: float) -> Vector3:
	var space := get_world_3d().direct_space_state
	var feet := bot.controller.state.position + Vector3.UP * G2GUnits.to_metres(8.0)
	var ahead := flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
	var side := Vector3(-ahead.z, 0.0, ahead.x)
	var reach := G2GUnits.to_metres(TRACE_UNITS)
	for dir: Vector3 in [Vector3.DOWN, (Vector3.DOWN + side).normalized(), (Vector3.DOWN - side).normalized()]:
		var query := PhysicsRayQueryParameters3D.create(feet, feet + dir * reach)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		var angle := rad_to_deg(n.angle_to(Vector3.UP))
		if angle > limit and angle < 85.0:
			return n
	return Vector3.ZERO
