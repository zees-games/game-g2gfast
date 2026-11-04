extends "headless_run_bend.gd"

func _test_surf_run() -> void:
	_section("a surf run")
	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	_check(changed.ok, "the surf map loads")
	game.config.air_accelerate = 150.0
	game.apply_movement()

	var bot: G2GPlayer = game.players[&"bot"]
	await get_tree().physics_frame

	# Off the front of the start platform first: the spawn is 320 units from its
	# edge and the strafing below carries the bot sideways, not forward.
	await _prestrafe(&"bot", 420)

	var airborne := 0
	var top := 0.0
	var started := bot.timer.run.is_active()
	var yaw := 0.0
	var descended := 0

	# Stopped at the pit, and that is not a tidy-up.
	#
	# The map's respawn zone works now — `DotTimer.effect_requested` was declared,
	# forwarded and connected, and emitted by NOTHING, so a bot that missed the ramps
	# fell out of the level and kept falling. Measured over a flat 1500 ticks, every
	# one of those falling ticks counted as "not grounded", and this check passed on
	# a bot that was nowhere near the map. The bot descends for about 500 ticks and
	# then hits the pit; over that window it is airborne for 94% of them, which is
	# what the check was always meant to say.
	#
	# An Array, not a bool: a GDScript lambda captures locals by value, so a flag set
	# inside a signal handler reads false outside it — and the first version of this
	# fix broke out of nothing and reported "468 of 1500".
	var reset: Array[bool] = [false]
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.effect_requested.connect(on_reset)

	# Where the bot actually gets to, so the assertions below can be read against it.
	var entry_z := bot.global_position.z
	var deepest_z := entry_z
	var splits: Array[int] = []
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	bot.timer.stage_reached.connect(on_stage)

	for i in range(1500):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		if bot.timer.run.is_active():
			started = true
		if not bot.controller.state.is_grounded():
			airborne += 1
		top = maxf(top, bot.speed())
		descended += 1
		deepest_z = minf(deepest_z, bot.global_position.z)

		if reset[0]:
			break

	game.timers.effect_requested.disconnect(on_reset)
	bot.timer.stage_reached.disconnect(on_stage)

	# [b]The number nobody had, PRINTED rather than asserted.[/b] Every check below
	# passes, and every one of them is satisfied by a bot that is FALLING: not grounded
	# because it is in mid-air, "surf speed" because that is what four seconds of
	# gravity is worth, and the respawn zone catching it is asserted as a feature. What
	# none of them says is how much of this route was ridden, and the answer is a
	# under 5% of it with neither split crossed.
	#
	# The cause is the map rather than the bot: `G2GGeometry.ramp` rotates about
	# `Vector3.FORWARD`, which banks a slab in X and Y and leaves its Z extent
	# horizontal, so both of this map's ramps are LEVEL along their length and give a
	# player nothing. The descent comes from the stepped valley floor between them. That
	# is `[surf-ramp-1]`, and it is the same finding game-playground's `pg_surf_intro`
	# made about itself — these two maps were built the same way.
	#
	# The main run is deliberately NOT reshaped: it has records against it and a scored
	# route is Christian's to change. `the fall line` below is the route on this map
	# where the answer is the ramp.
	var travelled := entry_z - deepest_z
	var route := G2GUnits.to_metres(8192.0)
	print(
		"        the main run: %.1f m of a %.0f m route, %d of 2 splits, top %s u/s"
		% [travelled, route, splits.size(), G2GUnits.format_speed(top)]
	)

	_check(
		reset[0],
		"missing the ramps drops the bot into the pit, which puts it back",
		"%d ticks" % descended
	)

	_check(started, "leaving the start platform starts a run")
	_check(
		airborne > descended * 6 / 10,
		"most of the descent is spent not grounded, which is surf",
		"%d of %d ticks" % [airborne, descended]
	)
	_check(G2GUnits.to_units(top) > 500.0, "and the bot reaches surf speed, twice its run speed", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.motor.stuck_ticks == 0, "without the slide ever running out of iterations")
	game.config.air_accelerate = 1000.0
	game.apply_movement()
	_done()


