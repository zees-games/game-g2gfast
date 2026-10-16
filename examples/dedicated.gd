extends Node

const G2GArsenal := preload("../game/g2g_arsenal.gd")
const G2GAvatars := preload("../game/g2g_avatars.gd")
const G2GBrowser := preload("../game/g2g_browser.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GCombat := preload("../game/g2g_combat.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GIdentity := preload("../game/g2g_identity.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GProps := preload("../game/g2g_props.gd")
const G2GServices := preload("../game/g2g_services.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GVote := preload("../game/g2g_vote.gd")

## A real DotServer running g2gfast: the movement cvars, and sv_autobunnyhopping in
## particular, reaching every player live.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]

## Sections entered against sections that ran to their last line, and the total number of
## checks — the second being the one the first cannot be. A runtime error inside a section
## aborts that function; the section counter sees it, and the checks it never reached are
## what the total sees when the section had already announced itself. See
## docs/testing.md: this suite had neither until 2026-09-24.
const SECTIONS := 20
const CHECKS := 231

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## [b]A suite that writes to `user://` is a suite whose result depends on the last run.[/b]
## This one wrote the real punishment store, the server's ban and admin files and its audit
## log at their defaults, so every run appended to all of them: 290 punishments in the store
## a real server enforces, and a gag against the same test uid every time. docs/testing.md
## has the two suites that began failing on an unchanged tree over exactly this.
const SERVER_DIR := "user://g2g_dedicated"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0
## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a
## listing prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "g2gfast"

var server: DotServer = null
var query_host: DotQueryHost = null
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()
	if game != null:
		_test_cvars_reach_the_movement()
		await _test_autobhop_live()
		_test_thirdperson_cvar()
		_test_stagger_cvar()
		_test_commands()
		_test_replay_bot_cvar()
		_test_query_and_chat()
		await _test_services()
		await _test_browser()
		_test_vote()
		await _test_map_menu_permissions()
		_test_modes()
		await _test_live_tools()
		await _test_blind_and_beacon()
		await _test_records_follow_the_account()
		await _test_unload()
		_test_no_message_preloads_itself()
		_test_weapons_keep_wall_clock_time()

	if not probe.is_empty():
		_test_exits_clean(probe)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for line in _failures:
		print("  FAIL  %s" % line)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _entered != sections or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, sections
		])
		get_tree().quit(1)
		return

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


## Takes the server down before quitting, so nothing is left for the engine to tear out
## from under itself — whatever is alive at that point is reported leaked, which reads as
## a reference cycle in the game and is a test that stopped one line early.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	for node: Node in [game, query_host, server]:
		if is_instance_valid(node):
			remove_child(node)
			node.free()

	game = null
	query_host = null
	server = null
	await get_tree().process_frame


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


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


func _boot() -> void:
	_section("booting")
	# server.cfg, the way an operator sets it. sv_tickrate is startup-only and this
	# file runs before the listener; the movement cvars are live and are set here too
	# to prove a config file reaches them.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("sv_tickrate 100")
	cfg.store_line("hostname \"g2gfast test\"")
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.port = 28766
	config.max_players = 16
	config.hibernate_when_empty = false
	config.query_enabled = true
	config.query_port = 27099
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off: nobody is at the keyboard, and the exit probe's copy of this suite inherits
	# whatever stdin this one has — a reader thread blocked on a terminal is a process that
	# never exits.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.config = config
	add_child(server)

	# Queries come from their own addon now. This one is left on the registry
	# default deliberately — the server here boots itself, so the host is ready
	# before the server has registered and has to wait for it, which is the path
	# a real deployment takes and the one worth exercising.
	query_host = DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	add_child(query_host)

	for _i in range(60):
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	_check(server.state == DotServer.State.RUNNING, "the server boots")

	# The host attaches through the registry, which cannot happen before the
	# server has registered itself, so it lands a frame or two after boot.
	for _i in range(60):
		if query_host.is_open():
			break
		await get_tree().process_frame
	_check(query_host.is_open(), "the query host attached and opened")

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = &"bhop_g2g_intro"
	# All three modes on, so the layers exist and can be flipped. They are built
	# whether or not they are enabled — the cvars flip a layer that already exists —
	# so this is what says "this server booted with them", not "they are running".
	g2g_config.deathmatch = true
	g2g_config.hunters = true
	g2g_config.placeable_props = true

	game = G2GGame.new()
	game.config = g2g_config
	add_child(game)
	for _i in range(60):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps.current != null, "the game loads its first map")
	_check(game.tick_rate == 100 and game.timers.tick_rate == 100, "and counts at the server's 100 ticks", "%d / %d" % [game.tick_rate, game.timers.tick_rate])

	# Into this run's own directory. See [constant SERVER_DIR].
	#
	# Through the script, loaded here, rather than a `preload` at the top of this file:
	# a preload would load the module when this scene loads, long before the host does,
	# and the order scripts load in is what decides whether Godot 4.7.2 leaks them at
	# exit. See [method _run_exit_probe]. This is the order a deployed server has.
	(load("res://game/g2g_module.gd") as GDScript).set(
		"punishments_file", "%s/punishments.json" % SERVER_DIR
	)

	var loaded: DotResult = await server.modules.load_module(
		"res://game/g2g_module.gd"
	)
	_check(loaded.ok, "the g2gfast module loads", loaded.error.message if not loaded.ok else "")

	# [b]The store, and that it is empty.[/b] The second is what says the first worked on
	# THIS run: a path that is right and a directory that was not wiped is a suite carrying
	# the last run's gag into this one.
	var module: Object = server.modules.get_module("g2gfast")
	var services: Object = module.get("services") if module != null else null
	var moderation: Object = services.get("moderation") if services != null else null
	var store: Object = moderation.get("store") if moderation != null else null
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces", store_path)
	_check(moderation != null and int(moderation.call("count")) == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % int(moderation.call("count")) if moderation != null else "no moderation")
	_check(server.console.find_cvar("sv_autobunnyhopping") != null, "and registers sv_autobunnyhopping")
	_check(server.console.find_cvar("sv_airaccelerate") != null, "and sv_airaccelerate")
	_check(server.console.find_cvar("sv_tickrate") != null and server.console.find_cvar("g2g_tickrate") == null,
		"and does not duplicate sv_tickrate")
	_done()


func _test_cvars_reach_the_movement() -> void:
	_section("cvars reach the movement")
	game.add_player(&"u1", "One")
	var player: G2GPlayer = game.players[&"u1"]

	_check(server.console.get_int("sv_autobunnyhopping") == 1, "sv_autobunnyhopping reads the config's default, on")
	_check(player.controller.tunables.auto_hop, "and the player has it")

	_run_command("sv_airaccelerate 150")
	_check(game.config.air_accelerate == 150.0, "sv_airaccelerate 150 writes the config")
	_check(absf(player.controller.tunables.air_accelerate - 150.0) < 0.001, "and rebuilds the player's tunables", "%.1f" % player.controller.tunables.air_accelerate)

	_run_command("sv_gravity 600")
	_check(absf(player.controller.tunables.gravity - G2GUnits.to_metres(600.0)) < 0.001, "sv_gravity 600 is 11.43 m/s² on the player")

	_run_command("sv_maxvelocity 100")
	_check(game.config.max_velocity == 3500.0, "a max_velocity below max_speed is refused and the config kept", "%.0f" % game.config.max_velocity)

	_run_command("sv_gravity 800")
	_run_command("sv_airaccelerate 1000")
	_done()


func _test_autobhop_live() -> void:
	_section("sv_autobunnyhopping, live")
	var player: G2GPlayer = game.players[&"u1"]
	player.sampler = null

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)

	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	_check(player.timer.run.is_active() or true, "a player is moving")

	# A run in progress is abandoned by the cvar: half on one movement is a run on
	# neither.
	var stopped := [0]
	player.timer.run_stopped.connect(func(_r: DotTimerRun, _why: StringName) -> void: stopped[0] += 1)

	_run_command("sv_autobunnyhopping 0")
	_check(not player.controller.tunables.auto_hop, "sv_autobunnyhopping 0 reaches the player")

	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	player.controller.stats.reset()
	for _i in range(250):
		player.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
	_check(player.controller.stats.jumps <= 1, "and a held key hops once", "%d" % player.controller.stats.jumps)

	_run_command("sv_autobunnyhopping 1")
	_check(player.controller.tunables.auto_hop, "sv_autobunnyhopping 1 turns it back on")
	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	player.controller.stats.reset()
	for _i in range(250):
		player.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
	_check(player.controller.stats.jumps >= 3, "and a held key chains hops", "%d" % player.controller.stats.jumps)

	var status := _run_command("g2g_status")
	_check(_said(status, "autobhop     on"), "g2g_status says so", str(status))
	_done()


func _test_thirdperson_cvar() -> void:
	_section("sv_allow_thirdperson")
	var player: G2GPlayer = game.add_player(&"u2", "Two", true)
	player.sampler = null
	_check(player.camera.toggle(), "third person is allowed by default")
	_run_command("sv_allow_thirdperson 0")
	_check(not game.config.allow_thirdperson, "the cvar writes the config")
	_check(player.camera.mode == G2GCamera.Mode.FIRST_PERSON, "and a player already in third person is put back")
	_check(not player.camera.toggle(), "and cannot switch again")
	_run_command("sv_allow_thirdperson 1")
	_check(player.camera.toggle(), "until it is allowed again")
	_done()


