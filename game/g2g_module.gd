extends "g2g_module_cvars.gd"

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

	_bind_movement_cvars()
	_bind_rule_cvars()
	_add_course_commands()
	_bind_map_cvars()
	_add_chat_commands()
	_bind_mode_cvars()
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


## dot-platform's broadcast_avatar_changes, received: the player is redressed and
## everybody is told, through the same JOIN a style change sends.
func _on_avatar_changed(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))
	if session == null or bridge == null:
		return
	var avatar := _avatar_for(session)
	if avatar != null:
		bridge.dress(session.userid, avatar)


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
		# The genre: runners pass through each other. dot-team's own default blocks enemies, and
		# everyone is one: so unless a cfg layer says otherwise, nobody stops until `mp_enemyblock 1`
		# or a pair of `!block` requests. (A client follows the server's value.)
		var cfg: Object = noblock.rules.get(&"config")
		if noblock.binder.source_of("enemy_block") == "default" and cfg != null:
			cfg.set(&"enemy_block", false)
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
