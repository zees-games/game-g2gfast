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

const SECTIONS := 4
const CHECKS := 16

const SERVER_DIR := "user://g2g_bots"
const SURF_MAP := &"surf_beginner"
## Rides on surf_beginner's stage 1 take about four seconds; three arrivals inside this many
## is a pilot that rides, and a stuck one runs out of it.
const SURF_SECONDS := 40.0
const SURF_ARRIVALS := 3

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
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
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