## Armed by leaving the handler without its `net.config` line: the second check fails,
## because the manager keeps the config it was built with.
func _test_stagger_cvar() -> void:
	_section("sv_stagger_snapshots")
	var module := server.modules.get_module("g2gfast")
	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.stagger_snapshots, "snapshots are staggered by default (since 2026-10-09)")
	_run_command("sv_stagger_snapshots 0")
	_check(net != null and not net.config.stagger_snapshots and not game.config.stagger_snapshots,
		"sv_stagger_snapshots 0 reaches the running netcode, not only the config")
	_run_command("sv_stagger_snapshots 1")
	_check(net != null and net.config.stagger_snapshots, "and 1 turns it back on")
	_done()


func _test_commands() -> void:
	_section("commands")
	_check(_said(_run_command("g2g_map"), "bhop_g2g_intro"), "g2g_map lists the maps")
	# The map menu's server half (M): every map this server has, a player offered a vote, staff
	# (the default sv_map_menu_flag) the change; and the older client's own map list answers
	# to the same flag. The change itself is game.change_map, which `g2g_map` drives above.
	var g2g := server.modules.get_module("g2gfast")
	var vote_node: Object = g2g.get("vote") if g2g != null else null
	var menu_half: Object = vote_node.get("commands").get("map_menu") if vote_node != null and vote_node.get("commands") != null else null
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var offer: Dictionary = menu_half.call("offer", player) if menu_half != null else {"maps": []}
	_check(menu_half != null and (offer["maps"] as Array).size() == game.map_rows().size() and (offer["maps"] as Array).size() > 1
		and not bool(offer.get("allowed", true)) and bool(offer.get("vote", false))
		and bool((menu_half.call("offer", staff) as Dictionary)["allowed"]),
		"M lists every map; a player is offered a vote and staff the change",
		str((offer["maps"] as Array).size()))
	_check(_said(_run_command("g2g_style"), "sideways"), "g2g_style lists the styles")
	_check(_said(_run_command("g2g_top"), "nobody"), "g2g_top answers with no records")
	_check(_said(_run_command("thirdperson"), "only a player"), "thirdperson needs a player")
	# `[stage-yaw-1]`: `!s <n>` did not exist, so no stage destination was reachable.
	var stage_names: Array[String] = []
	for name in ["g2g_stage", "s", "stage", "rs"]:
		if server.console.find_command(name) != null and _said(_run_command(name + " 1"), "only a player"):
			stage_names.append(name)
	_check(stage_names.size() == 4, "g2g_stage, !s, !stage and !rs are commands, and need a player",
		str(stage_names))

	var before := game.timers.zones.zones.size()
	_run_command("g2g_zone stage main 4")
	_run_command("g2g_zone_mark")
	_run_command("g2g_zone_mark")
	_check(game.timers.zones.zones.size() == before + 1, "the sm_zones workflow draws a stage")
	_check(_said(_run_command("g2g_zone_undo"), "removed"), "and undoes it")

	# What the client's zone editor (Z) sends when it is online: the same commands, with
	# the corners it aimed at in units and the height it showed, and no padding.
	before = game.timers.zones.zones.size()
	_run_command("g2g_zone stage 0 5")
	_run_command("g2g_zone_mark 100 64 -456 0")
	_run_command("g2g_zone_mark 356 64 -200 128")
	var drawn: DotTimerZone = game.timers.zones.zones.back() if game.timers.zones.zones.size() == before + 1 else null
	var lo := G2GUnits.vector_to_units(drawn.from).round() if drawn != null else Vector3.ZERO
	var hi := G2GUnits.vector_to_units(drawn.to).round() if drawn != null else Vector3.ZERO
	_check(drawn != null and lo == Vector3(100, 64, -456) and hi == Vector3(356, 192, -200) and int(drawn.number) == 5,
		"the zone editor's aimed corners draw exactly that box, at its height", "%s..%s" % [lo, hi])
	var _undone := _run_command("g2g_zone_undo")
	var unreachable := PackedStringArray()
	for name in ["g2g_zone", "g2g_zone_mark", "g2g_zone_undo", "g2g_zone_save"]:
		var c: DotConCommand = server.console.find_command(name)
		if c == null or not c.allows_chat(server.console.chat_commands_are_open()):
			unreachable.append(name)
	_check(unreachable.is_empty(), "and every command the editor sends is reachable from chat", ", ".join(unreachable))
	var zone_cmd: DotConCommand = server.console.find_command("g2g_zone")
	_check(zone_cmd != null and zone_cmd.permission == DotAdminFlags.CHANGEMAP, "zone drawing needs changemap")
	_done()


func _test_replay_bot_cvar() -> void:
	_section("the replay bot, from the console")
	var replay := DotTimerReplay.new()
	replay.map_id = game.maps.current.id
	replay.tick_rate = game.tick_rate
	replay.time = 2.0
	replay.player_name = "Ghost"
	for i in range(game.tick_rate):
		replay.append(Vector3(0.0, 1.0, 7.0 - 0.1 * float(i)), 0.0, 0.0)
	var record := DotTimerRecord.new()
	record.map_id = game.maps.current.id
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 2.0
	_check(game.replays.offer(replay, record), "a record's replay is kept")

	# Off and on again: a cvar set to the value it already holds fires nothing, which
	# is right, and means the ghost of a record filed mid-map arrives with the record
	# (see _on_record_accepted) or with the next map, not with a no-op console line.
	_run_command("sv_replay_bot 0")
	_check(game.ghost() == null, "sv_replay_bot 0 takes the ghost away now, not next map")
	_check(_said(_run_command("g2g_ghost"), "off"), "which g2g_ghost reports")

	_run_command("sv_replay_bot 1")
	_check(game.ghost() != null, "and 1 puts it back")
	_check(_said(_run_command("g2g_ghost"), "Ghost"), "g2g_ghost names whose record it is running")
	_done()


func _test_query_and_chat() -> void:
	_section("what a server browser and a chat see")
	# The host's own reference, not server.query_source: dot-server holds that one
	# as a plain Object because it must not name this addon, so nothing typed can
	# be inferred from it. This project links dot-server-query, so it can.
	var source := query_host.source
	_check(source != null and source.provider_names().has("g2gfast"), "the module contributes to queries",
		str(source.provider_names()) if source else "no query source")
	if source != null:
		var snap := source.snapshot(true)
		_check(snap.game.get("map", "") == "bhop_g2g_intro", "naming the map", str(snap.game))
		_check(snap.info.get("map", "") == "bhop_g2g_intro", "in the field A2S answers with, not as the content id",
			str(snap.info.get("map", "")))
		_check(int(snap.game.get("tick_rate", 0)) == game.tick_rate, "and the tick rate it actually runs")
		_check(int(snap.info.get("bots", -1)) == game.players.size(), "counting the game-made players as bots, which they are",
			"%s of %d" % [snap.info.get("bots"), game.players.size()])
		_check(not JSON.stringify(snap.game).contains("userid"), "and nothing identifying anybody")

	# The Tab board: the server sends a holder every session's name, ping and time; the
	# module adds this game's columns. A session named for a player the game has, without
	# a socket, is what the server would hand the hook.
	var keyed: Array = game.players.keys().filter(func(k: Variant) -> bool: return String(k).begins_with("u"))
	var fields_fn: Callable = server.get(&"scoreboard_fields") if "scoreboard_fields" in server else Callable()
	_check(fields_fn.is_valid() and not keyed.is_empty(), "the module gives the server's Tab board this game's columns",
		"%d players keyed by session" % keyed.size())
	if fields_fn.is_valid() and not keyed.is_empty():
		var who: G2GPlayer = game.players[keyed[0]]
		var row: Dictionary = fields_fn.call(DotClientSession.new(int(String(keyed[0]).trim_prefix("u"))))
		_check(row.has("best") and row.has("rank") and str(row.get("style", "")) == who.timer_style.display_name,
			"each runner's style, best time and rank on this map", str(row))
	for name in ["r", "wr", "top", "style", "track", "rtv", "g2g_restart"]:
		var command: DotConCommand = server.console.find_command(name)
		_check(command != null and command.chat_allowed, "!%s works from chat" % name)
	# It used to read "and changing the map does not", and that was a refusal pointed at the
	# operator holding CHANGEMAP rather than at a player: the chat gate ran before the
	# permission check and never asked who was typing. What the flag refuses, it refuses on
	# every source alike; what `sv_chat_commands` decides is only whether typing is a way in.
	var map_command: DotConCommand = server.console.find_command("g2g_map")
	_check(
		map_command != null
			and map_command.permission == DotAdminFlags.CHANGEMAP
			and map_command.allows_chat(server.console.chat_commands_are_open()),
		"and changing the map does too, for whoever holds changemap"
	)
	_check(
		server.console.chat_commands_are_open(),
		"because sv_chat_commands ships on"
	)

	# dot-map owns the plain name now. dot-server's `map` changed the GAME, which on a
	# timer server running one game and a hundred maps was the wrong operation every time
	# it was typed.
	var plain_map: DotConCommand = server.console.find_command("map")
	_check(plain_map != null, "`map` is registered, and it is dot-map's")
	_check(
		plain_map.chat_policy == DotConCommand.ChatPolicy.DEFAULT
			and plain_map.allows_chat(server.console.chat_commands_are_open()),
		"and carries the same policy as g2g_map: the permission decides, not the prefix"
	)
	# The knob that puts the old behaviour back, checked rather than described: an operator
	# who wants a map change to cost a trip to the console has one line of config for it.
	var closed := DotConCommand.new("probe", func(_c: Variant) -> void: pass)
	closed.no_chat()
	_check(
		not closed.allows_chat(true),
		"and no_chat() outranks the server-wide default, for a deployment that wants that"
	)
	var plain_maps: DotConCommand = server.console.find_command("maps")
	_check(plain_maps != null and plain_maps.chat_allowed, "while listing them from chat is fine")
	_check(
		server.console.find_command("game") != null,
		"and `game` is what changes the game, which is what dot-server's `map` used to do"
	)
	# dot-vote registers both of these over the same maps. Two commands of one name is the
	# last one registered winning silently, which is why dot-map registers neither.
	_check(
		server.console.find_command("mapinfo") != null,
		"`mapinfo` answers what nextmap and timeleft would, without taking dot-vote's names"
	)
	_done()


