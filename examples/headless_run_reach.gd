extends "headless_run_base.gd"

## Every jump a hand-written map declares, against what the movement can do.
##
## [b]`[reach-1]`, asked of this game.[/b] game-playlot's jump course was
## unfinishable past platform three and game-fatal-contact's three maps had routes nothing had
## ever climbed, and every check over all of them passed, because a box count and a
## zone file cannot tell a platform from a wall. Each map here says which of its bodies
## are a route and which reach a route is sized for (`G2GMap.add_course`); the rise and
## the gap are read off the geometry by [G2GReach], and the reach is read off the
## tunables the server applies. Nothing in this function is a number about a map.
func _test_reach() -> void:
	_section("what the movement can reach")

	var t := G2GMovement.tunables_for(game.config)
	var sweep := reach_sweep(t, game.tick_rate)

	# The one number here that is written down, and it is the genre's rather than a
	# map's: 301.99 u/s against 800 must peak at 57, or the units crossed wrongly.
	_near(G2GReach.apex(t), 57.0, 0.5, "a jump peaks at the 57 units the genre's players know")

	for line in sweep["lines"]:
		print(line)

	_check(
		(sweep["undeclared"] as Array).is_empty(),
		"every bhop map declares the courses it asks a player to jump",
		", ".join(sweep["undeclared"])
	)
	_check(
		(sweep["refused"] as Array).is_empty(),
		"and every body a course names is a level box a route can be read off",
		", ".join(sweep["refused"])
	)
	_check(
		(sweep["too_high"] as Array).is_empty(),
		"no route rises past what a jump climbs",
		"; ".join(sweep["too_high"])
	)
	_check(
		(sweep["too_far"] as Array).is_empty(),
		"no RUN route is wider than a jump from the lip at run speed",
		"; ".join(sweep["too_far"])
	)
	_check(
		(sweep["unchainable"] as Array).is_empty(),
		"and no CHAIN is out of reach from its start line even strafing perfectly",
		"; ".join(sweep["unchainable"])
	)

	# [b]The check can say no, and the cvar is why it matters.[/b] With
	# `sv_enablebunnyhopping 0` the landing cap trims every take-off to 275 u/s, so a
	# chain can only ever add one hop's strafing to that — and bhop_g2g_intro's main
	# route asks for a period no such hop spans. That is a property of the map a server
	# operator needs to know before turning the cvar off, and it is also the proof that
	# the chain arithmetic refuses something rather than approving everything.
	var capped_config: G2GConfig = game.config.duplicate()
	capped_config.enable_bunnyhopping = false
	var capped := G2GMovement.tunables_for(capped_config)
	var intro := _built_map("bhop_g2g_intro")
	var main_routes := G2GReach.measure((intro.courses[0] as Object).get("bodies"))
	var verdict := G2GReach.chain(main_routes, capped, game.tick_rate, 1.0)
	print("  ..    with sv_enablebunnyhopping 0, bhop_g2g_intro's main line falls at %s (%.0f u short)"
		% [(main_routes[int(verdict["at"])] as G2GReach.Route).name if not verdict["ok"] else "nothing", float(verdict["short"])])
	_check(
		not bool(verdict["ok"]),
		"and with the landing cap on, bhop_g2g_intro's main line is not a route at all",
		"it chained to the end at %.0f u/s" % float(verdict["top"])
	)
	intro.free()
	_done()


