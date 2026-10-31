extends "g2g_module_commands.gd"

var _shared_names: DotFpsCvars = null


func _module_name() -> String:
	return "g2gfast"

func _module_version() -> String:
	return "0.1.0"

func _module_description() -> String:
	return "Bunny-hop and surf timer in the competitive-shooter shape."

func _module_author() -> String:
	return "dot"


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

	# The bots (`g2g_bots.gd`): the family's three cvars, at 0 so a timer server has none until
	# its operator asks. A records community runs a server for people; a bot riding the first
	# stage is a demonstration somebody chooses, not a crowd somebody is sold.
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

	# Told to every client, because the light is drawn there and nowhere else: a client
	# holding one when this goes to 0 switches it off on the next RULES.
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

	# Who is watching you. Sent to the watched player and their watchers; off sends
	# nothing at all, and clears every list already on screen.
	add_cvar("sv_spec_list", "1" if game.config.spectator_list else "0",
		"Whether players see who is spectating them. 0 makes spectating anonymous.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.spectator_list = new_value != "0"
			if bridge != null:
				bridge.broadcast_spectators()
	)

	# mp_forcecamera, mp_freeroam and mp_freeroam_speed (dot-spectate): free roam is on by
	# default. REPLICATED, because each client flies its own camera at the server's speed and
	# hides the key when roaming is off.
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
	# Not `.with_chat()` and reachable from chat anyway: it carries CHANGEMAP and lets the flag
	# answer, so an operator can type `/map` in chat and a player without the flag is still refused.
	# `sv_chat_commands 0`, or `allow_chat_change = false` below, makes it console-only again.
	add_command(
		"g2g_map", _cmd_map, "Change map, or list them", DotAdminFlags.CHANGEMAP
	)

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


## dot-platform's own module, loaded beside this one.
##
## A PATH, because `DotModuleHost.load_module` takes one and constructs the module
## itself — so a pre-built instance with its hub assigned would be thrown away and a
## fresh one made with a null. dot-platform's module falls back to
## `DotRegistry.get_service(DotPlatformHub.SERVICE)` for exactly this, which is why
## [G2GIdentity] registers the hub.
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"

## Whether this module loaded the platform module, and so must unload it. See [method _module_unload].
var _loaded_platform := false


func _build_identity() -> DotResult:
	identity = G2GIdentity.new()
	identity.name = "Identity"
	identity.report_to_backbone = game.config.report_to_backbone
	add_child(identity)

	var ready: DotResult = await identity.setup()

	if not ready.ok:
		remove_child(identity)
		identity.queue_free()
		identity = null
		return ready

	if server.modules != null and not server.modules.has_module("platform"):
		# Awaited: see the same call in arena. A module load is a coroutine.
		var loaded: DotResult = await server.modules.load_module(
			PLATFORM_MODULE_PATH
		)

		_loaded_platform = loaded.ok

		if not loaded.ok:
			return loaded.wrap("The platform module would not load")

	return DotResult.success(identity)


func _build_services() -> DotResult:
	services = G2GServices.new()
	services.name = "Services"
	services.punishments_file = punishments_file
	add_child(services)

	var ready: DotResult = await services.setup(server, game, bridge.link)

	if not ready.ok:
		remove_child(services)
		services.queue_free()
		services = null
		return ready

	if services.voice != null and bridge != null:
		bridge.voice_relay_fn = services.relay_voice

	# sv_voice_enable and sv_voice_mode: enforced on the router, replicated so a client hides
	# its key. On this module, so they go when it unloads.
	if services.voice != null:
		var _voice_cvars := services.voice.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	services.command_entered.connect(_on_chat_command)

	# noclip, slay, bring and the rest. On this module, so they go when it unloads.
	if services.mod_tools != null:
		mod_commands = DotModToolCommands.install(self, services.mod_tools, server)
		mod_commands.items_fn = func() -> PackedStringArray:
			var out := PackedStringArray()
			if game.combat != null:
				for id in game.combat.catalogue().ids():
					out.append(String(id))
			return out

	return DotResult.success(services)


