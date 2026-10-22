extends Node

const G2GGame := preload("g2g_game.gd")
const G2GPaths := preload("g2g_paths.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GRouteBot := preload("g2g_route_bot.gd")
const G2GSurfCourse := preload("g2g_surf_course.gd")
const G2GUnits := preload("g2g_units.gd")

## The server's bots: players with no peer who ride one stage of the map, over and over, so a
## server somebody opens in a browser has somebody on the course and a newcomer has a line to
## watch.
##
## [b]What a bot rides.[/b] On a map with a surf cache (`maps/routes/<id>.surf.json`, written
## by `tools/surf_plan.tscn`) it rides the cache's first stage with dot-bot's [DotBotSurfPilot],
## planned and vetoed on a copy of its own motor ([method G2GSurfCourse.simulator_for]). On any
## other map it is the rule-based route bot ([code]g2g_route_bot.gd[/code]) on the whole run,
## spawn to finish, along the map's route file when there is one: on a surf ramp that bot looks
## along the face and strafes into it, which is all this game had before the pilot, and on an
## A-frame it wedges on the ridge. Either way the stage is [G2GSurfCourse], read from the
## timer's zones, and it decides when the ride is over.
##
## [b]Put back, never filed.[/b] A bot has no timer ([method G2GGame.add_player] with
## [code]bot[/code]): a records board with a bot on it is a board nobody trusts, and its
## statistics and achievements are nobody's. So the timer's zones never move it either; the
## course does instead. Arriving in the next stage (or the finish, or a door into either), a
## pit, falling under the course, or [constant RIDE_SECONDS] without arriving all put it back at
## the stage's start, facing the way `!s<n>` faces a player, and the pilot starts a new ride.
##
## [b]Before the moves[/b] ([method drive] from `G2GGame._simulate_tick`): a command applied
## after them would be one tick late on every tick, which on a ramp the pilot planned to the
## tick is a different ride.
##
## How many there are is dot-server's [DotBotQuota] (`bot_quota`, default 0 here, so a timer
## server has no bots until its operator asks), kept in step by `G2GModule`.

const CHANNEL := "g2g.bots"

## Session ids from here up, clear of a person's and of the ghost's (u900000001).
const FIRST_SESSION := 900000101

## How far ahead a bot's pilot checks its own ride ([member DotBotSurfPilot.horizon]), in ticks;
## 0 rides the cache alone.
##
## [b]0 on a live server, deliberately.[/b] A bot is always put back at the stage's exact start,
## standing, so its ride is the same deterministic ride every time and the forecast never vetoes
## anything on it (surf_beginner stage 1: 0 vetoes in every measured run). What the forecast
## costs is real all the same, and it comes in lumps a server feels: a fresh 192-tick forecast at
## every ride start measured 36 ms in one tick, and a veto tries every action that far ahead
## (twelve times that), where a 128 Hz tick has 7.8 ms for everybody. Without it the pilot is a
## lookup a tick. What is lost is the recovery after somebody knocks a bot off its line (88 to 90
## against 94 to 95 of a hundred perturbed starts arriving, docs/routes.md): it falls, and is put
## back. A test or a tool can set 192 to put the veto back.
var veto_horizon: int = 0

## A ride that has not arrived after this long is stuck (wedged on a ridge, walking into a
## wall) and starts over.
const RIDE_SECONDS := 30.0

## A ride whose bot has gone this far (metres) from where it was SETTLE_SECONDS ago has not moved;
## it is wedged where the route bot's own unsticking failed, and starts over. Kept under the soak's
## ten-second stuck limit so a bot in a pocket is put back, not left there.
const SETTLE_SECONDS := 6.0
const SETTLE_RADIUS := 1.5

## What the route planner may spend of one tick, microseconds. Until it is done the bots go
## straight at the finish as they always did, so planning is never a wait; a tick is 7.8 ms at
## 128 Hz and one step of the annotator can overrun this (docs/routes.md).
const NAV_BUDGET_USEC := 2000

## Whether a map with no route file is planned through dot-npc-ai's navigation annotations
## (`g2g_bot_nav.gd`) instead of aimed straight at the finish. The `bot_nav` cvar. Off by itself
## when dot-npc-ai is not in the project (a delivered shell may not carry it).
var use_nav: bool = true
## Where annotations are cached, by their own key.
var nav_cache_dir := "user://g2g_nav"

var game: G2GGame = null

## Bot player ids, oldest first.
var ids: Array[StringName] = []

## Per bot: `{"pilot": DotBotSurfPilot or null, "route": G2GRouteBot or null, "ticks": int,
## "rides": int, "arrived": int, "fell": int, "stuck": int, "usec": int, "driven": int,
## "best": float}`.
var _riders: Dictionary = {}

## The stage every bot rides on this map, or null when the map has none a course can be read
## from (it then stands at the spawn).
var course: DotBotSurfCourse = null
## Which kind of ride the map gives: `&"pilot"` (a surf cache), `&"route"` (the rule-based
## route bot), or `&""` before a map or with no course.
var mode: StringName = &""
var stage := 0
var _course_map: StringName = &""
## The cache's lookup, loaded once a map and shared by every bot's pilot.
var _cache: DotBotSurfPilot = null
var _route_points: Array[Dictionary] = []
## The planner for this map, or null (off, no dot-npc-ai, or the map has a route file).
var nav: RefCounted = null
## Whether the route is still being planned; the bots stand until it is.
var _planning := false
var _next_session := FIRST_SESSION


## A bot, named [param display_name], at the stage's start. Null when the game refused it.
func add_bot(display_name: String) -> G2GPlayer:
	var id := StringName("u%d" % _next_session)
	_next_session += 1
	var player := game.add_player(id, display_name, false, null, true)
	if player == null:
		return null
	_ensure_course()
	ids.append(id)
	_riders[id] = {"pilot": null, "route": null, "ticks": 0}
	_count_from_zero(_riders[id])
	_put_back(player, _riders[id])
	return player


func remove_bot(id: StringName) -> void:
	ids.erase(id)
	_riders.erase(id)
	if game.players.has(id):
		game.remove_player(id)


## Whether [param id] is one of this layer's bots.
func is_bot(id: StringName) -> bool:
	return _riders.has(id)


## This tick's command for every bot, before the game moves anybody.
func drive(step: float) -> void:
	if ids.is_empty():
		return
	_ensure_course()
	_step_nav()
	for id: StringName in ids:
		var player: G2GPlayer = game.players.get(id)
		var rider: Dictionary = _riders.get(id, {})
		if player == null or rider.is_empty():
			continue
		if course == null:
			player.controller.apply_command(DotFpsCommand.new())
			continue
		var event := course.event_at(player.controller.state)
		var limit := int(RIDE_SECONDS * float(game.tick_rate))
		var wedged := _wedged(player.controller.state.position, rider)
		if event != DotBotSurfCourse.EVENT_NONE or int(rider["ticks"]) >= limit or wedged:
			if event == DotBotSurfCourse.EVENT_GOAL:
				rider["arrived"] = int(rider["arrived"]) + 1
				var took := float(rider["ticks"]) / float(maxi(game.tick_rate, 1))
				rider["best"] = took if float(rider["best"]) <= 0.0 else minf(float(rider["best"]), took)
			elif event == DotBotSurfCourse.EVENT_NONE:
				rider["stuck"] = int(rider["stuck"]) + 1
			else:
				rider["fell"] = int(rider["fell"]) + 1
			_put_back(player, rider)

		var began := Time.get_ticks_usec()
		var command: DotFpsCommand = null
		var pilot: DotBotSurfPilot = rider["pilot"]
		var route: G2GRouteBot = rider["route"]
		if pilot != null:
			command = pilot.command(player.controller.state)
		elif route != null:
			command = route.command(player.controller.state, player.get_world_3d().direct_space_state,
				player.controller.tunables, step)
		else:
			command = DotFpsCommand.new()
		var spent := Time.get_ticks_usec() - began
		rider["usec"] = int(rider["usec"]) + spent
		rider["worst_usec"] = maxi(int(rider["worst_usec"]), spent)
		rider["driven"] = int(rider["driven"]) + 1
		rider["ticks"] = int(rider["ticks"]) + 1
		player.controller.apply_command(command)
		# The farthest from the start a ride got, as the crow flies, in metres: what a map nobody
		# can finish is measured by, and what `bot_nav` is judged on.
		var away := player.controller.state.position.distance_to(course.start)
		if away > float(rider["far_ride"]):
			rider["far_ride"] = away
			rider["far"] = maxf(float(rider["far"]), away)


## Whether the bot has stayed within SETTLE_RADIUS of one spot for SETTLE_SECONDS.
func _wedged(at: Vector3, rider: Dictionary) -> bool:
	var anchor: Vector3 = rider.get("anchor", Vector3.INF)
	if anchor == Vector3.INF or at.distance_to(anchor) > SETTLE_RADIUS:
		rider["anchor"] = at
		rider["anchor_tick"] = int(rider["ticks"])
		return false
	return int(rider["ticks"]) - int(rider.get("anchor_tick", 0)) >= int(SETTLE_SECONDS * float(game.tick_rate))


## Builds the course for the map that is loaded, once per map. Every bot is put back on it,
## because a bot riding last map's stage is a bot in mid-air over this one.
func _ensure_course() -> void:
	if game.maps == null or game.maps.current == null:
		course = null
		mode = &""
		return
	var id: StringName = game.maps.current.id
	if id == _course_map:
		return
	_course_map = id
	course = null
	mode = &""
	_cache = null
	_route_points = []
	_end_nav()

	var data := _stage_data(id)
	var why: Array = []
	if not data.is_empty():
		course = G2GSurfCourse.for_stage(game, stage, why)
		if course != null:
			_cache = DotBotSurfPilot.new()
			_cache.load_stage(data, G2GUnits.METRES_PER_UNIT)
			mode = &"pilot"
	if course == null:
		stage = 0
		course = G2GSurfCourse.for_stage(game, 0, why)
		if course != null:
			_route_points = G2GRouteBot.load_points(id, [])
			mode = &"route"
			if _route_points.is_empty():
				_begin_nav()
	if course == null:
		DotLog.info(CHANNEL, "no stage for the bots on this map; they stand at the spawn", {
			"map": String(id), "why": "; ".join(PackedStringArray(why.map(func(w: Variant) -> String: return str(w))))
		})
	else:
		DotLog.debug(CHANNEL, "bots ride", {"map": String(id), "mode": String(mode), "stage": stage})

	for bot_id: StringName in ids:
		var player: G2GPlayer = game.players.get(bot_id)
		_count_from_zero(_riders[bot_id])
		if player != null:
			_put_back(player, _riders[bot_id])


## Starts planning a route for this map, when the planner can run here.
func _begin_nav() -> void:
	if use_nav:
		_planning = true


func _start_nav() -> void:
	var path := G2GPaths.rebase("res://game/g2g_bot_nav.gd")
	var have := false
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry["class"] == &"DotNpcAiNavAnnotator":
			have = true
			break
	if not have:
		DotLog.info(CHANNEL, "dot-npc-ai is not in this project; bots go straight at the finish")
		_planning = false
		return
	var script := load(path) as GDScript
	var player: G2GPlayer = game.players.get(ids[0])
	var map := game.current_map_node()
	if script == null or player == null or map == null:
		_planning = false
		return
	nav = script.new()
	nav.begin(map, map.get_world_3d(), player.controller.tunables, course.start, course.goal_centre,
		PackedVector3Array([course.start]), nav_cache_dir, _in_a_pit)


## Whether a bot at [param at] would be put back by the course: in a pit, or under the floor.
func _in_a_pit(at: Vector3) -> bool:
	var probe := DotFpsState.new()
	probe.position = at
	var event := course.event_at(probe)
	return event == DotBotSurfCourse.EVENT_PIT or event == DotBotSurfCourse.EVENT_BELOW


## Steps the planner inside its share of the tick, and adopts the route when it has one.
func _step_nav() -> void:
	if not _planning:
		return
	if nav == null:
		_start_nav()
		return
	if nav.step(NAV_BUDGET_USEC):
		return
	_planning = false
	_route_points = nav.points
	# Counted afresh: what a bot rode on the straight line while the plan was made is not what
	# the plan gets it.
	for bot_id: StringName in ids:
		var rider: Dictionary = _riders.get(bot_id, {})
		var player: G2GPlayer = game.players.get(bot_id)
		if player != null and not rider.is_empty():
			_count_from_zero(rider)
			_put_back(player, rider)


func _end_nav() -> void:
	if nav != null:
		nav.cancel()
	nav = null
	_planning = false


## The counts describe() reports are this map's: a cost averaged over two maps' rides (one a
## route bot's raycasts, one a pilot's forecast) is nobody's cost.
static func _count_from_zero(rider: Dictionary) -> void:
	for key in ["rides", "arrived", "fell", "stuck", "usec", "driven"]:
		rider[key] = 0
	rider["best"] = 0.0
	rider["far"] = 0.0
	rider["far_ride"] = 0.0
	rider["worst_usec"] = 0


## The cache's first stage for map [param id], setting [member stage]; empty with no cache.
func _stage_data(id: StringName) -> Dictionary:
	var path := G2GSurfCourse.cache_path(id)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("stages")) != TYPE_DICTIONARY:
		DotLog.warn(CHANNEL, "a surf cache that does not read", {"path": path})
		return {}
	var stages: Dictionary = parsed["stages"]
	var numbers: Array = stages.keys().map(func(k: Variant) -> int: return int(str(k)))
	numbers.sort()
	if numbers.is_empty():
		return {}
	stage = numbers[0]
	return stages[str(stage)]


