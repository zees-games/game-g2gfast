extends "g2g_module_load.gd"

func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(G2GGame.SERVICE) as G2GGame
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "No G2GGame is registered.")

	var wb_made := _make_workbench()
	if not wb_made.ok:
		return wb_made
	var netted := _build_netcode()
	if not netted.ok:
		return netted

	# --- Movement cvars, in genre units --------------------------------------
	_movement_cvar("sv_autobunnyhopping", "auto_bhop", "Hold jump to hop.")
	_movement_cvar("sv_enablebunnyhopping", "enable_bunnyhopping", "Let hopping build speed. Off applies CS's landing cap.")
	_movement_cvar("sv_airaccelerate", "air_accelerate", "Air acceleration. 1000 bhop, 150 surf, 10 CS.")
	_movement_cvar("sv_accelerate", "accelerate", "Ground acceleration.")
	_movement_cvar("sv_gravity", "gravity", "Gravity, u/s².")
	_movement_cvar("sv_friction", "friction", "Ground friction.")
	_movement_cvar("sv_stopspeed", "stop_speed", "Friction floor, u/s.")
	_movement_cvar("sv_maxspeed", "max_speed", "Run speed, u/s.")
	_movement_cvar("sv_maxvelocity", "max_velocity", "Velocity backstop, u/s.")
	_movement_cvar("sv_airwishcap", "air_wish_cap", "Airborne wish-speed cap, u/s. Hard-coded at 30 in those games.")
	_movement_cvar("sv_stepsize", "step_size", "Step height, units.")
	_movement_cvar("sv_edgefriction", "edge_friction", "Friction near a ledge. 1 disables.")
	_movement_cvar("sv_jumpbuffer", "jump_buffer", "Easy-bhop window in seconds when autobhop is off.")
	_movement_cvar("sv_crestlaunch", "crest_launch", "A ramp's crest throws a player above this many times sv_maxspeed. 0 never.")

	_bind_shared_movement_names()
	_bind_stats_report()

	# The record's ghost, live. Turning it off takes the current one away rather than
	# waiting for the next map: an operator who turns a bot off wants it gone now.
	add_cvar("sv_replay_bot", "1" if game.config.show_replay_bot else "0",
		"Run the server record's replay as a visible bot.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.show_replay_bot = new_value != "0"
			if game.config.show_replay_bot:
				game.spawn_ghost()
			else:
				game.remove_player(G2GGame.GHOST_ID)
	)

	# The bots (`g2g_bots.gd`): the family's three cvars, at 0 until an operator asks.
	_quota = DotBotQuota.install(self, 0)
	add_cvar("bot_nav", "1", "Bots on a map without a route file plan one through the navigation annotations (0 aims them straight at the finish).").changed.connect(
		func(_old: String, new_value: String) -> void:
			if game.bots != null:
				game.bots.set("use_nav", new_value != "0")
	)

	add_cvar("sv_allow_thirdperson", "1" if game.config.allow_thirdperson else "0",
		"Whether players may use third person.").changed.connect(
		func(_old: String, new_value: String) -> void:
			# The older switch, kept: 0 is the family's mp_forceview 1 (first person only);
			# 1 lifts that and leaves a forced third person alone.
			if new_value == "0":
				game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
			elif game.view_rules.force_view == DotPlayerViewRules.FIRST_ONLY:
				game.view_rules.force_view = DotPlayerViewRules.ANY
			if bridge != null:
				bridge.broadcast_rules()
	)

	# mp_forceview: REPLICATED, because each client places its own camera.
	if not game.config.allow_thirdperson:
		game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	var _views := game.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	game.view_rules.changed.connect(func() -> void:
		if bridge != null:
			bridge.broadcast_rules())
	var _killview := game.killview_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	# Told to every client: the light is drawn there, and 0 switches it off on the next RULES.
	add_cvar("sv_flashlight", "1" if game.config.flashlight else "0",
		"Whether players may use their own flashlight (F). Drawn on their screen only.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.flashlight = new_value != "0"
			if bridge != null:
				bridge.broadcast_rules()
	)

	# Read by dot-net on every tick, so flipping it takes effect on the next snapshot.
	add_cvar("sv_stagger_snapshots", "1" if game.config.stagger_snapshots else "0",
		"Spread snapshot work over the ticks between snapshots. Lowers the worst tick on a full server.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.stagger_snapshots = new_value != "0"
			if net != null and net.config != null:
				net.config.stagger_snapshots = game.config.stagger_snapshots
	)

	# Off sends nothing and clears every list already on screen.
	add_cvar("sv_spec_list", "1" if game.config.spectator_list else "0",
		"Whether players see who is spectating them. 0 makes spectating anonymous.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.spectator_list = new_value != "0"
			if bridge != null:
				bridge.broadcast_spectators()
	)

	# dot-spectate's mp_* cvars, REPLICATED: each client flies its own camera at the server's speed.
	if game.spectate != null and game.spectate.manager != null:
		var _spectate_cvars := game.spectate.manager.rules.bind_cvars(
			add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
		)

	add_command("g2g_status", _cmd_status, "What this server is doing", "").with_chat()
	add_command("g2g_restart", _cmd_restart, "Back to the start", "").with_chat()
	add_command("g2g_style", _cmd_style, "List styles, or switch", "").with_chat()
	add_command("g2g_track", _cmd_track, "main, or bonus <n>", "").with_chat()
	add_command("g2g_stage", _cmd_stage, "To the start of stage <n>, or of this stage", "").with_chat()
	add_command("g2g_top", _cmd_top, "Fastest times here", "").with_chat()
	# Not `.with_chat()` yet reachable from chat: CHANGEMAP decides, so a player without the flag is refused.
	add_command("g2g_map", _cmd_map, "Change map, or list them", DotAdminFlags.CHANGEMAP)

	# `map`, `maps` and `mapinfo` come from dot-map; dot-server's `map` changed the GAME and is
	# `changelevel` now. `allow_chat_change` stays ON, matching `g2g_map`: CHANGEMAP decides.
	# `change_fn` rather than the session, because `G2GGame.change_map` resets the timer, zones and styles.
	var map_commands := DotMapCommands.new()
	map_commands.session = game.maps
	# The catalogue is not the set of maps this server can play: the pack excludes `maps/imported/`,
	# so an unknown id may be on the content origin, and `change_fn` below fetches it first.
	# A real typo is still refused, with the suggestion, after the fetch fails.
	map_commands.may_fetch_unknown = true
	map_commands.change_fn = func(id: StringName) -> DotResult:
		return await game.change_map(id)
	map_commands.player_count_fn = func() -> int:
		return game.players.size() if game != null else 0
	map_commands.rotation_file_fn = func() -> DotMapRotationFile: return game.rotation_file
	map_commands.spec_fn = func() -> Dictionary:
		return game.rotation_file.commands() if game.rotation_file != null else {}
	map_commands.bind(self)
	add_command("g2g_maps_reload", _cmd_maps_reload,
		"Re-read maps/ from disk, picking up anything dropped in", DotAdminFlags.CHANGEMAP)

	# The delivered server's map list. See [member G2GConfig.content_maps] for why a game
	# that finds its maps by looking needs to be told about these: there is no directory
	# to look in when the maps are on a CDN, so `maps`, the rotation and `rtv` would all
	# offer the three built-in scenes and nothing else.
	#
	# Set live as well as at load. The sweep is in the background either way, so an
	# operator adding a map id to a running server gets it without a restart, which is
	# the same promise `g2g_maps_reload` makes for the disk.
	add_cvar(G2GConfig.MAP_CONTENT_OWNER_CVAR, game.config.map_content_owner,
		"Whose namespace maps are fetched from: gamemann makes surf_mesa gamemann/surf_mesa."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.map_content_owner = new_value.strip_edges()
	)

	add_cvar("sv_content_maps", " ".join(game.config.content_maps),
		"Map ids to fetch from the content origin, space- or comma-separated."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.content_maps = _split_map_ids(new_value)
			# Not awaited on purpose -- see G2GGame.fetch_content_maps. A cvar handler
			# that blocked on 66 MB would hang the console that set it.
			game.fetch_content_maps()
	)

	if not game.config.content_maps.is_empty():
		game.fetch_content_maps()

	# Which installed maps rotate: cfg/maps.yml. Changing
	# it re-reads the file now, as `g2g_maps_reload` does.
	add_cvar("sv_map_rotation_file", game.config.map_rotation_file,
		"maps.yml: the maps that rotate, in named rotations. Unlisted maps stay installed."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.map_rotation_file = new_value.strip_edges()
			var _read := game.load_rotation()
	)

	# How long a map change waits for clients to have the map. See
	# [member G2GConfig.map_sync_seconds] for why it is thirty and not dot-map's three
	# hundred. Read by the next change; one in flight keeps the deadline it started with.
	add_cvar("sv_map_sync_timeout", str(int(game.config.map_sync_seconds)),
		"Seconds a map change waits for clients to have the map before going ahead without them."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.map_sync_seconds = clampf(new_value.to_float(), 1.0, 3600.0)
			if bridge != null and bridge.map_host != null:
				bridge.map_host.sync_timeout_sec = game.config.map_sync_seconds
	)
	add_command("g2g_rtv", _cmd_rtv, "Rock the vote", "").with_chat()

	# What twenty years of bhop servers taught everybody's fingers: `!r`, `!wr`,
	# `!style`. Aliases of the commands above, chat-enabled, nothing else.
	add_command("r", _cmd_restart, "Back to the start (alias)", "").with_chat()
	add_command("wr", _cmd_top, "Fastest times here (alias)", "").with_chat()
	add_command("top", _cmd_top, "Fastest times here (alias)", "").with_chat()
	add_command("style", _cmd_style, "List styles, or switch (alias)", "").with_chat()
	add_command("track", _cmd_track, "main, or bonus <n> (alias)", "").with_chat()
	add_command("s", _cmd_stage, "To the start of stage <n> (alias)", "").with_chat()
	add_command("stage", _cmd_stage, "To the start of stage <n> (alias)", "").with_chat()
	add_command("rs", _cmd_stage, "To the start of this stage (alias)", "").with_chat()
	add_command("g2g_zone", _cmd_zone, "Draw a zone: g2g_zone <kind> [track] [number]", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_mark", _cmd_zone_mark, "Mark a corner where you stand, or at x y z [height] (units)", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_save", _cmd_zone_save, "Write the zones to disk", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_undo", _cmd_zone_undo, "Remove the last zone", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_list", _cmd_zone_list, "List the zones", DotAdminFlags.CHANGEMAP)
	add_command("g2g_ghost", _cmd_ghost, "What the record ghost is running", "").with_chat()

	# --- Records -----------------------------------------------------------------
	#
	# The questions a timer server is asked all evening. The answers are dot-timer's
	# (`DotTimerManager.profile`, `recent_records`, ...); these only phrase them.
	add_command("pb", _cmd_pb, "Your best here, or another player's: !pb [name]", "").with_chat()
	add_command("rank", _cmd_rank, "Your ranking and title on this server", "").with_chat()
	add_command("players", _cmd_players, "The best-ranked players: !players [page]", "").with_chat()
	add_command("rr", _cmd_recent, "The latest records", "").with_chat()
	add_command("recent", _cmd_recent, "The latest records (alias)", "").with_chat()
	add_command("profile", _cmd_profile, "Your profile, or another player's", "").with_chat()
	add_command("p", _cmd_profile, "Your profile (alias)", "").with_chat()
	add_command("mapsdone", _cmd_maps_done, "Maps you have finished", "").with_chat()
	add_command("mapsleft", _cmd_maps_left, "Maps you have not finished", "").with_chat()
	add_command("wrcp", _cmd_sections, "The record for each stage of this map", "").with_chat()
	add_command("prinfo", _cmd_progress, "Your attempts and time on this map", "").with_chat()
	add_command("tier", _cmd_tier, "This map's tier", "").with_chat()
	add_command("end", _cmd_end, "To the end zone (stops the run)", "").with_chat()
	add_command("pause", _cmd_pause, "Pause your run (standing still, on the ground)", "").with_chat()
	add_command("unpause", _cmd_unpause, "Resume a paused run", "").with_chat()
	add_command("resume", _cmd_unpause, "Resume a paused run (alias)", "").with_chat()
	add_command("autorestart", _cmd_auto_restart, "Restart whenever you fall behind your best", "").with_chat()
	add_command("restore", _cmd_restore, "Take back the run you dropped", "").with_chat()
	add_command("g2g_settier", _cmd_set_tier, "Set this map's tier (1-10) and re-score it", DotAdminFlags.CHANGEMAP)
	add_command("g2g_deleterecord", _cmd_delete_record, "Remove a player's time: <name> [track] [style]", DotAdminFlags.BAN)
	add_command("g2g_wipeplayer", _cmd_wipe_player, "Remove every record of a player id", DotAdminFlags.BAN)
	add_command("g2g_rescore", _cmd_rescore, "Re-score every board on this map", DotAdminFlags.CHANGEMAP)
	add_command("thirdperson", _cmd_thirdperson, "Third-person view", "").with_chat()
	add_command("firstperson", _cmd_firstperson, "First-person view", "").with_chat()

	# --- Mode cvars, live -------------------------------------------------------
	#
	# Each one flips a layer that is already built. A layer constructed on the cvar
	# instead would be constructed under live players, which is where the interesting
	# failures are — and it would have to be torn down again on the way back.
	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's
	# reaction from them; REPLICATED, because the clients draw the bodies (the client's
	# _build_netcode follows them). Bound whether or not anybody can die yet, so a config's
	# `sv_ragdoll_style stiff` holds when deathmatch or the hunters are turned on later.
	var _ragdolls := game.ragdoll_rules.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	var _drops := game.weapon_layer.rules.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	# sv_falldamage stays 0 (see G2GGame.fall_rules); bound so an admin sees it is a decision.
	var _fall := game.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# mp_friendlyfire and mp_teammate_passthrough; the default is the rules the combat layer built (G2GConfig.friendly_fire).
	if game.combat != null and game.combat.manager != null:
		var _combat := game.combat.manager.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	add_cvar("sv_deathmatch", "1" if game.config.deathmatch else "0",
		"Whether players can shoot each other.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.deathmatch = new_value != "0"

			if game.combat != null:
				game.combat.enabled = game.config.deathmatch
			elif game.config.deathmatch:
				log_warn("deathmatch cannot be turned on", {
					"why": "this server booted without it; restart with sv_deathmatch 1"
				})
	)

	add_cvar("mp_killcam_time", str(game.config.killcam_seconds),
		"Seconds the final killcam plays when a deathmatch ends, added to the end's wait (0 for none)").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.killcam_seconds = clampf(new_value.to_float(), 0.0, 30.0)
			if game.combat != null:
				game.combat.apply_killcam_wait()
	)

	# Registered whether or not hunters are on, so `npc_skill hard` in a config holds
	# when an operator turns `sv_hunters` on later.
	game.npc_skill.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	add_cvar("sv_hunters", "1" if game.config.hunters else "0",
		"Whether hunters walk the course.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.hunters = new_value != "0"

			if game.hunters == null:
				return

			game.hunters.enabled = game.config.hunters

			# Off takes them away now rather than waiting for the next map — the same
			# rule `sv_replay_bot` follows, and for the same reason: an operator who
			# turns something off wants it gone.
			if not game.config.hunters:
				game.hunters.clear()
	)

	add_cvar("sv_props", "1" if game.config.placeable_props else "0",
		"Whether practice blocks may be placed.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.placeable_props = new_value != "0"

			if game.props != null and not game.config.placeable_props:
				game.props.clear()
	)

	var configured := _bind_config()
	if not configured.ok:
		return configured

	server.client_disconnected.connect(_on_client_disconnected)

	# The Tab board: dot-server sends every client holding it the names, pings and time
	# connected; these are this game's columns for each, the style, the best time on this
	# map and its rank, from what the game already worked out for the HUD. Asked rather
	# than assumed: a pack runs on whatever dot-server the host has, and one from before
	# the roster has neither property.
	if "scoreboard_fields" in server:
		server.set(&"scoreboard_fields", func(session: DotClientSession) -> Dictionary:
			if game == null or not is_instance_valid(game):
				return {}
			return game.board_fields(G2GNetBridge._player_key(session.userid)))
		server.set(&"scoreboard_extra", func() -> Dictionary:
			if game == null or not is_instance_valid(game) or game.maps == null or game.maps.current == null:
				return {}
			return {"header": {"": "Time left %s" % game.time_left_text()}})
	hook_post("client_spawn", _on_client_spawn)
	hook_post("player_avatar_changed", _on_avatar_changed)
	add_command("g2g_net", func(ctx: DotCmdContext) -> void: ctx.reply_lines(net.describe_lines()), "Netcode state", "")
	_register_games()

	# What a server browser sees. Registered through the module so it goes away with
	# it; a provider left behind is called with `self` pointing at a freed object.
	var query := G2GQuery.new()
	query.game = game
	query.bridge = bridge
	var provided := add_query_provider(query)
	if not provided.ok:
		DotLog.info(CHANNEL, "no query provider", {"why": provided.error.message})

	game.maps.changed.connect(_report_map)
	_report_map(game.maps.current)

	# Everything below runs the server rather than the game, and each one logs and
	# continues rather than refusing to load: a module that would not load because a
	# punishment file was unreadable is a module that takes the game down over a
	# permissions mistake, and the game is what the players came for.
	var identified: DotResult = await _build_identity()
	DotLog.result(CHANNEL, "the identity layer", identified)

	var serviced: DotResult = await _build_services()
	DotLog.result(CHANNEL, "chat, voice and moderation", serviced)

	var voted := _build_vote()
	DotLog.result(CHANNEL, "the vote", voted)

	_add_server_commands()

	log_info("g2gfast loaded", {"autobhop": game.config.auto_bhop, "tick_rate": game.tick_rate})
	return DotResult.success(null)