func _test_bonus_track() -> void:
	_section("the bonus track")
	var bot: G2GPlayer = game.players[&"bot"]
	_check(game.timers.set_player_track(&"bot", DotTimerTrack.of_bonus(1)), "a player can switch to the bonus")
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var spawn := game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1))
	_check(bot.global_position.distance_to(spawn) < 1.0, "and spawns at the bonus's own spawn")
	_check(bot.timer.track == DotTimerTrack.of_bonus(1), "and their timer is on it")

	await _test_single_bank()
	await _test_transfer_bonus()

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	_done()


## Bonus 1 on the surf map, driven from its pad into its finish.
##
## [b]A bank ridden by holding into it, which is the one surf skill a scripted bot has.[/b]
## The bank is level along its length, so nothing but the entry speed carries a rider
## down it, and gravity pulls them toward the low lip the whole way; holding strafe INTO
## the bank (+X) pushes them back up it. So the bot holds right while it is below a line
## on the bank and lets go above it, and never touches forward: forward-and-right is a
## real strafe, it gains speed, and a rider going much over 500 u/s leaves the end of this
## bank above the finish pad's height and lands past it (see below).
##
## The line is read off the map. Only the strip of bank between its low lip and the far
## edge of the finish pad lies over the pad, and the bot rides three quarters of a hull
## up from the lip — inside that strip, and on a line measured to finish from a
## standstill (see the numbers where `line` is set).
##
## [b]What this decides, and what it deliberately does not.[/b] It fails if the bot falls
## off the route (the respawn zone fires), if it never reaches the end of the bank, or
## if it reaches the end and does not finish — every one of which is the geometry being
## wrong. Unlike the transfer below, it asserts NOTHING about a bot that was put back,
## because a check that passes on the respawn is the one `[bonus-run-2]` found passing
## loudest in exactly the case it was written for.
func _test_single_bank() -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var bonus := DotTimerTrack.of_bonus(1)

	game.config.air_accelerate = 150.0
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var lip := SurfIntro.bonus_bank_lip_x()
	# Three quarters of a hull up from the lip. Measured 2026-09-24 from a standstill
	# spawn, once dot-player-controller 94f1c87 had removed the freeze: lines at +8, +16,
	# +24, +64 and +96 finish (1,299 to 1,676 ticks, 1 to 7 stalled slides each); +32,
	# where this sat, and +48 do not -- the rider sheds its forward speed mid-bank and
	# hangs against it. +32 finished here only because the sections before this one
	# leave the bot about 30 u/s of sideways drift, which is not a line to rely on.
	var line := lip + G2GUnits.PLAYER_HALF_WIDTH * 1.5
	var end_z := SurfIntro.bonus_bank_end_z()

	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var reset: Array[bool] = [false]
	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_finish := func(run: DotTimerRun) -> void: finished[0] = run.track == bonus
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	bot.timer.run_started.connect(on_start)
	bot.timer.run_finished.connect(on_finish)
	game.timers.effect_requested.connect(on_reset)

	var ticks := 0
	var rode_to := 0.0
	var ride_y_top := -INF
	var ride_y_low := INF
	var top := 0.0
	var still := 0
	var last := bot.global_position
	var duplicates_before := bot.controller.motor.duplicate_plane_ticks

	for i in range(2600):
		var at := G2GUnits.vector_to_units(bot.global_position)
		var c := DotFpsCommand.new()
		c.yaw = 0.0

		if bot.controller.state.is_grounded() and at.y > SurfIntro.START_Y - 64.0:
			# On the pad: across to the line first, then straight off the front, so the
			# bot arrives on the bank already over the strip it is going to ride.
			c.move = Vector2(1.0, 0.0) if at.x < line else Vector2(0.0, 1.0)
		else:
			c.move = Vector2(1.0 if at.x < line else 0.0, 0.0)

		bot.controller.apply_command(c)
		await get_tree().physics_frame
		ticks = i + 1

		at = G2GUnits.vector_to_units(bot.global_position)

		# On the bank: over its length, and with its feet on its face rather than above
		# it — the pad's front lies over the bank's near end, and so does the fall off
		# its far one.
		if at.z >= end_z - 32.0 and absf(at.y - SurfIntro.bonus_bank_surface_y(at.x)) < 32.0:
			rode_to = minf(rode_to, at.z)
			ride_y_top = maxf(ride_y_top, at.y)
			ride_y_low = minf(ride_y_low, at.y)
			top = maxf(top, -G2GUnits.to_units(bot.controller.state.velocity.z))

		# A rider who has not moved in a second and a half is not riding. The freeze
		# this was written for (velocity intact, no ground covered, one duplicate-plane
		# stall every tick) is gone since dot-player-controller 94f1c87; kept, because
		# a stall is exactly what a movement change would bring back.
		still = still + 1 if bot.global_position.distance_to(last) < 0.001 else 0
		last = bot.global_position

		if finished[0] or reset[0] or still > 192:
			break

	# Read before the movement is rebuilt, which starts the counters again.
	var duplicates := bot.controller.motor.duplicate_plane_ticks - duplicates_before

	bot.timer.run_started.disconnect(on_start)
	bot.timer.run_finished.disconnect(on_finish)
	game.timers.effect_requested.disconnect(on_reset)
	game.config.air_accelerate = 1000.0
	game.apply_movement()

	# The `[surf-ramp-1]` answer for this route, printed beside the ride: the bank is
	# level along its length, so the height a rider loses on it is only what holding the
	# line costs, and the descent of the route is the fall off its far end.
	print(
		"        the single bank: rode x %.0f to z %.0f of %.0f, %.0f u of height on the bank, "
		% [line, rode_to, end_z, ride_y_top - ride_y_low]
		+ "forward at up to %.0f u/s, then a %.0f u fall to the pad; %d ticks, %d of them a stalled slide"
		% [top, ride_y_low - SurfIntro.BONUS_FINISH_Y, ticks, duplicates]
	)

	_check(started[0], "leaving its pad starts a run on the single bank's track")
	_check(
		rode_to <= end_z + 32.0,
		"and a bot holding into the bank rides it to its far end",
		"left it at z %.0f of %.0f%s" % [
			rode_to, end_z,
			", frozen in place with %.0f u/s on the clock" % G2GUnits.to_units(bot.speed()) if still > 192 else "",
		]
	)
	_check(
		finished[0] and not reset[0],
		"and lands in the finish, on the bonus's own track, without being put back",
		"%s at %s after %d ticks" % [
			"put back by the respawn zone" if reset[0]
				else ("frozen on the bank" if still > 192 else "did not finish"),
			str(G2GUnits.vector_to_units(bot.global_position).round()),
			ticks,
		]
	)

	await _test_fast_bank_exit(line)

	game.spawn_player(&"bot")
	await get_tree().physics_frame