func _build_vote() -> DotResult:
	vote = G2GVote.new()
	vote.commands_spec_fn = func() -> Dictionary:
		return game.rotation_file.commands() if game.rotation_file != null else {}
	vote.name = "Vote"
	vote.game = game
	vote.authoritative = true
	add_child(vote)

	vote.announce_fn = func(line: String) -> void:
		if services != null:
			services.announce(line)
		else:
			server.broadcast_message(line)

	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(G2GCombat.userid_of(voter))
		return session != null and session.permissions.has(DotAdminFlags.CHANGEMAP)

	# The drawn ballot, to each playing session with its own voter id (`u<userid>`, what
	# dot-vote's commands key a voter by), so the client shell marks the player's own
	# choice. Topic `map_ballot`, beside a server's `game_ballot` when both are open.
	vote.ballot_fn = func(state: Dictionary) -> void:
		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = "u%d" % session.userid
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))

	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(G2GCombat.userid_of(voter))

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	var ready := vote.setup()

	if not ready.ok:
		remove_child(vote)
		vote.queue_free()
		vote = null
		return ready

	# An empty server hibernates (dot-server, 2026-10-07): the map clock waits instead of
	# running out with nobody on, and restarts from the top on the first join.
	vote.director.follow_hibernation(server)

	# The cues and the countdown, to every ready client. Chat carries what the ballot
	# says; a sound and a number a HUD counts are what it cannot carry.
	vote.cue_due.connect(
		func(cue: StringName, seconds_left: int, runoff: bool) -> void:
			if bridge != null:
				bridge.broadcast_vote(cue, seconds_left, runoff)
	)

	# The time left, from the clock that ends the map. The HUD drew the map session's,
	# which on a client is a clock nobody extends; see `DotVoteClockView`.
	vote.clock_due.connect(
		func(state: Dictionary) -> void:
			if bridge != null:
				bridge.broadcast_clock(state)
	)

	# A client's RTV request is this vote's rock-the-vote, not the map session's. See
	# `G2GNetBridge.rtv_fn`.
	if bridge != null:
		bridge.clock_fn = vote.clock_state
		bridge.rtv_fn = func(id: StringName) -> void:
			var res := vote.rock_the_vote(id)
			if not res.ok and services != null:
				var peer := bridge.peer_for_player(G2GCombat.userid_of(id))
				if peer > 0:
					services.notice(peer, res.error.message)

	# [b]One clock that ends a map, and it is the vote's.[/b] The map session's own time
	# limit ran beside it at the same length and, on expiry, changed to the rotation's
	# next map — so a map the players voted to EXTEND was ended on the old clock anyway,
	# by a rotation nobody asked. The session's clock still counts for the HUD; with a
	# vote it no longer decides anything.
	game.rotation_ends_maps = false

	# And the clock `g2g_status` reports, for the same reason: the session's is no longer
	# the one that ends the map.
	game.clock_fn = vote.clock_state

	return DotResult.success(vote)


## The commands that only exist once the optional halves loaded.
func _add_server_commands() -> void:
	if vote != null:
		# dot-vote's own: `rtv`, `nominate`, `vote`, `nextmap`, `timeleft` and the
		# operator's four, on the one director. See `G2GVote.install_commands`.
		var commanded := vote.install_commands(self)
		DotLog.result(CHANNEL, "the vote's commands", commanded)
		# The map menu (M), dot-vote's: every map this server has, as the solo list shows them,
		# changed now through the game's own change (which fetches delivered content first) for
		# a player holding the owner's `sv_map_menu_flag`, or the only human here while
		# `sv_map_menu_alone` is on; anybody else nominates, and rocks the vote once
		# `sv_map_menu_vote_min` humans are playing. Humans are the server's sessions, so the
		# bots never count. Read by name, because a server on a dot-vote older than the menu
		# has no `map_menu`.
		var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
		if menu_half is Object:
			(menu_half as Object).set(&"change_fn", game.change_map)
			(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return G2GGame.menu_rows(game.map_rows()))
		add_command("g2g_vote", _cmd_open_vote, "Open a vote now", DotAdminFlags.VOTE)
	else:
		# No ballot, so `rtv` is the map session's own tally — the one rock-the-vote this
		# server has, under the name players type.
		add_command("rtv", _cmd_rtv, "Rock the vote (alias)", "").with_chat()

	if services != null:
		add_command("g2g_services", _cmd_services,
			"Chat, voice and moderation", DotAdminFlags.GENERIC)

	if identity != null:
		add_command("g2g_identity", _cmd_identity,
			"The platform layer", DotAdminFlags.GENERIC)

	if game.progress != null:
		add_command("stats", _cmd_stats, "Your numbers on this server", "").with_chat()

	if game.hunters != null:
		add_command("g2g_hunt", _cmd_hunt,
			"Show, clear, or place one: g2g_hunt [clear|spawn <id>]",
			DotAdminFlags.GENERIC)

	if game.props != null:
		add_command("g2g_place", _cmd_place,
			"Place a block where you are looking", DotAdminFlags.CHANGEMAP)
		add_command("g2g_place_undo", _cmd_place_undo,
			"Take the last block back", DotAdminFlags.CHANGEMAP)
		add_command("g2g_place_clear", _cmd_place_clear,
			"Clear every placed block", DotAdminFlags.CHANGEMAP)
		add_command("g2g_nudge", _cmd_nudge,
			"Grab the block you are looking at, or drop the one you hold",
			DotAdminFlags.CHANGEMAP)


