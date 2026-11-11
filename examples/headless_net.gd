extends "headless_net_maps.gd"

## game-airdrift's netcode, end to end, in one process.
##
## A server game and a client game, each with its own [DotNetManager] and [G2GNetBridge], with a
## lossy loopback where the socket would be. This proves the bridge, not dot-net.
##
## [b]The client's tick lead is hand-stamped[/b] (INPUT_LEAD): a command for tick N
## has to be in the server's hands before it simulates N, and with no clock to
## synchronise against the harness does the arithmetic itself.


## What the client's engine is pretending to run at, and deliberately not the
## server's. See the note in [method _build].
const CLIENT_ENGINE_TICK_RATE := 60

const CHECKS := 273

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 37


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: netcode")
	print("")
	_test_command_wire()
	_test_neutralise()
	_test_movement_wire()
	_test_hello_wire()
	if await _build():
		await _test_handshake()
		await _test_prediction()
		await _test_prediction_hopping()
		await _test_timer()
		await _test_finish()
		# After the walked finish: run before it, they left that walk stopped short of the
		# pad's edge (cause unknown, see nightly 1546's note).
		await _test_pit_respawn_predicted()
		await _test_pit_zone_predicted()
		_test_movement_change()
		_test_style_and_track()
		_test_avatar()
		await _test_lossy()
		await _test_map_change()
		await _test_map_by_vote()
		await _test_map_delivered()
		await _test_map_owned()
		await _test_map_republished()
		await _test_map_straggler()
		await _test_map_refused()
		_test_ghost()
		await _test_solid_players()
		await _test_voice_wire()
		_test_vote_wire()
		_test_clock_wire()
		_test_rules_wire()
		_test_hit_wire()
		_test_end_of_match_wire()
		_test_death_wire()
		_test_blind_and_beacon()
		_test_hunters_reach_the_client()
		_test_spectating_reaches_the_client()
		_test_leave()
	_test_the_remote_workbench()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## sv_workbench_remote over the real frames, in the order G2GModule and G2GClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_done()
		return
	var rig := _remote_workbench_rig()
	var flags: Dictionary = rig["flags"]
	var state: Dictionary = rig["state"]
	var snet: DotNetManager = rig["snet"]
	var cnet: DotNetManager = rig["cnet"]
	var sconfig: G2GConfig = rig["sconfig"]
	var sbinder: DotGameConfigBinder = rig["sbinder"]
	var swb: DotGameWorkbench = rig["swb"]
	var slink: DotNetProfileLink = rig["slink"]
	var clink: DotNetProfileLink = rig["clink"]
	var cremote: DotGameWorkbenchRemoteClient = rig["cremote"]
	var crt: DotProfileRuntime = rig["crt"]
	var remote: DotGameWorkbenchRemote = rig["remote"]
	var cwb: DotGameWorkbench = rig["cwb"]
	var kind: String = rig["kind"]
	var edit: Dictionary = rig["edit"]
	var srt: DotProfileRuntime = rig["srt"]
	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sconfig.flashlight, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and not sconfig.flashlight, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": true})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(not sconfig.flashlight, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and not sconfig.flashlight, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(not sconfig.flashlight, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(not sconfig.flashlight, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_done()