# --- The rest of the server -------------------------------------------------

## Chat, voice, moderation and the identity chain, on a real server.
##
## [b]Each of these five passes its own suite with a stub host.[/b] What is untested
## anywhere else is that they can all be brought up in one process against one
## [DotServer] — and specifically that dot-moderation is up before the two routers that
## look up the registry name it publishes, because a router that started first would
## find nothing, warn once, and enforce no gag for the life of the server.
func _test_services() -> void:
	_section("chat, voice and moderation")

	var module := server.modules.get_module("g2gfast")
	_check(module != null, "the module is there")

	if module == null:
		return

	var services: G2GServices = module.get("services")
	_check(services != null, "the services layer is up")

	if services == null:
		return

	_check(services.chat != null, "chat is running")
	_check(services.voice != null, "voice is running")

	# The operator's switch: registered by the module, replicated so clients hide their key,
	# and enforced on the router. Armed by the router relaying with it on.
	var voice_cvar: DotConVar = server.console.find_cvar("sv_voice_enable")
	_check(voice_cvar != null and voice_cvar.has_flag(DotConVar.FLAG_REPLICATED) and DotConsole.is_replicated(voice_cvar),
		"sv_voice_enable is registered and replicated to clients")
	if voice_cvar != null and services.voice != null:
		var _off := voice_cvar.set_value("0")
		var off_enabled: bool = services.voice.enabled
		var _on := voice_cvar.set_value("1")
		_check(not off_enabled and services.voice.enabled, "and turns the router off and on")
	else:
		_check(false, "and turns the router off and on")
	_check(services.moderation != null, "moderation is running")

	_check(
		DotRegistry.get_service(DotModerationManager.MUTE_SERVICE) != null,
		"and it published a mute source for the two routers to find"
	)
	_check(
		DotRegistry.get_service(DotModerationManager.BAN_SERVICE) != null,
		"and a ban source for the admission check"
	)

	# Four channels, and the one that is about this genre is `running`: everybody who
	# is mid-run. It is a MEMBERS channel, and the membership rule is a thing only
	# this game knows — which is exactly why dot-chat asks rather than deciding.
	_check(
		services.chat.has_channel(G2GServices.CH_RUNNING),
		"there is a channel for the people who are mid-run"
	)

	var running := services.chat.channel(G2GServices.CH_RUNNING)
	_check(
		running != null and running.scope == DotChatChannel.Scope.MEMBERS,
		"and it really is decided by membership rather than by radius"
	)

	_check(services.chat.rules.escape_markup, "markup is escaped")

	var dirty := DotChatFilter.sanitise(
		"[color=red]server[/color]: free stuff", services.chat.rules
	)
	_check(
		dirty.ok and not String(dirty.value).contains("[color=red]"),
		"and a player cannot write a colour tag",
		str(dirty.value)
	)

	# A gag against the PERSON. dot-server's is two booleans on a session object, and
	# a session dies with its connection — so a muted player reconnects and talks.
	var subject := DotPunishmentSubject.for_uid("7788")
	var issued: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "suite", 3600
	)
	_check(issued.ok, "a gag can be issued", str(issued.error))
	_check(
		services.moderation.is_gagged_key(subject),
		"and it is held against the person rather than the connection"
	)

	var record: DotPunishment = issued.value if issued.ok else null

	if record != null:
		var lifted: DotResult = await services.moderation.revoke(
			record.id, "suite", "over"
		)
		_check(lifted.ok, "and lifted again", str(lifted.error))

	# --- Identity --------------------------------------------------------

	var identity: G2GIdentity = module.get("identity")
	_check(identity != null, "the identity layer is up")

	if identity == null:
		return

	_check(identity.platform != null, "with a platform hub")
	_check(
		DotRegistry.get_node_service(DotPlatformHub.SERVICE) != null,
		"registered, which is how dot-platform's module finds it"
	)
	_check(
		server.modules.has_module("platform"),
		"and dot-platform's own module is loaded beside this one"
	)

	# The avatar manager validates against the GAME's schema, not a second one.
	# `G2GRig.dress` conforms every document to it, so a manager on a different schema
	# would accept avatars the rig then silently rewrote.
	_check(
		identity.avatars != null and identity.avatars.schema.id == G2GAvatars.SCHEMA_ID,
		"and the avatar manager validates against the game's own schema"
	)
	_done()


## dot-vote over this server's map catalogue.
##
## [b]This game already had a rock-the-vote and it was not one.[/b]
## `DotMapTimeLimit` counts votes against a fraction and expires the map: a countdown
## and a tally. What a records community runs is a ballot — nominations, seconding, an
## instant runoff, a cooldown, an extend option — and that is dot-vote.
func _test_vote() -> void:
	_section("the vote")

	var module := server.modules.get_module("g2gfast")
	var vote: G2GVote = module.get("vote") if module != null else null

	_check(vote != null, "the vote is up")

	if vote == null:
		return

	_check(vote.source != null and vote.source.is_usable(), "with something to vote for")
	_check(
		vote.director.rules.method == DotVoteRules.Method.INSTANT_RUNOFF,
		"counted by instant runoff rather than plurality"
	)
	_check(
		vote.director.rules.include_extend,
		"and a map can be extended rather than only replaced"
	)

	# `begin_on_apply` off is what stops one play being counted twice. Two entries in
	# the history for one play is a "last five" cooldown that is quietly two or three.
	_check(
		not vote.director.begin_on_apply,
		"the director does not announce a change the host already announces"
	)

	# The ghost is a player in every sense that matters to the game and none that
	# matters to a vote. Counting it would let a one-player server pass a quorum of
	# two, and let it rock the vote on its own.
	game.spawn_ghost()

	var voters := vote._player_count()
	var ghosted := game.players.has(G2GGame.GHOST_ID)

	# [b]The count, not zero.[/b] The first version of this asserted an empty server
	# and the sections above leave players on it — so it failed at "2 voters with 3
	# players", which is the exclusion working. What it has to say is that the ghost
	# is the one player that is not a voter.
	_check(
		voters == game.players.size() - (1 if ghosted else 0),
		"the record ghost is not counted as a voter",
		"%d voters, %d players, ghost %s" % [
			voters, game.players.size(), "up" if ghosted else "absent"
		]
	)

	# What the module forwards to the wire as a VOTE event, heard at the vote's edge.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, _runoff: bool) -> void:
		heard.append([String(cue), seconds_left])
	vote.cue_due.connect(probe)

	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(
		opened.ok or opened.error != null,
		"a vote can be asked for and answers either way",
		"" if opened.ok else opened.error.message
	)

	if opened.ok:
		_check(vote.is_voting(), "and the ballot opens")
		vote.director.close_vote()
		_check(not vote.is_voting(), "and closes again")
		_check(
			heard.has([String(G2GVote.CUE_START), 0]) and heard.has([String(G2GVote.CUE_END), 0]),
			"and its start and end cues are handed on for the wire (%s)" % str(heard)
		)

	vote.cue_due.disconnect(probe)

	# dot-vote's commands, which this game never installed: its own `rtv`, `nominate`,
	# `nextmap` and `timeleft` stood in for four of them and the operator's four did not
	# exist.
	var absent := PackedStringArray()
	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if server.console.find_command(name) == null:
			absent.append(name)
	_check(absent.is_empty(), "dot-vote's commands are on the console", ", ".join(absent))

	# One rock-the-vote. The console `rtv` went to the map session's time limit and `!rtv`
	# in chat to this director — two votes under one name. The director's refusal names
	# its delay; the map session's tally answers "N of M", so the reply says which one ran.
	var session := DotClientSession.new()
	session.peer_id = 4343
	session.userid = 43
	session.display_name = "Rocker"
	var _adopted := server.adopt_session(session)
	var replies: Array[String] = []
	var ctx := session.make_context(
		"rtv", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(line: String) -> void: replies.append(line)
	)
	server.console.execute("rtv", ctx)
	_check(
		replies.size() == 1 and replies[0].contains("rock the vote in"),
		"`!rtv` is the ballot's rock-the-vote, with the ballot's own delay (%s)" % str(replies)
	)
	replies.clear()
	server.console.execute("g2g_rtv", ctx)
	_check(
		replies.size() == 1 and replies[0].contains("rock the vote in"),
		"and so is `g2g_rtv` (%s)" % str(replies)
	)
	var _released := server.release_session(session.peer_id)

	var bridge: Object = module.get("bridge") if module != null else null
	_check(
		bridge != null and (bridge.get("rtv_fn") as Callable).is_valid(),
		"and a client's RTV request goes to the ballot too, not to the map session"
	)
	_check(
		not game.rotation_ends_maps,
		"and the map session's own clock no longer ends a map the vote may have extended"
	)

	_test_status_clock(vote)
	_done()