func _module_unload() -> void:
	if game != null and game.progress != null and DotRegistry.get_service(DotGameStatsFeed.SERVICE) == game.progress.stats:
		DotRegistry.unregister_instance(DotGameStatsFeed.SERVICE, game.progress.stats)
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null
	if map_config != null:
		map_config.restore()
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)
	# The server outlives this game; a column hook left behind would be called on the next.
	if server != null and "scoreboard_fields" in server:
		server.set(&"scoreboard_fields", Callable())
		server.set(&"scoreboard_extra", Callable())
	if bridge != null and is_instance_valid(bridge):
		for userid in _joined.keys():
			bridge.remove_peer(bridge.peer_for_player(int(userid)))
	if game != null and is_instance_valid(game):
		if game.bots != null:
			for id: StringName in (game.bots.get("ids") as Array).duplicate():
				game.bots.call("remove_bot", id)
		for id in game.players.keys():
			game.remove_player(id)
		game.external_tick = false
		if game.maps.changed.is_connected(_report_map):
			game.maps.changed.disconnect(_report_map)
	if net != null and is_instance_valid(net):
		net.stop()
	# [b]The platform module goes with the identity that loaded it[/b], as dot-game's does: it
	# holds the hub G2GIdentity registered, which a game change frees. Left loaded, every game
	# after this one found "platform" already there, loaded none of its own, and kept asking
	# g2gfast's freed hub (dot-game's history: signal 11 on the next spawn).
	if _loaded_platform and server != null and server.modules != null \
			and server.modules.has_module("platform"):
		server.modules.unload_module("platform")
	_loaded_platform = false
	_painters.clear()
	_joined.clear()