func _cmd_open_vote(ctx: DotCmdContext) -> void:
	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	ctx.reply("Vote opened." if opened.ok else opened.error.message)


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_identity(ctx: DotCmdContext) -> void:
	ctx.reply_lines(identity.describe_lines())


func _cmd_stats(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)

	if id == &"":
		ctx.reply("Only a player has numbers.")
		return

	var values := game.progress.session_values(id)

	ctx.reply("Runs: %d started, %d finished" % [
		int(values.get_value(G2GStats.RUNS_STARTED, 0.0)),
		int(values.get_value(G2GStats.RUNS_FINISHED, 0.0)),
	])
	ctx.reply("Jumps: %d, %.0f%% perfect" % [
		int(values.get_value(G2GStats.JUMPS, 0.0)),
		G2GStats.perfect_ratio_of(values) * 100.0,
	])
	# Both derived, never stored: a stored quotient is a third number that can
	# disagree with the two it came from.
	ctx.reply("Finish rate: %.0f%%" % [G2GStats.finish_rate_of(values) * 100.0])
	ctx.reply("Top speed: %.0f u/s over %.0f m" % [
		values.get_value(G2GStats.TOP_SPEED, 0.0),
		values.get_value(G2GStats.DISTANCE, 0.0),
	])
	ctx.reply("Achievement points: %d" % game.progress.points_of(id))


func _cmd_hunt(ctx: DotCmdContext) -> void:
	if not ctx.args.is_empty() and ctx.args[0] == "clear":
		ctx.reply("Removed %d hunter(s)." % game.hunters.clear())
		return

	if not ctx.args.is_empty() and ctx.args[0] == "spawn":
		var caller := _caller(ctx)

		if caller == null:
			ctx.reply("Stand somewhere first.")
			return

		var which: StringName = (
			StringName(ctx.args[1]) if ctx.args.size() > 1 else G2GHunters.STALKER
		)

		# In front of the admin rather than at their feet, so the thing they just
		# placed is not immediately inside them.
		var at := caller.eye_position() + caller.aim_direction() * 4.0
		var made := game.hunters.spawn_one(which, at)

		ctx.reply(
			"Placed a %s." % String(which) if made != null
			else "That hunter could not be placed."
		)
		return

	ctx.reply_lines(game.hunters.describe_lines())