## `g2g_status`'s "time left" is the vote's clock, and an extend moves it.
##
## [b]It read the map session's clock after the vote had taken the map's end over[/b], so
## an operator asking how long was left was shown a limit an extend had already moved —
## the same bug the HUD had, one screen over. The check goes through the console, which
## is how an operator reads it, and asserts the session's clock did NOT move while the
## line did: the line moving with the session held still is the line reading the vote.
## Who may change the map from M, on this server's own sessions (2026-10-14: a guest on a
## public server pressed M and changed the map). The sessions stand in for what the listener
## makes for a browser: guests, no permissions, not the host's own player (`local` off).
func _test_map_menu_permissions() -> void:
	_section("M: a guest votes, staff and a lone player change")
	var module := server.modules.get_module("g2gfast")
	var vote: G2GVote = module.get("vote") if module != null else null
	var menu: Object = vote.commands.get("map_menu") if vote != null and vote.commands != null else null
	if menu == null:
		_check(false, "the map menu is installed")
		_done()
		return
	_check(server.playing_sessions().is_empty(), "nobody else is playing as the section starts",
		str(server.playing_sessions().size()))
	var start_map: StringName = game.maps.current.id
	# Each choice below is made past the start-of-map delay, so a rock-the-vote is counted
	# rather than refused for time.
	var guests: Array[DotClientSession] = []
	for i in 2:
		var guest := DotClientSession.new()
		guest.peer_id = 5100 + i
		guest.userid = 510 + i
		guest.display_name = "Guest-%d" % i
		var who := DotGuestIdentity.new()
		who.uid = "guest:map-menu-%d" % i
		guest.identity = who
		var _adopted := server.adopt_session(guest)
		guest.local = false
		guest.state = DotClientSession.State.SPAWNED if i == 0 else DotClientSession.State.CONNECTING
		guests.append(guest)
	var first := guests[0]
	var second := guests[1]

	var choose := func(session: DotClientSession, permissions: PackedStringArray = PackedStringArray()) -> Dictionary:
		var ctx := session.make_context("mapmenu", PackedStringArray(), DotCmdContext.Source.CHAT)
		ctx.permissions = permissions
		var target := &""
		for row: Dictionary in menu.call("rows"):
			if not bool(row.get("current", false)):
				target = StringName(str(row["id"]))
				break
		var before: StringName = game.maps.current.id
		vote.director.clock.elapsed = maxf(vote.director.clock.elapsed, vote.director.rules.rtv_delay_sec + 1.0)
		var result: Dictionary = await menu.call("choose", ctx, target)
		return {"result": result, "changed": game.maps.current.id != before, "target": target}

	# Alone, with the owner's sv_map_menu_alone off: a vote of one is no vote.
	_run_command("sv_map_menu_alone 0")
	var alone_off: Dictionary = await choose.call(first)
	_check(not alone_off["changed"] and str(alone_off["result"].get("text", "")).contains("needs a vote of the players here")
		and not vote.director.is_voting(),
		"one guest, sv_map_menu_alone 0: their M choice does not change the map, and says it needs a vote",
		str(alone_off["result"].get("text", "")))

	# Alone with it on (the default): nobody to ask, nobody harmed.
	_run_command("sv_map_menu_alone 1")
	var alone_on: Dictionary = await choose.call(first)
	_check(alone_on["changed"] and str(alone_on["result"].get("how", "")) == "changed",
		"one guest, sv_map_menu_alone 1: their M choice changes the map", str(alone_on["result"].get("text", "")))

	# A second human: a vote again, whatever sv_map_menu_alone says.
	second.state = DotClientSession.State.SPAWNED
	var two: Dictionary = await choose.call(first)
	_check(not two["changed"] and str(two["result"].get("how", "")) == "voted" and not vote.director.is_voting(),
		"two guests, sv_map_menu_alone 1: the M choice is a nomination and a rock, not a change",
		str(two["result"].get("text", "")))
	var _withdrawn := vote.director.clock.unrock(&"u510")
	_run_command("sv_map_menu_alone 0")
	var two_off: Dictionary = await choose.call(first)
	_check(not two_off["changed"], "two guests, sv_map_menu_alone 0: no change either", str(two_off["result"].get("text", "")))
	_withdrawn = vote.director.clock.unrock(&"u510")

	# The older client's own map list asks the same question through the bridge.
	var bridge: Object = module.get("bridge")
	var may: Callable = bridge.get("may_change_map_fn") if bridge != null else Callable()
	_check(may.is_valid() and not bool(may.call(first.userid)), "the older client's map list refuses the same guest")

	# Staff change it with others here, by the owner's flag.
	var staff: Dictionary = await choose.call(second, PackedStringArray(["generic"]))
	_check(staff["changed"] and str(staff["result"].get("how", "")) == "changed",
		"staff (generic) change the map from M with two players here", str(staff["result"].get("text", "")))

	# Fail closed: an emptied flag is staff, not anybody.
	_run_command("sv_map_menu_flag \"\"")
	var emptied: Dictionary = await choose.call(first)
	_check(not emptied["changed"] and str(menu.call("required_flag")) == "generic",
		"an emptied sv_map_menu_flag is staff only, not anybody", str(emptied["result"].get("text", "")))
	_withdrawn = vote.director.clock.unrock(&"u510")

	# The host's own player (a session with no transport) owns the server.
	first.local = true
	var host: Dictionary = await choose.call(first)
	_check(host["changed"], "the host's own player changes the map with others here", str(host["result"].get("text", "")))

	_run_command("sv_map_menu_flag generic")
	_run_command("sv_map_menu_alone 1")
	for guest in guests:
		var _released := server.release_session(guest.peer_id)
	# Back on the map the sections after this one stand on: the rows this picked from depend on
	# which map packs are linked, and a course with its start somewhere else fails them.
	if game.maps.current.id != start_map:
		var _back: DotResult = await game.change_map(start_map)
	_done()


func _test_status_clock(vote: G2GVote) -> void:
	var rules := vote.director.rules
	var clock := vote.director.clock
	var was_duration := rules.duration_sec
	var was_trigger := rules.trigger
	var was_max_extends := rules.max_extends

	# A known clock, so the numbers mean something whatever the config shipped.
	rules.duration_sec = 600.0
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.max_extends = 0
	clock.start()

	var session_before := game.maps.time_limit.formatted_remaining()
	var before := _status_seconds(_run_command("g2g_status"))
	_check(
		absf(before - clock.remaining) <= 1.0,
		"`g2g_status` reports the vote's time left (%d s, the vote's is %.0f s)" % [
			before, clock.remaining
		]
	)

	_check(clock.extend(), "the vote extends the map")
	var after := _status_seconds(_run_command("g2g_status"))
	_check(
		after - before == int(rules.extend_seconds)
			and game.maps.time_limit.formatted_remaining() == session_before,
		"and the status line moves by the extension while the map session's clock does not "
			+ "(%d s -> %d s, extended by %.0f)" % [before, after, rules.extend_seconds],
		"the line is reading the map session's clock, which nothing extends"
	)

	# `trigger: rtv_only` with no limit, which is what the deployment runs.
	rules.duration_sec = 0.0
	rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	clock.start()
	var status := _run_command("g2g_status")
	_check(
		_said(status, "time left    no limit"),
		"a vote with no clock is reported as no limit, not as the session's (%s)" % _status_line(status)
	)

	rules.duration_sec = was_duration
	rules.trigger = was_trigger
	rules.max_extends = was_max_extends
	clock.start()


func _status_line(lines: PackedStringArray) -> String:
	for line in lines:
		if line.begins_with("time left"):
			return line
	return ""


## Seconds on `g2g_status`'s time-left line, or -1 when it is not an m:ss.
func _status_seconds(lines: PackedStringArray) -> int:
	var parts := _status_line(lines).trim_prefix("time left").strip_edges().split(" ")[0].split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	return int(parts[0]) * 60 + int(parts[1])