## The manager and the bridge. The module drives the tick, because the game's tick
## has to happen INSIDE dot-net's — between applying inputs and building the snapshot.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = G2GGame.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 0
	config.stagger_snapshots = game.config.stagger_snapshots
	# A surf map is kilometres long in metres. The extent bounds position quantisation.
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()
	if not ready_result.ok:
		return ready_result.wrap("The netcode could not start")

	bridge = G2GNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net, server)
	if not attached.ok:
		return attached

	bridge.commands_fn = chat_commands
	# The older client's map list (its own wire, before dot-menu's map menu) asks the map
	# menu's own question, so the two can never disagree: staff by the owner's
	# `sv_map_menu_flag`, the host's own player, or the only human here under
	# `sv_map_menu_alone`. Fails closed: with no map menu (a dot-vote older than it) only
	# `changemap` changes the map. Until 2026-10-14 this read an empty flag as "anybody".
	bridge.may_change_map_fn = func(session_id: int) -> bool:
		var session := server.session_by_userid(session_id)
		if session == null:
			return false
		# Level 7 is the map menu that fails closed and counts humans; an older one read an
		# empty flag as "anybody", so on a host still on it this answers `changemap` alone.
		var menu_half: Variant = vote.commands.get(&"map_menu") if vote != null and vote.commands != null else null
		if menu_half is Object and DotAddonApi.build_level("dot_vote") >= 7:
			var ctx := session.make_context("mapmenu", PackedStringArray(), DotCmdContext.Source.CHAT)
			return bool((menu_half as Object).call(&"may_change", ctx))
		return DotAdminFlags.granted(session.permissions, DotAdminFlags.CHANGEMAP)

	# Avatar actions: the relay, and the loadouts the join/leave handlers below tell.
	var avatar := DotGameAvatarActionRelay.serve(net, self, server)
	if not avatar.ok:
		log_warn("avatar actions not served", {"why": avatar.error.message})

	# The remote workbench's frame, inert until sv_workbench_remote is 1; and the profile rows, so an admin's edit reaches every client.
	var bench := DotGameWorkbenchRemote.serve(net)
	if not bench.ok:
		log_warn("remote workbench not served", {"why": bench.error.message})
	if _wb_runtime != null:
		profile_link = DotNetProfileLink.attach(net, _wb_runtime)
		if bench.ok and workbench.serve_remote(net) == null:
			log_warn("remote workbench not bound", {})
		bridge.peer_ready_fn = func(peer: int) -> void:
			if profile_link != null:
				profile_link.peer_joined(peer)

	net.messages.seal()
	# [b]A client whose game messages cannot work with this server's is dropped, in words.[/b]
	# dot-net compares the two schema tables and refuses a pair where either lacks a type
	# the other REQUIRES, but it owns no socket and can only say so; this is the socket.
	# The same line DotGameNetcode.refuse_peer is for games built on dot-game.
	net.peer_schema_refused.connect(_refuse_peer)
	return net.start()


