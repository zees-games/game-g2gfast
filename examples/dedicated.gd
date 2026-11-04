extends "dedicated_votes.gd"

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotLog.signals().record.connect(_on_log_record)
	_run.call_deferred()


## An ERROR from the stats layer would otherwise scroll past and leave a stat dead with every check green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= DotLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))


func _run() -> void:
	print("g2gfast — dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await ExitProbe.run(self, EXIT_PROBE_FLAG)

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()
	if game != null:
		_test_cvars_reach_the_movement()
		_test_the_shared_movement_names()
		await _test_autobhop_live()
		_test_thirdperson_cvar()
		_test_stagger_cvar()
		_test_stats_report()
		_test_config_and_noblock()
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
		await Accounts.new(self, server, game).run()
		await _test_unload()
		_test_no_message_preloads_itself()
		_test_weapons_keep_wall_clock_time()

	if not probe.is_empty():
		_test_exits_clean(probe)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)
	_report_sections(_entered, _completed, sections, checks)


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
	config.port = G2GTestPorts.free_port()
	config.max_players = 16
	config.hibernate_when_empty = false
	config.query_enabled = true
	config.query_port = G2GTestPorts.free_port()
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
	# exit. See [method ExitProbe.run]. This is the order a deployed server has.
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
	var refused := player.timer.can_record(Accounts.finished_copy(player.timer.run))
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



## The two that are about a screen: the flag on the player and on the netcode entity is what the
## server decides; delivery to the owner is `headless_net`'s, the look is `tools/screenshot_hud.sh`'s.
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

## The flag this suite hands the copy of itself it runs. See [method ExitProbe.run].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3



func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


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
		ExitProbe.last_lines(stdout, 15), ExitProbe.last_lines(stderr, 10)
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
		"it was killed before it reached its exit" if hung else ExitProbe.line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else ExitProbe.line_with(text, "still in use at exit"))
	_done()
