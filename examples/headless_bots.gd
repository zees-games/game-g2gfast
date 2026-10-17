extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")

## The server's bots on a live server: a real `DotServer` with `G2GModule` at 128 ticks, the
## bots asked for through `bot_quota`, and what each map gives them to ride (`g2g_bots.gd`).
##
## [codeblock]
## godot --headless --path . res://examples/headless_bots.tscn
## [/codeblock]
##
## On a hand-built map with no surf cache a bot is the rule-based route bot on the whole run;
## on surf_beginner, whose cache has stage 1, it rides that stage with dot-bot's surf pilot and
## is put back at the stage's start each time it arrives in stage 2. The surf half needs
## `maps/imported/surf_beginner` (g2gfast-maps, linked by dot-bootstrap) and says so when it is
## missing, as `headless_imported` does. The cost a bot's driving adds per tick is printed: it is
## the number docs/routes.md quotes.
##
## Armed by having `G2GBots._ensure_course` skip the cache (the pilot check fails: the route bot
## wedges on the first ramp's ridge and never arrives) and by dropping `bots.drive` from
## `G2GGame._simulate_tick` (every bot stands still and nothing arrives).

const SECTIONS := 5
const CHECKS := 21

## Checks the navigation section did not make because the maps were absent; the count above
## holds for a checkout with g2gfast-maps linked.
var _skipped_checks := 0

const SERVER_DIR := "user://g2g_bots"
const SURF_MAP := &"surf_beginner"
## Rides on surf_beginner's stage 1 take about four seconds; three arrivals inside this many
## is a pilot that rides, and a stuck one runs out of it.
const SURF_SECONDS := 40.0
const SURF_ARRIVALS := 3

## Maps with no route file and no surf cache, where a bot only ever had the straight line, and
## how long each is ridden. The farthest a bot got from its start (metres, as the crow flies) is
## compared with `bot_nav` 0 and 1.
const NAV_MAPS: Array[StringName] = [&"bhop_fur", &"bhop_platformer_fxd", &"bhop_elate"]
const NAV_SECONDS := 20.0
## The most a single planning step may take, milliseconds, a bound that catches a step that grew
## with the map. The tick is 7.8 ms at 128 Hz and the planner is given 2 ms of it; the one step
## that overruns is a single item of dot-npc-ai's annotator, measured 30 to 100 ms on these maps
## (docs/routes.md), which is why this is not 8.
## The most ticks a plan is waited for (it is made in the background, 2 ms of each tick).
const NAV_PLAN_TICKS := 20000
const NAV_STEP_LIMIT_MS := 150.0
## Annotations are kept between runs here (by their own key, so a changed setting is a new file),
## which a cold run of the biggest of those maps would otherwise spend half a minute making.
const NAV_CACHE := "user://g2g_bots_nav_cache"