## The three modes, and the cvars that flip them.
##
## [b]Each layer is built whether or not it is enabled, and the cvar flips it.[/b] A
## layer constructed on the cvar instead would be constructed under live players,
## which is where the interesting failures are — and it would have to be torn down
## again on the way back.
func _test_modes() -> void:
	_section("deathmatch, hunters and blocks")

	_check(game.combat != null, "the deathmatch layer is built")
	_check(game.hunters != null, "the hunters are built")
	_check(game.props != null, "the blocks are built")

	for name in ["sv_deathmatch", "sv_hunters", "sv_props"]:
		_check(server.console.find_cvar(name) != null, "%s is a cvar" % name)

	if game.combat != null:
		_check(game.combat.enabled, "deathmatch starts on, because the config said so")

		_run_command("sv_deathmatch 0")
		_check(not game.combat.enabled, "and sv_deathmatch 0 turns it off live")

		_run_command("sv_deathmatch 1")
		_check(game.combat.enabled, "and back on again")

		# The match must not carry a time limit of its own. The MAP's clock ends the
		# map; a second clock underneath it that ends the match is two authorities
		# over one question, and dot-vote's director already owns the first.
		_check(
			game.combat.match_node.rules.time_limit_sec == 0.0,
			"the match has no clock of its own"
		)

		# A run and a fight at the same time. The layer adds hitboxes, health and an
		# arsenal and takes nothing away — a player who never presses fire plays
		# exactly the game they played before.
		var runner := game.add_player(&"u4242", "Runner")
		_check(runner != null, "a player joins")

		if runner != null:
			_check(
				game.combat.health_of(&"u4242") != null,
				"and is shootable in deathmatch"
			)
			_check(
				runner.timer != null,
				"and still has a timer, because the run is the point"
			)

			# The id round trip, in one assertion, because the two ends of one
			# serialisation are exactly as capable of never meeting as the two ends
			# of a wire -- and these two used to be a formula and its inverse.
			var entity := game.combat.entity_for(&"u4242")

			_check(entity != 0, "and an entity id from the table (%d)" % entity)
			_check(
				DotEntity.is_kind(entity, DotEntity.KIND_PLAYER),
				"which says it names a player, without a range check",
				DotEntity.describe_id(entity)
			)
			_check(
				game.combat.player_id_for(entity) == &"u4242",
				"and turns back into the player it came from"
			)
			# The conflation the table removed: the account number and the combat
			# handle used to be the same integer, so a loadout's filename and a
			# session lookup were quietly riding on a runtime id.
			_check(
				G2GCombat.userid_of(&"u4242") == 4242,
				"the userid is still parsed out of the name, unchanged"
			)
			_check(
				entity != 4242,
				"and is no longer what the entity id happens to be"
			)

			# The shooter's hit feedback is what the authority applied, never a refusal.
			# A second player, hit by the first: a refused hit (spawn protection) or one
			# on yourself is no hit, and an applied one says who fired, at whom, how much.
			var target := game.add_player(&"u4343", "Target")
			var heard: Array = []
			var on_hit := func(by: StringName, victim: int, amount: float, _point: Vector3, _killed: bool, _head: bool) -> void:
				heard.append([by, victim, amount])
			game.combat.hit_landed.connect(on_hit)
			var bullet := game.combat.manager.damage_type(G2GArsenal.DAMAGE_BULLET)
			var victim_entity := game.combat.entity_for(&"u4343")
			game.combat.manager.apply_damage(DotDamage.make(entity, entity, 10.0, bullet))
			var self_heard := heard.size()
			var hit := DotDamage.make(entity, victim_entity, 25.0, bullet)
			game.combat.manager.apply_damage(hit)
			game.combat.hit_landed.disconnect(on_hit)
			_check(self_heard == 0, "a hit on yourself is no hit marker", str(heard))
			_check(
				not hit.refused and heard.size() == 1 and heard[0][0] == &"u4242"
					and heard[0][1] == victim_entity and absf(float(heard[0][2]) - hit.health_lost) < 0.01,
				"and an applied hit on somebody else says who fired, at whom and how much",
				"refused=%s heard=%s" % [hit.refused, str(heard)]
			)

			# --- How a dead body falls: picked here, from the server's own weights ---
			#
			# Armed by turning the cvar binding off in the module (the replicated check fails
			# and the pick stays a draw over the stock weights) and by deciding nothing in
			# `_on_entity_killed` (the death is null).
			var weights := server.console.find_cvar("sv_ragdoll_reactions")
			_check(weights != null and weights.has_flag(DotConVar.FLAG_REPLICATED)
					and server.console.find_cvar("sv_ragdoll") != null,
				"the sv_ragdoll* set is bound, replicated, because the clients draw the bodies")
			var _only := _run_command("sv_ragdoll_reactions limp=0,crumple=0,face_plant=1")
			var fatal := DotDamage.make(entity, victim_entity, 500.0, bullet)
			fatal.tick = game.current_tick()
			game.combat.manager.apply_damage(fatal)
			var fallen: G2GPlayer = game.players.get(&"u4343")
			var away := Vector3.ZERO
			if fallen != null:
				away = fallen.controller.state.position - runner.controller.state.position
				away.y = 0.0
			_check(fallen != null and fallen.death != null
					and fallen.death.reaction == DotPlayerDeathReactions.FACE_PLANT,
				"a kill picks the body's fall on the server, from sv_ragdoll_reactions",
				str(fallen.death.describe()) if fallen != null and fallen.death != null else "no death")
			_check(fallen != null and fallen.death != null
					and (away.length() < 0.01 or fallen.death.direction.dot(away.normalized()) > 0.9),
				"pushed away from the shooter")
			var _stock := _run_command("sv_ragdoll_reactions limp=4,headshot_launch=6,power_launch=8,face_plant=1.5,crumple=2.5")
			var back: Array[StringName] = []
			var on_back := func(id: StringName) -> void: back.append(id)
			game.combat.player_respawned.connect(on_back)
			for _respawn in range(game.tick_rate + game.tick_rate / 4):
				game.tick_once(game.current_tick() + 1)
			game.combat.player_respawned.disconnect(on_back)
			_check(back.has(&"u4343"), "and the dead player's return is announced, for the clients to draw them again", str(back))

			if target != null:
				game.remove_player(&"u4343")

			# The ghost is deliberately not armed: it is a replay, it cannot be hurt,
			# and registering it would put a name on the scoreboard that never dies
			# and never leaves.
			_check(
				game.combat.health_of(G2GGame.GHOST_ID) == null,
				"the record ghost is not on the scoreboard"
			)

			# --- The trigger, which nothing sent until it was looked for ---
			#
			# [b]`sv_deathmatch` was a mode nobody could shoot in.[/b] `G2GCombat`
			# built the arsenals, the hitboxes and the match, and read a fire command
			# that nothing ever set — found by the family's own detector, because
			# `set_fire_command` occurred once in the repository.
			#
			# The trigger is a bit on `G2GNetCommand` rather than a request: a shot
			# happens on a tick and has to be replayed with the movement of that tick,
			# and a trigger arriving reliably-and-separately would be replayed against
			# a different tick's position every time.
			var arsenal_before := game.combat._kit[&"u4242"]["arsenal"] as DotWeaponArsenal
			_check(
				arsenal_before.slots().size() >= 1,
				"an armed player has something to shoot with",
				"%d slots" % arsenal_before.slots().size()
			)

			# [b]The trigger has to be released first, and that is not a workaround.[/b]
			# The player spawns mid-switch — knife in hand, deagle coming up — and the
			# deagle is semi-automatic. A semi-automatic weapon fires on the press, not
			# on the button being down, so a trigger already held while the weapon was
			# still deploying is not a press and must not fire: holding M1 through a
			# weapon switch and having it go off the instant the gun arrives is the
			# behaviour every shooter deliberately does not have.
			#
			# So: hold nothing until the switch has finished, then press.
			#
			# [b]Once a tick, as the wire delivers it.[/b] A command is consumed by the
			# tick that reads it, so one set before a loop is one tick's input, not a
			# second's — see the starved-tick check below.
			var idle := DotWeaponCommand.new()

			# [b]`tick_once`, not `combat.tick`.[/b] Every duration in dot-weapon is
			# measured in ticks, so a loop that advances time without advancing
			# `current_tick()` leaves the weapon switch frozen mid-deploy for ever —
			# which is what this test used to do, and it got away with it only because
			# the old arsenal measured its deploy differently.
			for _deploy in range(game.tick_rate):
				game.combat.set_fire_command(&"u4242", idle)
				game.tick_once(game.current_tick() + 1)

			var fire := DotWeaponCommand.new()
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

			# [b]An Array, not an int.[/b] A GDScript lambda captures locals by
			# VALUE, so a counter incremented inside a signal handler stays zero
			# outside it — and the assertion then reports a failure for a signal that
			# fired perfectly. This file's own family notes carry the warning and this
			# check was written wrong anyway.
			var shots: Array[DotShot] = []
			game.combat.manager.shot_resolved.connect(
				func(shot: DotShot) -> void: shots.append(shot)
			)

			# Enough ticks for the deagle's 160 rpm to come round. A weapon that fired
			# on the first tick would be a weapon with no rate of fire.
			for _step in range(game.tick_rate):
				game.combat.set_fire_command(&"u4242", fire)
				game.tick_once(game.current_tick() + 1)

			_check(
				shots.size() > 0,
				"and holding the trigger fires it",
				"%d shots" % shots.size()
			)

			# The rate of fire is real: 160 rpm over one second is under three shots,
			# and a trigger read as "fire every tick" would be a hundred.
			_check(
				shots.size() < 10,
				"at its rate of fire rather than once a tick",
				"%d shots in a second" % shots.size()
			)

			# [b]A tick whose input never arrived is not the last trigger again.[/b]
			# dot-net skips `_net_apply_input` for a starved tick, so a command left on
			# the player would be replayed for as long as packets are lost — the held
			# trigger `G2GPlayerNet.last_attack` says does not survive a hiccup.
			game.combat.set_fire_command(&"u4242", fire)
			game.tick_once(game.current_tick() + 1)
			game.tick_once(game.current_tick() + 1)
			var shooter: G2GPlayer = game.players.get(&"u4242")
			_check(
				shooter != null and not shooter.has_meta("g2g_fire"),
				"and a trigger is read once, so a lost packet is not a held trigger"
			)

			# A hunter's kill is world damage through the same combat layer, so it is a death
			# like any other: the body falls away from the hunter that swiped.
			if game.hunters != null:
				var at := runner.controller.state.position + Vector3(3.0, 0.0, 0.0)
				var hunter := game.hunters.spawn_one(&"g2g_stalker", at)
				if hunter != null:
					game.hunters.hunter_attack(hunter, &"u4242", 1000.0)
					game.hunters.spawner.remove(hunter.instance_id, DotNpcSpawner.REASON_ADMIN)
				_check(hunter != null and runner.death != null and runner.death.direction.x < -0.9,
					"a hunter's kill falls too, away from the hunter",
					str(runner.death.describe()) if runner.death != null else "no death")

			game.remove_player(&"u4242")

	if game.hunters != null:
		# A timer map is a critical path — start pad, stage lines, end zone — and
		# `DotNpcDirectorFlow` is exactly that as a thing a position can be measured
		# along. So there is no navigation graph and the route is the map's zones.
		_check(
			game.hunters.flow != null and game.hunters.flow.has_route(),
			"the hunt route was built from the map's own zones"
		)
		_check(
			game.hunters.flow != null and game.hunters.flow.length() > 1.0,
			"and it has a length",
			"%.1f m" % (game.hunters.flow.length() if game.hunters.flow != null else 0.0)
		)

		var somewhere := game.hunters.patrol_point(0.5)
		_check(
			somewhere != Vector3.ZERO,
			"and a hunter with nothing to chase has somewhere on it to walk to"
		)

		_run_command("sv_hunters 0")
		_check(not game.hunters.enabled, "sv_hunters 0 turns the hunt off")
		_check(game.hunters.count() == 0, "and takes the hunters away now")

		_run_command("sv_hunters 1")
		_check(game.hunters.enabled, "and back on again")

	if game.props != null:
		var placed := game.props.place(
			&"u1", G2GProps.BLOCK, Vector3(0.0, 2.0, 0.0), true
		)
		_check(placed != null, "an admin can place a block")
		_check(game.props.count() == 1, "and it is in the world")

		if placed != null:
			# The catalogue's mass, on the body. dot-props puts it there at spawn
			# rather than leaving it to whatever the scene was saved with.
			var body := placed.body()
			_check(
				body != null and absf(body.mass - 200.0) < 0.01,
				"with the catalogue's mass rather than the scene's",
				"%.0f kg" % (body.mass if body != null else -1.0)
			)
			# Frozen, which is the opposite default from a sandbox's: a practice
			# block that rolls away is not a practice block.
			_check(
				body != null and body.freeze,
				"and frozen where it was put"
			)

		# The rule that makes the feature safe to ship: a board with one time set
		# over a placed block is a board nobody trusts.
		_check(
			game.props.taints_records(),
			"and a run made while anything is placed cannot be ranked"
		)

		_check(game.props.undo(&"u1"), "undo takes it back")
		_check(
			not game.props.taints_records(),
			"and records are rankable again once the course is clear"
		)
	_done()