## The event carries `userid`, not `peer_id` — dot-2d-hungry's note on this, in full:
## looking a session up by a peer id that is not in the payload returns null every
## time, and nobody is ever added, with no error.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))
	if session == null or _joined.has(session.userid):
		return

	# dot-moderation's records, which are not dot-server's ban list.
	#
	# [b]dot-server's mute is two booleans on a session object and a session dies with
	# its connection[/b], so a muted player reconnects and talks. A punishment is a
	# durable record with an expiry and a scope, and this is the second gate — the
	# first is dot-server's own admission, which has already run.
	if services != null:
		var admitted := services.check_admission(session)

		if not admitted.ok:
			server.kick(session, admitted.error.message)
			return

	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name, _avatar_for(session),
		_record_key_for(session)
	)
	if not added.ok:
		log_warn("could not add a player", {"userid": session.userid, "error": str(added.error)})
		return

	_joined[session.userid] = true

	var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.add_peer(session.peer_id)

	if services != null:
		services.add_peer(session.peer_id)


## The avatar dot-platform resolved for this session, if there is a dot-platform.
##
## Duck-typed: a module that answers `player_for` is enough, and naming
## DotPlatformModule would make a LAN server impossible without the identity stack.
## Without one, the game gives the player a stock character.
func _avatar_for(session: DotClientSession) -> DotAvatar:
	var platform: Object = server.modules.get_module("platform")
	if platform == null or not platform.has_method("player_for"):
		return _identity_avatar(session)
	var player: Variant = platform.call("player_for", session)
	if player == null or not (player is Object):
		return _identity_avatar(session)
	var avatar: Variant = (player as Object).get("avatar")
	if avatar is DotAvatar:
		return avatar as DotAvatar
	return _identity_avatar(session)