var server: DotServer = null
var game: G2GGame = null

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — bots on a live server")
	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()
	if game != null:
		await _test_a_bot_without_a_cache()
		await _test_a_bot_rides_the_surf_stage()
		await _test_nav_routes_get_further()
		await _test_quota_zero_takes_them_away()

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [_passed, _failed, _completed, _entered])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS - _skipped_checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS - _skipped_checks])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _boot() -> void:
	_section("booting at 128 ticks")
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("sv_tickrate 128")
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.port = 28786
	config.max_players = 8
	config.hibernate_when_empty = false
	config.query_enabled = false
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.stdin_console_enabled = false
	server = DotServer.new()
	server.config = config
	add_child(server)
	for _i in range(60):
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	_check(server.state == DotServer.State.RUNNING, "the server boots")

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = &"bhop_g2g_intro"
	game = G2GGame.new()
	game.config = g2g_config
	add_child(game)
	for _i in range(60):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	_check(game.maps.current != null and game.tick_rate == 128, "the game loads its first map at 128 ticks",
		"tick rate %d" % game.tick_rate)

	(load("res://game/g2g_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/g2g_module.gd")
	_check(loaded.ok and server.console.find_cvar("bot_quota") != null,
		"the module loads and registers bot_quota", loaded.error.message if not loaded.ok else "")
	_check(server.console.find_cvar("bot_quota").get_string() == "0" and (game.bots.get("ids") as Array).is_empty(),
		"which is 0 here, so a timer server has no bots until its operator asks")
	_done()


func _test_a_bot_without_a_cache() -> void:
	_section("a bot on a map with no surf cache is the route bot")
	_run_command("bot_quota_mode fixed")
	_run_command("bot_quota 1")
	await _ticks(80)
	var ids: Array = game.bots.get("ids")
	_check(ids.size() == 1, "bot_quota 1 puts one bot on", str(ids))
	if ids.size() != 1:
		for _i in range(4):
			_check(false, "(no bot)")
		_done()
		return
	var bot: G2GPlayer = game.players.get(ids[0])
	var described: Dictionary = game.bots.call("describe")
	_check(bot != null and bot.is_bot and bot.timer == null,
		"a player with no timer, so nothing it does is filed", str(bot.describe()) if bot != null else "")
	_check(described["mode"] == "route" and int(described["stage"]) == 0,
		"riding the whole run with the rule-based route bot", str(described))
	var bridge: Object = server.modules.get_module("g2gfast").get("bridge")
	var behaviour: Object = bridge.call("behaviour_for", String(ids[0]).trim_prefix("u").to_int())
	_check(behaviour != null and int(behaviour.get("identity").get("owner_peer_id")) == 0,
		"replicated as an entity with no peer")
	var from := bot.controller.state.position
	await _ticks(128)
	for line in game.bots.call("describe_lines"):
		print("        %s" % line)
	_check(bot.controller.state.position.distance_to(from) > 1.0, "and it moves",
		"%.2f m in a second" % bot.controller.state.position.distance_to(from))
	_done()


func _test_a_bot_rides_the_surf_stage() -> void:
	_section("a bot rides surf_beginner's first stage with the surf pilot")
	if not DirAccess.dir_exists_absolute("res://maps/imported/%s" % SURF_MAP):
		for what in ["the map changes", "the bots ride the cache's stage with the pilot",
				"a bot arrives in the next stage and is put back, again and again", "and its driving cost is measured"]:
			_check(true, what, "no maps/imported/%s" % SURF_MAP)
		_done()
		return
	var changed: DotResult = await game.change_map(SURF_MAP)
	_check(changed.ok and game.maps.current.id == SURF_MAP, "the map changes", changed.error.message if not changed.ok else "")
	await _ticks(4)
	var described: Dictionary = game.bots.call("describe")
	_check(described["mode"] == "pilot" and int(described["stage"]) == 1 and int(described["cache_entries"]) > 0,
		"the bots ride the cache's stage with the pilot", str(described))

	var limit := int(SURF_SECONDS * 128.0)
	var t := 0
	while t < limit:
		await _ticks(64)
		t += 64
		var bots: Array = (game.bots.call("describe") as Dictionary)["bots"]
		if not bots.is_empty() and int(bots[0]["arrived"]) >= SURF_ARRIVALS:
			break
	described = game.bots.call("describe")
	var first: Dictionary = (described["bots"] as Array)[0] if not (described["bots"] as Array).is_empty() else {}
	for line in game.bots.call("describe_lines"):
		print("        %s" % line)
	if first.has("pilot"):
		print("        pilot: %s" % str(first["pilot"]))
	_check(int(first.get("arrived", 0)) >= SURF_ARRIVALS and int(first.get("rides", 0)) > int(first.get("arrived", 0)),
		"a bot arrives in the next stage and is put back, again and again",
		"%d arrived of %d rides in %.1f s" % [first.get("arrived", 0), first.get("rides", 0), float(t) / 128.0])
	_check(float(first.get("usec_per_tick", 0.0)) > 0.0 and int(first.get("ticks_driven", 0)) > 0,
		"and its driving cost is measured", "%.0f us a tick over %d ticks" % [first.get("usec_per_tick", 0.0), first.get("ticks_driven", 0)])
	_done()


func _test_nav_routes_get_further() -> void:
	_section("bots plan through the navigation annotations: farthest reached, bot_nav 0 against 1")
	_run_command("bot_quota 1")
	game.bots.set("nav_cache_dir", NAV_CACHE)
	var far := {}
	var held_maps := 0
	for map_id in NAV_MAPS:
		if DirAccess.dir_exists_absolute("res://maps/imported/%s" % map_id):
			held_maps += 1
	if held_maps == 0:
		# Third-party maps are not redistributable, so CI checks out without g2gfast-maps.
		# Nothing to plan over is not a planner failure, and saying so beats a false green.
		print("        SKIP  navigation planning: none of %s is in maps/imported (g2gfast-maps not linked)" % str(NAV_MAPS))
		_skipped_checks += NAV_MAPS.size() + 2
		_done()
		return
	var worst_step := 0.0
	var planned := 0
	for use in [0, 1]:
		_run_command("bot_nav %d" % use)
		for map_id in NAV_MAPS:
			if not DirAccess.dir_exists_absolute("res://maps/imported/%s" % map_id):
				far[[use, map_id]] = -1.0
				continue
			var changed: DotResult = await game.change_map(map_id)
			if not changed.ok:
				far[[use, map_id]] = -1.0
				continue
			if use == 1:
				# Planned first, then ridden: the cache is warm from the run before and a
				# plan is a few seconds of ticks; the bots' count starts when it is adopted.
				for _t in range(NAV_PLAN_TICKS / 64):
					await _ticks(64)
					var nav_state: Dictionary = (game.bots.call("describe") as Dictionary)["nav"]
					if nav_state.is_empty() or nav_state["state"] in ["ready", "failed"]:
						break
			await _ticks(int(NAV_SECONDS * 128.0))
			var d: Dictionary = game.bots.call("describe")
			var bots: Array = d["bots"]
			far[[use, map_id]] = float(bots[0]["far_m"]) if not bots.is_empty() else 0.0
			if use == 1 and d["nav"] is Dictionary and not (d["nav"] as Dictionary).is_empty():
				var n: Dictionary = d["nav"]
				print("        %s nav: %s" % [map_id, str(n)])
				worst_step = maxf(worst_step, float(n["worst_step_ms"]))
				if n["state"] == "ready":
					planned += 1
	for map_id in NAV_MAPS:
		var before: float = far[[0, map_id]]
		var after: float = far[[1, map_id]]
		print("        %-22s farthest %6.1f m without, %6.1f m with" % [map_id, before, after])
		_check(before < 0.0 or after >= before - 1.0, "%s: planning reaches about as far as the straight line, or further" % map_id,
			"%.1f m against %.1f m" % [after, before])
	var gain := 0.0
	for map_id in NAV_MAPS:
		gain += maxf(float(far[[1, map_id]]) - float(far[[0, map_id]]), 0.0)
	_check(gain > 10.0, "and on the whole it reaches clearly further", "%.1f m gained over %d maps" % [gain, NAV_MAPS.size()])
	_check(planned > 0 and worst_step < NAV_STEP_LIMIT_MS, "the planner finishes, a step at a time",
		"%d planned, worst step %.1f ms" % [planned, worst_step])
	_run_command("bot_nav 1")
	game.bots.set("nav_cache_dir", "user://g2g_nav")
	_run_command("bot_quota 0")
	await _ticks(10)
	_done()


func _test_quota_zero_takes_them_away() -> void:
	_section("bot_quota 0 takes them away")
	_run_command("bot_quota 0")
	await _ticks(80)
	var bot_players := game.players.values().filter(func(p: G2GPlayer) -> bool: return p.is_bot)
	_check((game.bots.get("ids") as Array).is_empty() and bot_players.is_empty(), "now, not next map",
		"%d left" % bot_players.size())
	_run_command("bot_quota 2")
	await _ticks(80)
	_check((game.bots.get("ids") as Array).size() == 2, "and bot_quota 2 brings two",
		str(game.bots.get("ids")))
	_run_command("bot_quota 0")
	await _ticks(80)
	_check((game.bots.get("ids") as Array).is_empty(), "and 0 again takes both")
	_done()


func _ticks(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame


func _shut_down() -> void:
	if server == null:
		return
	if server.modules != null:
		server.modules.unload_all()
	server.shutdown("the bots test is finished")
	for _i in range(10):
		await get_tree().process_frame
	for node: Node in [game, server]:
		if is_instance_valid(node):
			remove_child(node)
			node.free()
	game = null
	server = null
	await get_tree().process_frame


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
