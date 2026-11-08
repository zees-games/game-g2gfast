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


func _physics_process(delta: float) -> void:
	if not loaded or bridge == null:
		return
	_tick += 1
	_follow_npc_lod(game.hunters.spawner if game != null and game.hunters != null else null, delta)
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


## Reused by [method _keep_bots] so a bot being added allocates no list.
var _bot_names_taken: Array = []


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
		_bot_names_taken.clear()
		for id: StringName in game.players:
			_bot_names_taken.append((game.players[id] as G2GPlayer).display_name)
		if game.bots.call("add_bot", DotBotNames.pick(_bot_names_taken, game.players.size())) == null:
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


## The family `stats_report` cvar (off by default); the tracker is registered when first needed, since the progress node may not exist at load.
func _bind_stats_report() -> void:
	var _cv := DotGameStatsReport.bind(self,
		func(on: bool) -> DotResult:
			if game.progress == null or game.progress.stats == null:
				return DotResult.fail(DotError.CODE_STATE, "No progress yet.")
			if DotRegistry.get_service(DotGameStatsFeed.SERVICE) != game.progress.stats:
				DotRegistry.register(DotGameStatsFeed.SERVICE, game.progress.stats)
			return DotGameStatsReport.apply_default(self, on))


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


## The NPC level of detail and sense workers follow the `npc_lod*` cvars (dot-game's DotGameNpcLod; all off by default). This module is a DotModule, so it holds the attachment itself.
var _npc_lod: DotGameNpcLod = null


func _follow_npc_lod(spawner: Object, delta: float) -> void:
	if spawner == null or console == null:
		return
	if _npc_lod == null or _npc_lod.spawner != spawner:
		if _npc_lod != null:
			_npc_lod.release()
		_npc_lod = DotGameNpcLod.attach(self, console, spawner, server.config if server != null else null)
	if _npc_lod != null:
		_npc_lod.follow(delta)