func _cmd_place(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Stand somewhere first.")
		return

	var which: StringName = (
		StringName(ctx.args[0]) if not ctx.args.is_empty() else G2GProps.BLOCK
	)

	# Where they are looking, four metres out. The same "mark where you stand" idea
	# `g2g_zone_mark` uses, one step in front so the block is not inside the admin.
	var at := player.eye_position() + player.aim_direction() * 4.0
	var made := game.props.place(_caller_id(ctx), which, at, true)

	ctx.reply(
		"Placed %s." % String(which) if made != null
		else "That block could not be placed."
	)


func _cmd_place_undo(ctx: DotCmdContext) -> void:
	ctx.reply("Removed." if game.props.undo(_caller_id(ctx)) else "Nothing to remove.")


func _cmd_place_clear(ctx: DotCmdContext) -> void:
	ctx.reply("Cleared %d block(s)." % game.props.clear())


## Grabs, or drops. One command for both, because an admin who has to remember which
## of two they typed last is an admin holding a block they cannot put down.
func _cmd_nudge(ctx: DotCmdContext) -> void:
	var caller := _caller(ctx)

	if caller == null:
		ctx.reply("Stand somewhere first.")
		return

	var id := _caller_id(ctx)

	if game.props.drop(id):
		ctx.reply("Dropped it, frozen where it is.")
		return

	var took := game.props.nudge(
		id, caller.eye_position(), caller.aim_direction(),
		1.0 / float(maxi(game.tick_rate, 1))
	)

	ctx.reply("Grabbed it — it follows you now." if took else "Nothing there.")


## A player typed `!something` that dot-server's own commands did not answer.
##
## [b]Claimed, or it is broadcast as chat.[/b] dot-chat holds a command until somebody
## says they handled it; an unclaimed one with `broadcast_unknown_commands` off is
## dropped, so a player typing `!rtv` on a server whose vote failed to load would get
## silence rather than "there is no vote here".
func _on_chat_command(peer: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer)

	if session == null:
		return

	var voter := _player_id(session)

	# [b]`!rtv` and `!vote` are not answered here.[/b] They are dot-vote's console
	# commands, registered `.with_chat()`, and an unclaimed `!` line carries on to the
	# console — one path. This handler answered both itself once, beside a console `rtv`
	# that went to the map session's time limit instead: two votes under one name.
	match command:
		"spec", "spectate":
			if game.spectate == null:
				services.notice(peer, "Spectating is not available here.")
			elif args.is_empty():
				var best := game.spectate.watch_best(voter)
				services.notice(
					peer,
					("Watching %s. Click to switch; R or !spec off to stop."
						% _shown_name(game.spectate.target_of(voter))) if best.ok
					else best.error.message
				)
			elif args[0] == "free" or args[0] == "roam":
				var roamed := game.spectate.toggle_roam(voter)
				services.notice(
					peer,
					"Flying free. !spec free again goes back to the players."
						if roamed.ok and game.spectate.is_roaming(voter)
					else ("Back to watching a player." if roamed.ok else roamed.error.message)
				)
			elif args[0] == "off" or args[0] == "stop":
				game.spectate.stop(voter)
				services.notice(peer, "Back to your own view.")
			else:
				# By name, and then by id. A player types what is on the scoreboard and
				# an id is what the game keys by; asking for the id alone is asking a
				# player to know something they cannot see.
				var wanted := _player_named(args[0])
				var res := game.spectate.watch(
					voter, wanted if wanted != &"" else StringName(args[0])
				)
				services.notice(
					peer,
					("Watching %s." % _shown_name(game.spectate.target_of(voter))) if res.ok
					else res.error.message
				)

			services.claim_command()
		"specnext", "next":
			if game.spectate == null:
				services.notice(peer, "Spectating is not available here.")
			else:
				var res := game.spectate.next_target(voter)
				services.notice(
					peer,
					("Watching %s." % _shown_name(game.spectate.target_of(voter))) if res.ok
					else res.error.message
				)

			services.claim_command()
		"vote":
			# Only without a vote, so a player gets "no vote" rather than silence.
			if vote == null:
				services.notice(peer, "There is no vote on this server.")
				services.claim_command()
		_:
			# Left for dot-server's own chat commands, which this game registers with
			# `.with_chat()` — `!r`, `!wr`, `!top`, `!style`, `!track`.
			pass


## A player's name for a reply, from their id. A reply that says "Watching u12." is
## a reply in the game's own bookkeeping.
func _shown_name(id: StringName) -> String:
	var player = game.players.get(id) if game != null else null
	return str(player.display_name) if player != null else String(id)


## A player id by display name, or "".
##
## Case-insensitive, and the best kind of match wins: the whole name, then the start of
## one, then anywhere in one — `!spec ad` finds Ada, and `!spec kitsune` finds
## "xX_kitsune_Xx", whose name nobody can type from the front. Within a kind the first in
## the roster wins, which is stable; the alternative is refusing an ambiguous match, and a
## player who typed two letters and got "be more specific" types three letters and gives up.
func _player_named(text: String) -> StringName:
	var wanted := text.strip_edges().to_lower()

	if wanted == "":
		return &""

	var prefix := &""
	var inside := &""

	for session in server.sessions():
		var name := session.display_name.to_lower()
		if name == wanted:
			return _player_id(session)
		if prefix == &"" and name.begins_with(wanted):
			prefix = _player_id(session)
		elif inside == &"" and name.contains(wanted):
			inside = _player_id(session)

	return prefix if prefix != &"" else inside


func _module_unload() -> void:
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


## Tells dot-server which map is running, so A2S and DQP print it in their map field (and
## the backbone report does too) rather than this game's content id. On every change
## through the session's own signal, which every route to a new map ends at.
func _report_map(map: DotMapDef, _world: Node = null) -> void:
	if map != null:
		if map_config == null:
			map_config = G2GMapConfig.build(console)
		map_config.apply(String(map.id))
	if server != null and server.games != null:
		server.games.set_current_map(String(map.id) if map != null else "")


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
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
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


func _physics_process(delta: float) -> void:
	if not loaded or bridge == null:
		return
	_tick += 1
	bridge.server_tick(_tick)

	# Twice a second is soon enough for a person to take a bot's seat.
	if _tick % 64 == 1:
		_keep_bots()

	# The vote clock, from the SIMULATED tick rather than from the frame. dot-vote
	# says why and it is the same reason dot-map does: a server that stalls should not
	# lose that time off its map, and a test must be able to run an hour of one in a
	# millisecond.
	if vote != null:
		vote.advance(delta)


## Adds or removes bots until there are as many as [DotBotQuota] wants for the people
## playing. Newest first out, so the bot that has been riding longest keeps riding.
func _keep_bots() -> void:
	if game == null or game.bots == null or _quota == null:
		return
	var humans := 0
	for id: StringName in game.players:
		var player: G2GPlayer = game.players[id]
		if not player.is_bot and id != G2GGame.GHOST_ID:
			humans += 1
	var slots: int = server.config.max_players if server != null and server.config != null else -1
	var wanted := _quota.wanted(humans, slots)
	var ids: Array = game.bots.get("ids")
	while ids.size() < wanted:
		var taken: Array = []
		for id: StringName in game.players:
			taken.append((game.players[id] as G2GPlayer).display_name)
		if game.bots.call("add_bot", DotBotNames.pick(taken, game.players.size())) == null:
			break
	while ids.size() > wanted:
		game.bots.call("remove_bot", ids[ids.size() - 1])


## Every command a player can type in chat here with no admin flag: what the client's
## help screen (H) lists, as [code][name, help][/code], sorted by name.
##
## [b]Read off the console, never written down a second time.[/b] The help screen is on
## the client and these are on the server, and a list kept in the client would be one
## that drifts the first time somebody adds a `!` command — which on this server is most
## weeks. Commands that need a flag are left out: a player who is not an admin should not
## be shown a menu of things that will answer "no".
func chat_commands() -> Array:
	var out: Array = []

	if console == null:
		return out

	# Already sorted by the console.
	for command_name in console.command_names():
		var cmd := console.find_command(str(command_name))

		if cmd == null or cmd.permission != "":
			continue

		var by_chat := cmd.chat_policy == DotConCommand.ChatPolicy.ALLOWED or (
			cmd.chat_policy == DotConCommand.ChatPolicy.DEFAULT and console.chat_commands_are_open()
		)

		if by_chat:
			out.append([str(command_name), cmd.description])

	return out


## So `changegame` and a vote have something to change to. Ships in the build, so the
## client owns its own scene and the signon takes the no-scene path.
func _register_games() -> void:
	if server.games == null:
		return
	if server.games.find_game("g2gfast") != null:
		return
	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = "g2gfast"
	descriptor.display_name = "g2gfast"
	descriptor.scene = G2GPaths.rebase("res://game/g2g.tscn")
	descriptor.client_scene = ""
	server.games.add_game(descriptor)


## A cvar mirrored onto a G2GConfig field. Writing it rebuilds every player's movement.
##
## Movement cvars are NOT startup-only: a surf server switches airaccelerate per map
## and that has to work live. What it costs is every run in progress, which
## `apply_movement` says loudly.
##
## [b]Validated BEFORE the config is written, through the console's own validator,
## and not after.[/b] The first version wrote the field, ran `validate()`, and on
## failure logged and returned — leaving the config invalid. `sv_maxvelocity 100`
## then blocked every later cvar: each one wrote its field, found the config still
## invalid because of the first, and quietly did nothing. The console reported all
## of them as set. Refusing at the console is what makes the operator see the
## refusal, and trying the value on a copy is what keeps the live config clean.
## Split `sv_content_maps` into ids. Commas or spaces, because an operator pasting a
## map list has one or the other and being refused over a separator is a waste of their
## afternoon.
func _split_map_ids(value: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in value.replace(",", " ").split(" ", false):
		var id := part.strip_edges()
		if id != "":
			out.append(id)
	return out


func _movement_cvar(cvar_name: String, field: String, description: String) -> void:
	var current: Variant = game.config.get(field)
	var text := ("1" if current else "0") if current is bool else str(current)

	var cvar := add_cvar(
		cvar_name, text, description, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	cvar.with_validator(func(proposed: String) -> DotResult:
		var trial := game.config.clone() as G2GConfig
		trial.set(field, _coerce(trial.get(field), proposed))
		return trial.validate()
	)

	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		var wanted: Variant = _coerce(game.config.get(field), new_value)
		if game.config.get(field) != wanted:
			game.config.set(field, wanted)
			game.apply_movement()
		_mirror_to_shared_cvar(field)
	)


## Registers the shared movement names that differ from g2g's (`sv_runspeed`, `sv_airwishspeed`, `sv_autohop`) over G2GConfig, through the same binder dot-game's `bind_movement_cvars` uses (this module is a DotModule, not a DotGameModule). The names spelled alike are g2g's own cvars already.
func _bind_shared_movement_names() -> void:
	var adapter := G2GMovementNames.new(game)
	adapter.changed_fn = _mirror_to_g2g_cvar
	_shared_names = DotFpsCvars.new().add_target(adapter)
	var _made := _shared_names.bind_cvars(Callable(self, "add_cvar"), DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)


## The config field changed (or a shared-name write was refused): both spellings show what G2GConfig holds.
func _mirror_to_g2g_cvar(field: String) -> void:
	for shared: String in G2GMovementNames.RENAMES:
		if G2GMovementNames.RENAMES[shared]["field"] == field:
			_set_cvar_text(G2GMovementNames.RENAMES[shared]["g2g"], field)
			_set_cvar_text(shared, field)


## The shared-name cvar of [param field] follows a change made through the g2g name.
func _mirror_to_shared_cvar(field: String) -> void:
	_set_cvar_text(G2GMovementNames.shared_name_for(field), field)


func _set_cvar_text(cvar_name: String, field: String) -> void:
	var cv: DotConVar = console.find_cvar(cvar_name) if console != null and cvar_name != "" else null
	if cv == null:
		return
	var current: Variant = game.config.get(field)
	var text := ("1" if current else "0") if current is bool else str(current)
	if cv.get_string() != text and not _is_same_number(cv.get_string(), text):
		var _res := cv.set_value(text)


static func _is_same_number(a: String, b: String) -> bool:
	return a.is_valid_float() and b.is_valid_float() and is_equal_approx(a.to_float(), b.to_float())


## A cvar's string in the type the config field already has.
static func _coerce(current: Variant, text: String) -> Variant:
	if current is bool:
		return text != "0" and text.to_lower() != "false" and text.to_lower() != "off"
	if current is int:
		return text.to_int()
	return text.to_float()


# --- Sessions --------------------------------------------------------------

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


func _on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	_painters.erase(_player_id(session))
	if noblock != null:
		noblock.rules.call(&"forget", session.userid)

	if services != null:
		services.remove_peer(session.peer_id)

		# Their noclip, and who gave it them. The next player with this userid starts clean.
		if services.mod_tools != null:
			services.mod_tools.forget(StringName(str(session.userid)))

	if vote != null:
		# Their rock-the-vote and their nominations. `rtv_forgets_leavers` decides
		# whether the tally shrinks with them, and it cannot do its job if nothing
		# tells it they went.
		vote.forget_voter(_player_id(session))

	if game != null and game.props != null:
		game.props.release_player(_player_id(session))

	if _joined.has(session.userid):
		bridge.remove_peer(session.peer_id)
		_joined.erase(session.userid)

		var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
		if loadouts != null:
			loadouts.remove_peer(session.peer_id)


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


func _painter_for(id: StringName) -> DotTimerZonePainter:
	if not _painters.has(id):
		_painters[id] = DotTimerZonePainter.on(game.timers.zones)
	var painter: DotTimerZonePainter = _painters[id]
	painter.zones = game.timers.zones
	# Zone heights in metres: 128 genre units of headroom, which is what the zone tools on those servers
	# gives and enough for a jumping player.
	painter.height = G2GUnits.to_metres(128.0)
	painter.padding = G2GUnits.to_metres(16.0)
	return painter


func _mark_position(ctx: DotCmdContext) -> Vector3:
	var player := _caller(ctx)
	if player != null:
		return player.controller.state.position
	var map := game.current_map_node()
	return map.spawn_for(DotTimerTrack.MAIN) if map != null else Vector3.ZERO


func _cmd_zone(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zone set.")
		return
	if ctx.args.is_empty():
		ctx.reply("g2g_zone <start|end|stage|respawn|stop|teleport> [track] [number]")
		return
	var kinds := {"start": DotTimerZone.Kind.START, "end": DotTimerZone.Kind.END,
		"stage": DotTimerZone.Kind.STAGE, "respawn": DotTimerZone.Kind.RESPAWN,
		"stop": DotTimerZone.Kind.STOP, "teleport": DotTimerZone.Kind.TELEPORT}
	var wanted := ctx.args[0].to_lower()
	if not kinds.has(wanted):
		ctx.reply("No such zone kind: %s" % ctx.args[0])
		return

	var track := DotTimerTrack.MAIN
	var consumed := 1
	if ctx.args.size() > 1:
		var text := ctx.args[1]
		if text.to_lower() in ["bonus", "b"] and ctx.args.size() > 2:
			text = "%s %s" % [text, ctx.args[2]]
			consumed = 2
		track = DotTimerTrack.parse(text)
		if track < 0:
			ctx.reply("No such track: %s" % text)
			return

	var number := 0.0
	if ctx.args.size() > consumed + 1 and ctx.args[consumed + 1].is_valid_float():
		number = ctx.args[consumed + 1].to_float()

	var began := _painter_for(_caller_id(ctx)).begin(kinds[wanted], track, number)
	if not began.ok:
		ctx.reply_error(began)
		return
	ctx.reply("Drawing a %s zone on %s. Stand on one corner and run g2g_zone_mark, then the other." % [
		wanted, DotTimerTrack.name_of(track)])


func _cmd_zone_mark(ctx: DotCmdContext) -> void:
	var painter := _painter_for(_caller_id(ctx))
	if painter.zones == null:
		ctx.reply("This map has no zone set.")
		return
	var at := _mark_position(ctx)
	# `g2g_zone_mark x y z [height]` in genre units is the corner the client's zone editor
	# aimed at (Z): exact, so no padding, and the height the editor showed. Standing on
	# the corner and marking without numbers is what it always was.
	if ctx.args.size() >= 3 and ctx.args[0].is_valid_float() and ctx.args[1].is_valid_float() \
			and ctx.args[2].is_valid_float():
		at = G2GUnits.vector_to_metres(Vector3(ctx.args[0].to_float(), ctx.args[1].to_float(),
			ctx.args[2].to_float()))
		painter.padding = 0.0
		if ctx.args.size() >= 4 and ctx.args[3].is_valid_float() and ctx.args[3].to_float() > 0.0:
			painter.height = G2GUnits.to_metres(clampf(ctx.args[3].to_float(), 8.0, 4096.0))
	var marked := painter.mark(at)
	if not marked.ok:
		ctx.reply_error(marked)
		return
	if marked.value == null:
		ctx.reply("First corner. Now the other.")
		return
	game.timers.set_zones(painter.zones)
	ctx.reply("Drew %s." % str(marked.value))


func _cmd_zone_undo(ctx: DotCmdContext) -> void:
	var undone := _painter_for(_caller_id(ctx)).undo()
	if not undone.ok:
		ctx.reply_error(undone)
		return
	game.timers.set_zones(game.timers.zones)
	ctx.reply("Removed %s." % str(undone.value))


func _cmd_zone_list(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones.")
		return
	ctx.reply_lines(_painter_for(_caller_id(ctx)).summary())


func _cmd_zone_save(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones.")
		return
	var problems := game.timers.zones.problems()
	if not problems.is_empty():
		ctx.reply("Not saving — fix these first:")
		ctx.reply_lines(problems)
		return
	var path := ctx.args[0] if ctx.args.size() > 0 else "user://zones/%s.json" % String(game.timers.zones.map_id)
	var wrote := game.timers.zones.save_json(path)
	if not wrote.ok:
		ctx.reply_error(wrote)
		return
	ctx.reply("Wrote %s (%d zones)." % [path, game.timers.zones.zones.size()])


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