## Every declared course on every hand-written map, decided. Separate from the checks
## so the numbers can be printed whether or not anything fails — a detail line only
## shows on a failure, and the widths and the strafe a chain needs are the measurement.
func reach_sweep(t: DotFpsTunables, tick_rate: int) -> Dictionary:
	var out := {
		"lines": [], "undeclared": [], "refused": [], "too_high": [], "too_far": [],
		"unchainable": [], "restarts": [],
	}

	out["lines"].append(
		"  ..    a jump peaks at %.1f u, climbs %.1f; from the lip at %.0f u/s it clears %.0f flat, %.0f onto +24, %.0f down 48; a perfect strafe adds %.0f u/s a tick"
		% [G2GReach.apex(t), G2GReach.climb_limit(t), G2GReach.run_speed(t),
			G2GReach.run_reach(0.0, t), G2GReach.run_reach(24.0, t), G2GReach.run_reach(-48.0, t),
			G2GReach.strafe_gain(t, tick_rate)]
	)

	for id in _hand_written_map_ids():
		var map := _built_map(id)
		var zones: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		var courses: Array = map.get("courses")

		if courses.is_empty():
			out["lines"].append("  ..    %s declares no course" % id)
			if id.begins_with("bhop_"):
				out["undeclared"].append(id)

		for course: Object in courses:
			var refused: Array = []
			var routes := G2GReach.measure(course.get("bodies"), refused)
			var label := "%s %s" % [id, course.get("name")]

			for index in refused:
				out["refused"].append("%s body %d" % [label, index])

			var widest := 0.0
			var widest_route: G2GReach.Route = null

			for route: G2GReach.Route in routes:
				widest = maxf(widest, route.gap)
				if widest_route == null or route.gap > widest_route.gap:
					widest_route = route

				if G2GReach.walked(route, t):
					continue

				if route.rise > G2GReach.climb_limit(t):
					out["too_high"].append("%s %s rises %.0f u" % [label, route.name, route.rise])
					continue

				if int(course.get("kind")) == G2GReach.Kind.RUN:
					var reach := G2GReach.run_reach(route.rise, t)
					if route.gap > reach:
						out["too_far"].append("%s %s is %.0f u against %.0f" % [label, route.name, route.gap, reach])

			# [b]Against the reach from the widest gap's OWN height[/b], which is what the
			# check above asks. This printed the flat reach whatever the landing, so the
			# ridge read "widest 192 u against a standing jump's 189" -- a failure on the
			# page for a gap that is a drop of 48 with 222 to spare, and passing.
			if int(course.get("kind")) == G2GReach.Kind.RUN:
				out["lines"].append("  ..    %s: RUN, %d jumps, widest %s" % [
					label, routes.size(), _reach_text(widest_route, t)])
				continue

			var needed := G2GReach.strafe_needed(routes, t, tick_rate)
			var from_start := G2GReach.chain(routes, t, tick_rate, 1.0)

			if not bool(from_start["ok"]):
				out["unchainable"].append("%s falls at %s, %.0f u short" % [
					label, (routes[int(from_start["at"])] as G2GReach.Route).name, float(from_start["short"])
				])

			out["lines"].append("  ..    %s: CHAIN, %d hops, widest %.0f u, from the start line needs %s"
				% [label, routes.size(), widest, _percent(needed)])

			# `!s<n>` puts a player on a stage line at a standstill, so from there the
			# chain begins again at run speed rather than at what the stages before it
			# built. Found by the stage zone's own destination, not by an index.
			for zone in zones.zones:
				if zone.kind != DotTimerZone.Kind.STAGE or zone.track != int(course.get("track")):
					continue

				var at := G2GUnits.vector_to_units(zone.destination)
				var from_index := -1

				for i in range(routes.size()):
					var landing := G2GReach.footprint((routes[i] as G2GReach.Route).to_body)
					if Geometry2D.is_point_in_polygon(Vector2(at.x, at.z), landing["corners"]):
						from_index = i + 1
						break

				var restart := G2GReach.strafe_needed(routes, t, tick_rate, from_index) if from_index >= 0 else 2.0
				out["restarts"].append([label, int(zone.number), restart])
				out["lines"].append("  ..      !s%d from a standstill%s: needs %s" % [
					int(zone.number),
					"" if from_index >= 0 else " (its destination is on no body of the course)",
					_percent(restart),
				])

		map.free()

	return out


## "192 u down 48, inside the 222 a jump from its lip reaches": a RUN gap beside the
## reach [method reach_sweep] judges it by, which depends on the landing's height.
static func _reach_text(route: G2GReach.Route, t: DotFpsTunables) -> String:
	if route == null:
		return "none"
	var height := ""
	if route.rise > 0.5:
		height = " onto +%.0f" % route.rise
	elif route.rise < -0.5:
		height = " down %.0f" % -route.rise
	var reach := G2GReach.run_reach(route.rise, t)
	return "%.0f u%s, %s the %.0f a jump from its lip reaches there" % [
		route.gap, height, "inside" if route.gap <= reach else "PAST", reach]


