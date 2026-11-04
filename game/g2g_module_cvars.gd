extends "g2g_module_load.gd"

## The cvars and commands G2GModule registers when it loads, one function per family.


## Movement cvars in the genre's units.
func _bind_movement_cvars() -> void:
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


## Replay bot, bots, view, flashlight, snapshot and spectator cvars.
func _bind_rule_cvars() -> void:
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


## Course commands and dot-map's map commands.
func _add_course_commands() -> void:
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


## Content maps, rotation file, map sync and the rtv command.
func _bind_map_cvars() -> void:
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


## Chat aliases, zone tools and the records commands.
func _add_chat_commands() -> void:
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


## Mode cvars that flip layers already built.
func _bind_mode_cvars() -> void:
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
