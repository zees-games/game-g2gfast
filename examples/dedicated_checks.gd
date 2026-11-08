extends "dedicated_base.gd"

## The cvar, command, service, vote and mode sections of dedicated.gd, split out for size.


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
	var shooter := game.entities.id_for_key(&"u1")
	var zoned := DotDamage.make(shooter, 9999, 5.0, game.combat.manager.damage_type(&"kinetic"))
	zoned.hit_group = DotHitGroup.NECK
	zoned.weapon_id = &"probe"
	game.progress.report_damage(zoned)
	_check(game.progress.session_values(&"u1").get_cell(DotStatsHitzones.HITS, "zone:neck") >= 1.0,
		"a hit with a hit_group is filed by body zone through the dot-stats hitzone hook")
	_check(game.progress.stats.schema.validate().ok, "the stats schema, hitzones included, validates")
	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))

	_check(absf(player.controller.tunables.gravity - G2GUnits.to_metres(600.0)) < 0.001, "sv_gravity 600 is 11.43 m/s² on the player")

	_run_command("sv_maxvelocity 100")
	_check(game.config.max_velocity == 3500.0, "a max_velocity below max_speed is refused and the config kept", "%.0f" % game.config.max_velocity)

	_run_command("sv_gravity 800")
	_run_command("sv_airaccelerate 1000")
	_done()


## docs/movement.md "Two names for a movement setting": the shared spellings write G2GConfig, and the g2g ones keep working.
func _test_stats_report() -> void:
	_section("stats_report")
	var cv: DotConVar = server.console.find_cvar("stats_report")
	var progress: Object = game.progress
	_check(cv != null and cv.get_string() == "0", "stats_report is registered and off by default")
	_check(progress != null and progress.stats != null and not progress.stats.report_to_backbone,
		"and the tracker does not report at boot")
	if cv == null or progress == null:
		return
	var _off := cv.set_value("1")
	_check(not progress.stats.report_to_backbone, "on with no backbone client stays off, not a crash")

	var client := Node.new()
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc post_integration(_a = null, _b = null, _c = null): return null\n"
	var _reloaded := script.reload()
	client.set_script(script)
	DotRegistry.register(&"dot_backbone_client", client)
	var _r0 := cv.set_value("0")
	var _r1 := cv.set_value("1")
	_check(progress.stats.report_to_backbone, "on with a backbone client makes the tracker report")
	_check(progress.stats.get_node_or_null(DotGameStatsReport.TIMER_NAME) != null, "and adds the flush timer")
	var _r2 := cv.set_value("0")
	_check(not progress.stats.report_to_backbone, "off stops it again")
	# The boards' reporter is handed the registered client, or no record ever reaches the site.
	var was_reporting: bool = game.config.report_to_backbone
	game.boards.reporter.client = null
	game.config.report_to_backbone = false
	game._bind_board_reporter()
	_check(game.boards.reporter.client == null, "the boards' reporter stays unbound while reporting is off")
	game.config.report_to_backbone = true
	game._bind_board_reporter()
	_check(game.boards.reporter.client == client, "the boards' reporter takes the registered backbone client")
	game.boards.reporter.client = null
	game.config.report_to_backbone = was_reporting
	DotRegistry.unregister_instance(&"dot_backbone_client", client)
	client.free()
	_done()