static func _percent(fraction: float) -> String:
	if fraction > 1.0:
		return "more than a perfect strafe — nobody can"
	if fraction <= 0.0:
		return "no strafe at all"
	return "%d%% of a perfect strafe" % int(ceil(fraction * 100.0))


# --- Runs ------------------------------------------------------------------

## `!s <n>` and `!rs`: the game moves the player the timer names, facing on, and stops
## the run. `[stage-yaw-1]` found nothing listened to `stage_requested`.
func _test_stage_command() -> void:
	_section("a stage restart")
	var bot: G2GPlayer = game.players[&"bot"]
	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var sent := game.request_stage(&"bot", 2)
	var zone: DotTimerZone = sent.value if sent.ok else null
	_check(zone != null and bot.global_position.distance_to(zone.destination) < 0.01,
		"`!s 2` puts the player on stage 2's own spot",
		str(bot.global_position) if zone == null else "%s vs %s" % [bot.global_position, zone.destination])
	_check(zone != null and is_equal_approx(bot.controller.state.yaw, zone.destination_yaw),
		"facing the stage's own yaw", "%.1f" % bot.controller.state.yaw)
	_check(not bot.timer.run.is_running(), "and no run is going: a stage restart is practice")
	_check(not game.request_stage(&"bot", 9).ok, "a stage the track does not have is refused")

	var back := game.restart_stage(&"bot")
	_check(back.ok and bot.global_position.distance_to((back.value as DotTimerZone).destination) < 0.01
			and int((back.value as DotTimerZone).number) == 1,
		"`!rs` before any stage line is stage 1")

	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## R and R twice: `G2GGame.restart`, which both the offline client and the server's
## RESTART request call. One R is the start of the stage you are in, and the start of the
## track when you are in none; two are the main start zone, from a bonus too.
func _test_restart_key() -> void:
	_section("R once is the stage, R twice is the start")
	var loaded: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(loaded.ok, "bhop_g2g_intro loads, for its staged main route and its bonuses")
	await get_tree().physics_frame
	var bot: G2GPlayer = game.players[&"bot"]
	var map: G2GMap = game.current_map_node() as G2GMap
	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var start := bot.global_position

	# A run past the first stage line, put there directly: driving one is what the route
	# sections are for, and what is being asked here is only where R sends it.
	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.RUNNING
	bot.timer.run.stage = 2
	var once := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	var stage_two := game.timers.zones.stage_zone(DotTimerTrack.MAIN, 2)
	_check(once.ok and stage_two != null and bot.global_position.distance_to(stage_two.destination) < 0.01,
		"one R in stage 2 is the start of stage 2", "%s" % bot.global_position)
	_check(not bot.timer.run.is_running(), "and stops the run, because a stage restart is practice")

	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.RUNNING
	bot.timer.run.stage = 1
	var _first := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.global_position.distance_to(start) < 0.01, "in stage 1 it is the start zone")

	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.STOPPED
	bot.timer.run.stage = 3
	var _idle := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.global_position.distance_to(start) < 0.01, "and with no run going it is the start zone too")

	game.timers.set_player_track(&"bot", 1)
	var bonus_spawn := map.spawn_for(1) if map != null else Vector3.ZERO
	var _bonus := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.timer.track == 1 and bot.global_position.distance_to(bonus_spawn) < 1.0,
		"on a bonus one R is the bonus's start", "%s vs %s" % [bot.global_position, bonus_spawn])
	var _twice := game.restart(&"bot", G2GEvents.RESTART_MAIN)
	_check(bot.timer.track == DotTimerTrack.MAIN and bot.global_position.distance_to(start) < 0.01,
		"and two are the main start zone")

	var watcher := game.add_player(&"watcher", "Watcher", false)
	await get_tree().physics_frame
	var _watching := game.spectate.watch(&"watcher", &"bot")
	var _r := game.restart(&"watcher", G2GEvents.RESTART_STAGE)
	_check(not game.spectate.is_spectating(&"watcher"), "R stops spectating: a player who pressed it wants to run")
	game.remove_player(&"watcher")

	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