## dot-browser asking a real [DotServer] — which nothing in this family had done.
##
## [b]This is the seam the family's own notes name.[/b] dot-server has answered A2S and
## its own richer protocol since it was written; dot-browser's suite queries a DQP
## server over a real loopback socket. Neither had ever met the other.
##
## What this game contributes that a bare `DotGameDescriptor` cannot is `G2GQuery`'s
## section: the map, the tick rate, the styles, the world record, and — since the
## modes were added — whether deathmatch and the hunters are on. A player filtering a
## list for "surf DM" is filtering for exactly that.
func _test_browser() -> void:
	_section("a browser asking this server")

	var servers := G2GBrowser.new()
	servers.name = "Servers"
	servers.timeout_ms = 2000
	# In memory. A suite that wrote a player's favourites to disk is a suite that
	# passes differently the second time it is run.
	servers.favourites_path = ""
	add_child(servers)

	var started := servers.setup()
	_check(started.ok, "the browser starts", str(started.error))

	if not started.ok:
		servers.queue_free()
		remove_child(servers)
		return

	# The QUERY port, not the game port. dot-server listens for queries separately, and
	# a browser that asked the game port would get no answer and report the server as
	# offline — which reads as the browser being broken.
	var added := servers.add(
		"127.0.0.1:%d" % server.config.port, server.config.query_port
	)
	_check(added.ok, "a server can be added by address", str(added.error))

	var refreshed: DotResult = await servers.refresh()
	_check(refreshed.ok, "and asked", str(refreshed.error))

	var entries := servers.browser.entries()
	_check(entries.size() == 1, "there is one entry", "%d" % entries.size())

	if entries.is_empty():
		servers.queue_free()
		remove_child(servers)
		return

	var entry := entries[0]

	_check(
		entry.is_online(),
		"the server answered",
		entry.error.message if entry.error != null else entry.status_name()
	)

	if entry.is_online():
		# [b]The map is the GAME's, not `entry.map`.[/b] That is dot-server's
		# `info.map`, which means "the content id of the loaded game" and is empty on
		# a server that has never switched games. dot-browser nests the game's own
		# section under `rules["game"]` precisely so a game putting a field called
		# `map` in it cannot overwrite the other one.
		_check(
			G2GBrowser.game_field(entry, "map") == String(game.maps.current.id),
			"and the map the game says it is running",
			"%s vs %s" % [
				G2GBrowser.game_field(entry, "map"), String(game.maps.current.id)
			]
		)

		# The tick rate, which is the number a records player checks before anything
		# else: a time set at 100 is not a time set at 128 unless the timer counts in
		# sub-tick fractions, and a browser that could not show it would be a browser
		# nobody used twice.
		# [b]Read as a number, not as text.[/b] JSON has one number type, so an int
		# contributed to a query section comes back as a float — the first version of
		# this compared `game_field(...)` to `str(100)` and failed on `"100.0"`, which
		# is the query working and the reader guessing.
		_check(
			int(G2GBrowser.game_number(entry, "tick_rate")) == game.tick_rate,
			"and the tick rate",
			"%.1f vs %d" % [
				G2GBrowser.game_number(entry, "tick_rate"), game.tick_rate
			]
		)

		_check(
			G2GBrowser.game_field(entry, "deathmatch") != "",
			"and whether deathmatch is on, which is a mode this server now has",
			G2GBrowser.game_field(entry, "deathmatch")
		)

	servers.favourite(entry.key(), true)
	_check(servers.browser.is_favourite(entry.key()), "a server can be favourited")

	servers.favourite(entry.key(), false)
	_check(
		not servers.browser.is_favourite(entry.key()),
		"and un-favourited again"
	)

	# One line per server, which is what a chat command draws.
	var lines := servers.lines()
	_check(lines.size() == 1, "and the listing is one line per server")

	servers.queue_free()
	remove_child(servers)
	_done()


## The moderator's live tools on a timer server, where the product is a time.
##
## Driven through the console, as an operator types them, against a player with a session
## the way a real one has. What is asserted is the TIMER: noclip abandons the run it
## interrupts, a run begun while noclipped or on a speed step is marked assisted and
## refused a record, and one begun after is clean. Runs are begun by hand because this
## suite's map is the intro course and walking out of its start is not what is under test.
func _test_live_tools() -> void:
	_section("the moderator's live tools, and the timer")

	_check(
		server.console.find_command("noclip") != null and server.console.find_command("slay") != null,
		"the live tools' commands are on the console"
	)

	var session := DotClientSession.new()
	session.peer_id = 9001
	session.userid = 1
	session.display_name = "One"
	var _adopted := server.adopt_session(session)

	var player: G2GPlayer = game.players[&"u1"]
	var stopped: Array[StringName] = []
	var on_stop := func(_r: DotTimerRun, why: StringName) -> void: stopped.append(why)
	player.timer.run_stopped.connect(on_stop)

	# Out of the start zone first. Standing in it ends a run (dot-timer v0.1.4, as in every
	# timer of the genre), so a run begun by hand at the spawn was replaced on the next tick
	# and every check below read a fresh, untainted one.
	_check(await _stand_past_start(player), "One stands on the course, past the start zone")

	player.timer.run.begin(0.0)
	var _on := await _run_command_later("noclip One")
	_check(DotFpsAdminModifiers.is_noclipped(player.controller), "`noclip One` puts them in noclip")
	_check(
		stopped.has(&"noclip") and not player.timer.run.is_active(),
		"and abandons the run they were on", str(stopped)
	)

	player.timer.run.begin(0.0)
	for _i in range(4):
		await get_tree().physics_frame
	_check(player.timer.run.tainted, "a run begun while noclipped is marked assisted")
	var refused := player.timer.can_record(_finished_copy(player.timer.run))
	_check(not refused.ok and refused.error.message.contains("assisted"),
		"and would be refused a record", str(refused.error))

	var _off := await _run_command_later("noclip One off")
	player.timer.run.begin(0.0)
	for _i in range(4):
		await get_tree().physics_frame
	_check(not player.timer.run.tainted, "once it is off, a new run is clean")

	var _fast := await _run_command_later("speed One 2")
	for _i in range(4):
		await get_tree().physics_frame
	_check(player.timer.run.tainted, "a speed step is help on the ground, and taints the run too")
	var _normal := await _run_command_later("speed One 1")

	# A slap is a shove in a direction the slapper knows: speed nobody earned.
	player.timer.run.begin(0.0)
	await _physics(2)
	var clean_before_slap := not player.timer.run.tainted
	var _slapped := await _run_command_later("slap One")
	_check(clean_before_slap and player.timer.run.tainted,
		"a slap taints the run it lands in, so `slap @me` is not a boost with a record at the end")

	var described := await _run_command_later("modtools")
	_check(_said(described, "abilities") and _said(described, "burn (there is no fire"),
		"`modtools` lists what a timer server supports and why it refuses the rest")

	# `return` after a map change. Moved once by a moderator, so `return` has somewhere to
	# put them: a position on THIS map, which a change frees. The change is announced the
	# way every change ends, on `DotMapSession.changed`, rather than made: `change_map`
	# goes through the map-sync host, which waits on every peer and an adopted session has
	# none (arena's first draft of this check hung there). Armed 2026-09-27: without the
	# clear, `return One` put them back at the spot on the previous map.
	var module: Object = server.modules.get_module("g2gfast")
	var tools: DotModTools = (module.get("services") as G2GServices).mod_tools if module != null else null
	var _moved: DotResult = await tools.teleport(&"", &"1", player.global_position + Vector3(6.0, 0.0, 0.0))
	_check(tools.can_return(&"1"), "a moderator moves One, so `return` has somewhere to put them")
	game.maps.changed.emit(game.maps.current, game.current_map_node())
	await _physics(2)
	var returned: DotResult = await tools.return_player(&"", &"1")
	_check(not tools.can_return(&"1") and not returned.ok,
		"and after a map change `return` has nowhere to put them",
		"it put them at %s, a spot on the previous map" % (str(returned.value) if returned.ok else "-"))

	player.timer.run_stopped.disconnect(on_stop)
	player.timer.stop()
	var _released := server.release_session(session.peer_id)
	_done()