## A rider leaving bonus 1's bank at 900 u/s comes down in its finish (`[surf-finish-1]`).
##
## [b]Launched rather than ridden[/b], because the bot above holds a line and never
## strafes, so it leaves the bank at a few hundred u/s and could not find out that the
## pad only caught those. Put on the bank's far end at the ridden line and at the top of
## the strip over the pad, just past the bank's end, given 900 u/s along the run and no
## input, and followed until it lands. Armed against the 512-unit pad this replaced: both
## came down in the pit.
func _test_fast_bank_exit(line: float) -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var finish := game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 1)
	# Just clear of the bank's end, so the hull is in the air rather than half on the
	# slab's corner, which snags a launch into a drop straight down past the pad.
	var end_z := SurfIntro.bonus_bank_end_z() - G2GUnits.PLAYER_HALF_WIDTH - 4.0
	var top_x := SurfIntro.BONUS_X + SurfIntro.BONUS_FINISH_SIZE * 0.5 - G2GUnits.PLAYER_HALF_WIDTH
	for x: float in [line, top_x]:
		var from := Vector3(x, SurfIntro.bonus_bank_surface_y(x) + 2.0, end_z)
		bot.teleport(from * G2GUnits.METRES_PER_UNIT, 0.0)
		await get_tree().physics_frame
		bot.controller.state.velocity = Vector3(0.0, 0.0, -900.0 * G2GUnits.METRES_PER_UNIT)
		var landed := Vector3.INF
		for _i in range(300):
			var c := DotFpsCommand.new()
			c.yaw = 0.0
			bot.controller.apply_command(c)
			await get_tree().physics_frame
			var at := G2GUnits.vector_to_units(bot.global_position)
			if at.y < SurfIntro.BONUS_FINISH_Y + 2.0 or (
					bot.controller.state.is_grounded() and at.y < SurfIntro.BONUS_FINISH_Y + 64.0):
				landed = at
				break
		_check(
			finish != null and landed.is_finite() and finish.contains(landed * G2GUnits.METRES_PER_UNIT + Vector3.UP * 0.1),
			"a rider leaving the bank at 900 u/s from x %.0f comes down in its finish" % x,
			"came down at %s; the finish is z %.0f to %.0f" % [
				str(landed.round()), SurfIntro.BONUS_FINISH_NEAR_Z,
				SurfIntro.BONUS_FINISH_NEAR_Z - SurfIntro.BONUS_FINISH_LENGTH]
		)