## Two managers over a loopback, the server's workbench and the client's, wired as G2GModule and G2GClient wire them.
func _remote_workbench_rig() -> Dictionary:
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var snet := _make_manager(true, &"wbserver", 1, self, 64)
	var cnet := _make_manager(false, &"wbclient", 5, self, 64)
	var sconfig := G2GConfig.new()
	var cconfig := G2GConfig.new()
	var sbinder := G2GConfig.make_binder(sconfig)
	var cbinder := G2GConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("movement"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("movement"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "flashlight", "value": false}
	var srt := swb.api.runtime as DotProfileRuntime
	return {"flags": flags, "state": state, "snet": snet, "cnet": cnet, "sconfig": sconfig, "sbinder": sbinder, "swb": swb, "slink": slink, "clink": clink, "cremote": cremote, "crt": crt, "remote": remote, "cwb": cwb, "kind": kind, "edit": edit, "srt": srt}



func _test_command_wire() -> void:
	_section("a command survives the wire")
	var packet := G2GNetCommand.new()
	packet.tick = 77
	packet.delta = 1.0 / 128.0
	packet.move.move = Vector2(-1.0, 0.5)
	packet.move.yaw = 45.0
	packet.move.pitch = -20.0
	packet.move.set_button(DotFpsCommand.BUTTON_JUMP, true)
	packet.move.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	var writer := DotNetWriter.new()
	packet.write(writer)
	var back := G2GNetCommand.new()
	back.read(DotNetReader.new(writer.to_bytes()))

	_check(back.tick == 77, "tick")
	_check(back.move.move.distance_to(packet.move.move) < 0.01, "move axes", str(back.move.move))
	_check(absf(back.move.yaw - 45.0) < 0.2 and absf(back.move.pitch + 20.0) < 0.5, "view angles", "%s %s" % [back.move.yaw, back.move.pitch])
	_check(back.move.is_pressed(DotFpsCommand.BUTTON_JUMP) and back.move.is_pressed(DotFpsCommand.BUTTON_CROUCH), "buttons")
	# Quantised once is quantised for good: a second trip must change nothing.
	var again := DotNetWriter.new()
	back.write(again)
	var twice := G2GNetCommand.new()
	twice.read(DotNetReader.new(again.to_bytes()))
	_check(twice.equals(back), "and is stable under a second trip, which is what input compression rests on")
	_done()


func _test_neutralise() -> void:
	_section("a silent player's command lets go")
	var command := G2GNetCommand.new()
	command.attack = true
	command.move.move = Vector2(0.0, 1.0)
	command.move.yaw = 40.0
	command.move.set_button(DotFpsCommand.BUTTON_JUMP, true)
	command._neutralise()
	_check(not command.attack and command.move.move == Vector2.ZERO and command.move.buttons == 0,
		"attack, move and buttons are cleared")
	_check(is_equal_approx(command.move.yaw, 40.0), "and the view is kept")
	_done()


func _test_movement_wire() -> void:
	_section("the movement configuration travels")
	var config := G2GConfig.new()
	config.air_accelerate = 1000.0
	config.gravity = 600.0
	config.auto_bhop = false

	var reader := DotNetReader.new(G2GEvents.write_movement(config))
	var received := G2GConfig.new()
	var fingerprint := G2GEvents.read_movement(reader, received)

	_check(received.air_accelerate == 1000.0 and received.gravity == 600.0, "cvars arrive")
	_check(received.auto_bhop == false, "and the autobhop switch")
	_check(G2GMovement.tunables_for(received).fingerprint() == fingerprint,
		"and the receiver derives the same tunables the sender fingerprinted")
	_check(G2GMovement.tunables_for(config).fingerprint() == fingerprint, "which are the sender's")
	_done()


func _test_hello_wire() -> void:
	_section("hello")
	var config := G2GConfig.new()
	var reader := DotNetReader.new(G2GEvents.write_hello(128, 7, 2, 4096, config))
	var hello := G2GEvents.read_hello(reader)
	_check(bool(hello["ok"]), "parses")
	_check(int(hello["tick_rate"]) == 128 and int(hello["player_id"]) == 7 and int(hello["peer_id"]) == 2, "with ids")
	# No map. It carried one, and the client changed to it by id out of its own build —
	# the ad-hoc half of what dot-map's protocol now does. The map arrives as an announce.
	_check(int(hello["server_tick"]) == 4096 and not hello.has("map_id"), "the tick, and no map: the protocol's announce carries that")

	# The protocol's own messages, through the game's codec both ways.
	var map := DotMapDef.new()
	map.id = &"surf_g2g_intro"
	map.scene_path = "res://maps/surf_g2g_intro.tscn"
	map.tier = 4
	var announce := G2GEvents.read_map_message(DotNetReader.new(
		G2GEvents.write_map_message(DotMapMessage.announce(map))))
	var back := DotMapDef.from_dictionary(announce.get("map", {}))
	_check(DotMapMessage.kind_of(announce) == DotMapMessage.KIND_ANNOUNCE and back.id == map.id
		and back.tier == 4 and back.version == map.version and back.is_local(),
		"a map announce survives the wire, tier and all", str(announce))
	var huge := DotMapMessage.announce(map)
	(huge["map"] as Dictionary)["description"] = "x".repeat(G2GEvents.MAP_MESSAGE_BYTES)
	_check(G2GEvents.write_map_message(huge).is_empty(),
		"one too big to send is refused whole rather than cut into JSON nobody can parse")
	var garbage := DotNetWriter.new()
	garbage.write_string("{not json", G2GEvents.MAP_REPLY_BYTES)
	_check(G2GEvents.read_map_message(DotNetReader.new(garbage.to_bytes()), G2GEvents.MAP_REPLY_BYTES).is_empty(),
		"and a reply that is not a JSON object reads as nothing, which dot-map ignores")
	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way. The track is
	# dot-timer's number in dot-timer's width, which can grow under this game.
	_check(G2GEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [G2GEvents.Kind.size(), G2GEvent.KIND_BITS])
	_check(G2GRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [G2GEvents.Ask.size(), G2GRequest.KIND_BITS])
	_check(G2GEvents.tracks_fit(), "every timer track fits JOIN's track field",
		"%d tracks in %d bits" % [DotTimerTrack.COUNT, DotTimerTrack.BITS])
	_done()


# --- Bringing both halves up ---------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(120):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_check(_server_game.maps.current != null and _client_game.maps.current != null, "both games load the map")
	_check(_server_game.tick_rate == _client_game.tick_rate, "at one tick rate, because one process has one engine rate")

	# [b]And that is exactly why this suite could not see the tick rate bug.[/b] Both
	# halves read `Engine.physics_ticks_per_second`, so they agreed no matter what the
	# wire carried — while a real client is a separate process whose rate is its own
	# project's export and has nothing to do with the server's `sv_tickrate`. The
	# client shell in dot-server-deploy never sets one at all and runs at 60.
	#
	# So put the client on a rate the server is not on, the way a host project would,
	# and let HELLO be what corrects it. Every check after this one is then running
	# against a client that had to adopt rather than one that happened to match.
	_check(
		_client_game.set_tick_rate(CLIENT_ENGINE_TICK_RATE),
		"the client is put on %d, as a host project with its own export would be" % CLIENT_ENGINE_TICK_RATE
	)
	_check(
		_client_game.tick_rate != _server_game.tick_rate,
		"so the two now disagree", "%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)

	# [b]The ENGINE too, or the check below passes for the wrong reason.[/b] Both halves
	# share one process and this project exports 128, so an assertion that the engine
	# ends up on the server's rate would hold whether or not anything ever set it — the
	# same "agrees versus was never asked to disagree" trap that let the original tick
	# rate bug live here. The browser shell genuinely runs at 60, so put the engine
	# there and make HELLO be what moves it.
	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE
	# And the engine's default step cap, which is what a shell that sets none runs with:
	# HELLO must be what raises it (see the slow-frame check below).
	Engine.max_physics_steps_per_frame = 8
	_check(
		Engine.physics_ticks_per_second != _server_game.tick_rate,
		"and so does the engine, which is what a browser shell that sets none runs at",
		"engine %d vs server %d" % [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = G2GNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = G2GNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	# The link mirrors a node named "Server" on both ends: the manager is one.
	var attached := _server_bridge.attach(_server_game, _server_net, _server_net)
	_check(attached.ok, "the server bridge attaches", str(attached.error) if not attached.ok else "")
	var client_attached := _client_bridge.attach(_client_game, _client_net, _client_net)
	_check(client_attached.ok, "the client bridge attaches", str(client_attached.error) if not client_attached.ok else "")

	var wrong := G2GNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net, self)
	_check(not refused.ok and refused.error.code == DotError.CODE_STATE, "a client game on a server manager is refused")
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the message schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	# What a real client wires to DotClientLink.ping_ms(). Without it the clock
	# believes the link is instant and every command arrives a flight time late.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	# start() announced the client's schema before the loopback existed, so it went nowhere
	# and the server kept the pre-list snapshot format. Announce again now it can arrive;
	# it is delivered with the rest of _to_server once the loop runs.
	_client_net.announce_schema(1)

	_check(_server_game.external_tick, "the server game hands its tick to the bridge")
	_check(_client_game.external_tick, "and so does the client's, which predicts and interpolates instead")

	_done()
	return attached.ok and client_attached.ok



func _test_handshake() -> void:
	_section("a client joins")

	var hellos := []
	# [b]Whether the local player exists at the moment HELLO says who you are.[/b] It does
	# not — `_apply_join` is what calls `game.add_player` — and a client that resolved its
	# own player on `hello_received` therefore held null for the whole session. G2GClient
	# did exactly that, and the symptom was the entire keyboard and mouse dead on a client
	# whose HUD, movement and camera all worked: everything below its `player == null`
	# guard is mouse look and the keybinds, while movement is polled from the InputMap and
	# never touches it.
	#
	# Captured in the handler rather than checked afterwards, because by the time the
	# exchange returns JOIN has been applied and the answer is yes either way.
	var local_at_hello := []
	var added_locally: Array[StringName] = []
	_client_game.player_added.connect(func(p: G2GPlayer) -> void: added_locally.append(p.player_id))
	_client_bridge.hello_received.connect(func(id: int) -> void:
		hellos.append(id)
		local_at_hello.append(_client_game.players.has(StringName("u%d" % id)))
	)

	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. The
	# server sends nothing on it, keeps it, and answers it when the seat comes; a bridge that
	# dropped it never told this client anything.
	_client_bridge.ask_ready()
	_exchange()
	_check(not _server_net.peers().has(CLIENT_PEER) and _client_player() == null and hellos.is_empty(),
		"a READY before the seat admits nothing yet")

	var loaded: Array[String] = []
	_client_bridge.map_loaded.connect(func(m: DotMapDef) -> void: loaded.append(String(m.id)))
	var standings := []
	_client_bridge.standing_received.connect(func(id: int, _standing: Dictionary) -> void: standings.append(id))

	var added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(added.ok, "the server adds the player", str(added.error) if not added.ok else "")
	_check(_server_player() != null and not _server_player().samples_input, "as a remote player on the server")
	_exchange()

	_check(_server_net.peers().has(CLIENT_PEER), "asking admits them")
	# The client's announce reached the server, so snapshots to it carry the unchanged list.
	# By the constant map, so this parses against a dot-net from before the feature.
	var runs_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_UNCHANGED_RUNS", 0))
	_check(runs_bit == 0 or _server_net.messages.peer_supports(CLIENT_PEER, runs_bit),
		"the server knows its client reads the unchanged list")
	_check(hellos == [SESSION], "and the client is told who it is", str(hellos))
	_check(_client_bridge.local_player_id == SESSION, "which the bridge remembers")
	# The join's spawn works the standing out inside `game.add_player`, before the peer is
	# mapped, so with a store that answers from memory it went to nobody: a reconnecting
	# record holder's timer showed no best and no record while Tab showed both.
	_check(standings.has(SESSION), "and is sent its standing, which the join worked out before it had a peer",
		str(standings))
	_handshake_stage_ref()
	await _handshake_tick_rate(local_at_hello)
	await _handshake_map(loaded, added_locally)
	_done()


## A splits comparison survives the wire and reaches the owner.
func _handshake_stage_ref() -> void:
	var reference_in: Array[Dictionary] = []
	_client_bridge.stage_reference_received.connect(func(id: int, ref: Dictionary) -> void:
		if id == SESSION:
			reference_in.append(ref)
	)
	var sent := {
		"map": "bhop_x", "track": 0, "style": &"normal", "stages": 3,
		"pb": {"splits": {1: 10.25, "2": 21.5}, "total": 33.125},
		"wr": {"splits": {1: 9.0, 2: 20.0, 3: 29.5}, "total": 31.75},
		"bests": {1: 9.5, 3: 11.0, 4: 12.0},
	}
	var wire := G2GEvents.read_stage_ref(DotNetReader.new(G2GEvents.write_stage_ref(SESSION, sent)))
	_check(bool(wire["ok"]) and int(wire["stages"]) == 3 and is_equal_approx(float(wire["pb"]["total"]), 33.125)
		and wire["pb"]["splits"].size() == 2 and is_equal_approx(float(wire["wr"]["splits"][3]), 29.5)
		and wire["bests"].size() == 3 and not wire["bests"].has(2),
		"a splits comparison survives the wire, absent splits staying absent", str(wire))
	_check(wire["map"] == "bhop_x", "carrying the map it was worked out for", str(wire.get("map")))
	# A message from before the map id was added ends after the bests: refused whole.
	var short := G2GEvents.write_stage_ref(SESSION, sent)
	short = short.slice(0, short.size() - 1 - "bhop_x".length())
	var old_wire := G2GEvents.read_stage_ref(DotNetReader.new(short))
	_check(not bool(old_wire["ok"]), "and one without a map id is refused, not guessed at", str(old_wire.get("ok")))
	_server_game.stage_reference_changed.emit(G2GNetBridge._player_key(SESSION), sent)
	_exchange()
	_check(reference_in.size() == 1 and reference_in[0]["style"] == "normal"
		and is_equal_approx(float(reference_in[0]["wr"]["total"]), 31.75),
		"and the server sends the owner their comparison when it changes", str(reference_in))
	_check(reference_in.size() == 1 and reference_in[0]["map"] == "bhop_x", "map id included", str(reference_in))
	_check(G2GEvent.fits(), "and the new message kind still fits the kind field")


## HELLO moves the client game, timers, clock and engine to the server's tick rate.
func _handshake_tick_rate(local_at_hello: Array) -> void:
	# Game, net config and the clock's setup() copy all have to move.
	_check(
		_client_game.tick_rate == _server_game.tick_rate,
		"and the client adopts the server's tick rate from HELLO",
		"%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)
	_check(
		_client_game.timers.tick_rate == _server_game.tick_rate,
		"its timers with it, or every run time is wrong by the ratio",
		"%d vs %d" % [_client_game.timers.tick_rate, _server_game.tick_rate]
	)
	_check(
		_client_net.clock.tick_rate == _server_game.tick_rate
			and _client_net.config.tick_rate == _server_game.tick_rate,
		"and so does the netcode clock, which is a copy taken at setup()",
		"clock %d, config %d" % [_client_net.clock.tick_rate, _client_net.config.tick_rate]
	)
	# [b]And the ENGINE's, which is the half that decides whether it looks smooth.[/b]
	# The three rates above make the simulation correct; this one makes it drawable.
	# `G2GClient._physics_process` asks the clock how many ticks a frame is worth, so a
	# client on a 60 Hz engine against a 128-tick server simulated the right number of
	# ticks — in bursts of two and three. Nothing renders between ticks, so the camera
	# advanced 74 mm on six frames out of seven and 112 mm on the seventh: a 47% change
	# in apparent speed, eight times a second. Interpolation cannot fix it on its own,
	# because a fraction through a PHYSICS frame is only a fraction through a tick while
	# the two rates agree. `examples/jitter_probe.tscn` measures all four combinations.
	_check(
		Engine.physics_ticks_per_second == _server_game.tick_rate,
		"and the ENGINE, so one physics frame is one tick and a renderer can interpolate",
		"engine %d vs server %d" % [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)
	# [b]And every tick of a slow frame.[/b] The engine runs at most
	# `max_physics_steps_per_frame` steps a frame and drops the rest; the default 8 is
	# 62.5 ms at 128, so a client under 16 frames a second (a browser's first visit) ran
	# fewer ticks than the server, every command it sent was late, and the server never
	# moved the player off the spawn pad. Measured through real slow frames, because a
	# setting that is written and not obeyed is this family's most repeated bug. Armed:
	# without `_keep_up_through_slow_frames` both fail (8 steps; about 53 ticks a second).
	var wanted_steps := ceili(G2GNetBridge.SLOW_FRAME_SECONDS * float(_server_game.tick_rate))
	_check(
		Engine.max_physics_steps_per_frame >= wanted_steps,
		"HELLO lets the engine run a quarter second of ticks in one frame",
		"%d steps a frame, %d wanted" % [Engine.max_physics_steps_per_frame, wanted_steps]
	)
	await get_tree().process_frame
	var physics_before := Engine.get_physics_frames()
	var wall_before := Time.get_ticks_usec()
	for _i in range(6):
		OS.delay_msec(150)
		await get_tree().process_frame
	var ran := Engine.get_physics_frames() - physics_before
	var owed := float(Time.get_ticks_usec() - wall_before) / 1000000.0 * float(Engine.physics_ticks_per_second)
	_check(
		float(ran) >= 0.85 * owed,
		"through 150 ms frames the engine still runs every tick the server does",
		"%d physics steps for %.0f ticks of wall time" % [ran, owed]
	)
	_check(
		local_at_hello == [false],
		"the local player does NOT exist yet when HELLO names it — JOIN is what creates it",
		str(local_at_hello)
	)


## The joiner is told the map, mirrors itself as the local player and is predicted.
func _handshake_map(loaded: Array[String], added_locally: Array[StringName]) -> void:
	var announced := _client_bridge.map_client.announced
	_check(announced != null and announced.id == _server_game.maps.current.id,
		"the joiner is announced the map the server is on",
		String(announced.id) if announced != null else "nothing announced")
	_exchange()
	for _i in range(10):
		if not loaded.is_empty():
			break
		await get_tree().process_frame
		_flush()
	_check(loaded == [String(_server_game.maps.current.id)],
		"and told to load it once it said it had it", str(loaded))
	_check(_server_bridge.map_host.peers.has(CLIENT_PEER), "and follows every change from now on")
	_check(
		added_locally.has(StringName("u%d" % SESSION)),
		"so `player_added` is the hook a client has to follow, and it fires for the local one",
		str(added_locally)
	)
	_check(_client_player() != null and _client_player().samples_input, "the client mirrors itself as the local player")
	_check(_client_player() != null and _client_player().sampler == null, "which the bridge drives rather than the devices")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "with the server's movement")
	_check(_client_player() != null and _client_player().timer != null and not _client_player().timer.authoritative,
		"and a timer that mirrors rather than decides")

	var mine := _client_bridge.behaviour_for(SESSION)
	_check(mine != null and mine.identity != null and mine.identity.is_predicted(), "the local player is predicted")
	_check(mine != null and mine.identity.net_id == _server_bridge.behaviour_for(SESSION).identity.net_id,
		"under the server's entity id")


func _test_prediction_hopping() -> void:
	_section("prediction converges while hopping and turning in the start zone")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()
	for i in range(600):
		var c := DotFpsCommand.new()
		c.move = Vector2(1.0 if (i / 40) % 2 == 0 else -1.0, 1.0)
		c.yaw = float(i) * 0.7
		c.set_button(DotFpsCommand.BUTTON_JUMP, true)
		_step(c)
		if i % 4 == 0:
			_flush()
	_flush()
	_check(client.global_position.distance_to(server.global_position) < 0.5, "the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_check(_client_net.predictor.correction_rate() < 0.1, "with almost no corrections", "%.3f" % _client_net.predictor.correction_rate())
	await get_tree().process_frame
	_done()


## nightly 1546: the client ignored a lethal hurt volume and the server's respawn reached it a
## round trip later as a 5 m correction. It now predicts the respawn at the map's start.
func _test_pit_respawn_predicted() -> void:
	_section("a pit's respawn is predicted, not corrected")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(8)
	_steps(60, _forward())
	var pit := server.global_position
	_server_game.spawn_player(server.player_id)
	_steps(30)
	var box := {"box": AABB(pit - Vector3(1.0, 1.0, 1.0), Vector3(2.0, 2.0, 2.0)), "damage": 1000.0}
	_server_game.mechanics.hurt.append(box)
	_client_game.mechanics.hurt.append(box.duplicate())
	var hits := {"server": 0, "client": 0}
	var on_server := func(event: int, _index: int) -> void:
		if event == G2GPlayer.G2GMapMechanics.Event.HURT:
			hits["server"] += 1
	var on_client := func(event: int, _index: int) -> void:
		if event == G2GPlayer.G2GMapMechanics.Event.HURT:
			hits["client"] += 1
	server.map_event.connect(on_server)
	client.map_event.connect(on_client)
	_client_net.predictor.set("_worst_error", 0.0)
	_steps(100, _forward())
	_flush()
	server.map_event.disconnect(on_server)
	client.map_event.disconnect(on_client)
	_server_game.mechanics.hurt.pop_back()
	_client_game.mechanics.hurt.pop_back()
	var worst: float = _client_net.predictor.get("_worst_error")
	_check(int(hits["server"]) >= 1, "the server's player runs into the pit", "%d hits" % hits["server"])
	_check(int(hits["client"]) >= 1, "and the client's prediction does too", "%d hits" % hits["client"])
	_check(worst < 0.5, "the respawn needs no large correction", "%.3f m" % worst)
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_server_game.spawn_player(server.player_id)
	_steps(30)
	await get_tree().process_frame
	_done()


## nightly 1546: a RESPAWN zone (the intro maps' pit) on the client teleported only after the predictor had
## remembered the tick, so every pit was a 5 m correction in netchaos.
func _test_pit_zone_predicted() -> void:
	_section("a pit zone's respawn is predicted, not corrected")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(8)
	_steps(60, _forward())
	var pit := server.global_position
	_server_game.spawn_player(server.player_id)
	_steps(30)
	var added: Array[DotTimerZone] = []
	for game: G2GGame in [_server_game, _client_game]:
		var zone := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN).set_box(
			pit - Vector3(1.0, 1.0, 1.0), pit + Vector3(1.0, 1.0, 1.0))
		game.timers.zones.add(zone)
		game.timers.set_zones(game.timers.zones)
		added.append(zone)
	var hits := {"server": 0, "client": 0}
	var on_server := func(_id: StringName, zone: DotTimerZone) -> void:
		if zone == added[0]:
			hits["server"] += 1
	var on_client := func(_id: StringName, zone: DotTimerZone) -> void:
		if zone == added[1]:
			hits["client"] += 1
	_server_game.timers.effect_requested.connect(on_server)
	_client_game.timers.effect_requested.connect(on_client)
	_client_net.predictor.set("_worst_error", 0.0)
	_steps(100, _forward())
	_flush()
	_server_game.timers.effect_requested.disconnect(on_server)
	_client_game.timers.effect_requested.disconnect(on_client)
	for i in range(2):
		var game: G2GGame = [_server_game, _client_game][i]
		game.timers.zones.remove_id(added[i].id)
		game.timers.set_zones(game.timers.zones)
	var worst: float = _client_net.predictor.get("_worst_error")
	_check(int(hits["server"]) >= 1, "the server's player falls into the pit zone", "%d hits" % hits["server"])
	_check(int(hits["client"]) >= 1, "and the client's timer sees it too", "%d hits" % hits["client"])
	_check(worst < 0.5, "the zone's respawn needs no large correction", "%.3f m" % worst)
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client ends where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	_server_game.spawn_player(server.player_id)
	_steps(30)
	await get_tree().process_frame
	_done()


func _test_prediction() -> void:
	_section("prediction converges")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()

	var forward := _forward()
	_steps(96, forward)

	_check(G2GUnits.to_units(server.speed()) > 200.0, "the server player moves on the client's input", G2GUnits.format_speed(server.speed()))
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client shows it where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	var rate := _client_net.predictor.correction_rate()
	_check(rate < 0.1, "with almost no corrections", "%.3f" % rate)
	_check(absf(_client_net.stats.rtt_percentile(0.5) - 40.0) < 0.01, "and the clock has been told how long the link is",
		"%.1f ms" % _client_net.stats.rtt_percentile(0.5))
	await get_tree().process_frame
	_done()


func _test_timer() -> void:
	_section("the timer replicates")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(2)

	_check(server.timer.in_zone(DotTimerZone.Kind.START), "the server player spawns on the start pad")

	var hold := _forward()
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)
	_steps(120, _forward())
	_steps(120, hold)

	_check(server.timer.run.is_running(), "the server's run starts when its player hops off the pad",
		"in start: %s, %s" % [server.timer.in_zone(DotTimerZone.Kind.START), G2GUnits.format_speed(server.speed())])
	_check(client.timer.run.is_running(), "and the client's mirror is running too")
	_check(client.timer.run.style_id == server.timer.run.style_id, "in the same style")
	var drift := absf(client.timer.run.time() - server.timer.run.time())
	_check(drift < 0.05, "reading the same time", "%.3f s apart" % drift)
	await get_tree().process_frame
	_done()


func _test_finish() -> void:
	_section("a finish reaches the client")
	var server := _server_player()
	var finishes := []
	var notices := []
	_client_bridge.finish_received.connect(func(id: int, time: float, rank: int) -> void: finishes.append([id, time, rank]))
	_client_bridge.notice_received.connect(func(_id: int, text: String) -> void: notices.append(text))

	# A fresh run walked off the pad on the ground, so its length is known: the
	# hopping run above may have fallen at a gap and been respawned since.
	_server_game.spawn_player(server.player_id)
	_steps(2)
	_steps(260, _forward())
	_check(server.timer.run.is_running(), "a walked run is going", str(server.timer.describe()))
	var before := server.timer.run.time()

	var end := _server_game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0)
	server.controller.state.position = end.centre() + Vector3.UP * 0.3
	server.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
	_steps(6, _forward())
	for _i in range(4):
		await get_tree().process_frame
	_flush()

	var who := _server_game.timers.player(server.player_id)
	var filed := who.last_finished if who != null else null
	_check(finishes.size() == 1, "once", str(finishes))
	_check(finishes.size() == 1 and finishes[0][0] == SESSION and float(finishes[0][1]) >= before,
		"with a time", "%s before=%.3f notices=%s" % [finishes, before, notices])
	_check(finishes.size() == 1 and filed != null and absf(float(finishes[0][1]) - filed.time()) < 0.0001,
		"which is the server's own to the sub-tick fraction",
		"%s vs %s" % [finishes[0][1] if finishes.size() == 1 else "none", filed.time() if filed else "none"])
	_check(finishes.size() == 1 and (int(finishes[0][2]) >= 1 or not notices.is_empty()),
		"ranked, or told why not", str(notices))
	_check(not _client_player().timer.run.is_running(), "and the client's mirror stops")
	_done()


func _test_movement_change() -> void:
	_section("changing the movement under a live client")
	_server_game.config.air_accelerate = 150.0
	_server_game.apply_movement()
	_flush()
	_check(_client_game.config.air_accelerate == 150.0, "the cvar reaches the client")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "and both derive the same tunables")
	_steps(2)
	_done()


func _test_style_and_track() -> void:
	_section("asking for a style and a track")
	_client_bridge.ask_style(&"sideways")
	_exchange()
	_check(_server_player().timer_style != null and _server_player().timer_style.id == &"sideways", "the server switches",
		str(_server_player().timer_style.id) if _server_player().timer_style else "")
	_check(_client_player().timer_style != null and _client_player().timer_style.id == &"sideways", "and tells the client")

	_client_bridge.ask_track(DotTimerTrack.BONUS_FIRST)
	_exchange()
	_check(_server_player().timer.track == DotTimerTrack.BONUS_FIRST, "a bonus track, on the server")
	_check(_client_player().timer.track == DotTimerTrack.BONUS_FIRST, "and on the client")

	_client_bridge.ask_track(99)
	_exchange()
	_check(_server_player().timer.track == DotTimerTrack.BONUS_FIRST, "an invalid track is ignored")

	_client_bridge.ask_style(&"normal")
	_client_bridge.ask_track(DotTimerTrack.MAIN)
	_exchange()
	_done()


func _test_avatar() -> void:
	_section("an avatar published by the client")
	var avatar := G2GAvatars.stock_avatar(&"someone-else")
	var before := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_client_bridge.publish_avatar(avatar)
	_exchange()
	var after := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_check(after != before or avatar.to_dict() == before, "reaches the server's rig")
	_check(_client_player().rig.avatar != null and _client_player().rig.avatar.to_dict() == after, "and comes back to the client")
	_done()


func _test_lossy() -> void:
	_section("losing every third snapshot")
	_server_game.spawn_player(_server_player().player_id)
	_steps(4)
	_drop_every = 3
	_steps(128, _forward())
	_drop_every = 0
	var apart := _client_player().global_position.distance_to(_server_player().global_position)
	_check(apart < 0.5, "the client still shows the server's position", "%.3f m" % apart)
	_check(_client_net.predictor.correction_rate() < 0.15, "and prediction still converges", "%.3f" % _client_net.predictor.correction_rate())
	await get_tree().process_frame
	_done()


func _test_ghost() -> void:
	_section("the record's ghost")
	var map_id: StringName = _server_game.maps.current.id
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = _server_game.tick_rate
	replay.time = 2.0
	replay.player_name = "Ghost"
	for i in range(_server_game.tick_rate * 2):
		var t := float(i) / float(_server_game.tick_rate * 2 - 1)
		replay.append(Vector3(0.0, 1.0, 7.0 - 20.0 * t), 0.0, 0.0)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 2.0
	_server_game.replays.offer(replay, record)

	var ghost := _server_game.spawn_ghost()
	_check(ghost != null, "the server spawns it")
	_check(_server_bridge.behaviour_for(G2GGame.GHOST_SESSION) != null, "and the bridge adopts it as a bot")
	_exchange()
	_check(_client_game.players.has(G2GGame.GHOST_ID), "the client sees it")
	var mirrored: G2GPlayer = _client_game.players.get(G2GGame.GHOST_ID)
	var before := mirrored.global_position if mirrored else Vector3.ZERO
	_steps(64)
	for _i in range(3):
		_client_net.interpolate_frame()
	var after := mirrored.global_position if mirrored else Vector3.ZERO
	_check(before.distance_to(after) > 0.5, "running", "%.2f m" % before.distance_to(after))
	_check(mirrored != null and mirrored.replay == null and mirrored.timer == null,
		"as a remote player with no timer to mislead a HUD")

	_server_game.remove_player(G2GGame.GHOST_ID)
	_exchange()
	_check(_server_bridge.behaviour_for(G2GGame.GHOST_SESSION) == null, "removing it releases the entity")
	_check(not _client_game.players.has(G2GGame.GHOST_ID), "and the client drops it")
	_done()


## Players solid to each other behind the block rules: a runner walks through a stationary one while the
## pair passes (the genre's default) and stops at it once the pair blocks, and the client, which predicts
## against the same hull, ends where the server has it.
func _test_solid_players() -> void:
	_section("players are solid when the block rules say so")
	var rules := _server_game.body_rules
	var server := _server_player()
	var client := _client_player()
	var other := _server_game.add_player(&"u9000", "Other")
	_check(other != null and rules.solid, "a second player joins, and mp_solidplayers is on")
	_check(other.get_node_or_null(NodePath("SolidHullBody/SolidHull")) != null, "every player carries a hull")
	_check(not _server_game.hulls_live, "and nothing is live while no pair blocks")
	var pair_before := rules.pair_fn
	var forward := _forward()
	var travelled: Array[float] = []
	for blocked in [false, true]:
		rules.pair_fn = func(_a: Variant, _b: Variant) -> bool: return blocked
		rules.refresh()
		_check(_server_game.hulls_live == blocked, "hulls are live exactly when a pair blocks", str(blocked))
		_server_game.spawn_player(server.player_id)
		_steps(4)
		_flush()
		var start := server.global_position
		var ahead := Vector3(-sin(server.controller.state.yaw), 0.0, -cos(server.controller.state.yaw))
		other.teleport(start + ahead * 1.5, INF)
		# The physics server takes a moved or new hull into its broadphase on its next step.
		await get_tree().physics_frame
		await get_tree().physics_frame
		_steps(4)
		_steps(200, forward)
		var along := (server.global_position - start).dot(ahead)
		travelled.append(along)
		if blocked:
			_check(along < 1.5, "a blocking pair stops the runner at the other's hull", "%.2f m along" % along)
			_flush()
			_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client, predicting against the same hull, ends where the server has it",
				"%.3f m apart" % client.global_position.distance_to(server.global_position))
		else:
			_check(along > 2.5, "a passing pair is walked through", "%.2f m along" % along)
	_check(travelled.size() == 2 and travelled[0] > travelled[1] + 1.0, "so the same walk goes further when nobody blocks")
	rules.pair_fn = pair_before
	rules.solid = false
	_check(not _server_game.hulls_live and (other.get_node("SolidHullBody/SolidHull") as CollisionShape3D).disabled, "mp_solidplayers 0 disables every hull")
	rules.solid = true
	_server_game.remove_player(&"u9000")
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()
	await get_tree().process_frame
	_done()