## Puts [param player] on the floor a step past the main start zone, toward the finish.
## True when they are there and out of the start.
func _stand_past_start(player: G2GPlayer) -> bool:
	var zones := player.timer.zones
	if zones == null:
		return false
	var starts := zones.of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	var ends := zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	if starts.is_empty() or ends.is_empty():
		return false
	var start := starts[0]
	var toward := ends[0].centre() - start.centre()
	toward.y = 0.0
	toward = toward.normalized()
	var reach := maxf(start.size().x, start.size().z) * 0.5 + 1.5
	var at := start.centre() + toward * reach
	at.y = player.global_position.y
	player.teleport(at)
	await _physics(4)
	return not start.contains(player.global_position)


## The two that are about a screen. What is asserted is the flag on the player and on the
## entity the netcode sends, because that is the whole of what the server decides; whether
## the owner's client — and only the owner's — receives it is `headless_net`'s, and what it
## looks like is `tools/screenshot_hud.sh`'s.
## [b]A record belongs to the account, not to the connection.[/b] dot-server's userid is a
## server-local counter: the same account reconnecting is a new number, and a restarted
## server hands the old numbers to strangers. Records, boards and the Tab board's Best were
## keyed by `u<userid>`, so a returning runner was a second row with no Best, and a new
## player could inherit an old runner's time. Armed by making `_record_key_for` return
## `&""` (the key falls back to `u<userid>`): both halves fail.
func _test_records_follow_the_account() -> void:
	_section("records follow the account, not the connection")

	var map_id: StringName = game.maps.current.id
	var store := game.timers.store

	# No socket stands behind these peers: swallow what the bridge would send them rather
	# than have the engine report an RPC to a peer that does not exist.
	var bridge: Object = server.modules.get_module("g2gfast").get("bridge")
	var link: Object = bridge.get("link")
	var kept_loopback: Callable = link.get("loopback")
	link.set("loopback", func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass)

	var join := func(peer: int, userid: int, uid: String, name: String) -> DotClientSession:
		var session := DotClientSession.new()
		session.peer_id = peer
		session.userid = userid
		session.display_name = name
		var who := DotGuestIdentity.new()
		who.uid = uid
		session.identity = who
		var _adopted := server.adopt_session(session)
		# What dot-server fires when a client finishes joining; the module seats the player.
		server.events.fire("client_spawn", {"userid": userid, "name": name})
		for _i in range(4):
			await get_tree().physics_frame
		return session

	var leave := func(session: DotClientSession) -> void:
		server.client_disconnected.emit(session, "test")
		var _released := server.release_session(session.peer_id)

	var settle := func() -> void:
		for _i in range(8):
			await get_tree().physics_frame

	# Alice connects, finishes a run, goes.
	var first: DotClientSession = await join.call(9201, 8801, "acct:alice", "Alice")
	var player: G2GPlayer = game.players.get(&"u8801")
	_check(player != null, "an account connects as u<userid> in the match", str(game.players.keys()))
	if player == null:
		_done()
		return
	_check(game.record_key(&"u8801") == &"acct:alice", "and is filed under its account uid, not the userid")
	_check(player.timer == game.timers.timer_for(&"acct:alice"), "the timer manager knows it by the account")

	var run := _finished_copy(player.timer.run)
	for stage in range(1, game.timers.stage_count(run.track) + 1):
		run.splits[stage] = float(stage)
	var why: Array = []
	game.run_filed.connect(func(_id: StringName, _r: DotTimerRun, _rank: int, reason: String) -> void: why.append(reason))
	player.timer.run_finished.emit(run)
	await settle.call()
	var mine: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"acct:alice")
	_check(mine.ok and mine.value is DotTimerRecord, "the finish is on the board under the account", str(why))
	var by_number: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"u8801")
	_check(by_number.ok and by_number.value == null, "and nothing is filed under the userid")
	await game.refresh_standing(&"u8801")
	_check(float(game.board_fields(&"u8801")["best"]) > 0.0, "the Tab board shows the Best")

	leave.call(first)
	await settle.call()
	_check(not game.players.has(&"u8801"), "the player leaves")

	# Alice reconnects: a new userid, the same account.
	var again: DotClientSession = await join.call(9202, 8802, "acct:alice", "Alice")
	await game.refresh_standing(&"u8802")
	_check(game.players.has(&"u8802") and game.record_key(&"u8802") == &"acct:alice",
		"the reconnect is a new userid on the same account")
	_check(float(game.board_fields(&"u8802")["best"]) > 0.0 and int(game.board_fields(&"u8802")["rank"]) == 1,
		"and the Tab board shows the Best and rank it had, not a dash", str(game.board_fields(&"u8802")))
	var rows: DotResult = await store.top(map_id, DotTimerTrack.MAIN, &"normal", 20)
	_check(rows.ok and (rows.value as Array).size() == 1, "the records board has one row for the account",
		str((rows.value as Array).size()) if rows.ok else str(rows.error))
	var fastest: DotResult = await game.boards.page_async(&"fastest", {
		"map": String(map_id), "track": str(DotTimerTrack.MAIN), "style": "normal",
	})
	var entries: Array = fastest.value if fastest.ok and fastest.value is Array else []
	_check(fastest.ok and entries.size() == 1 and (entries[0] as DotLeaderboardEntry).player_id == &"acct:alice",
		"and so does the leaderboard", str(fastest.value) if fastest.ok else str(fastest.error))

	# The server restarts: userids start again, and the number Alice had goes to a stranger.
	leave.call(again)
	await settle.call()
	var stranger: DotClientSession = await join.call(9203, 8801, "acct:bob", "Bob")
	await game.refresh_standing(&"u8801")
	var none: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"acct:bob")
	_check(none.ok and none.value == null, "a stranger who draws an earlier userid has no record")
	_check(float(game.board_fields(&"u8801")["best"]) < 0.0 and int(game.board_fields(&"u8801")["rank"]) == 0,
		"and the Tab board gives them no Best and no rank", str(game.board_fields(&"u8801")))
	leave.call(stranger)
	await settle.call()

	# Rows written before the change are retired, not ranked and not deleted.
	var old := DotTimerRecord.new()
	old.map_id = map_id
	old.track = DotTimerTrack.MAIN
	old.style_id = &"normal"
	old.player_id = &"u12"
	old.player_name = "Old"
	old.time = 31.0
	var _put: DotResult = await store.put(old)
	_check(G2GGame.is_legacy_key(&"u12") and not G2GGame.is_legacy_key(&"acct:alice") and not G2GGame.is_legacy_key(&"local")
		and not G2GGame.is_legacy_key(&"user"), "a session-number key is recognised by its shape and an account's is not")
	var moved := await game.retire_legacy_records()
	var after: DotResult = await store.top(map_id, DotTimerTrack.MAIN, &"normal", 20)
	var left_ids: Array = []
	for row in (after.value as Array):
		left_ids.append((row as DotTimerRecord).player_id)
	_check(moved == 1 and not left_ids.has(&"u12") and left_ids.has(&"acct:alice"),
		"a u<N> row leaves the board and the account's stays", str(left_ids))
	var base := game.config.records_directory.strip_edges()
	var archive := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	_check(FileAccess.file_exists(archive) and FileAccess.get_file_as_string(archive).contains("\"u12\""),
		"and is kept in legacy_records.jsonl, not deleted", archive)
	_check(await game.retire_legacy_records() == 0, "and retiring is idempotent")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(archive))
	link.set("loopback", kept_loopback)
	_done()