## Back to the stage's start, standing, facing the way the stage faces, on a new ride.
func _put_back(player: G2GPlayer, rider: Dictionary) -> void:
	rider["ticks"] = 0
	rider["anchor"] = Vector3.INF
	rider["far_ride"] = 0.0
	rider["rides"] = int(rider["rides"]) + 1
	if course == null:
		rider["pilot"] = null
		rider["route"] = null
		return
	player.teleport(course.start, course.start_yaw)
	player.controller.apply_command(DotFpsCommand.new())
	if mode == &"pilot":
		var pilot: DotBotSurfPilot = rider["pilot"]
		# A pilot of its own per bot (the forecast is one ride's), over the one shared lookup;
		# its simulator is a copy of THIS bot's motor, rebuilt after a map change.
		if pilot == null or pilot.sim == null or rider.get("map") != _course_map:
			pilot = DotBotSurfPilot.new().share_cache(_cache)
			pilot.sim = (course as G2GSurfCourse).simulator_for(player.controller, game.mechanics)
			pilot.score = course.score
			pilot.horizon = veto_horizon
			rider["pilot"] = pilot
			rider["map"] = _course_map
		pilot.reset()
		rider["route"] = null
	else:
		rider["pilot"] = null
		rider["route"] = G2GRouteBot.new(_route_points, course.goal_centre)