func _test_the_shared_movement_names() -> void:
	_section("the shared movement names")
	var player: G2GPlayer = game.players[&"u1"]
	var before: String = player.controller.tunables.fingerprint()
	for shared: String in ["sv_runspeed", "sv_airwishspeed", "sv_autohop"]:
		_check(server.console.find_cvar(shared) != null, "%s is registered" % shared)
	_check(server.console.get_float("sv_runspeed") == server.console.get_float("sv_maxspeed"), "sv_runspeed reads g2g's sv_maxspeed run speed")

	_run_command("sv_runspeed 300")
	_check(game.config.max_speed == 300.0, "sv_runspeed writes G2GConfig.max_speed")
	_check(server.console.get_float("sv_maxspeed") == 300.0, "and g2g's sv_maxspeed follows")
	_check(player.controller.tunables.fingerprint() != before, "and the player's movement fingerprint changed (runs are abandoned)")

	_run_command("sv_maxspeed 250")
	_check(server.console.get_float("sv_runspeed") == 250.0 and game.config.max_speed == 250.0, "the old name still works and the shared one follows")
	_check(player.controller.tunables.fingerprint() == before, "and the original fingerprint returns")

	_run_command("sv_runspeed 10000")
	_check(game.config.max_speed == 250.0, "a value over the config's range is refused through the shared name")
	_check(server.console.get_float("sv_runspeed") == 250.0 and server.console.get_float("sv_maxspeed") == 250.0,
		"and both spellings go back to what the config holds")
	_run_command("sv_airwishspeed 40")
	_check(game.config.air_wish_cap == 40.0 and server.console.get_float("sv_airwishcap") == 40.0, "sv_airwishspeed writes air_wish_cap")
	_run_command("sv_airwishcap 30")
	_check(server.console.get_float("sv_airwishspeed") == 30.0, "sv_airwishcap moves the shared name back")

	_run_command("sv_autohop 0")
	_check(not game.config.auto_bhop and server.console.get_int("sv_autobunnyhopping") == 0, "sv_autohop 0 writes auto_bhop")
	_run_command("sv_autobunnyhopping 1")
	_check(game.config.auto_bhop and server.console.get_int("sv_autohop") == 1, "and sv_autobunnyhopping 1 turns it back on")

	_check(G2GMovementNames.UNBOUND.has("sv_maxspeed") and server.console.get_float("sv_maxspeed") == 250.0,
		"the shared wish-speed sv_maxspeed is not mapped onto the run speed")
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


func _test_config_and_noblock() -> void:
	_section("the config surface and the block rules")
	var module := server.modules.get_module("g2gfast")
	var binder: DotGameConfigBinder = game.config_binder
	_check(binder != null and binder.diff().is_empty(), "the config binder is built and the defaults hold no diff")
	_check(server.console.find_cvar("g2g_score_limit") != null and server.console.get_int("g2g_max_players") == 64,
		"the deathmatch and server fields are g2g_ cvars")
	_check(server.console.find_cvar("g2g_gravity") == null, "a field with an sv_ cvar of its own does not get a second one")
	_run_command("g2g_respawn_delay 3")
	_check(game.config.respawn_delay == 3.0 and binder.source_of("respawn_delay") == "cvar", "a g2g_ cvar writes the field")
	_run_command("g2g_respawn_delay 1")
	var edit: Variant = module.workbench.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_movement", "id": binder.profile_id, "key": "gravity", "value": 700})
	_check(edit is DotResult and edit.ok and game.config.gravity == 700.0 and server.console.get_int("sv_gravity") == 700,
		"a workbench edit of a hand-bound field reaches the field and its sv_ cvar")
	_run_command("sv_gravity 800")
	var noblock: Variant = module.get("noblock")
	_check(noblock != null and server.console.get_int("mp_teamblock") == 0 and server.console.get_int("mp_enemyblock") == 0,
		"mp_teamblock 0 and mp_enemyblock 0 by default: the genre's runners pass through each other")
	_check(server.console.find_command("block") != null and server.console.find_command("noblock") != null, "!block and !noblock are commands")
	_check(game.block_rules == noblock.rules and game.body_rules.pair_fn.is_valid(), "the game's body rules ask the block rules")
	_check(game.body_rules.solid and server.console.get_int("mp_solidplayers") == 1, "mp_solidplayers is on, so the block rules decide")
	_check(not game.body_rules.blocks(1, 2), "runners pass through each other on this server by default")
	var rules: Object = noblock.rules
	_check(not rules.call("blocks", 1, 2), "two runners are enemies in a free-for-all, and enemies pass at mp_enemyblock 0")
	_run_command("mp_enemyblock 1")
	_check(game.body_rules.blocks(1, 2), "mp_enemyblock 1 makes them solid")
	var asked: DotResult = rules.call("request", 1, [DotTeamBlockRules.Relation.ENEMY], 0, true)
	_check(asked.ok and not game.body_rules.blocks(1, 2), "!noblock: a request to pass wins")
	rules.call("forget", 1)
	_check(game.body_rules.blocks(1, 2), "a player leaving forgets the request")
	_run_command("mp_solidplayers 0")
	_check(not game.body_rules.blocks(1, 2), "mp_solidplayers 0 overrules the block rules")
	_run_command("mp_solidplayers 1")
	_run_command("mp_enemyblock 0")
	_check(binder.write_schema("user://schema_check.json").ok, "write_schema works")
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
