extends "g2g_net_bridge_world.gd"

func attach(p_game: G2GGame, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	for style in game.timers.styles_in_order():
		_style_ids.append(style.id)

	net.send_fn = _send

	var registered := _register_messages()
	if not registered.ok:
		return registered

	link = G2GNetLink.attached_to(link_parent, self, net.is_server)
	# Not a bare add_child: the link must sit under the server node (RPCs route by path) yet die
	# with this bridge, or a module reload leaves a second link and every RPC is lost silently.
	DotGameLink.attach(link, link_parent, self, G2GNetLink.NODE_NAME)

	_build_map_sync()

	# Both ends tick through server_tick / client_tick; a client game running its own loop
	# would simulate the local player twice a tick.
	game.external_tick = true

	if net.is_server:
		_connect_server()

	return DotResult.success(self)


func _register_messages() -> DotResult:
	var event := net.messages.register(
		G2GEvent.NAME, G2GEvent, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		G2GRequest.NAME, G2GRequest, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(G2GEvent.NAME, _on_event)
	net.messages.on(G2GRequest.NAME, _on_request)

	return DotResult.success(null)


func _on_event(message: DotNetMessage) -> void:
	var event := message as G2GEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		G2GEvents.Kind.HELLO:
			_apply_hello(reader)
		G2GEvents.Kind.JOIN:
			_apply_join(reader)
		G2GEvents.Kind.LEAVE:
			var session_id := G2GEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		G2GEvents.Kind.MOVEMENT:
			_apply_movement(reader)
		G2GEvents.Kind.MAP:
			_on_map_message(G2GEvents.read_map_message(reader))
		G2GEvents.Kind.TIMER:
			var timer := G2GEvents.read_timer(reader)
			if bool(timer["ok"]):
				_apply_timer(int(timer["player_id"]), timer["state"])
		G2GEvents.Kind.FINISH:
			var finish := G2GEvents.read_finish(reader)
			if bool(finish["ok"]):
				var f: DotTimerNet.Finish = finish["finish"]
				finish_received.emit(int(finish["player_id"]), f.time(1.0 / float(game.tick_rate)), f.rank)
		G2GEvents.Kind.RECORD, G2GEvents.Kind.NOTICE:
			var text := G2GEvents.read_text(reader)
			notice_received.emit(int(text["player_id"]), str(text["text"]))
		G2GEvents.Kind.VOTE:
			var voted := G2GEvents.read_vote(reader)
			if bool(voted["ok"]):
				vote_received.emit(voted)
		G2GEvents.Kind.CLOCK:
			var clock := G2GEvents.read_clock(reader)
			if bool(clock["ok"]):
				clock_view.adopt(clock, Time.get_ticks_msec() / 1000.0)
				clock_received.emit(clock)
		G2GEvents.Kind.NPC:
			var hunter := G2GEvents.read_npc(reader)
			if bool(hunter["ok"]):
				_mirror_hunter(hunter)
		G2GEvents.Kind.NPC_GONE:
			var gone := G2GEvents.read_npc_gone(reader)
			if bool(gone["ok"]):
				_drop_hunter_mirror(int(gone["net_id"]))
		G2GEvents.Kind.STANDING:
			var standing := G2GEvents.read_standing(reader)
			if bool(standing["ok"]):
				standing_received.emit(int(standing["player_id"]), standing)
		G2GEvents.Kind.STAGE_REF:
			var reference := G2GEvents.read_stage_ref(reader)
			if bool(reference["ok"]):
				stage_reference_received.emit(int(reference["player_id"]), reference)
		G2GEvents.Kind.MAPS:
			maps_received.emit(G2GEvents.read_maps(reader))
		G2GEvents.Kind.RULES:
			var rules := G2GEvents.read_rules(reader)
			if bool(rules["ok"]):
				rules_received.emit(rules)
		G2GEvents.Kind.KILLVIEW:
			var view := DotKillViewClip.unpack(event.body)
			if bool(view["ok"]):
				killview_received.emit(view["clip"], view["info"])
		_:
			if not weapon_net.apply(event.kind, reader, game.weapon_layer):
				_on_watch_event(event.kind, reader)

func _apply_hello(reader: DotNetReader) -> void:
	var hello := G2GEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# [b]The server's tick rate, before anything is derived from it.[/b] HELLO has
	# carried it since it was written and `read_hello` has always decoded it; nothing
	# read it back out, so a client counted at its own project's
	# `physics_ticks_per_second` — 128 in this repository, 60 in a host project that
	# never set one — against a server counting at `sv_tickrate`. Produced correctly
	# and consumed by nothing, which is this family's most repeated bug and is
	# invisible to `headless_net` for the usual reason: one process has one engine
	# rate, so both ends agreed no matter what the wire said.
	#
	# Before `sync_from_server`, because the clock converts its error and its lead
	# through `tick_rate` and would otherwise do that arithmetic at the old rate.
	_adopt_tick_rate(int(hello["tick_rate"]))
	_keep_up_through_slow_frames()

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	_apply_movement(DotNetReader.new(hello["movement"]))

	# No map here. The map this client joins onto arrives as the protocol's announce,
	# right behind HELLO — see `_map_admit`.
	hello_received.emit(local_player_id)


## Puts the whole client — game, timers, netcode clock — on the server's tick rate.
##
## Three places hold this number and all three have to move together. `game.tick_rate`
## is the step the simulation and every reconstituted run time use; `net.config.tick_rate`
## is what `DotNetInput.sanitise` and the interpolator's extrapolation budget read; and
## `net.clock.tick_rate` is the live one, built from the config back at `setup()` and
## therefore NOT updated by writing the config alone.
##
## A server never calls this: its rate is `sv_tickrate` and adopting a peer's would be
## a client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	net.clock.tick_rate = game.tick_rate

	# [b]And the engine's, which is the half that decides whether it looks smooth.[/b]
	# `G2GClient._physics_process` asks the clock how many ticks a frame is worth, so
	# the simulation was already correct with the engine left at 60 — it just ran them
	# in bursts of two and three. Nothing renders between ticks, so the camera moved
	# 74 mm on six frames out of seven and 112 mm on the seventh: a 47% change in
	# apparent speed, eight times a second, for as long as a browser client has
	# existed. That is the "very jittery in the browser" report.
	#
	# Interpolating fixes it and cannot be done without this line.
	# `DotFpsController.render_state` and `DotNetManager.interpolate_frame` both draw
	# at `Engine.get_physics_interpolation_fraction()`, which is a fraction through a
	# PHYSICS frame — only a fraction through a tick while the two rates are the same.
	# Measured at 60-against-128 the interpolation changes nothing at all; measured
	# with both on 128 the drawn step is uniform to within 0.3 mm. See
	# `examples/jitter_probe.tscn`, which runs all four combinations.
	#
	# A server is already excluded above: its rate is `sv_tickrate` and dot-server
	# writes this itself.
	Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## Client: lets the engine run every tick of a slow frame instead of dropping the rest.
##
## [b]The engine runs at most `max_physics_steps_per_frame` physics steps a frame, 8 by
## default, and silently drops the time past that.[/b] 8 steps are 133 ms at 60 Hz but 62.5 ms
## at this game's 128, so any client below 16 frames a second (a browser's first visit:
## packs mounting, every material's shader compiling) runs fewer ticks than the server.
##
## [b]Not what kept players on the spawn pad, though it was first taken for it.[/b] That was
## dot-net's clock, which was handed only the steps and never saw the dropped time, so every
## command was stamped for a tick the server had already simulated (dot-net API 5 credits it
## from the wall clock; docs/history.md has both). What the cap still buys is a command of the
## client's own for every tick: at 128 with 150 ms frames and a cap of 8, 57% of the server's
## ticks had none and repeated the one before, which drops a jump or a strafe shorter than a
## frame.
##
## Raised to cover [constant SLOW_FRAME_SECONDS] at the server's rate, never lowered: a
## frame that slow costs more physics steps, which is far cheaper than inputs the server
## never hears.
func _keep_up_through_slow_frames() -> void:
	if net == null or net.is_server or game == null or game.tick_rate <= 0:
		return
	var steps := ceili(SLOW_FRAME_SECONDS * float(game.tick_rate))
	if Engine.max_physics_steps_per_frame < steps:
		DotLog.info(CHANNEL, "the engine keeps up with slow frames", {
			"steps_per_frame": steps, "was": Engine.max_physics_steps_per_frame,
			"tick_rate": game.tick_rate,
		})
		Engine.max_physics_steps_per_frame = steps


func _apply_movement(reader: DotNetReader) -> void:
	var fingerprint := G2GEvents.read_movement(reader, game.config)
	game.apply_movement()

	# The whole reason the config travels rather than the tunables: both ends derive
	# through the same code, and a mismatch is one log line rather than a week of
	# "the netcode feels bad".
	if game.tunables.fingerprint() != fingerprint:
		DotLog.warn(CHANNEL, "movement fingerprint disagrees with the server", {
			"ours": game.tunables.fingerprint(), "theirs": fingerprint
		})


func _apply_join(reader: DotNetReader) -> void:
	var join := G2GEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var peer_id := int(join["peer_id"])
	var id := _player_key(session_id)
	var is_me := session_id == local_player_id

	var player: G2GPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), is_me, join["avatar"])
		if player == null:
			return
		# A client never samples: the client loop hands it commands. It keeps the
		# camera and the HUD's attention if it is the local one.
		player.sampler = null

		# The ghost has no timer anywhere: the server never feeds one, so no TIMER
		# event will ever correct what a mirror started on its own by watching the
		# ghost leave the start pad.
		if session_id == G2GGame.GHOST_SESSION:
			game.timers.remove_player(game.record_key(id))
			player.timer = null

		var identity := _build_entity(player, peer_id)
		var registered := net.registry.register(identity, int(join["net_id"]), net.clock.tick, net.config)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])
		if join["avatar"] != null:
			player.rig.dress(join["avatar"], game.avatar_schema, game.avatar_catalogue)

	game.set_player_style(id, _style_id(int(join["style_index"])))
	game.timers.set_player_track(game.record_key(id), int(join["track"]))

	roster_changed.emit(session_id)


func _apply_timer(session_id: int, state: DotTimerNet.RunState) -> void:
	var player: G2GPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	# Against the ESTIMATED server tick, not the local one: the local tick runs a
	# lead ahead so commands arrive in time, and a HUD counting from it would show
	# every run a flight time longer than the server will file it.
	player.timer.run = DotTimerNet.run_from_state(
		state, net.clock.server_tick(), 1.0 / float(game.tick_rate), _style_id(state.style_index)
	)


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"local": local_player_id,
		"tick": _tick,
		"link": link.describe() if link != null else {},
		"map_sync": (
			map_host.describe() if map_host != null
			else map_client.describe() if map_client != null else {}
		),
	}