## Bonus 2 on the surf map: two ramps banked opposite ways, with a gap.
##
## [b]The check that matters is the last one, and it is the only one an assertion
## about the zone file cannot make.[/b] Bonus 1 is a single bank -- get on it, hold
## it, ride it down -- and a bot that can do that can do it on any single bank. This
## route ends the first ramp in mid-air and asks the player to catch a second one
## banked the other way, so a bot that reaches the finish has proved the two pieces
## of geometry actually line up. Numbers that are 200 units out produce a route that
## looks perfect in a screenshot and drops every player into the pit.
func _test_transfer_bonus() -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var transfer := DotTimerTrack.of_bonus(2)

	_check(game.timers.set_player_track(&"bot", transfer), "and to the transfer bonus")

	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(transfer)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"which has a spawn of its own, away from the first bonus's",
		"%.1f m apart" % spawn.distance_to(game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1)))
	)

	var ride: Dictionary = await _transfer_ride(bot, transfer)
	_transfer_verdict(bot, spawn, ride)


## Drives the bot across the transfer; the figures come back in a dictionary.
func _transfer_ride(bot: G2GPlayer, transfer: int) -> Dictionary:
	game.config.air_accelerate = 150.0
	game.apply_movement()

	# Off the pad first, then strafe: the spawn is behind the lip.
	await _prestrafe(&"bot", 300)

	var started := false
	var yaw := 0.0
	var entry := bot.global_position
	var rode := entry
	var travelled := 0.0

	# An Array, because a lambda captures a local by value (docs/gdscript-hazards.md).
	var reset: Array[bool] = [false]

	var watch := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.effect_requested.connect(watch)

	# 2000 ticks is load-bearing: at 1200 the falling bot ended mid-air, above the
	# respawn zone, and the reset check passed by asking about nothing.
	for i in range(2000):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		if bot.timer.run.is_active():
			started = true

		if bot.timer.track == transfer and not bot.timer.run.is_active() and started:
			break

		if reset[0]:
			break

		# Read BEFORE the respawn zone fires, which teleports the bot to the pad.
		rode = bot.global_position
		travelled = maxf(travelled, entry.z - rode.z)

	game.timers.effect_requested.disconnect(watch)
	game.config.air_accelerate = 1000.0
	game.apply_movement()
	return {"started": started, "reset": reset[0], "rode": rode, "travelled": travelled}


func _transfer_verdict(bot: G2GPlayer, spawn: Vector3, ride: Dictionary) -> void:
	var reset: bool = ride["reset"]
	var rode: Vector3 = ride["rode"]

	_check(ride["started"], "leaving its pad starts a run on the bonus's own track")

	# A crude strafer cannot clear this route (see `[bonus-run-2]`); what it proves is
	# that a player who loses the bank is put back rather than falling for ever.
	print(
		"        the transfer: rode %.1f m to y %.1f, %s"
		% [
			ride["travelled"], rode.y,
			"put back on its pad" if reset
				else ("still on the route" if rode.y > G2GUnits.to_metres(START_Y - 1700.0)
					else "below the route's floor and still falling"),
		]
	)

	_check(
		reset and bot.global_position.distance_to(spawn) < 1.0,
		"and a bot that loses the bank is put back on its pad rather than falling for ever",
		"reset=%s, %.1f m from the pad" % [reset, bot.global_position.distance_to(spawn)]
	)

	var surf_zones := game.timers.zones
	_check(
		surf_zones != null and surf_zones.route_problems().is_empty(),
		"and a bonus that is missed puts the player back, like the main track",
		", ".join(surf_zones.route_problems()) if surf_zones else "no zones"
	)