func _test_bhop_run() -> void:
	_section("a bhop run")
	var bot: G2GPlayer = game.players[&"bot"]
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var finished: Array[DotTimerRun] = []
	var filed := []
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))
	game.run_filed.connect(func(_id: StringName, _run: DotTimerRun, rank: int, reason: String) -> void: filed.append([rank, reason]))

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	await _prestrafe(&"bot", 100)
	bot.controller.stats.reset()

	var top := 0.0
	for i in range(900):
		bot.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
		top = maxf(top, bot.speed())
		if not finished.is_empty():
			break

	_check(bot.timer.runs_started >= 1, "leaving the start pad starts the run")
	# Kept, not gained: a straight-line hopper has no strafe to gain from, so the
	# most it can do is not lose the prestrafe to friction — which a held key on a
	# server with autobhop does, and a tapped one usually does not.
	_check(G2GUnits.to_units(top) >= 240.0, "and hopping keeps the run speed friction would have taken", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.stats.perfect_ratio() > 0.9, "with the hops perfect, because the key is held", "%.2f" % bot.controller.stats.perfect_ratio())

	# A straight-line bot cannot strafe, so it falls at the wide gaps — and the
	# respawn zone then abandons its run, which is correct. Start a fresh one and put
	# it in the finish: the run machinery, not the bot's driving, is under test.
	if finished.is_empty():
		game.spawn_player(&"bot")
		await get_tree().physics_frame

		# Driven until the run starts rather than for a fixed 420 ticks. That number
		# was tuned when `DotTimer.effect_requested` was emitted by nothing, so the
		# map's respawn zone did nothing and a fallen bot simply kept going: now it
		# is put back on the start pad, and a fixed drive long enough to leave the
		# pad is also long enough to fall off, be reset, and be standing on the pad
		# again with no run at the moment the check runs.
		var waited := 0

		while not bot.timer.run.is_running() and waited < 600:
			await _prestrafe(&"bot", 20)
			waited += 20

		_check(bot.timer.run.is_running(), "a fresh run is going", "%d ticks" % waited)
		var end := game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0)
		bot.controller.state.position = end.centre() + Vector3.UP * 0.3
		bot.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
		var forward := DotFpsCommand.new()
		forward.move = Vector2(0.0, 1.0)
		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes once", "%d" % finished.size())
	if finished.size() == 1:
		_check(finished[0].stats.has("max_speed") and float(finished[0].stats["max_speed"]) > 100.0,
			"with statistics in genre units", str(finished[0].stats.get("max_speed")))
	for _i in range(5):
		await get_tree().process_frame
	_check(filed.size() == 1, "and is offered to the store", str(filed))

	var page: DotResult = await game.boards.page_async(&"fastest", {"map": "bhop_g2g_intro", "track": "0", "style": "normal"})
	_check((page.value as Array).size() >= 1 or (filed.size() == 1 and filed[0][1] != ""),
		"and reaches the leaderboard, or says why not", str(filed))
	_done()


## Whether a bot at [param z_units] on the needle should be holding jump this tick.
##
## [b]The map's arithmetic, not a copy of it.[/b] `-z_units` is how far down the route
## the bot has come; the blocks repeat every `BLOCK_LENGTH + NEEDLE_GAP`, occupying the
## first `BLOCK_LENGTH` of each cycle. Jump in the last thirty units of a block and
## nowhere else: airborne the answer stops mattering, because with `auto_hop` a jump is
## taken on the landing tick and the key is long since released by then.
##
## Nothing before the start line, where the bot is building the speed it will spend.
func _needle_jumps_at(z_units: float) -> bool:
	if z_units >= 0.0:
		return false

	var cycle := BhopIntro.BLOCK_LENGTH + BhopIntro.NEEDLE_GAP

	return fposmod(-z_units, cycle) >= BhopIntro.BLOCK_LENGTH - 30.0


