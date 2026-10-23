extends Node

const G2GAvatars := preload("../game/g2g_avatars.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GEvents := preload("../game/net/g2g_events.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GHunters := preload("../game/g2g_hunters.gd")
const G2GNetBridge := preload("../game/net/g2g_net_bridge.gd")
const G2GNetCommand := preload("../game/net/g2g_net_command.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GVote := preload("../game/g2g_vote.gd")
const G2GHud := preload("../game/g2g_hud.gd")
const G2GModTools := preload("../game/g2g_mod_tools.gd")
const G2GPlayerNet := preload("../game/net/g2g_player_net.gd")
const G2GRequest := preload("../game/net/g2g_request.gd")
const G2GEvent := preload("../game/net/g2g_event.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
## game-g2gfast's netcode, end to end, in one process.
##
## A server game and a client game, each with its own [DotNetManager] and
## [G2GNetBridge], with a lossy loopback where the socket would be. Exits non-zero on
## any failure. Everything here that could run over a real socket already has, in
## dot-2d-hungry; this proves the bridge, not dot-net.
##
## [b]The client's tick lead is hand-stamped[/b] (INPUT_LEAD): a command for tick N
## has to be in the server's hands before it simulates N, and with no clock to
## synchronise against the harness does the arithmetic itself.

const CLIENT_PEER := 2
const SESSION := 7
const INPUT_LEAD := 2
const SNAPSHOT_RATE := 32

## What the client's engine is pretending to run at, and deliberately not the
## server's. See the note in [method _build].
const CLIENT_ENGINE_TICK_RATE := 60

const CHECKS := 231

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 31

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server_game: G2GGame = null
var _client_game: G2GGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: G2GNetBridge = null
var _client_bridge: G2GNetBridge = null

var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []
var _drop_every: int = 0
var _snapshot_count: int = 0
var _tick: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: netcode")
	print("")
	_test_command_wire()
	_test_movement_wire()
	_test_hello_wire()
	if await _build():
		await _test_handshake()
		await _test_prediction()
		await _test_timer()
		await _test_finish()
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
	_report()


func _report() -> void:
	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for f in _failures:
		print("  FAIL " + f)
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok   " + what)
	else:
		_failed += 1
		_failures.append(what + (": " + detail if detail != "" else ""))
		print("  FAIL " + what + (": " + detail if detail != "" else ""))


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


# --- Wire ------------------------------------------------------------------

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

func _make_game(server: bool, scope: StringName, parent: Node) -> G2GGame:
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.authoritative = server

	var game := G2GGame.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


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


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return
	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()
	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])
	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## A request and its answer: the answer is queued during the first flush and
## delivered by the second.
func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	_client_net.clock.advance(1.0 / float(_client_game.tick_rate))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		_step(command)


func _forward() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	return c


func _server_player() -> G2GPlayer:
	return _server_game.players.get(&"u%d" % SESSION)


func _client_player() -> G2GPlayer:
	return _client_game.players.get(&"u%d" % SESSION)


# --- Tests -----------------------------------------------------------------

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

	# The splits panel's comparison: a client has no store, so the server says. The message
	# is sent to the owner on the game's `stage_reference_changed`, and arrives intact.
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

	# HELLO has carried the server's tick rate since it was written and `read_hello`
	# has always decoded it; until this was fixed, nothing read it back out. All three
	# have to move: the game's rate is the step prediction replays with and the
	# divisor every replicated run time is reconstituted through, the net config's is
	# what input sanitising and the extrapolation budget read, and the CLOCK's is a
	# copy taken at setup() that writing the config does not touch.
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

	# The map a joiner lands on, through the protocol rather than an id in HELLO. dot-map's
	# host sent `load` only at the end of a change, so a joiner said ready and was never
	# told to show anything; this check found it, the bridge answered the ready itself for
	# a day, and dot-map's host answers it now (`admit_peer`). Armed against the bridge's
	# answer and again against dot-map's: this check fired both times.
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


# --- Map changes, through dot-map's protocol --------------------------------

## A content client that takes its time over the first fetch, in front of a real one.
##
## [b]What is mounted is a real signed pack[/b], published by this suite into `user://` and
## mounted by a real [DotCloudClient] at `res://dot_cloud/<id>/<version>/` — so what the
## client loads when its download lands is a world built from a manifest out of a pack, as
## a delivered map is. The delay is the suite's, so the server's timeout can pass while the
## client is still downloading: a straggler, on demand. Registered as `dot_cloud_client`,
## which is where dot-map's loader looks on both ends — one process has one registry and
## one set of mounts, which is also why the server's own map definition below is built by
## hand rather than fetched: a server that had mounted the pack would have mounted it for
## the client too, and there would be nothing left to download.
class SlowCloud:
	extends Node

	signal progress_changed(progress: Dictionary)

	var real: DotCloudClient = null
	var delay_first: float = 0.0
	## "id@version" of every fetch asked for, in order.
	var asked: Array[String] = []
	var _delayed := false

	func ensure(
		content_id: StringName, version: String = "",
		groups: PackedStringArray = PackedStringArray(), manifest_url: String = ""
	) -> DotResult:
		asked.append("%s@%s" % [content_id, version])
		if delay_first > 0.0 and not _delayed:
			_delayed = true
			await get_tree().create_timer(delay_first).timeout
		return await real.ensure(content_id, version, groups, manifest_url)

	func is_mounted(content_id: StringName, version: String = "") -> bool:
		return real.is_mounted(content_id, version)


const SYNC_FIXTURE := &"g2g_sync_fixture"
const DELIVERED_FIXTURE := &"g2g_delivered_fixture"
const OWNED_FIXTURE := &"g2g_owned_fixture"
const REPUB_FIXTURE := &"g2g_repub_fixture"

## The signing key the delivered-map section made, which the content client trusts.
var _fixture_keys: Dictionary = {}
const SYNC_FIXTURE_ROOT := "user://g2g_headless_net_sync"
const SYNC_TIMEOUT := 1.0
const SLOW_FETCH := 2.0

var _cloud: SlowCloud = null
var _real_cloud: DotCloudClient = null


## Runs a change on the server while pumping the link, and says how it ended.
##
## [b]A bare statement, and not an await[/b] — the fan-out trap in the form dot-map's
## own suite records: the change waits on a client that only answers when this pump
## runs, so awaiting it here deadlocks. The outcome comes back through the host's signals.
## [param during] runs right after the change starts, while the host is waiting on peers.
func _change_and_pump(id: StringName, seconds: float, during: Callable = Callable()) -> Dictionary:
	var host := _server_bridge.map_host
	var outcome := {"done": false, "ok": false, "reason": "", "ms": 0, "client_then": ""}
	var started := Time.get_ticks_msec()

	var on_finished := func(_map: DotMapDef) -> void:
		outcome["done"] = true
		outcome["ok"] = true
		outcome["ms"] = Time.get_ticks_msec() - started
		# Where the client is at the moment the server swaps: the straggler's proof.
		outcome["client_then"] = String(_client_game.maps.current.id) if _client_game.maps.current != null else ""
	var on_failed := func(_map: DotMapDef, reason: String) -> void:
		outcome["done"] = true
		outcome["reason"] = reason
		outcome["ms"] = Time.get_ticks_msec() - started

	host.change_finished.connect(on_finished)
	host.change_failed.connect(on_failed)

	_server_game.change_map(id)
	if during.is_valid():
		during.call()

	var deadline := started + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline and not bool(outcome["done"]):
		_flush()
		await get_tree().process_frame

	# The `load` the host sent on its way out, and the client's own load after it.
	for _i in range(4):
		_flush()
		await get_tree().process_frame

	host.change_finished.disconnect(on_finished)
	host.change_failed.disconnect(on_failed)
	return outcome


## Pumps until the client is on [param id], or [param seconds] pass.
func _until_client_on(id: StringName, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _client_game.maps.current != null and _client_game.maps.current.id == id:
			return true
		_flush()
		await get_tree().process_frame
	return _client_game.maps.current != null and _client_game.maps.current.id == id


## A map as a signed pack: a manifest and a mesh, published into `user://`. Empty of
## geometry on purpose — this suite is about who has it, not what is in it.
##
## [param version] empty publishes as [method G2GMapCatalogue.pack_version] does, from the
## files; [param extra] is merged into the manifest, so a republish can change them.
func _publish_map_fixture(
	id: StringName, version: String, keys: Dictionary, owner := "", extra := {}
) -> DotResult:
	var source := SYNC_FIXTURE_ROOT.path_join("src").path_join(String(id))
	DirAccess.make_dir_recursive_absolute(source)
	var manifest := {
		"id": String(id), "tier": 1, "display_name": String(id).replace("_", " "),
		"spawn": {"origin": [0, 64, 0]}, "surfaces": [], "zones": [],
	}
	manifest.merge(extra, true)
	var json := FileAccess.open(source.path_join("%s.json" % id), FileAccess.WRITE)
	json.store_string(JSON.stringify(manifest))
	json.close()
	var bin := FileAccess.open(source.path_join("%s.bin" % id), FileAccess.WRITE)
	bin.store_8(0)
	bin.close()

	var content := String(id) if owner.is_empty() else "%s/%s" % [owner, id]
	var publisher := DotCloudPublisher.new()
	publisher.content_id = content
	publisher.version = version if not version.is_empty() else G2GMapCatalogue.pack_version(source)
	publisher.signing_key_pem = str(keys["private"])
	publisher.signing_key_id = "headless_net"
	# Published at `<base>/<id>/`, the layout a server's version-less `ensure(id)` finds —
	# `G2GGame.ensure_map_content` asks for whatever version the origin has, and a client
	# asks for the version its announce named; both reach the same manifest.
	return publisher.publish(source, "%s/dist/%s" % [SYNC_FIXTURE_ROOT, content])


## One content client for both ends, behind [SlowCloud], trusting only this suite's key.
func _start_content(keys: Dictionary) -> void:
	var config := DotCloudConfig.new()
	config.side = "both"
	config.cache_dir = SYNC_FIXTURE_ROOT.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"headless_net": str(keys["public"])}

	_real_cloud = DotCloudClient.new()
	_real_cloud.name = "RealCloud"
	_real_cloud.config = config
	_real_cloud.config_file = ""
	_real_cloud.local_search_dirs = PackedStringArray([SYNC_FIXTURE_ROOT.path_join("dist")])
	_real_cloud.manifest_url_template = "{base}/{id}/manifest.json"
	_real_cloud.register_service = false
	add_child(_real_cloud)

	_cloud = SlowCloud.new()
	_cloud.name = "SlowCloud"
	_cloud.real = _real_cloud
	add_child(_cloud)
	DotRegistry.register(&"dot_cloud_client", _cloud)


func _test_map_change() -> void:
	_section("changing the map: a client that has it")

	var host := _server_bridge.map_host
	host.poll_interval_sec = 0.05
	host.sync_timeout_sec = 5.0

	var order: Array[String] = []
	var fetched: Array[String] = []
	var on_ready := func(m: DotMapDef) -> void: order.append("client ready:" + String(m.id))
	var on_swap := func(m: DotMapDef, _w: Node) -> void: order.append("server swap:" + String(m.id))
	var on_fetch := func(m: DotMapDef) -> void: fetched.append(String(m.id))
	_client_bridge.map_client.content_ready.connect(on_ready)
	_server_game.maps.changed.connect(on_swap)
	_client_bridge.map_client.fetching.connect(on_fetch)

	# A second client admitted WHILE the change is in flight. dot-map's `add_peer` said
	# such a peer "is not waited for" and its wait loop counted it anyway, so it held the
	# change to the timeout for a map it was never announced; dot-map snapshots the peers
	# a change was announced to now. Its traffic goes nowhere in this loopback, which is
	# exactly a peer that would never answer. Armed by admitting it straight into the
	# host before the fix: the change took the full five seconds.
	var late_peer := 4
	var late_session := 9
	var mid_change := func() -> void:
		_server_bridge.add_player(late_peer, late_session, "Late")
		var writer := DotNetWriter.new()
		_server_net.messages.encode(G2GRequest.new(G2GEvents.Ask.READY, PackedByteArray()), writer)
		_server_bridge.receive_request(late_peer, writer.to_bytes())

	var outcome := await _change_and_pump(&"surf_g2g_intro", 8.0, mid_change)

	_client_bridge.map_client.content_ready.disconnect(on_ready)
	_server_game.maps.changed.disconnect(on_swap)
	_client_bridge.map_client.fetching.disconnect(on_fetch)

	_check(bool(outcome["ok"]), "the server changes", str(outcome["reason"]))
	_check(_server_game.maps.current.id == &"surf_g2g_intro", "and is on it")
	_check(_client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro", "and the client follows")
	_check(order == ["client ready:surf_g2g_intro", "server swap:surf_g2g_intro"],
		"having said it had the map BEFORE the server swapped, which the old broadcast never asked",
		str(order))
	_check(int(outcome["ms"]) < int(host.sync_timeout_sec * 1000.0),
		"as soon as it was ready, not at the timeout — the joiner mid-change was not waited on",
		"%d ms" % int(outcome["ms"]))
	_check(host.peers.has(late_peer),
		"and that joiner follows the next change, having been announced the map this one settled on")

	# A built-in map is not a pack and the protocol says so: the announce names no content,
	# and the client reports ready without starting a fetch. Nothing was faked into a
	# download to make the protocol happy.
	var announced := _client_bridge.map_client.announced
	_check(announced != null and announced.is_local() and announced.content_id == &"",
		"a built-in map is announced as one — no content id, nothing to fetch")
	_check(fetched.is_empty(), "and the client fetched nothing", str(fetched))

	_server_bridge.remove_player(late_session)
	_check(not host.peers.has(late_peer), "a peer that leaves stops being followed")

	_check(_client_player() != null, "keeping its players")
	_steps(4)
	_check(_client_player().global_position.distance_to(_server_player().global_position) < 1.0, "at the new spawn",
		"%.3f m" % _client_player().global_position.distance_to(_server_player().global_position))
	_done()


## [b]A map won by vote reaches the clients.[/b]
##
## The vote's map source was handed `game.maps`, and `DotMapSession.change_to` swaps the
## server's own world and tells nobody — so on a live server a vote moved it to bhop_fur
## while both players stayed on surf_mesa, and the respawn put them at bhop_fur's start
## in the sky over a map they were still drawing. `_test_map_change` could not see it: it
## calls `G2GGame.change_map`, which was always right. This goes in through the door the
## vote uses — `source.apply`, exactly what the director calls on a winner. Armed by
## giving the source `game.maps` back: the server changed and the client did not.
func _test_map_by_vote() -> void:
	_section("changing the map by vote: the clients are told")

	var host := _server_bridge.map_host
	host.poll_interval_sec = 0.05
	host.sync_timeout_sec = 5.0

	var vote := G2GVote.new()
	vote.name = "MapVote"
	vote.game = _server_game
	vote.authoritative = false
	vote.config_path = ""
	add_child(vote)
	var built := vote.setup()
	_check(built.ok, "a vote is built on the server's game", str(built.error) if not built.ok else "")

	var announced := [0]
	var on_announce := func(_m: Variant) -> void: announced[0] += 1
	host.change_finished.connect(on_announce)

	var target := &"bhop_g2g_intro"
	var applied := [null]
	var apply := func() -> void: applied[0] = await vote.source.apply(target)
	apply.call()

	var on_client := await _until_client_on(target, 8.0)
	host.change_finished.disconnect(on_announce)

	_check(_server_game.maps.current.id == target, "the server changes to the map that won")
	_check(announced[0] == 1, "through the map-sync host, which tells the clients",
		"the vote swapped the server's world on its own")
	_check(on_client, "and the client follows it",
		"client on %s" % (String(_client_game.maps.current.id) if _client_game.maps.current != null else "nothing"))

	_steps(4)
	_check(_client_player() != null and _client_player().global_position.distance_to(_server_player().global_position) < 1.0,
		"standing where the server put it, not at the new map's start inside the old one")

	vote.queue_free()
	_done()


## [b]An imported map, delivered, through the protocol.[/b]
##
## Every imported map is ONE scene in the build, `maps/imported_map.tscn`, pointed at a
## manifest — the mount constraint forbids putting a scene that extends a build class in
## the pack. dot-map's rule for a map a client does not have used to be that its scene is
## in the pack, so it refused every one; the bridge fetched by its own convention before
## dot-map saw the announce. Now the client lists that scene as a trusted template and
## dot-map requires the MANIFEST to be in the pack instead. Armed by removing the template
## from the bridge: the client refused the map and stayed where it was.
func _test_map_delivered() -> void:
	_section("changing the map: an imported map that is delivered")

	DotPaths.remove_tree(SYNC_FIXTURE_ROOT)
	var keys := DotCloudSignature.generate_keypair()
	_check(keys.ok, "a signing key is made for this suite's content")
	if not keys.ok:
		return
	_fixture_keys = keys.value
	var published := _publish_map_fixture(DELIVERED_FIXTURE, "1.2.0", keys.value)
	var slow_one := _publish_map_fixture(SYNC_FIXTURE, "1.0.0", keys.value)
	_check(published.ok and slow_one.ok, "two imported maps publish as signed packs",
		"%s %s" % [published.error, slow_one.error])
	if not (published.ok and slow_one.ok):
		return
	_start_content(keys.value)
	await get_tree().process_frame

	# The server fetches it the way it fetches `content_maps`, and says what it is.
	var fetched: DotResult = await _server_game.ensure_map_content(DELIVERED_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(DELIVERED_FIXTURE)
	var mount := "res://dot_cloud/%s/1.2.0/" % DELIVERED_FIXTURE
	_check(fetched.ok and on_server != null, "the server fetches the map into its catalogue",
		str(fetched.error) if not fetched.ok else "")
	_check(on_server != null and on_server.content_id == DELIVERED_FIXTURE
		and on_server.content_version == "1.2.0"
		and str(on_server.meta.get("manifest", "")).begins_with(mount),
		"and marks it as that content and version, its manifest in the mount",
		str(on_server.describe()) if on_server != null else "none")
	_check(not _client_game.maps.catalogue.has(DELIVERED_FIXTURE), "the client does not have it")

	var refused: Array[String] = []
	var on_refused := func(id: StringName, why: String) -> void: refused.append("%s: %s" % [id, why])
	_client_bridge.map_refused.connect(on_refused)

	var outcome := await _change_and_pump(DELIVERED_FIXTURE, 8.0)
	_client_bridge.map_refused.disconnect(on_refused)

	_check(bool(outcome["ok"]) and refused.is_empty(), "the server changes to it and the client does not refuse",
		"%s %s" % [outcome["reason"], refused])
	var followed := await _until_client_on(DELIVERED_FIXTURE, 3.0)
	_check(followed, "the client is on it",
		String(_client_game.maps.current.id) if _client_game.maps.current != null else "none")
	var world := _client_game.maps.world
	_check(world != null and world.scene_file_path == G2GMapCatalogue.IMPORTED_SCENE
		and str(world.get("manifest_path")).begins_with(mount),
		"as the imported-map scene out of its own build, built from the manifest in the pack",
		"%s %s" % [world.scene_file_path if world != null else "-", world.get("manifest_path") if world != null else "-"])
	var kept := _client_game.maps.catalogue.get_map(DELIVERED_FIXTURE)
	_check(kept != null and kept.content_id == DELIVERED_FIXTURE,
		"and keeps it, as delivered content, for next time")
	_done()


## A map republished with different files, in one process: the server's next fetch and a
## client that had mounted the OLD pack both end on the new one.
##
## [b]Every map pack was `@0.0.0` (`[g2g-maps-version-1]`).[/b] dot-cloud keys a mount on
## `id@version` and cannot undo one, so a client that had mounted the old pack was told
## "that map, 0.0.0" by a server that had the new one, found it mounted, and played the
## old geometry. `G2GMapCatalogue.pack_version` names a pack by its files; this is the
## check that a change of files reaches a client that already holds the map.
func _test_map_republished() -> void:
	_section("changing the map: a map republished with different files")
	if _fixture_keys.is_empty():
		_check(false, "the delivered section made a signing key")
		_done()
		return

	var first := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys)
	var again := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys)
	_check(first.ok and again.ok, "a map publishes under the version of its files",
		"%s %s" % [first.error, again.error])
	var source := SYNC_FIXTURE_ROOT.path_join("src").path_join(String(REPUB_FIXTURE))
	var v1 := G2GMapCatalogue.pack_version(source)

	var fetched: DotResult = await _server_game.ensure_map_content(REPUB_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(REPUB_FIXTURE)
	var outcome := await _change_and_pump(REPUB_FIXTURE, 8.0)
	var followed := await _until_client_on(REPUB_FIXTURE, 3.0)
	_check(fetched.ok and on_server != null and on_server.content_version == v1
		and bool(outcome["ok"]) and followed and _client_world_from(REPUB_FIXTURE, v1),
		"and the server and a client are on it at that version (%s)" % v1,
		"%s %s" % [fetched.error if not fetched.ok else "", outcome["reason"]])

	var changed := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys, "",
		{"display_name": "repub fixture, second cut"})
	var v2 := G2GMapCatalogue.pack_version(source)
	_check(changed.ok and v2 != v1 and v2.begins_with("0.0.0-"),
		"republished with different files, it is a different version (%s)" % v2)

	# What a restarted server knows: nothing about this map. Same process, same mounts,
	# and the client still holds the first pack and its catalogue entry.
	_server_game.maps.catalogue.remove(REPUB_FIXTURE)
	_server_game._map_content_seen.erase(REPUB_FIXTURE)
	var away := await _change_and_pump(DELIVERED_FIXTURE, 8.0)
	var refetched: DotResult = await _server_game.ensure_map_content(REPUB_FIXTURE)
	on_server = _server_game.maps.catalogue.get_map(REPUB_FIXTURE)
	_check(bool(away["ok"]) and refetched.ok and on_server != null
		and on_server.content_version == v2,
		"the server's next fetch mounts the new version beside the old",
		str(on_server.describe()) if on_server != null else str(refetched.error))

	outcome = await _change_and_pump(REPUB_FIXTURE, 8.0)
	followed = await _until_client_on(REPUB_FIXTURE, 3.0)
	_check(bool(outcome["ok"]) and followed and _client_world_from(REPUB_FIXTURE, v2),
		"and a client that had the old one plays the new one",
		"%s %s" % [outcome["reason"],
			_client_game.maps.world.get("manifest_path") if _client_game.maps.world != null else "-"])
	_done()


## Whether the client's world was built from [param id]'s pack at [param version].
func _client_world_from(id: StringName, version: String) -> bool:
	var world := _client_game.maps.world
	return world != null and str(world.get("manifest_path")).begins_with(
		"res://dot_cloud/%s/%s/" % [id, version])


## A map on an origin that keeps packs under an owner: the map id stays what a player
## types, the pack is `<owner>/<id>`. See [member G2GConfig.map_content_owner].
func _test_map_owned() -> void:
	_section("changing the map: a map published under an owner")

	# The key the delivered section made and the content client already trusts. A fresh
	# one here replaced it, and every fixture signed before it stopped verifying.
	var published := _publish_map_fixture(OWNED_FIXTURE, "1.0.0", _fixture_keys, "someone") \
		if not _fixture_keys.is_empty() else DotResult.fail(DotError.CODE_STATE, "no key")
	_check(published.ok, "a map publishes as someone/<id>", str(published.error))
	if not published.ok:
		_done()
		return

	_server_game.config.map_content_owner = "someone"
	var fetched: DotResult = await _server_game.ensure_map_content(OWNED_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(OWNED_FIXTURE)
	_check(fetched.ok and on_server != null,
		"the server fetches it by the map id alone, with the owner from its config",
		str(fetched.error) if not fetched.ok else "")
	_check(on_server != null and String(on_server.content_id) == "someone/%s" % OWNED_FIXTURE
		and str(on_server.meta.get("manifest", "")).begins_with(
			"res://dot_cloud/someone/%s/1.0.0/" % OWNED_FIXTURE),
		"and files it under the map id, marked as the owned content it came from",
		str(on_server.describe()) if on_server != null else "none")

	var outcome := await _change_and_pump(OWNED_FIXTURE, 8.0)
	var followed := await _until_client_on(OWNED_FIXTURE, 3.0)
	_check(bool(outcome["ok"]) and followed,
		"and a client follows it there, fetching the owned pack the announce names",
		"%s" % outcome["reason"])
	_server_game.config.map_content_owner = ""
	_done()


func _test_map_straggler() -> void:
	_section("changing the map: a client that is still downloading")

	var host := _server_bridge.map_host
	host.sync_timeout_sec = SYNC_TIMEOUT

	# What `G2GGame.ensure_map_content` makes of a pack it fetched — built by hand, because
	# a server in this process that mounted the pack would have mounted it for the client
	# too (see [SlowCloud]). The server's own load at the swap mounts it for real.
	var on_server := DotMapDef.new()
	on_server.id = SYNC_FIXTURE
	on_server.scene_path = G2GMapCatalogue.IMPORTED_SCENE
	on_server.content_id = SYNC_FIXTURE
	on_server.content_version = "1.0.0"
	on_server.meta["manifest"] = "res://dot_cloud/%s/1.0.0/%s.json" % [SYNC_FIXTURE, SYNC_FIXTURE]
	on_server.meta["imported"] = true
	_check(_server_game.maps.catalogue.add(on_server).ok,
		"the server has a map the client does not")
	_check(not _client_game.maps.catalogue.has(SYNC_FIXTURE), "and the client does not")

	_cloud.asked.clear()
	_cloud.delay_first = SLOW_FETCH

	var timed_out: Array[int] = []
	var on_timeout := func(peer: int) -> void: timed_out.append(peer)
	host.peer_timed_out.connect(on_timeout)
	var notices: Array[String] = []
	var on_notice := func(_pid: int, text: String) -> void: notices.append(text)
	_client_bridge.notice_received.connect(on_notice)
	var progress: Array[float] = []
	var on_progress := func(_peer: int, fraction: float) -> void: progress.append(fraction)
	host.peer_progress.connect(on_progress)

	var outcome := await _change_and_pump(SYNC_FIXTURE, SYNC_TIMEOUT + 3.0)

	_check(bool(outcome["ok"]), "the change goes ahead without the client", str(outcome["reason"]))
	_check(timed_out == [CLIENT_PEER], "and the server names the one it did not wait for", str(timed_out))
	_check(outcome["client_then"] != String(SYNC_FIXTURE),
		"which was still downloading when the server swapped", str(outcome["client_then"]))
	_check(not _cloud.asked.is_empty() and _cloud.asked[0] == "%s@1.0.0" % SYNC_FIXTURE,
		"from its own content client, for exactly the content and version announced",
		str(_cloud.asked))
	_check(not progress.is_empty(), "the server heard it had started (%d reports)" % progress.size())
	_check(notices.any(func(t: String) -> bool: return t.contains("changed before your client had it")),
		"and the client was told the map changed without it", str(notices))

	# The one that matters. The `load` arrived while the fetch was still running. The bridge
	# used to queue map messages behind its own fetch for this; dot-map holds such a load
	# until the fetch lands now. Armed both times by taking the load at once: before, it
	# was dropped and the client stayed on the old world; in dot-map, it asked for the
	# pack a second time mid-download (dot-map's suite asserts that one).
	# [b]And while it waits, it does not play a world it does not have.[/b] The server is
	# simulating this player on the new map; the client still has the old one, or on a
	# joiner's first connect no world at all. Predicting there was a player falling through
	# nothing and corrected back by every snapshot, while the server applied the keys it was
	# sent to somewhere the player could not see — the grey, jittering first connect that a
	# reconnect, with the pack cached, never showed. Armed by making `in_transit` answer
	# false: the client predicts the held key and sends it, and both checks below fail.
	_check(_client_bridge.in_transit() and _client_bridge.transit_text().begins_with("Loading"),
		"the client knows the server is on a map it has not loaded, and says so",
		_client_bridge.transit_text())
	var history_before := _client_net.local_inputs().since(0).size()
	var client_before := _client_player().global_position
	_steps(8, _forward())
	_check(_client_net.local_inputs().since(0).size() <= history_before
		and _client_player().global_position.distance_to(client_before) < 0.05,
		"so it predicts nothing from the keys held meanwhile",
		"history %d -> %d, moved %.3f m" % [history_before,
			_client_net.local_inputs().since(0).size(),
			_client_player().global_position.distance_to(client_before)])
	var held: G2GPlayerNet = _server_bridge.behaviour_for(SESSION)
	_check(held != null and held.last_move.move.length() < 0.01,
		"and the server is sent a player standing still, not the key it would repeat",
		str(held.last_move.move) if held != null else "no behaviour")

	var followed := await _until_client_on(SYNC_FIXTURE, SLOW_FETCH + 2.0)
	_check(followed, "and it follows once the download finishes, because the load waited behind it",
		String(_client_game.maps.current.id) if _client_game.maps.current != null else "none")
	_check(_client_game.maps.catalogue.has(SYNC_FIXTURE), "and keeps the map for next time")
	_check(not _client_bridge.in_transit() and _client_bridge.transit_text() == "",
		"and the cover comes down once it is on the server's map")

	host.peer_timed_out.disconnect(on_timeout)
	host.peer_progress.disconnect(on_progress)
	_client_bridge.notice_received.disconnect(on_notice)
	_done()


func _test_map_refused() -> void:
	_section("changing the map: a client that refuses")
	print("  (the refusals below log on purpose: a WRN from dot-map and one from the bridge each)")

	var host := _server_bridge.map_host
	host.sync_timeout_sec = SYNC_TIMEOUT
	var refused: Array[String] = []
	var on_refused := func(id: StringName, why: String) -> void: refused.append("%s: %s" % [id, why])
	_client_bridge.map_refused.connect(on_refused)
	var timed_out: Array[int] = []
	var on_timeout := func(peer: int) -> void: timed_out.append(peer)
	host.peer_timed_out.connect(on_timeout)

	# A map the server has in ITS build and the client has nowhere, named by a host.
	# Loading it would mean loading a path of the host's choosing out of THIS build — the
	# rule dot-map exists to enforce, now enforced over a real wire.
	var stages := _server_game.maps.catalogue.get_map(&"bhop_g2g_stages")
	var server_only := DotMapDef.from_dictionary(stages.to_dictionary())
	server_only.id = &"g2g_server_only"
	_server_game.maps.catalogue.add(server_only)

	var before: StringName = _client_game.maps.current.id
	var outcome := await _change_and_pump(&"g2g_server_only", SYNC_TIMEOUT + 3.0)

	_check(bool(outcome["ok"]) and _server_game.maps.current.id == &"g2g_server_only",
		"the server changes anyway", str(outcome["reason"]))
	_check(timed_out == [CLIENT_PEER], "timing out the client, which never said ready", str(timed_out))
	_check(refused.size() == 1 and refused[0].begins_with("g2g_server_only: A host may not send a map that is not delivered content"),
		"the client refuses a map that is neither its own nor delivered", str(refused))
	_check(_client_game.maps.current.id == before,
		"and stays where it was rather than load a scene the host named out of its own build",
		String(_client_game.maps.current.id))

	# A map both have, at a version the client does not: the republished-map case, which on
	# a timer server is a record set on geometry nobody else has.
	refused.clear()
	timed_out.clear()
	var republished := DotMapDef.from_dictionary(stages.to_dictionary())
	republished.version = "2.0.0"
	_server_game.maps.catalogue.remove(&"bhop_g2g_stages")
	_server_game.maps.catalogue.add(republished)
	var second := await _change_and_pump(&"bhop_g2g_stages", SYNC_TIMEOUT + 3.0)
	_check(bool(second["ok"]) and timed_out == [CLIENT_PEER], "a map the client has at another version times it out too",
		"%s %s" % [second["reason"], timed_out])
	_check(refused.size() == 1 and refused[0].contains("different version"),
		"because it refuses to play old geometry the server has replaced", str(refused))
	_check(_client_game.maps.current.id == before, "and stays put again")

	# And a refusal wedges nothing: the next change to a map both have is an ordinary one.
	_server_game.maps.catalogue.remove(&"bhop_g2g_stages")
	_server_game.maps.catalogue.add(stages)
	_server_game.maps.catalogue.remove(&"g2g_server_only")
	host.sync_timeout_sec = 5.0
	var back := await _change_and_pump(&"surf_g2g_intro", 8.0)
	_check(bool(back["ok"]) and int(back["ms"]) < 5000
		and _client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro",
		"the next change after a refusal is an ordinary one", "%s %d ms" % [back["reason"], int(back["ms"])])

	host.peer_timed_out.disconnect(on_timeout)
	_client_bridge.map_refused.disconnect(on_refused)
	DotRegistry.unregister_instance(&"dot_cloud_client", _cloud)
	_cloud.queue_free()
	_real_cloud.queue_free()
	_server_game.maps.catalogue.remove(SYNC_FIXTURE)
	_server_game.maps.catalogue.remove(DELIVERED_FIXTURE)
	DotPaths.remove_tree(SYNC_FIXTURE_ROOT)
	_steps(4)
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


## A kill and the end of a deathmatch round-trip: the killcam's inputs and the podium's rows.
func _test_end_of_match_wire() -> void:
	_section("a kill and a match's end over the link")
	var shot := G2GEvents.read_kill(DotNetReader.new(G2GEvents.write_kill(4097, 12, "deagle", true)))
	_check(bool(shot["ok"]) and int(shot["killer"]) == 4097 and int(shot["victim"]) == 12
			and shot["weapon"] == "deagle" and bool(shot["headshot"]),
		"a KILL round-trips: killer, victim, weapon and the head", str(shot))
	var rows := [{"name": "Ana", "kills": 40, "deaths": 3}, {"name": "Bo", "kills": 12, "deaths": 20},
		{"name": "Cy", "kills": 0, "deaths": 9}, {"name": "Dee", "kills": 0, "deaths": 0}]
	var over := G2GEvents.read_match_end(DotNetReader.new(G2GEvents.write_match_end(7.0, rows)))
	_check(bool(over["ok"]) and is_equal_approx(float(over["killcam"]), 7.0) and over["rows"].size() == 3
			and over["rows"][0] == rows[0] and over["rows"][2] == rows[2],
		"a MATCH_END round-trips: the killcam's seconds and the podium's three rows", str(over))
	var none := G2GEvents.read_match_end(DotNetReader.new(G2GEvents.write_match_end(0.0, [])))
	_check(bool(none["ok"]) and none["rows"].is_empty() and float(none["killcam"]) == 0.0,
		"and an empty board reads as none")
	_done()


## A hit the server applied reaches the one who fired, and only as the server described it.
func _test_hit_wire() -> void:
	_section("a confirmed hit over the link")

	var round_trip := G2GEvents.read_hit(DotNetReader.new(
		G2GEvents.write_hit(4097, 33.5, Vector3(-9123.25, 412.5, 15000.0), true, false)))
	_check(bool(round_trip["ok"]) and int(round_trip["victim"]) == 4097
			and absf(float(round_trip["amount"]) - 33.5) < 0.1
			and (round_trip["point"] as Vector3).is_equal_approx(Vector3(-9123.25, 412.5, 15000.0))
			and bool(round_trip["killed"]) and not bool(round_trip["headshot"]),
		"a HIT round-trips: victim, amount, point and both flags", str(round_trip))

	var arrived: Array[Dictionary] = []
	var on_hit := func(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
		arrived.append({"victim": victim, "amount": amount, "point": point, "killed": killed, "headshot": headshot})
	_client_bridge.hit_received.connect(on_hit)
	_server_bridge._on_hit_landed(&"u%d" % SESSION, 12, 20.0, Vector3(1.0, 2.0, 3.0), false, true)
	# A shooter with no peer (a bot) is told nothing, and nothing reaches this client for it.
	_server_bridge._on_hit_landed(&"u999999", 12, 20.0, Vector3.ZERO, false, false)
	_flush()
	_client_bridge.hit_received.disconnect(on_hit)

	_check(arrived.size() == 1 and int(arrived[0]["victim"]) == 12 and bool(arrived[0]["headshot"]),
		"the shooter's own hit reaches their client, and a peerless shooter's does not (%s)" % str(arrived))
	_done()


## A death and a return, to everybody: who, and how the body falls (the server's pick). Before
## DEATH existed nothing connected `G2GCombat.player_killed` and a dead runner stood upright on
## every screen. Armed by dropping the fall from `write_death` (the reaction check fails) and by
## reading it unconditionally (the bare check fails: an older server's DEATH reads garbage).
func _test_death_wire() -> void:
	_section("a death and a return over the link")

	var fall := DotPlayerDeath.new()
	fall.reaction = DotPlayerDeathReactions.HEADSHOT_LAUNCH
	fall.roll_seed = 9001
	fall.damage = 62.0
	fall.direction = Vector3(1.0, 0.0, 0.0)
	fall.headshot = true
	var carried := G2GEvents.read_death(DotNetReader.new(G2GEvents.write_death(4097, fall)))
	var read: DotPlayerDeath = carried.get("death")
	_check(bool(carried["ok"]) and int(carried["player_id"]) == 4097 and read != null
			and read.reaction == fall.reaction and read.roll_seed == 9001 and read.headshot
			and read.direction.distance_to(Vector3(1.0, 0.0, 0.0)) < 0.05,
		"a DEATH round-trips: the victim and the server's fall", str(carried))
	var bare := G2GEvents.read_death(DotNetReader.new(G2GEvents.write_death(4097)))
	_check(bool(bare["ok"]) and int(bare["player_id"]) == 4097 and not bare.has("death"),
		"and one without a fall reads as the victim alone", str(bare))

	var deaths: Array = []
	var alive: Array = []
	var on_death := func(id: StringName, death: DotPlayerDeath) -> void:
		deaths.append([id, death])
	var on_alive := func(id: StringName) -> void:
		alive.append(id)
	_client_bridge.death_received.connect(on_death)
	_client_bridge.alive_received.connect(on_alive)
	var victim := _server_player()
	victim.death = fall
	_server_bridge.broadcast_death(victim.player_id)
	_flush()
	_server_bridge.broadcast_alive(victim.player_id)
	_flush()
	victim.death = null
	_client_bridge.death_received.disconnect(on_death)
	_client_bridge.alive_received.disconnect(on_alive)

	_check(deaths.size() == 1 and deaths[0][0] == victim.player_id,
		"the death reaches the client, keyed as the client keys the player", str(deaths))
	_check(deaths.size() == 1 and deaths[0][1] != null
			and (deaths[0][1] as DotPlayerDeath).reaction == DotPlayerDeathReactions.HEADSHOT_LAUNCH,
		"with the reaction the server picked, so every screen draws the same fall")
	_check(alive == [victim.player_id], "and so does the return", str(alive))
	_done()


## `sv_flashlight`, `sv_allow_thirdperson` and the chat commands the help screen lists.
##
## Armed by sending the flags from the client's config instead of the server's (the live
## checks fail) and by letting `write_rules` truncate instead of shortening (the oversize
## check fails: a cut JSON document parses to nothing and loses the flags with it).
func _test_rules_wire() -> void:
	_section("what a client may do on its own screen, over the link")

	var round_trip := G2GEvents.read_rules(DotNetReader.new(G2GEvents.write_rules({
		"flashlight": false, "thirdperson": true, "commands": [["r", "Back to the start"], ["wr", "Fastest"]],
	})))
	_check(
		bool(round_trip["ok"]) and not bool(round_trip["flashlight"]) and bool(round_trip["thirdperson"])
			and (round_trip["commands"] as Array).size() == 2
			and str(round_trip["commands"][1][0]) == "wr",
		"a RULES body round-trips: both flags and the command list in order"
	)

	var many: Array = []
	for i in range(1500):
		many.append(["command_%04d" % i, "a description long enough to fill the body quickly %d" % i])
	var big := G2GEvents.read_rules(DotNetReader.new(G2GEvents.write_rules({
		"flashlight": false, "thirdperson": false, "commands": many,
	})))
	_check(
		bool(big["ok"]) and not bool(big["flashlight"]) and not bool(big["thirdperson"])
			and (big["commands"] as Array).size() > 0 and (big["commands"] as Array).size() < many.size(),
		"a list too long for the cap is shortened, never cut: the flags survive (%d of %d commands)" % [
			(big["commands"] as Array).size() if bool(big["ok"]) else 0, many.size()
		]
	)

	var junk := DotNetWriter.new()
	junk.write_string("{not json", G2GEvents.RULES_BYTES)
	_check(
		not bool(G2GEvents.read_rules(DotNetReader.new(junk.to_bytes()))["ok"]),
		"a body that is not a JSON object is refused rather than half-read"
	)

	var arrived: Array[Dictionary] = []
	var on_rules := func(r: Dictionary) -> void: arrived.append(r)
	_client_bridge.rules_received.connect(on_rules)
	var listed := func() -> Array: return [["r", "Back to the start"], ["spec", "Watch somebody"]]
	_server_bridge.commands_fn = listed

	_server_game.config.flashlight = false
	_server_bridge.broadcast_rules()
	_flush()
	_check(
		arrived.size() == 1 and not bool(arrived[0]["flashlight"]),
		"sv_flashlight 0 on the server reaches the client"
	)
	_check(
		arrived.size() == 1 and (arrived[0]["commands"] as Array).size() == 2
			and str(arrived[0]["commands"][1][0]) == "spec",
		"with the server's own command list, not one the client keeps"
	)

	_server_game.config.flashlight = true
	_server_game.config.allow_thirdperson = false
	_server_bridge.broadcast_rules()
	_flush()
	_check(
		arrived.size() == 2 and bool(arrived[1]["flashlight"]) and not bool(arrived[1]["thirdperson"]),
		"and so does turning it back on, and sv_allow_thirdperson 0"
	)

	_server_game.config.allow_thirdperson = true
	_server_bridge.commands_fn = Callable()
	_client_bridge.rules_received.disconnect(on_rules)
	_done()


func _test_voice_wire() -> void:
	_section("voice over the link")

	var relayed: Array[Dictionary] = []
	var heard: Array[PackedByteArray] = []

	_server_bridge.voice_relay_fn = func(speaker: int, bytes: PackedByteArray) -> void:
		relayed.append({"speaker": speaker, "bytes": bytes})
		# Straight back out, which is what DotVoiceRouter does once it has decided
		# who hears it. The router itself is checked on a real server in `dedicated`.
		_server_bridge.link.send_voice(CLIENT_PEER, bytes)

	_client_bridge.voice_in_fn = func(bytes: PackedByteArray) -> void:
		heard.append(bytes)

	var frame := PackedByteArray([9, 8, 7, 6, 5, 4, 3, 2])
	_client_bridge.link.send_voice_frame(frame)
	_flush()

	_check(relayed.size() == 1, "a captured frame reaches the server")

	if not relayed.is_empty():
		# [b]The speaker is stamped from the transport, never read out of the
		# payload.[/b] A client that could name its own speaker id could put words in
		# anybody's mouth, and the only symptom is words coming out of the wrong
		# player — which nobody would report as a security problem.
		_check(
			int(relayed[0]["speaker"]) == CLIENT_PEER,
			"stamped with the peer the transport reported",
			str(relayed[0]["speaker"])
		)
		_check(
			(relayed[0]["bytes"] as PackedByteArray) == frame,
			"and the bytes are unchanged"
		)

	_flush()
	_check(heard.size() == 1, "and the relay reaches a listener")

	# Never a broadcast. `send(bytes, 0)` is how this family last delivered a private
	# message to every client at once, and a voice packet sent to peer 0 would be
	# exactly that bug with audio in it.
	var before := _server_bridge.link.voice_sent
	_server_bridge.link.send_voice(0, frame)
	_check(
		_server_bridge.link.voice_sent == before,
		"and a voice frame addressed to peer 0 is refused rather than broadcast"
	)

	# [b]The client's own voice reaches the server.[/b] Armed: until 2026-10-11 the client's
	# DotVoiceManager had no send_fn, so a player holding the talk key captured, encoded and
	# counted frames that went nowhere, while every check above (which hands the link bytes
	# by hand) passed.
	relayed.clear()
	var extras_script := preload("../game/g2g_client_extras.gd")
	var extras: Node = extras_script.new()
	extras.name = "VoiceExtras"
	add_child(extras)
	var attached: DotResult = extras.call(&"attach", _client_bridge, _client_game)
	var voice: DotVoiceManager = extras.get(&"voice")
	_check(attached.ok and voice != null, "the client's chat and voice attach to its bridge")
	if voice != null:
		var mic := DotVoiceSourceBuffer.new()
		mic.sample_rate = voice.config.sample_rate
		mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, mic.sample_rate, 0.4))
		voice.source = mic
		_check(not voice.is_capturing(), "no microphone is open before the talk key")
		extras.call(&"set_talking", true)
		for _i in range(4):
			await get_tree().process_frame
		_flush()
		_check(voice.frames_sent > 0 and relayed.size() == voice.frames_sent,
			"holding it sends the player's speech to the server (%d sent, %d relayed)" % [voice.frames_sent, relayed.size()])
		extras.call(&"set_talking", false)
	extras.queue_free()
	await get_tree().process_frame
	_done()