## The hub's own answer, when the module has not resolved one yet.
##
## [b]Admission usually finishes before the spawn now; this covers when it does not.[/b]
## dot-server's signon has a PROFILE stage between authentication and content, and
## dot-platform's module holds every authenticated player there while the hub admits
## them, so a player is normally seated already resolved and `player_for` answers. It
## still lets an optional player in after `admission_timeout_sec` with admission
## finishing behind them, and a session it first hears of past the stage (an older
## dot-server, an adopted session, a guest who signed in after spawning) is admitted
## after the spawn as before. For those, asking the hub directly closes the gap: it
## answers with what it has, and `G2GIdentity.avatar_for` falls back to the stock
## document, which is a real avatar over the same schema. dot-platform docs/design.md.
func _identity_avatar(session: DotClientSession) -> DotAvatar:
	if identity == null or session == null:
		return null

	return identity.avatar_for("u%d" % session.userid)


func _cmd_thirdperson(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or player.camera == null:
		ctx.reply("Only a player with a camera can do that.")
		return
	if not player.camera.set_mode(G2GCamera.Mode.THIRD_PERSON):
		ctx.reply("Third person is not allowed on this server.")
		return
	ctx.reply("Third person.")


func _cmd_firstperson(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or player.camera == null:
		ctx.reply("Only a player with a camera can do that.")
		return
	player.camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
	ctx.reply("First person.")


## dot-platform's broadcast_avatar_changes, received: the player is redressed and
## everybody is told, through the same JOIN a style change sends.
func _on_avatar_changed(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))
	if session == null or bridge == null:
		return
	var avatar := _avatar_for(session)
	if avatar != null:
		bridge.dress(session.userid, avatar)


func _cmd_ghost(ctx: DotCmdContext) -> void:
	if not game.config.show_replay_bot:
		ctx.reply("The replay bot is off (sv_replay_bot 0).")
		return

	var ghost := game.ghost()
	if ghost == null:
		ctx.reply("Nobody has set a record here yet, so there is nothing to run.")
		return

	ctx.reply("%s, %.0f%% through its run." % [
		ghost.display_name, ghost.replay.progress() * 100.0
	])


## Disconnects a peer whose message schema this server cannot play with, with dot-net's
## sentence as the reason. See `peer_schema_refused` above.
func _refuse_peer(peer_id: int, error: DotError) -> void:
	var session: DotClientSession = server.session_of(peer_id) if server != null else null
	if session != null:
		server.kick(session, error.message, error)


## The workbench node and its runtime, before the netcode: the remote frame and the profile link register before the seal.
func _make_workbench() -> DotResult:
	_noblock_made = DotGameNoblock.create(G2GGame.CONFIG_GAME_ID, Callable(game, "block_side"))
	if not _noblock_made.ok and _noblock_made.error.code != DotError.CODE_UNSUPPORTED:
		return _noblock_made.wrap("noblock")
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	for set: DotProfileSet in game.config_binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	if _noblock_made.ok:
		workbench.add_set((_noblock_made.value as DotGameNoblock).binder.profile_set(), "Block rules")
	add_child(workbench)
	var started := workbench.start()
	_wb_runtime = workbench.api.runtime if started.ok and workbench.api != null else null
	return DotResult.success(null)


## The config as cvars (`g2g_<field>`), commands, the workbench and the block rules.
func _bind_config() -> DotResult:
	var binder := game.config_binder
	var made := _noblock_made
	var wanted := made.ok
	if not wanted:
		DotLog.warn(CHANNEL, "noblock unavailable: dot-team is not in this build")
	var runtime := _wb_runtime

	var covered := PackedStringArray()
	for field: String in HAND_CVARS:
		covered.append("g2g_%s" % field)
	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE,
		func(name: String) -> bool: return covered.has(name) or console.has_name(name))
	binder.bind_commands(add_command)
	binder.field_changed.connect(_on_config_field)
	if runtime != null:
		binder.attach(runtime)

	if wanted:
		noblock = made.value
		var bound := noblock.bind(add_cvar, self, runtime)
		if not bound.ok:
			return bound.wrap("noblock")
		noblock.feed(game.body_rules)
		game.block_rules = noblock.rules
	return DotResult.success(null)


## A workbench or file edit of a field: pushed through its cvar, or applied directly.
func _on_config_field(key: String, _value: Variant, source: String) -> void:
	if source == "cvar":
		return
	if HAND_CVARS.has(key):
		var text: Variant = game.config.get(key)
		if text is bool:
			text = "1" if text else "0"
		elif text is PackedStringArray:
			text = " ".join(text)
		console.set_cvar(HAND_CVARS[key], str(text))
	elif key == "lethal_damage" and game.mechanics != null:
		game.mechanics.lethal_damage = game.config.lethal_damage
	elif key == "score_limit" and game.combat != null:
		game.combat.score_limit = game.config.score_limit