## `surf_g2g_intro`'s third bonus — the route where the descent comes from the ramp.
##
## [b]This exists because of the measurement in [method _test_surf_run].[/b] Both of
## this map's main ramps are banked about the run axis and level along their length, so
## the descent on every other route here comes from the floor; a scripted strafer covers
## under 5% of a 156 m route and crosses neither split, while two checks over it pass about
## a player who is falling into the pit. The fall line is a single face pitched past the
## standable limit and descending ALONG the run, so gravity accelerates the player down
## it — which is the thing the map was supposed to be about and was not.
##
## It is straight, and that is deliberate for the same reason `_test_needle_bonus` gives
## about a constant gap: a scripted bot cannot air-strafe, so a route that needs turning
## is a route no suite ever runs end to end. Here the bot holds forward and nothing else.
func _test_the_fall_line() -> void:
	_section("the fall line — surf_g2g_intro's third bonus")

	var bot: G2GPlayer = game.players[&"bot"]
	var fall := DotTimerTrack.of_bonus(3)
	await _fall_line_route_checks(bot, fall)
	await _fall_line_run(bot)
	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	_done()


func _fall_line_route_checks(bot: G2GPlayer, fall: int) -> void:
	var zones := game.timers.zones

	_check(
		zones != null and zones.playable_tracks() == PackedInt32Array([0, 1, 2, 3]),
		"the surf map has four routes now rather than three",
		str(zones.playable_tracks()) if zones else "no zones"
	)

	# [b]Asked per track, rather than of `problems()`.[/b] A zone carries a track, so a
	# set that is complete for track 0 and partial for track 3 passes `problems()` —
	# which is a per-zone check — while being an unfinishable route. This was four
	# checks walking this track's kinds by name; it is dot-timer's `route_problems()`
	# now, which asks the same of every route. See `[track-zone-1]`.
	_check(
		zones != null and zones.route_tracks().has(fall)
			and zones.route_problems().is_empty(),
		"the fall line has its own start, finish, spawn and pit",
		", ".join(zones.route_problems()) if zones else "no zones"
	)

	_check(
		zones != null and zones.stage_count(fall) == SurfIntro.FALL_SPLITS.size(),
		"and a split for each fraction the map names",
		"%d" % (zones.stage_count(fall) if zones else -1)
	)

	# The face has to be unstandable or none of this is surf, and it is asked of the
	# tunables this game actually runs a player with rather than of a number written
	# down a second time here. The pitch is the one thing about this route that cannot
	# be changed without changing what the route IS.
	var max_slope: float = bot.controller.tunables.max_slope_angle
	_check(
		SurfIntro.FALL_PITCH > max_slope,
		"its bed is steeper than a player can stand on",
		"%.0f° against %.1f°" % [SurfIntro.FALL_PITCH, max_slope]
	)

	# A player here is the fastest thing on the map, so it is the route where a thin
	# line is certain to be passed through between ticks rather than merely likely.
	_check(
		zones != null and zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate).is_empty(),
		"and no zone a 3500 u/s player crosses without entering"
	)

	_check(game.timers.set_player_track(&"bot", fall), "the track switches to the fall line")
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(fall)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"which spawns on its own pad, away from the other three",
		"%.1f m from the main spawn" % spawn.distance_to(game.current_map_node().spawn_for(0))
	)