## An administrator's blind and beacon, through the real handlers, over the lossy link.
##
## [b]The audience is the whole point of both.[/b] This client owns Ada (session 7); Bea
## (session 8) is another client's, on peer 3, whose traffic this loopback drops. A blind
## is its owner's screen and nobody else's, so this client must be told Ada's and must NOT
## be told Bea's — a player who could read it would know the moment somebody could not see.
## A beacon is for everybody, so this client must be told both. Asserted on the client's
## own copy of each player, which is what its HUD and its renderer read.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	var handlers := G2GModTools.handlers(_server_game)
	var blind: Callable = handlers[DotModTools.ACTION_BLIND]
	var beacon: Callable = handlers[DotModTools.ACTION_BEACON]

	var bea := _server_bridge.add_player(3, 8, "Bea")
	_check(bea.ok, "a second player joins, owned by another client", str(bea.error) if not bea.ok else "")
	_exchange()
	_steps(4)

	var ada_here: G2GPlayerNet = _client_bridge.behaviour_for(SESSION)
	var bea_here: G2GPlayerNet = _client_bridge.behaviour_for(8)
	_check(ada_here != null and bea_here != null, "and this client mirrors both")
	if ada_here == null or bea_here == null:
		return

	_check(
		ada_here.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and ada_here.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var results: Array[DotResult] = [
		blind.call(&"7", {"on": true, "actor": "1"}),
		blind.call(&"8", {"on": true, "actor": "1"}),
		beacon.call(&"7", {"on": true, "actor": "1"}),
		beacon.call(&"8", {"on": true, "actor": "1"}),
	]
	_check(results.all(func(r: DotResult) -> bool: return r.ok), "the server blinds and beacons both")

	# Long enough for several snapshots through one-in-five loss.
	_drop_every = 5
	_steps(48)
	_drop_every = 0

	_check(_client_player().blinded, "this client blacks its own screen out")
	_check(
		not bea_here.player.blinded and not bea_here.net_blind,
		"and is never told the other client's player is blind",
		"received net_blind = %s" % str(bea_here.net_blind)
	)
	_check(
		_client_player().beacon and bea_here.player.beacon,
		"while it draws the beacon on both"
	)
	_check(
		_server_bridge.behaviour_for(8).identity.always_relevant,
		"a beaconed player is relevant to every peer, however far away"
	)

	# The weapon in hand: owner only, like the blind, and named on this client's HUD.
	_server_player().held_weapon = &"deagle"
	_server_bridge.behaviour_for(8).player.held_weapon = &"knife"
	_steps(24)
	_check(_client_player().held_weapon == &"deagle",
		"the weapon in hand reaches its owner", str(_client_player().held_weapon))
	_check(bea_here.player.held_weapon == &"" and bea_here.net_weapon == 0,
		"and nobody else's weapon reaches this client", "received net_weapon = %d" % bea_here.net_weapon)
	var hud := G2GHud.new()
	add_child(hud)
	hud.bind(_client_game, _client_player().player_id)
	hud.show_weapon(_client_player())
	_check(hud.ammo.weapon_name == "Deagle", "and the client's counter names it", str(hud.ammo.describe()))
	hud.queue_free()
	_server_player().held_weapon = &""
	_steps(24)
	_check(_client_player().held_weapon == &"", "and empty hands reach it too")

	var _off: Array[DotResult] = [
		blind.call(&"7", {"on": false, "actor": "1"}),
		blind.call(&"8", {"on": false, "actor": "1"}),
		beacon.call(&"7", {"on": false, "actor": "1"}),
		beacon.call(&"8", {"on": false, "actor": "1"}),
	]
	_steps(24)

	_check(
		not _client_player().blinded and not _client_player().beacon and not bea_here.player.beacon,
		"and turning both off reaches this client"
	)
	# Every player here is always-relevant, so the arena's "relevant while beaconed" would
	# cut Bea from everybody the moment her beacon went off.
	_check(
		_server_bridge.behaviour_for(8).identity.always_relevant,
		"and leaves the player relevant, as every player here always is"
	)

	_server_bridge.remove_player(8)
	_exchange()
	_done()


## `!spec`, a click, and who is watching — over the link.
##
## [b]Spectating changed the server and nothing else.[/b] The server's manager decided,
## the server replied "Watching Bea." in chat, and the client's camera stayed on the
## client's own player, because the client's manager is a mirror and no message told it
## anything. So this asserts on the CLIENT: its mirror is watching, its camera has a pose
## to follow, and the list of who is watching arrives — and stops arriving the moment the
## operator says spectating is anonymous.
func _test_spectating_reaches_the_client() -> void:
	_section("spectating reaches the client, and who is watching")

	var bea := _server_bridge.add_player(3, 8, "Bea")
	_check(bea.ok, "a second player to watch joins", str(bea.error) if not bea.ok else "")
	_exchange()
	_steps(4)

	var told: Array = [null]
	var lists := {}
	var on_spec := func(target: StringName, target_name: String) -> void: told[0] = [target, target_name]
	var on_list := func(target: StringName, names: PackedStringArray) -> void: lists[target] = names
	_client_bridge.spectate_received.connect(on_spec)
	_client_bridge.spectators_received.connect(on_list)

	_client_bridge.ask_spectate(G2GEvents.SPECTATE_NEXT)
	_exchange()
	_steps(2)

	var ada := &"u%d" % SESSION
	var target := _server_game.spectate.target_of(ada)
	_check(target == &"u8", "a click asks the server, and the server picks the next player (%s)" % target)
	_check(told[0] != null and told[0][0] == &"u8" and told[0][1] == "Bea",
		"the client is told whom, by name", str(told[0]))
	var mirror := _client_game.spectate
	_check(mirror != null and mirror.is_spectating(ada) and mirror.target_of(ada) == &"u8",
		"and its own mirror is watching the same player")
	_check(mirror != null and mirror.camera_for(ada) != Transform3D.IDENTITY,
		"so its camera has a pose to follow, from the players it already draws")
	_check(lists.has(&"u8") and Array(lists[&"u8"]).has("Ada"),
		"the watcher is told who is watching the player they watch", str(lists))

	_server_game.config.spectator_list = false
	_server_bridge.broadcast_spectators()
	_exchange()
	_check(lists.has(&"u8") and (lists[&"u8"] as PackedStringArray).is_empty(),
		"sv_spec_list 0 clears the list on every screen, rather than leaving the last one")
	_client_bridge.ask_spectate(G2GEvents.SPECTATE_PREVIOUS)
	_exchange()
	_check((lists[&"u8"] as PackedStringArray).is_empty(),
		"and nothing is sent while it is off, whoever changes whom they watch")
	_server_game.config.spectator_list = true
	_server_bridge.broadcast_spectators()
	_exchange()
	_check(Array(lists.get(&"u8", PackedStringArray())).has("Ada"), "and turning it back on sends it again")

	# The free-roam key: the mode crosses the wire with no target, and the same key returns.
	_client_bridge.ask_spectate(G2GEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(_server_game.spectate.is_roaming(ada), "the free-roam request puts the server's viewer in ROAMING")
	_check(mirror != null and mirror.is_roaming(ada) and mirror.target_of(ada) == &"",
		"and the client's mirror is told, with no target")
	_client_bridge.ask_spectate(G2GEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_roaming(ada) and _server_game.spectate.is_spectating(ada),
		"the same request goes back onto a player")
	var _off := _server_game.spectate.manager.rules.set_cvar("mp_freeroam", "0")
	_client_bridge.ask_spectate(G2GEvents.SPECTATE_ROAM)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_roaming(ada), "and with mp_freeroam 0 the request is refused")
	var _on := _server_game.spectate.manager.rules.set_cvar("mp_freeroam", "1")

	# R: one press stops watching and restarts. A runner who pressed R wants to run.
	_client_bridge.ask_restart(G2GEvents.RESTART_STAGE)
	_exchange()
	_steps(2)
	_check(not _server_game.spectate.is_spectating(ada), "R stops spectating on the server")
	_check(told[0] != null and told[0][0] == &"" and mirror != null and not mirror.is_spectating(ada),
		"and the client is told it is back in its own view")

	# Two Rs from a bonus: back to the MAIN track's start, and everybody is told the track.
	_client_bridge.ask_track(1)
	_exchange()
	_steps(2)
	var on_bonus := _server_game.timers.timer_for(ada).track == 1
	_client_bridge.ask_restart(G2GEvents.RESTART_STAGE)
	_exchange()
	_check(on_bonus and _server_game.timers.timer_for(ada).track == 1,
		"one R on a bonus restarts the bonus")
	_client_bridge.ask_restart(G2GEvents.RESTART_MAIN)
	_exchange()
	_steps(2)
	_check(_server_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"a double tap from a bonus goes back to the main track")
	_check(_client_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"and the client is told, as a track change from the menu is")

	# A client from before the body existed sends RESTART with nothing in it, which must
	# still mean what its R meant: the start of the track it is on.
	var request := G2GRequest.new(G2GEvents.Ask.RESTART, PackedByteArray())
	request.sender_peer_id = CLIENT_PEER
	_server_bridge._on_request(request)
	_check(_server_game.timers.timer_for(ada).track == DotTimerTrack.MAIN,
		"an empty RESTART body still restarts, on the track the player is on")

	_client_bridge.spectate_received.disconnect(on_spec)
	_client_bridge.spectators_received.disconnect(on_list)
	_server_bridge.remove_player(8)
	_exchange()
	_done()


## The hunters reach a connected runner: a hunter the server spawns is drawn, moves with the
## server's, and goes when the server's does.
##
## [b]Hunters were never replicated.[/b] They ran on the server only, and every check about
## them ran on an authoritative game where they are real bodies in the same tree — so a
## runner on a dedicated server was hit by hunters nobody could see.
func _test_hunters_reach_the_client() -> void:
	_section("hunters reach the client")

	var hunters := G2GHunters.new()
	hunters.name = "Hunters"
	hunters.game = _server_game
	_server_game.add_child(hunters)
	var built := hunters.setup()
	_check(built.ok, "the server's hunters set up", str(built.error) if not built.ok else "")
	_server_game.hunters = hunters
	_steps(1)

	var at := _server_player().global_position + Vector3(4.0, 0.5, 0.0)
	var hunter := hunters.spawn_one(&"g2g_stalker", at)
	_check(hunter != null, "a hunter spawns")

	if hunter == null:
		_done()
		return

	_exchange()
	_steps(2)
	_check(_client_bridge.hunter_count() == 1, "the client builds it", "%d" % _client_bridge.hunter_count())

	# Moved by hand, not by its brain: the point is that the client follows the server, and
	# a hunter left to think may stand still or chase the runner out of the test's frame.
	(hunter.node as Node3D).global_position = at + Vector3(0.0, 0.0, 6.0)
	_steps(30)
	var mirror: Node3D = null
	for entry in _client_bridge.get("_hunter_mirrors").values():
		mirror = entry.body
	_check(mirror != null and mirror.global_position.distance_to(hunter.position()) < 1.0,
		"and draws it where the server has it",
		"%.2f apart" % mirror.global_position.distance_to(hunter.position()) if mirror != null else "no mirror")
	_check(mirror != null and absf(angle_difference(mirror.rotation.y, DotNpcNetSync.yaw_of(hunter))) < 0.3,
		"facing the way the server's faces")

	hunters.spawner.remove(hunter.instance_id, DotNpcSpawner.REASON_ADMIN)
	_exchange()
	_steps(2)
	_check(_client_bridge.hunter_count() == 0, "and lets it go when the server does")

	_server_game.hunters = null
	_server_game.remove_child(hunters)
	hunters.queue_free()
	_steps(1)
	_done()


func _test_leave() -> void:
	_section("a bot, and leaving")
	var roster := []
	_client_bridge.roster_changed.connect(func(id: int) -> void: roster.append(id))

	var bot := _server_bridge.add_player(0, 9, "Bot")
	_check(bot.ok, "a bot joins on the server with no peer behind it", str(bot.error) if not bot.ok else "")
	_check(not _server_net.peers().has(0), "and is not a peer, because 0 is the broadcast address")
	_exchange()
	_check(_client_game.players.has(&"u9"), "the client mirrors it", str(roster))
	_steps(4)

	_server_bridge.remove_player(9)
	_exchange()
	_check(not _client_game.players.has(&"u9") and roster.has(9), "and drops it when it leaves", str(roster))

	_server_bridge.remove_peer(CLIENT_PEER)
	_flush()
	_check(_server_player() == null, "the server drops a leaving peer's player")
	_check(not _server_net.peers().has(CLIENT_PEER), "and the peer")
	_done()


## A voice frame, client to server to another client, over this game's own link.
##
## [b]Deliberately not through [DotNetManager].[/b] dot-net decodes a bit-packed
## message against a sealed schema; a voice frame is an opaque blob from a codec, and
## putting it through would mean a message type per codec — or a schema that changes
## when the codec does, and the schema hash is what both ends check to agree they are
## speaking the same game. So it rides its own channel and its own two calls.
## The map vote's cue and countdown, server to client, and a client's RTV request back.
##
## Before this there was no message for either direction's vote traffic worth the name:
## the ballot went out as chat, a cue went nowhere, and an RTV request off the wire went
## to the map session's tally rather than to the ballot.
func _test_vote_wire() -> void:
	_section("the map vote over the link")

	var round_trip := G2GEvents.read_vote(DotNetReader.new(G2GEvents.write_vote("vote_count", 7, true)))
	_check(
		bool(round_trip["ok"]) and String(round_trip["cue"]) == "vote_count"
			and int(round_trip["seconds_left"]) == 7 and bool(round_trip["runoff"]),
		"a VOTE round-trips, with the cue, the second and the runoff flag"
	)

	var arrived: Array[Dictionary] = []
	var on_vote := func(info: Dictionary) -> void: arrived.append(info)
	_client_bridge.vote_received.connect(on_vote)
	_server_bridge.broadcast_vote(&"vote_start", 0, false)
	_server_bridge.broadcast_vote(&"", 3, false)
	_flush()
	_client_bridge.vote_received.disconnect(on_vote)

	_check(
		arrived.size() == 2
			and String(arrived[0]["cue"]) == "vote_start"
			and int(arrived[1]["seconds_left"]) == 3,
		"a cue and a countdown second reach a ready client, in order (%s)" % str(arrived)
	)

	var rocked: Array[StringName] = []
	_server_bridge.rtv_fn = func(id: StringName) -> void: rocked.append(id)
	_client_bridge.ask_rtv()
	_flush()
	_server_bridge.rtv_fn = Callable()

	_check(
		rocked.size() == 1 and String(rocked[0]).begins_with("u"),
		"and a client's RTV request reaches the server's rtv_fn, as a player id (%s)" % str(rocked)
	)
	_done()


## The map's time left, from the server's vote to what the client's HUD draws.
##
## The HUD drew the client's own map session, which starts when the client loads the map
## and hears nothing the server decides — so an extend changed the server's clock and
## not one pixel on a client. This is the check that an extend reaches the screen.
func _test_clock_wire() -> void:
	_section("the vote's clock over the link")

	var round_trip := G2GEvents.read_clock(DotNetReader.new(
		G2GEvents.write_clock({"has_clock": true, "seconds_left": 1234, "running": true})
	))
	_check(
		bool(round_trip["ok"]) and bool(round_trip["has_clock"])
			and int(round_trip["seconds_left"]) == 1234 and bool(round_trip["running"]),
		"a CLOCK round-trips, with the flag, the seconds and whether it counts"
	)

	# A real vote on the server's game. Not authoritative, so it applies nothing and
	# registers no service; its clock is the thing under test.
	var vote := G2GVote.new()
	vote.name = "ClockVote"
	vote.game = _server_game
	vote.authoritative = false
	vote.config_path = ""
	add_child(vote)
	var built := vote.setup()
	_check(built.ok, "a vote is built on the server's game", str(built.error) if not built.ok else "")
	if not built.ok:
		vote.queue_free()
		return

	var arrived: Array[Dictionary] = []
	var on_clock := func(state: Dictionary) -> void: arrived.append(state)
	_client_bridge.clock_received.connect(on_clock)
	vote.clock_due.connect(_server_bridge.broadcast_clock)
	var dt := 1.0 / float(_server_game.tick_rate)

	vote.advance(dt)
	_flush()
	var now := Time.get_ticks_msec() / 1000.0
	var before := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 1 and _client_bridge.clock_view.has_clock
			and absf(before - vote.director.clock.remaining) <= 1.0,
		"the client is told the vote's time left (%.0f s, the server's is %.0f s)" % [
			before, vote.director.clock.remaining
		]
	)
	_check(
		G2GHud.time_left_text(_client_bridge.clock_view, "9:59", now)
			== _client_bridge.clock_view.formatted_at(now),
		"and the HUD draws that rather than the client's own map clock (%s)" % (
			G2GHud.time_left_text(_client_bridge.clock_view, "9:59", now)
		)
	)

	for i in range(_server_game.tick_rate * 3):
		vote.advance(dt)
	_flush()
	_check(
		arrived.size() == 1,
		"three quiet seconds send nothing: the client counts them itself (%d sent)" % (
			arrived.size() - 1
		)
	)

	var extend_by := vote.director.rules.extend_seconds
	_check(vote.director.clock.extend(), "the server extends the map")
	vote.advance(dt)
	_flush()
	now = Time.get_ticks_msec() / 1000.0
	var after := _client_bridge.clock_view.remaining_at(now)
	_check(
		arrived.size() == 2 and absf((after - before) - (extend_by - 3.0)) <= 2.0,
		"and what the client sees moves by the extension (%.0f s -> %.0f s, extended by %.0f)" % [
			before, after, extend_by
		],
		"the HUD would go on counting down the old limit"
	)

	# `trigger: rtv_only` with no limit: the server has no clock, and neither does the HUD
	# — not even the client's local map session's, which is the number that was wrong.
	vote.director.rules.duration_sec = 0.0
	vote.director.rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	vote.director.begin(_server_game.maps.current.id)
	vote.advance(dt)
	_flush()
	now = Time.get_ticks_msec() / 1000.0
	_check(
		arrived.size() == 3 and not _client_bridge.clock_view.has_clock,
		"a vote with no clock tells the client so"
	)
	_check(
		G2GHud.time_left_text(_client_bridge.clock_view, "9:59", now) == "",
		"and the HUD shows no clock at all, rather than its own"
	)
	_check(
		G2GHud.time_left_text(null, "9:59", now) == "9:59",
		"while a HUD nothing has told (offline) keeps the local session's, which is the real one there"
	)

	_client_bridge.clock_received.disconnect(on_clock)
	_client_bridge.clock_view = DotVoteClockView.new()
	remove_child(vote)
	vote.free()
	_done()