## `the needle`: a bonus a scripted bot can run from its start line to its finish.
##
## [b]This is the first route in this repository a bot completes end to end, and the
## map was shaped so that it could be.[/b] Every other bonus here is checked by putting
## a bot on the pad, driving it, and asserting where it ENDED — because a straight-line
## bot cannot strafe, cannot gain speed, and so cannot clear a gap that demands a gain.
## `bhop_g2g_intro`'s main route is exactly such a gap by its tenth block, and the surf
## bonuses need a strafe to stay on a bank at all.
##
## The needle keeps its gap at a constant 96 units, which a player at run speed clears
## without gaining anything, and puts the difficulty in the landing instead. That makes
## it hard for a person and possible for a bot — and a route a bot can run is a route
## whose geometry, zones, stage splits and finish are all checked by something other
## than reading them.
##
## So the assertions here are the ones the other bonuses cannot make: the run starts at
## the start line, BOTH stage splits are crossed in order, and the finish line ends it.
## A block moved 100 units fails this; it fails nothing anywhere else.
func _test_needle_bonus() -> void:
	_section("the needle, run end to end")

	var bot: G2GPlayer = game.players[&"bot"]
	var needle := DotTimerTrack.of_bonus(2)

	_check(game.timers.set_player_track(&"bot", needle), "a player can switch to the needle")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(needle)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"and spawns on its own pad rather than the main one",
		"%.1f m from the main spawn"
			% bot.global_position.distance_to(game.current_map_node().spawn_for(DotTimerTrack.MAIN))
	)

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so `reset = true` inside
	# one never reached this function and "without ever being put back" could not fail.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))

	# [b]Jumped AT the gaps, not held.[/b] This is the whole reason the route is
	# runnable, and it was measured here rather than assumed: a bot that holds jump on a
	# server with `sv_autobunnyhopping 1` leaves the ground on the tick it lands, so
	# `accelerate` never gets a grounded tick to work in and there is no strafe to gain
	# in the air — so it bleeds to `sv_maxairwishspeed`, which is 30 u/s. Driven that way
	# it carried the prestrafe across two gaps and fell at the third, every time.
	#
	# Pressing jump only in the last thirty units of a block keeps it grounded for the
	# rest of each one, which is where `accelerate` puts the speed back. The window is
	# read out of the MAP's own constants rather than written down here, so moving a
	# block moves the bot's jump with it; a copied number would be this tree's own stale
	# list at the size of a test that silently stops proving anything.
	await _prestrafe(&"bot", 120)

	var started := false
	var top := 0.0
	var deepest := 0.0
	var resets := 0

	for _i in range(2600):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_needle_jumps_at(G2GUnits.vector_to_units(bot.global_position).z)
		)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		deepest = minf(deepest, G2GUnits.vector_to_units(bot.global_position).z)

		if reset[0]:
			resets += 1
			reset[0] = false

		if bot.timer.run.is_active():
			started = true

		if not finished.is_empty():
			break

	print("  ..    needle: top %.0f u/s, reached z %.0f u, %d resets" % [top, deepest, resets])

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)

	_check(started, "leaving its pad starts a run on the needle's own track")
	_check(
		deepest <= BhopIntro.needle_end_z(),
		"and the bot reaches the far end of the blocks rather than falling short",
		"reached %.0f u of %.0f" % [deepest, BhopIntro.needle_end_z()]
	)
	_check(
		splits == [1, 2],
		"crossing both of its stage lines, in order",
		"%s, ended at %s u, %s u/s" % [
			str(splits),
			str(G2GUnits.vector_to_units(bot.global_position).round()),
			G2GUnits.format_speed(bot.speed())
		]
	)
	_check(
		finished.size() == 1 and finished[0].track == needle,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished" % finished.size()
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## Whether a bot at [param z_units] on the ridge should be holding jump: in the last
## twenty units of the start pad or of any block, read off the MAP's own list of blocks
## so moving one moves the jump with it. Twenty rather than the needle's thirty because
## the ridge's gaps are wider, and every unit before the lip is a unit off the reach.
func _ridge_jumps_at(z_units: float) -> bool:
	var edges: Array = [BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5]
	for block: Dictionary in BhopStages.ridge_blocks():
		edges.append(float(block["far"]))
	for far: float in edges:
		if z_units >= far and z_units - far <= 20.0:
			return true
	return false


## `the ridge`, `bhop_g2g_stages` bonus 2, run end to end by a bot that cannot strafe:
## up five steps, along a crest that narrows to 80 units, down five drops, through
## both stage splits into the finish, without once being put back. The second route
## here a bot runs from start line to finish, and shaped RUN for the needle's reason.
func _test_ridge_bonus() -> void:
	_section("the ridge, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var ridge := DotTimerTrack.of_bonus(2)
	var zones := game.timers.zones
	_check(zones != null and zones.playable_tracks() == PackedInt32Array([0, 1, 2, 3, 4])
		and zones.stage_count(ridge) == 2,
		"with a second bonus that has two stages (and a third, the weave, and a fourth, the bend)",
		str(zones.playable_tracks()) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", ridge), "a player can switch to the ridge")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so `reset = true` inside
	# one never reached this function and "without ever being put back" could not fail.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	await _prestrafe(&"bot", 120)

	var started := false
	var resets := 0
	var top := 0.0
	var deepest := 0.0
	var highest := -INF
	var entry := G2GUnits.vector_to_units(bot.global_position)
	var descent := _DescentLedger.new()

	for _i in range(4000):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_ridge_jumps_at(G2GUnits.vector_to_units(bot.global_position).z)
		)
		var before := G2GUnits.vector_to_units(bot.global_position)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		var at := G2GUnits.vector_to_units(bot.global_position)
		if not reset[0]:
			descent.add(before.y - at.y, bot.controller.state)
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		deepest = minf(deepest, at.z)
		highest = maxf(highest, at.y)
		if reset[0]:
			resets += 1
			reset[0] = false
		if bot.timer.run.is_active():
			started = true
		if not finished.is_empty():
			break

	print("  ..    ridge: top %.0f u/s, highest %.0f u, reached z %.0f u, %d resets, %s" % [
		top, highest, deepest, resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	# `[surf-ramp-1]`'s question, asked of this route: where its descent comes from.
	var pad := BhopStages.ridge_pad()
	print("  ..    ridge descent: %.0f u covered of a %.0f u route, %s" % [
		entry.z - deepest, entry.z - pad.z, descent.describe()])

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	_check(started, "leaving its pad starts a run on the ridge's own track")
	_check(highest >= 120.0, "the bot climbs to the crest", "highest %.0f u" % highest)
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(
		finished.size() == 1 and finished[0].track == ridge,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())]
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()

## Where every timed route on `bhop_g2g_stages` gets its descent from (`[surf-ramp-1]`).
##
## [b]Printed, not asserted, as `surf_g2g_intro`'s was.[/b] A check named after surf
## is satisfied by a player falling, so the honest detector is the numbers themselves:
## how far a bot got against how long the route is, and how much of the height it lost
## while standing on the surface the route is named after, against in the air.
##
## The main route is a CHAIN nobody scripted can run (it needs a strafe), so its answer
## is read off `_course()`; the ridge's is from `_test_ridge_bonus`'s own drive; the
## surf bonus is driven here, and since `[stages-slabs-1]` asserted: its slabs stand at
## `BONUS_RAMP_PITCH` (50°), past the 45.57° a player can stand on, so a bot that holds into
## the west face rides it to the finish (at 45 it landed on the slope and stopped).
##
## [b]Still timing-dependent, and the cause is not here[/b] (2026-10-12): the rider hangs in
## the crease between the slabs at x 6144 with 11.5 m/s along it and its position frozen
## (dot-player-controller's surf-crease hang), and when it lets go depends on the tick the ride
## starts on. Started 0 to 100 physics frames later it finishes in 1243 to 1288 ticks; 300
## later, it never lets go. In the full run that start tick moves with the machine's load, which
## is the flake. Queue item `g2gfast-surf-crease-hang-1`.
## How far west of the crease between the stages bonus's slabs the descent's bot lets go of
## the face, in units.
const CREASE_RELEASE := 48.0


## Height lost, split by what the player was on when it was lost: a face tilted more
## than 30° (the named surface on a surf route), level ground, or nothing. Height
## GAINED is not subtracted from any bucket -- a jump's rise is not descent -- so the
## three add up to more than start minus finish on a route that climbs.
class _DescentLedger:
	var on_slope := 0.0
	var on_flat := 0.0
	var in_air := 0.0

	func add(dropped: float, state: DotFpsState) -> void:
		if dropped <= 0.0:
			return
		if not state.is_grounded():
			in_air += dropped
		elif state.ground_normal.angle_to(Vector3.UP) > deg_to_rad(30.0):
			on_slope += dropped
		else:
			on_flat += dropped

	func describe() -> String:
		var total := on_slope + on_flat + in_air
		return "%.0f u of descent: %.0f standing on a slope, %.0f on level ground, %.0f in the air (%d%%)" % [
			total, on_slope, on_flat, in_air, int(round(100.0 * in_air / maxf(total, 1.0)))]