func _fall_line_run(bot: G2GPlayer) -> void:
	game.config.air_accelerate = 150.0
	game.apply_movement()

	# Arrays, because a GDScript lambda captures a local by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var reset: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	bot.timer.run_started.connect(on_start)
	bot.timer.stage_reached.connect(on_stage)
	bot.timer.run_finished.connect(on_finish)
	game.timers.effect_requested.connect(on_reset)

	# Off the pad, then nothing but forward. No jump pattern and no strafe: on a face
	# nobody can stand on there is no ground to leave.
	await _prestrafe(&"bot", 60)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = 0.0

	var ticks := 0
	var airborne := 0
	var top := 0.0
	var entry_z := bot.global_position.z
	var entry_y := bot.global_position.y

	for i in range(1400):
		bot.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i + 1

		if not bot.controller.state.is_grounded():
			airborne += 1

		top = maxf(top, bot.speed())

		if finished[0] or reset[0]:
			break

	bot.timer.run_started.disconnect(on_start)
	bot.timer.stage_reached.disconnect(on_stage)
	bot.timer.run_finished.disconnect(on_finish)
	game.timers.effect_requested.disconnect(on_reset)

	game.config.air_accelerate = 1000.0
	game.apply_movement()

	# The whole difference between the two routes, stated as a number and printed
	# beside the main run's. A detail line shows only when a check fails, and this is
	# the figure every future question about this map is really about.
	print(
		"        the fall line: %.1f m travelled, chute is %.0f m, in %d ticks, top %s u/s"
		% [
			entry_z - bot.global_position.z,
			G2GUnits.to_metres(SurfIntro.FALL_RUN),
			ticks,
			G2GUnits.format_speed(top),
		]
	)

	_fall_line_verdict(bot, {
		"started": started[0], "finished": finished[0], "reset": reset[0], "splits": splits,
		"ticks": ticks, "top": top, "entry_y": entry_y,
	})


func _fall_line_verdict(bot: G2GPlayer, r: Dictionary) -> void:
	var started: bool = r["started"]
	var finished: bool = r["finished"]
	var reset: bool = r["reset"]
	var splits: Array = r["splits"]
	var ticks: int = r["ticks"]
	var top: float = r["top"]
	var entry_y: float = r["entry_y"]
	_check(started, "leaving its pad starts a run on the fall line's own track")
	_check(
		G2GUnits.to_units(top) > 1200.0,
		"the bed makes the player fast, which this map's own ramps never do",
		"%s u/s" % G2GUnits.format_speed(top)
	)
	_check(splits == [1, 2], "it crosses both splits, in order", str(splits))
	_check(
		finished and not reset,
		"and reaches the finish holding nothing but forward",
		"gave up at tick %d, y %.1f, z %.1f%s" % [
			ticks, bot.global_position.y, bot.global_position.z,
			", put back by the respawn zone" if reset else "",
		]
	)
	_check(not bot.timer.run.is_active(), "and the run is over rather than still running")
	_check(
		bot.controller.motor.stuck_ticks == 0,
		"without the slide ever running out of iterations",
		"%d stuck ticks" % bot.controller.motor.stuck_ticks
	)
	_check(
		entry_y - bot.global_position.y > G2GUnits.to_metres(SurfIntro.fall_drop() * 0.9),
		"and the descent is the ramp's, not a fall past it",
		"%.1f m of %.1f m" % [
			entry_y - bot.global_position.y, G2GUnits.to_metres(SurfIntro.fall_drop())
		]
	)


# --- The ghost -------------------------------------------------------------

static func _fake_replay(map_id: StringName, seconds: float, tick_rate: int) -> DotTimerReplay:
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = tick_rate
	replay.time = seconds
	replay.player_name = "Ghost"
	var frames := int(seconds * float(tick_rate))
	for i in range(frames):
		var t := float(i) / float(maxi(frames - 1, 1))
		replay.append(Vector3(0.0, 1.0, 7.0 - 30.0 * t), 90.0 * t, 0.0)
	return replay