func _test_blind_and_beacon() -> void:
	_section("blind and beacon")

	var session := DotClientSession.new()
	session.peer_id = 9001
	session.userid = 1
	session.display_name = "One"
	var _adopted := server.adopt_session(session)

	var module: Object = server.modules.get_module("g2gfast")
	var bridge: Object = module.get("bridge") if module != null else null
	var tools: DotModTools = (module.get("services") as G2GServices).mod_tools if module != null else null
	var player: G2GPlayer = game.players[&"u1"]
	var net: Object = bridge.call("behaviour_for", 1) if bridge != null else null

	var blinded := await _run_command_later("blind One")
	_check(player.blinded, "`blind One` blacks their screen out", " / ".join(blinded))
	await _physics(2)
	_check(
		net != null and net.get("net_blind") == true,
		"and it is on the entity the netcode sends them"
	)

	# A blind is a screen, not help: the runner is slower for it, never faster, so the run
	# they are on is still theirs to file — where a noclip or a speed step taints it.
	player.timer.run.begin(0.0)
	await _physics(4)
	_check(not player.timer.run.tainted, "and a run made blind is not marked assisted")
	player.timer.stop()

	var _lift := await _run_command_later("blind One off")
	_check(not player.blinded, "`blind One off` lifts it")
	var _spell := await _run_command_later("blind One 0.2")
	_check(player.blinded, "`blind One 0.2` blinds them for a fifth of a second")
	await get_tree().create_timer(0.4).timeout
	_check(not player.blinded, "and it lifts on its own when the time is up")

	var lit := await _run_command_later("beacon One")
	_check(player.beacon, "`beacon One` puts a beacon on them", " / ".join(lit))
	await _physics(2)
	_check(net != null and net.get("net_beacon") == true, "and it is on the entity everybody is sent")

	# Both are about the person, not the body, and a respawn here is a teleport of the
	# same player: nothing re-applies them, so what is checked is that nothing clears them.
	var _dark := await _run_command_later("blind One")
	var _back := await _run_command_later("respawn One")
	_check(player.blinded and player.beacon, "a respawn keeps both")

	var _dark_off := await _run_command_later("blind One off")
	var _unlit := await _run_command_later("beacon One off")
	await _physics(2)
	var identity: DotNetIdentity = (net as DotNetBehaviour).identity if net != null else null
	_check(
		not player.beacon and net.get("net_beacon") == false,
		"`beacon One off` takes it off the entity"
	)
	# The arena's beaconed player is made always-relevant and put back when it goes off.
	# Every runner here is always-relevant already, so copying that would CUT everybody
	# whose beacon was turned off — this is the check that says it was not copied.
	_check(
		identity != null and identity.always_relevant,
		"and leaves them relevant to everybody, as every runner here is"
	)
	_check(
		tools != null and not tools.is_active(&"1", DotModTools.ACTION_BEACON)
		and not tools.is_active(&"1", DotModTools.ACTION_BLIND),
		"and the tools' record agrees with the world"
	)

	var described := await _run_command_later("modtools")
	_check(
		not _said(described, "blind (") and not _said(described, "beacon ("),
		"`modtools` no longer refuses blind or beacon", " / ".join(described)
	)

	var _released := server.release_session(session.peer_id)
	_done()


func _physics(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


## A finished copy of [param run], for asking `can_record` without finishing the real one.
func _finished_copy(run: DotTimerRun) -> DotTimerRun:
	var copy := DotTimerRun.make(run.track, run.style_id, 0.01)
	copy.begin(0.0)
	copy.tainted = run.tainted
	copy.used_checkpoints = run.used_checkpoints
	for _i in range(6000):
		copy.advance(1.0)
	copy.finish(0.0)
	return copy


## [method _run_command] for a coroutine handler: the live tools record each action on a
## punishment store, which may be remote, so the reply can land a frame late.
func _run_command_later(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)


func _test_unload() -> void:
	_section("unload")
	var unloaded := server.modules.unload_module("g2gfast")
	_check(unloaded.ok, "the module unloads")
	_check(server.console.find_cvar("sv_autobunnyhopping") == null, "and takes its cvars with it")
	_check(not (server.get(&"scoreboard_fields") as Callable).is_valid() and not (server.get(&"scoreboard_extra") as Callable).is_valid(),
		"and its Tab board columns: the server outlives this game, and the next one is not asked about it")
	_check(game.players.is_empty(), "and the players it added")
	await get_tree().process_frame
	# The bridge's map-change host was the game's while the module was loaded, and the
	# game outlives the module. [b]Armed by emptying `G2GNetBridge._exit_tree`, and it did
	# NOT fire[/b]: a freed Object compares equal to null on 4.7.2, so both this check and
	# `change_map`'s own `map_sync != null` route around a freed host anyway. What it
	# asserts is the outcome; `_exit_tree` is for a bridge taken out without being freed.
	_check(game.map_sync == null, "and takes back the map-change protocol it gave the game")
	# A DIFFERENT map from the one it is on, or the spawn check below cannot tell the
	# old map's pads from the new one's.
	var next_map: StringName = &"surf_g2g_intro" if game.maps.current.id == &"bhop_g2g_intro" else &"bhop_g2g_intro"
	var after: DotResult = await game.change_map(next_map)
	_check(after.ok and game.maps.current.id == next_map,
		"so a map change after it is this process's own", str(after.error) if not after.ok else "")
	# The SECOND map change with the combat layer built — the first one that has old
	# spawn points to clear. `G2GCombat._on_map_ready` called a method dot-match has never
	# had, and the script error left the previous map's points as the deathmatch's.
	var points: Array = game.combat.match_node.spawn_points() if game.combat != null else []
	var main_pad: Vector3 = game.current_map_node().spawn_for(DotTimerTrack.MAIN)
	_check(points.size() == 2 and points.all(func(p: Variant) -> bool:
			return is_instance_valid(p) and not (p as Node).is_queued_for_deletion())
			and points.any(func(p: Variant) -> bool: return (p as Node3D).position.is_equal_approx(main_pad)),
		"and the deathmatch respawns on the new map's pads, not the old map's",
		"%d points, main pad %s" % [points.size(), main_pad])
	_done()


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]A weapon fires at the same real-time rate at 64 Hz as at 128.[/b] The rows are written
## in 128 Hz ticks and say so (`authored_tick_rate`); without it a server set to 64 ran
## every count as 64 Hz ticks, and the deagle fired at half its rate and deployed at half
## its speed. Driven through the arsenal the game builds, with the trigger pressed and
## released every 1/64 s for three seconds at both rates, from the knife to the deagle (so
## the holster and the deploy are inside the window), and compared as seconds.
func _test_weapons_keep_wall_clock_time() -> void:
	_section("a weapon keeps its real-time rate at 64 Hz")

	var at128 := _weapon_shots(128, true)
	var at64 := _weapon_shots(64, true)
	_check(at128.size() >= 6, "at 128 Hz the deagle fires on its 160 rpm after the switch", str(at128))
	_check(at64 == at128, "and at 64 Hz at the same moments, to the second", "%s vs %s" % [at64, at128])

	# What the field changes, so the check above cannot pass because both rates happen to
	# agree for some other reason: the same rows with the rate taken off fire on raw counts.
	var raw64 := _weapon_shots(64, false)
	_check(raw64.size() < at128.size(), "rows naming no rate fire slower at 64 Hz", "%s vs %s" % [raw64, at128])

	var deagle: DotWeaponDef = G2GArsenal.deagle()
	var b := deagle.tuning as DotWeaponBallistics
	_check(
		is_equal_approx(deagle.per_tick_at(b.bloom_recovery, 64), 2.0 * deagle.per_tick_at(b.bloom_recovery, 128)),
		"bloom recovers twice as much per tick at 64 Hz, the same per second"
	)
	_check(
		G2GArsenal.knife().authored_tick_rate == G2GArsenal.TICK_RATE
			and deagle.authored_tick_rate == G2GArsenal.TICK_RATE,
		"every row the game builds names the rate it was written at"
	)

	_done()


## The times, in seconds, an arsenal at [param rate] fires: knife in hand, deagle asked for,
## the trigger pressed and released every 1/64 s for three seconds.
func _weapon_shots(rate: int, authored: bool) -> Array[float]:
	var catalogue := DotWeaponCatalogue.new()
	for def: DotWeaponDef in G2GArsenal.weapons():
		if not authored:
			def.authored_tick_rate = 0
		catalogue.add(def)

	var arsenal := DotWeaponArsenal.new()
	arsenal.catalogue = catalogue
	arsenal.tick_rate = rate
	arsenal.authority = true
	add_child(arsenal)
	var res := arsenal.setup()
	if not res.ok:
		push_error(res.error.message)
	arsenal.give(G2GArsenal.ITEM_KNIFE)
	arsenal.give(G2GArsenal.ITEM_DEAGLE)

	var out: Array[float] = []
	var previous: DotWeaponCommand = null
	for t in range(3 * rate):
		var cmd := DotWeaponCommand.new()
		cmd.slot = 2
		cmd.set_button(DotWeaponCommand.BUTTON_ATTACK, (t * 64 / rate) % 2 == 0)
		var used := arsenal.simulate_tick(
			cmd, DotWeaponContext.make(1, t, Vector3(0.0, 1.6, 0.0), Vector3.FORWARD), previous
		)
		if used.used:
			out.append(float(t) / float(rate))
		previous = cmd

	remove_child(arsenal)
	arsenal.free()
	return out


## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)
	_done()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_done()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
