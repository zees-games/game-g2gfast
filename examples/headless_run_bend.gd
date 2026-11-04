extends "headless_run_reach.gd"

func _test_stages_descent() -> void:
	_section("where bhop_g2g_stages' descent comes from")

	var course := BhopStages._course()
	var up := 0.0
	var down := 0.0
	var y := BhopStages.FLOOR_Y
	for block: Dictionary in course:
		var step := float(block["y"]) - y
		if step > 0.0:
			up += step
		else:
			down -= step
		y = float(block["y"])
	print("  ..    main: not ridden (a CHAIN needs a strafe no scripted bot has); the finish is %.0f u under the start, %.0f u down in stage 4's drops and %.0f u up in stage 3's climb, every unit of it between blocks, in the air" % [
		BhopStages.FLOOR_Y - y, down, up])

	var on_stages: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(on_stages.ok, "the stages map is loaded for its bonus")
	if not on_stages.ok:
		_done()
		return
	# The movement a fresh server has: the sections before this one set what they need and
	# do not all put it back (in the full run the ride got two thirds of the way; alone, all).
	var fresh := G2GConfig.new()
	for field in G2GConfig.MOVEMENT_FIELDS:
		game.config.set(field, fresh.get(field))
	game.apply_movement()
	var bot: G2GPlayer = game.players[&"bot"]
	var surf := DotTimerTrack.of_bonus(1)
	_check(game.timers.set_player_track(&"bot", surf), "a player can switch to the surf bonus")
	game.spawn_player(&"bot")
	# A command of nothing for the tick after the spawn. Without it the controller repeats the
	# last command it was given (a starved tick does), which is the previous section's: in the
	# full run the bot began the ride turned to -81.6 degrees and already moving, so where it
	# went depended on which sections ran before this one and how they ended.
	bot.controller.apply_command(DotFpsCommand.new())
	await get_tree().physics_frame

	var reset: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true
	var on_finished := func(_run: DotTimerRun) -> void: finished[0] = true
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	# Off the pad's front edge over the west slab rather than down the middle: the two
	# slabs' low edges are 318 u apart, and a player walking straight off the pad falls
	# between them into the pit. So sideways first, to 200 u west of the centre line,
	# then forward along -Z and nothing else.
	var entry := G2GUnits.vector_to_units(bot.global_position)
	var deepest := entry.z
	var descent := _DescentLedger.new()
	var ticks := 0

	# Then the single-bank rule (`_test_single_bank`): once on the face, hold west (into it)
	# while below a line partway up it, let go above, and forward throughout.
	var hold_line := BhopStages.BONUS_X - 520.0
	for i in range(2400):
		var at := G2GUnits.vector_to_units(bot.global_position)
		var c := DotFpsCommand.new()
		c.yaw = 0.0
		if at.y > 900.0:
			# On the pad: across to the west slab's side, then off its FRONT edge (its side
			# is in front of where the slabs begin).
			c.move = Vector2(-1.0, 0.0) if at.x > BhopStages.BONUS_X - 200.0 else Vector2(0.0, 1.0)
		else:
			# Never into the face once in the crease between the slabs: pressed into one face
			# with the other underneath, the motor's duplicate-plane early-out pins the rider
			# there (dot-player-controller's crease hang), and whether a ride reached the crease
			# pressing or not depended on what the sections before this one left in the world.
			var into := at.x > hold_line and at.x < BhopStages.BONUS_X - CREASE_RELEASE
			c.move = Vector2(-1.0 if into else 0.0, 1.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		ticks = i + 1
		var now := G2GUnits.vector_to_units(bot.global_position)
		if reset[0] or finished[0]:
			break
		descent.add(at.y - now.y, bot.controller.state)
		deepest = minf(deepest, now.z)

	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var finish_z := BhopStages.START_Z - 3072.0
	print("  ..    surf bonus: %.0f u covered of a %.0f u route in %d ticks, %s; %s" % [
		entry.z - deepest, entry.z - finish_z, ticks, descent.describe(),
		"finished" if finished[0] else ("put back by the pit" if reset[0] else "not finished")])
	_check(finished[0] and not reset[0], "the surf bonus is surfed: a bot holding into the face rides it to the finish",
		"%.0f u of %.0f, %s" % [entry.z - deepest, entry.z - finish_z, "put back by the pit" if reset[0] else "not finished"])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## Which hairpin piece a bot at [param at] (x, z units) is over, never going backwards
## from [param current]: -1 is the start pad. A piece counts once the bot is inside its
## footprint, which it is only on landing or on the way down to it.
func _hairpin_piece(blocks: Array, current: int, at: Vector2) -> int:
	for i in range(blocks.size() - 1, current, -1):
		var centre: Vector3 = blocks[i]["centre"]
		var half: Vector2 = (blocks[i]["extent"] as Vector2) * 0.5
		if absf(at.x - centre.x) <= half.x and absf(at.y - centre.z) <= half.y:
			return i
	return current


## `the weave`, `bhop_g2g_stages` bonus 3: fourteen blocks, each off to the other side of
## the one before, run end to end by the hairpin's kind of bot.
##
## [b]It takes the line, not the zigzag.[/b] It faces a point just inside the inner edge
## of the block it is jumping for (the edge on the centre line), and jumps in the last
## twenty units before its line of travel leaves the block it is on.
## That is the route's whole question. Holding forward along -Z, as the ridge's bot does,
## lands between the blocks on the first jump. The pace is asserted as well as the
## finish: covering the route at under 80% of run speed would mean the bot stopped to
## line jumps up, and a route that only works at a crawl is not a RUN line.
func _test_weave_bonus() -> void:
	_section("the weave, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var weave := DotTimerTrack.of_bonus(3)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(weave) == 2,
		"with a third bonus that has two stages",
		str(zones.stage_count(weave)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", weave), "a player can switch to the weave")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopStages.weave_blocks()
	var pad := BhopStages.weave_pad()
	# The start pad as piece -1, so the bot has something to leave from.
	var start_rect := Rect2(BhopStages.WEAVE_X - 128.0, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5,
		256.0, BhopStages.RIDGE_PAD_LENGTH)

	var route_length := 0.0
	var last := Vector2(BhopStages.WEAVE_X, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5)
	for block: Dictionary in blocks:
		var middle := Vector2((block["centre"] as Vector3).x, (block["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle
	route_length += last.distance_to(Vector2(pad.x, pad.z + 192.0))

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so a bool set inside
	# one never reaches this function.
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

	var resets := 0
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)
	var goal := 0

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)
		var rect := start_rect if piece < 0 else _block_rect(blocks[piece])
		# The line a player takes: past the blocks' INNER corners, the ones on the
		# centre line, because that is where one block meets the next. So aim 32 units
		# in from the inner edge of the block it is jumping for, 48 past its near edge,
		# on the ground and in the air alike; and keep that block as the aim until
		# landing on it, because passing over its footprint on the way down is not
		# reaching it.
		var grounded := bot.controller.state.is_grounded()
		if grounded and rect.has_point(at):
			goal = piece + 1
		var target := Vector2(pad.x, pad.z + 128.0)
		if goal < blocks.size():
			var next: Vector3 = blocks[goal]["centre"]
			var half: Vector2 = (blocks[goal]["extent"] as Vector2) * 0.5
			var inward := -signf(next.x - BhopStages.WEAVE_X)
			target = Vector2(next.x + inward * (half.x - 32.0), next.z + half.y - 48.0)
		var aim := target - at
		var to_lip := _rect_exit(rect, at, aim.normalized()) if grounded and rect.has_point(at) else -1.0
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
			goal = 0
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    weave: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, block %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, furthest + 1, blocks.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest == blocks.size() - 1, "the bot reaches the last block", "block %d of %d" % [furthest + 1, blocks.size()])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(finished.size() == 1 and finished[0].track == weave,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every jump is taken on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## `the bend`, `bhop_g2g_stages` bonus 4: ten blocks round a 640-unit left-hand arc,
## each 22.5 degrees on from the last (30 on the drops), climbing then dropping onto a finish that faces
## nearly back the way the run began.
##
## [b]It turns on every jump.[/b] It faces the middle of the block it is jumping for,
## 32 units short of it, and jumps in the last twenty units before its line of travel
## leaves the block it is on -- both measured in that block's own frame, since every
## block is turned. Holding one heading, as the ridge's bot does, leaves the arc at the
## second block. The pace is asserted as for the weave: a RUN line that only works at a
## crawl is not one.
func _test_bend_bonus() -> void:
	_section("the bend, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var bend := DotTimerTrack.of_bonus(4)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(bend) == 2,
		"with a fourth bonus that has two stages",
		str(zones.stage_count(bend)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", bend), "a player can switch to the bend")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopStages.bend_blocks()
	var pad: Dictionary = BhopStages.bend_pad()
	var pad_centre: Vector3 = pad["centre"]
	# The start pad and the finish pad as pieces too, in the blocks' own shape.
	var start := {"centre": Vector3(BhopStages.BEND_X, 0.0, BhopStages.START_Z), "yaw": 0.0,
		"width": 256.0, "length": BhopStages.RIDGE_PAD_LENGTH}
	var pieces: Array = []
	for block: Dictionary in blocks:
		pieces.append({"centre": block["centre"], "yaw": block["yaw"], "width": block["width"],
			"length": BhopStages.BEND_BLOCK_LENGTH})
	pieces.append({"centre": pad_centre, "yaw": pad["yaw"], "width": 256.0, "length": 384.0})

	var route_length := 0.0
	var last := Vector2(BhopStages.BEND_X, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5)
	for piece_of: Dictionary in pieces:
		var middle := Vector2((piece_of["centre"] as Vector3).x, (piece_of["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
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

	var resets := 0
	var fell: Array[String] = []
	var furthest := -1
	var piece := -1
	var goal := 0
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		for i in range(pieces.size() - 1, piece, -1):
			if _bend_local(pieces[i], at).has_point(Vector2.ZERO):
				piece = i
				break
		var on: Dictionary = start if piece < 0 else pieces[piece]
		var grounded := bot.controller.state.is_grounded()
		var standing := _bend_local(on, at).has_point(Vector2.ZERO)
		if grounded and standing:
			goal = piece + 1
		var next: Dictionary = pieces[mini(goal, pieces.size() - 1)]
		var next_centre: Vector3 = next["centre"]
		var target := Vector2(next_centre.x, next_centre.z)
		var aim := target - at
		if goal < pieces.size() - 1:
			aim = aim.normalized() * maxf(aim.length() - 32.0, 1.0)
		var to_lip := -1.0
		if grounded and standing:
			var local := _bend_local(on, at)
			var direction := aim.normalized().rotated(deg_to_rad(float(on["yaw"])))
			to_lip = _rect_exit(local, Vector2.ZERO, direction)
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0 and goal < pieces.size())
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			fell.append("from piece %d at %s" % [piece, str(here.round())])
			reset[0] = false
			piece = -1
			goal = 0
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    bend: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, piece %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, furthest + 1, pieces.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest >= blocks.size() - 1, "the bot reaches the last block", "piece %d of %d" % [furthest + 1, pieces.size()])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets: %s" % [resets, ", ".join(fell)])
	_check(finished.size() == 1 and finished[0].track == bend,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every jump is taken on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## A bend piece's footprint in its own frame (x across, y along; forward is -y), offset so
## that [param at] is the origin: has_point(ZERO) is "standing over it", and _rect_exit
## from ZERO is the distance to its edge.
static func _bend_local(piece: Dictionary, at: Vector2) -> Rect2:
	var centre: Vector3 = piece["centre"]
	var d := (at - Vector2(centre.x, centre.z)).rotated(deg_to_rad(float(piece["yaw"])))
	var half := Vector2(float(piece["width"]), float(piece["length"])) * 0.5
	return Rect2(-half - d, half * 2.0)


## A block's footprint as a Rect2 in (x, z).
static func _block_rect(block: Dictionary) -> Rect2:
	var centre: Vector3 = block["centre"]
	var extent: Vector2 = block["extent"]
	return Rect2(Vector2(centre.x, centre.z) - extent * 0.5, extent)


## How far from [param at], along the unit [param direction], until it leaves [param rect].
static func _rect_exit(rect: Rect2, at: Vector2, direction: Vector2) -> float:
	var best := INF
	for axis in 2:
		var d := direction[axis]
		if absf(d) < 1e-6:
			continue
		var bound := rect.end[axis] if d > 0.0 else rect.position[axis]
		best = minf(best, (bound - at[axis]) / d)
	return best


## The route's length along its centre line: pad edge, block to block, into the pad.
func _hairpin_route_length(blocks: Array, pad: Vector3) -> float:
	var route_length := 0.0
	var last := Vector2(BhopIntro.HAIRPIN_X, BhopIntro.START_Z)
	for block: Dictionary in blocks:
		var middle := Vector2((block["centre"] as Vector3).x, (block["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle
	return route_length + last.distance_to(Vector2(pad.x, pad.z))


## The command that steers the bot from `at` on `piece` of the hairpin.
func _hairpin_command(blocks: Array, pad: Vector3, piece: int, at: Vector2) -> DotFpsCommand:
	var exit := Vector2(BhopIntro.HAIRPIN_X, BhopIntro.START_Z)
	var heading := Vector2(0.0, -1.0)
	if piece >= 0:
		exit = blocks[piece]["exit"]
		heading = blocks[piece]["heading"]

	# Aim through the middle of the edge the route leaves by, and past it, so the bot
	# arrives at the lip square to the gap rather than sliding along it. Once past
	# the lip it is in the air over the gap, and aims at the far edge of the next
	# piece instead: a point it has already reached is a point it hovers over.
	var to_lip := (exit - at).dot(heading)
	var aim := exit + heading * 96.0 - at
	if to_lip < 0.0:
		aim = ((blocks[piece + 1]["exit"] as Vector2) if piece + 1 < blocks.size()
			else Vector2(pad.x, pad.z)) - at
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
	c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
	return c


## What the hairpin run must have done.
func _check_hairpin_run(started: bool, furthest: int, block_count: int, highest: float,
		splits: Array[int], resets: int, finished: Array[DotTimerRun]) -> void:
	_check(started, "leaving its pad starts a run on the hairpin's own track")
	_check(furthest == block_count - 1, "the bot reaches the last block, both corners behind it",
		"block %d of %d" % [furthest + 1, block_count])
	_check(highest >= 112.0, "and climbs to the top corner", "highest %.0f u" % highest)
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(
		finished.size() == 1 and finished[0].track == DotTimerTrack.of_bonus(3),
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units((game.players[&"bot"] as G2GPlayer).global_position).round())]
	)


func _print_hairpin(covered: float, route_length: float, top: float, highest: float, furthest: int,
		block_count: int, resets: int, finished: Array[DotTimerRun]) -> void:
	print("  ..    hairpin: covered %.0f u of a %.0f u route, top %.0f u/s, highest %.0f u, block %d of %d, %d resets, %s" % [
		covered, route_length, top, highest, furthest + 1, block_count, resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])


## `the hairpin`, `bhop_g2g_intro` bonus 3, run end to end by a bot that cannot strafe:
## out, a right turn onto a climb, a right turn at the top, and back down a stair of
## drops, through both corner splits into the finish without once being put back.
##
## [b]The first route here a bot has to STEER.[/b] The needle's and the ridge's bots
## hold forward along -Z; this one reads the map's own list of blocks, aims at the edge
## of whichever block it is over that the route leaves by, and jumps in the last twenty
## units before that edge — so on a corner it lands going one way, runs a diagonal to
## the exit edge and leaves going the other. Moving a block or a corner moves the aim
## and the jump with it.
func _test_hairpin_bonus() -> void:
	_section("the hairpin, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(changed.ok, "the intro map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var hairpin := DotTimerTrack.of_bonus(3)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(hairpin) == 2,
		"with a third bonus that has two stages",
		str(zones.stage_count(hairpin)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", hairpin), "a player can switch to the hairpin")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopIntro.hairpin_blocks()
	var pad := BhopIntro.hairpin_pad()
	var route_length := _hairpin_route_length(blocks, pad)

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

	var started := false
	var resets := 0
	var top := 0.0
	var highest := -INF
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(5000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)

		var c := _hairpin_command(blocks, pad, piece, at)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		covered += Vector2(now.x - previous.x, now.z - previous.z).length()
		previous = now
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		highest = maxf(highest, now.y)
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
		if bot.timer.run.is_active():
			started = true
		if not finished.is_empty():
			break

	_print_hairpin(covered, route_length, top, highest, furthest, blocks.size(), resets, finished)

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	_check_hairpin_run(started, furthest, blocks.size(), highest, splits, resets, finished)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## `the stutter`, `bhop_g2g_intro` bonus 4, run end to end by the hairpin's kind of bot:
## three flat stones and a runway, four rollers and a runway, and five drops of 48 onto
## stones with one runway among them, through both runway splits into the finish.
##
## [b]What it proves is that every stone CATCHES a lip jump.[/b] The bot jumps in the last
## twenty units of whatever it is on, so each landing is where a jump from the lip at the
## speed it has comes down; a stone sized too short throws it off the far end, one sized
## too long lands it early, and either way the next jump is taken from the wrong place.
## The height it reaches at the top of the rollers and the pace are asserted as well as
## the finish, so a route that only works at a crawl fails.
func _test_stutter_bonus() -> void:
	_section("the stutter, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(changed.ok, "the intro map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var stutter := DotTimerTrack.of_bonus(4)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(stutter) == 2,
		"with a fourth bonus that has two stages",
		str(zones.stage_count(stutter)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", stutter), "a player can switch to the stutter")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopIntro.stutter_blocks()
	var pad := BhopIntro.stutter_pad()
	var route_length := BhopIntro.START_Z - (pad.z - BhopIntro.STUTTER_FINISH_LENGTH * 0.5)

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value.
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

	var resets := 0
	var stood: Dictionary = {}
	# How far onto each block the bot came down, from its near edge: what a stone has to
	# contain. Printed, not asserted; the assertion is that it stood on every block.
	var landed_at: Array[float] = []
	var was_grounded := true
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)

		var exit := Vector2(BhopIntro.STUTTER_X, BhopIntro.START_Z)
		if piece >= 0:
			exit = blocks[piece]["exit"]
		# Straight down -Z, aimed at the route's centre line so a drift is corrected.
		var to_lip := at.y - exit.y
		var aim := Vector2(BhopIntro.STUTTER_X, at.y - 256.0) - at
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		# Stood ON it: grounded, over its footprint, at its height. Passing over a stone
		# in the air is not landing on it.
		if piece >= 0 and bot.controller.state.is_grounded() \
				and absf(now.y - (blocks[piece]["centre"] as Vector3).y) < 4.0:
			stood[piece] = true
		var grounded := bot.controller.state.is_grounded()
		if grounded and not was_grounded and piece >= 0 \
				and absf(now.y - (blocks[piece]["centre"] as Vector3).y) < 4.0:
			var near: float = (blocks[piece]["exit"] as Vector2).y + (blocks[piece]["extent"] as Vector2).y
			landed_at.append(near - now.z)
		was_grounded = grounded
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var shallow := INF
	var deep := -INF
	for d in landed_at:
		shallow = minf(shallow, d)
		deep = maxf(deep, d)
	print("  ..    stutter: %d landings on its blocks, %.0f to %.0f u past the near edge: %s" % [
		landed_at.size(), shallow, deep, str(landed_at.map(func(d: float) -> int: return roundi(d)))])
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    stutter: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, stood on %d, block %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, stood.size(), furthest + 1, blocks.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest == blocks.size() - 1, "the bot reaches the last stone", "block %d of %d" % [furthest + 1, blocks.size()])
	_check(stood.size() == blocks.size(), "standing on every one of its blocks: each stone catches a lip jump",
		"stood on %d of %d: %s" % [stood.size(), blocks.size(), str(stood.keys())])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(finished.size() == 1 and finished[0].track == stutter,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every stone is left on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()