func _test_ghost() -> void:
	_section("the world-record ghost")
	var map_id: StringName = game.maps.current.id
	var replay := _fake_replay(map_id, 3.0, game.tick_rate)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.track = DotTimerTrack.MAIN
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 3.0

	_check(game.replays.offer(replay, record), "a record's replay is kept")
	var slower := _fake_replay(map_id, 4.0, game.tick_rate)
	record.time = 4.0
	_check(not game.replays.offer(slower, record), "a slower one is not")
	_check(game.replays.best(map_id, 0, &"normal") == replay, "and the best is the fast one")

	var ghost := game.spawn_ghost()
	_check(ghost != null and ghost.replay != null and ghost.timer == null, "the ghost is a player with a replay and no timer")
	_check(ghost != null and ghost.display_name.begins_with("WR 0:03.000"), "named for the record", ghost.display_name if ghost else "")
	var before := ghost.global_position if ghost != null else Vector3.ZERO
	for _i in range(64):
		await get_tree().physics_frame
	var after := ghost.global_position if ghost != null else Vector3.ZERO
	_check(before.distance_to(after) > 1.0, "and it runs the map", "%.2f m in half a second" % before.distance_to(after))
	_check(ghost != null and G2GUnits.to_units(ghost.speed()) > 100.0, "at the replay's speed", G2GUnits.format_speed(ghost.speed()) if ghost else "")
	_check(game.players.size() >= 2 and game.timers.player(G2GGame.GHOST_ID) == null, "without a timer to feed")

	_ghost_persistence(map_id, replay, record)

	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	# The surf run above may have filed a record of its own, in which case surf has
	# a ghost too — its own, never the bhop map's.
	var swapped := game.ghost()
	_check(changed.ok and (swapped == null or swapped.replay.replay.map_id == &"surf_g2g_intro"),
		"a map change swaps the ghost for that map's own, or none",
		str(changed.error) if not changed.ok else String(swapped.replay.replay.map_id) if swapped else "")
	changed = await game.change_map(map_id)
	for _i in range(4):
		await get_tree().process_frame
	_check(changed.ok and game.ghost() != null, "and it is back with its map")

	_look_guard()
	_done()


func _ghost_persistence(map_id: StringName, replay: DotTimerReplay, record: DotTimerRecord) -> void:
	# Persistence: a second keeper over the same directory finds it.
	var dir := "user://g2gfast-test-replays-%d" % Time.get_ticks_usec()
	var keeper := G2GReplays.new()
	_check(keeper.setup(dir).ok, "a keeper opens a directory")
	record.time = 3.0
	_check(keeper.offer(replay, record), "and writes a replay there")
	var again := G2GReplays.new()
	again.setup(dir)
	var found := again.best(map_id, 0, &"normal")
	_check(found != null and found.frames.size() == replay.frames.size() and absf(found.time - 3.0) < 0.001,
		"which a fresh keeper reads back", str(found.describe()) if found else "none")
	_check(again.best(&"surf_kitsune2", 0, &"normal") == null and again.best(&"surf_kitsune3", 0, &"normal") == null,
		"and two ids that differ by a digit do not share a file")
	for file in DirAccess.get_files_at(dir.path_join("replays")):
		DirAccess.remove_absolute(dir.path_join("replays").path_join(file))
	DirAccess.remove_absolute(dir.path_join("replays"))
	DirAccess.remove_absolute(dir)


func _look_guard() -> void:
	# [b]The look guard, on the predicate rather than through a client.[/b] Nothing in
	# this suite stands a `G2GClient` up, so the honest thing this can check is the
	# contract the motion handler branches on. `Input.mouse_mode` is not the thing to
	# assert against: the dummy display server pins it to VISIBLE and drops every write
	# without erroring, which is why `game-arena`'s identical guard has never been
	# exercised by anything either.
	var look := G2GClient.new()
	_check(not look.mouse_drives_view(),
		"a released cursor is not a look input")
	look.mouse_capture_override = true
	_check(look.mouse_drives_view(),
		"and a captured one is")
	# A modal that holds the pointer keeps the click-to-capture from taking it back.
	look.platform = DotGameClient.new()
	_check(look.click_may_capture(), "a click may capture with no modal open")
	look.platform.hold_pointer(&"shop")
	_check(not look.click_may_capture(), "but not while a modal holds the pointer")
	look.platform.release_pointer(&"shop")
	_check(look.click_may_capture(), "and again once it is released")
	look.platform.free()
	look.free()


# --- Progression ------------------------------------------------------------