## Per bot, what it rode and what it cost: the pilot's (or route bot's) own time per driven
## tick, in microseconds. The bot's own move is not in it: a person's costs the same.
func describe() -> Dictionary:
	var bots: Array = []
	for id: StringName in ids:
		var r: Dictionary = _riders.get(id, {})
		var pilot: DotBotSurfPilot = r.get("pilot")
		var entry := {
			"id": String(id),
			"rides": r.get("rides", 0), "arrived": r.get("arrived", 0), "fell": r.get("fell", 0),
			"stuck": r.get("stuck", 0), "best_sec": r.get("best", 0.0), "far_m": r.get("far", 0.0),
			"usec_per_tick": float(r.get("usec", 0)) / float(maxi(int(r.get("driven", 0)), 1)),
			"worst_usec": r.get("worst_usec", 0),
			"ticks_driven": r.get("driven", 0),
		}
		if pilot != null:
			entry["pilot"] = pilot.describe()
		var route: G2GRouteBot = r.get("route")
		if route != null:
			entry["route"] = {"index": route.index, "points": route.points.size(), "target": route.target()}
			var player: G2GPlayer = game.players.get(id)
			if player != null:
				entry["route"]["at"] = player.controller.state.position
		bots.append(entry)
	return {"map": String(_course_map), "mode": String(mode), "stage": stage,
		"cache_entries": _cache.size() if _cache != null else 0, "nav": nav.describe() if nav != null else {}, "bots": bots}


func describe_lines() -> PackedStringArray:
	var d := describe()
	var out := PackedStringArray(["bots         %d on %s, %s stage %d" % [
		ids.size(), d["map"] if d["map"] != "" else "-", d["mode"] if d["mode"] != "" else "standing", d["stage"]]])
	for b: Dictionary in d["bots"]:
		out.append("  %s  %d rides, %d arrived (best %.2f s), %d fell, %d stuck, farthest %.0f m; %.0f us a tick, worst %d" % [
			b["id"], b["rides"], b["arrived"], b["best_sec"], b["fell"], b["stuck"], b["far_m"], b["usec_per_tick"], b["worst_usec"]])
	return out
