extends DotGameCheckSuite

## Constants, the stand-in client and server, and the sampling harness of headless_feel.

const G2GClient := preload("../game/g2g_client.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")

## dot-net's lossy UDP relay, by path (it has no class_name; see dot-net's CLAUDE.md).
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## What a connected player SEES: a real server, the real client, a real socket, real loss.
##
## [codeblock]
## godot --headless --path . res://examples/headless_feel.tscn
## godot --headless --path . res://examples/headless_feel.tscn -- --ws        # a browser's link
## godot --headless --path . res://examples/headless_feel.tscn -- --verbose
## godot --headless --path . res://examples/headless_feel.tscn -- --only "144 Hz"
## [/codeblock]
##
## Every other suite here asserts a simulated value, and `jitter_probe` measures a render
## path with a hand-made clock that never drifts. This one stands up a dual-stack
## `DotServer` running `G2GModule`, connects the real `G2GClient` to it -- over ENet through
## dot-net's UDP relay (delay, jitter, loss), or with `--ws` over WebSocket through
## [TcpDelay] (delay, and retransmit stalls that hold the whole stream) -- holds a key and
## moves the mouse the way a player does, and samples what each rendered frame shows: the
## eye, the view angle, and a runner the server moves (a seated bot, so its every tick is
## known) as this client draws it. The display rate is `Engine.max_fps`; the engine's
## physics runs at the server's 128, as the bridge sets it on HELLO.
##
## Checked: a key moves the eye on the next frame; a 30 cm correction is eased rather than
## drawn in one frame (G2GPlayer.drawn_offset); and in every window the view turns on every
## frame the mouse moves (G2GPlayer.view_now). Printed per window, and the reason this
## exists: for the LOCAL player, the eye's frame-to-frame motion against its speed, frames
## it went backwards, frames more than 2 cm off steady motion, the share of server ticks
## that had this client's command, and every correction and its size; for the REMOTE
## runner, the drawing against where the server had it at that render time, the render
## timeline going back, and frames extrapolated. The numbers are this suite's output, not
## the docs': docs/netcode.md "What a connected player sees" says what each fix was for.

const PORT := 28794
const DATA := "user://g2g_feel"
const MAP := &"bhop_g2g_intro"
const BOT_SESSION := 900001

## name, display fps, loss each way, delay each way (ms), jitter (ms), seconds.
const WINDOWS := [
	["60 Hz display, steady 40 ms", 60, 0.0, 40.0, 0.0, 6.0],
	["144 Hz display, steady 40 ms", 144, 0.0, 40.0, 0.0, 6.0],
	["144 Hz display, 5% loss 30..80 ms", 144, 0.05, 55.0, 25.0, 8.0],
	["240 Hz display, 20% loss 30..80 ms", 240, 0.20, 55.0, 25.0, 8.0],
]

## The same, over WebSocket through [TcpDelay] (`-- --ws`): name, fps, the chance a chunk
## is "lost" and held with everything behind it for [constant TCP_STALL_MS] (what a TCP
## retransmit does to a stream), delay each way, unused, seconds.
const WS_WINDOWS := [
	["144 Hz display, WebSocket 40 ms", 144, 0.0, 40.0, 0.0, 6.0],
	["144 Hz display, WebSocket 40 ms, 1% of segments retransmitted", 144, 0.01, 40.0, 0.0, 8.0],
	["60 Hz display, WebSocket 40 ms, 3% of segments retransmitted", 60, 0.03, 40.0, 0.0, 8.0],
]
const TCP_STALL_MS := 200.0

## How fast the player turns the mouse, in degrees a second whatever the display rate, and
## how fast the bot turns, in degrees a tick: both run circles about a metre across, so
## neither leaves the start platform for a pit.
const TURN_RATE := 240.0
const BOT_TURN := 2.0
## The forced slips each pass of `_test_a_clock_slip` judges.
const SLIPS := 12

var _verbose := false
var _only := ""

var _entered := 0
var _completed := 0

var _server_side: Node = null
var _server: DotServer = null
var _game: G2GGame = null
var _relay = null
var _tcp: TcpDelay = null
var _ws := false
var _client_side: Node = null
var _link: DotClientLink = null
var _client: G2GClient = null
var _bot: G2GPlayer = null

## The per-frame drivers run while true.
var _driving := false
## Sends mouse motion while true.
var _turning := false

## Server truth for the bot: server tick -> position.
var _bot_track: Dictionary = {}
## The local player as the server has it: server tick -> position.
var _a_track: Dictionary = {}
## The local player as predicted: input tick -> position.
var _a_predicted: Dictionary = {}

## The current window's measurements. See [method _begin_window].
var _w: Dictionary = {}

## Client clock tick before the client's physics pass, to count the ticks it ran.
var _tick_before := 0
var _physics_frames_since_render := 0

## Called with the frame's delta after everything has drawn, while a section records.
var _frame_hook := Callable()

## Ticks to add to the client clock's accumulator before its next physics pass (-1 runs
## none, +1 two), and whether the clock's slip is forgotten after each pass (the control).
## See [method _test_a_clock_slip].
var _force_slip := 0
var _forget_slip := false


class Early extends Node:
	var probe = null

	func _physics_process(_delta: float) -> void:
		probe._early_physics()

	func _process(delta: float) -> void:
		probe._early_process(delta)


class Late extends Node:
	var probe = null

	func _physics_process(_delta: float) -> void:
		probe._late_physics()

	func _process(delta: float) -> void:
		probe._late_process(delta)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _module() -> Object:
	return _server.modules.get_module("g2gfast") if _server != null else null


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("a dual-stack g2gfast server, and the relay in front of its UDP port")
	Engine.physics_ticks_per_second = 128

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	var config := DotServerConfig.new()
	config.hostname = "g2gfast feel"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "info" if _verbose else "error"
	# What g2gfast's server.cfg sets. dot-server's own default is not the genre's rate, and
	# a server left on it would measure a different game.
	config.tickrate = 128

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots", str(booted.error)):
		_done()
		return false

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = MAP
	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = g2g_config
	_server_side.add_child(_game)
	await _until(func() -> bool: return _game.maps != null and _game.maps.current != null, 10.0)

	(load("res://game/g2g_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % DATA)
	var loaded: DotResult = await _server.modules.load_module("res://game/g2g_module.gd")
	if not _check(loaded.ok, "the g2gfast module loads on %s" % MAP, str(loaded.error)):
		_done()
		return false

	var bridge: Object = _module().get("bridge")
	var added: DotResult = bridge.call("add_player", 0, BOT_SESSION, "Runner B")
	_check(added.ok, "the server seats a runner for the client to watch", str(added.error))
	_bot = added.value as G2GPlayer if added.ok else null

	_relay = Relay.new()
	_relay.seed = 20261010
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(), str(relayed.error))
	if _ws:
		_tcp = TcpDelay.new()
		var proxied := _tcp.start(PORT + 1, PORT)
		_check(proxied.ok, "and a TCP proxy in front of the WebSocket port", str(proxied.error))
	_done()
	return relayed.ok and _bot != null


func _connect() -> bool:
	_section("the real client connects through the relay")
	_set_link(WINDOWS[0])

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Runner A"
	_link.transport_preference = "ws" if _ws else "udp"
	_link.udp_address = "" if _ws else "127.0.0.1:%d" % _relay.port()
	_client_side.add_child(_link)
	var direct := "--ws-direct" in OS.get_cmdline_user_args()
	_link.connect_to_server("127.0.0.1:%d" % (PORT + 1 if _ws and not direct else PORT))

	# The client scene is built once the link is playing, as the shell builds it: a
	# WebSocket peer has no unique id before its handshake, and a client built before then
	# registers its own player as somebody else's and never predicts it.
	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	await _until(func() -> bool: return spawned[0] or _link.is_playing(), 30.0)

	_client = (load("res://game/g2g.tscn") as PackedScene).instantiate() as G2GClient
	_client_side.add_child(_client)
	_client.mouse_capture_override = true
	_client.presentation.settings.local_store = DotSettingsStoreMemory.new()
	_client.presentation.settings.load_now()
	_client.presentation.apply_all()

	var playing := await _until(func() -> bool:
		return _client.player != null and _client.net != null and _client.net.clock.is_synced() \
			and _client.game.maps.current != null and not _client.bridge.in_transit(), 30.0)
	_check(playing, "the client is told who it is, adopts its player and loads the map",
		"transport %s" % _link.transport_used)
	_check(_link.transport_used == ("websocket" if _ws else "enet") or (_ws and _link.transport_used != "enet"),
		"on %s, through the %s" % ["WebSocket" if _ws else "ENet", "proxy" if _ws else "relay"], _link.transport_used)
	var sees_bot := await _until(func() -> bool:
		return _client.game.players.has(StringName("u%d" % BOT_SESSION)) or _remote_bot() != null, 10.0)
	_check(sees_bot, "and sees the server's runner")
	_check(Engine.physics_ticks_per_second == 128, "the engine steps physics at the server's rate",
		str(Engine.physics_ticks_per_second))
	_done()
	return playing and sees_bot


func _remote_bot() -> G2GPlayer:
	if _client == null or _client.game == null:
		return null
	for id in _client.game.players:
		var p: G2GPlayer = _client.game.players[id]
		if p != _client.player and String(id).ends_with(str(BOT_SESSION)):
			return p
	return null


func _set_link(window: Array) -> void:
	if _tcp != null:
		_tcp.delay_ms = float(window[3])
		_tcp.stall_chance = float(window[2])
		return
	_relay.up.configure(float(window[2]), float(window[3]), float(window[4]))
	_relay.down.configure(float(window[2]), float(window[3]), float(window[4]))


func _teardown() -> void:
	if _link != null:
		_link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	if _relay != null:
		_relay.stop()
	if _tcp != null:
		_tcp.stop()
	if _server != null:
		_server.shutdown("done") if _server.has_method("shutdown") else null
	for _i in range(10):
		await get_tree().process_frame
	DotPaths.remove_tree(DATA)


# --- The drivers --------------------------------------------------------------

## Before everybody's physics: the bot's command for the tick the module is about to run,
## and the client clock's tick, to count what the client's pass runs.
func _early_physics() -> void:
	# The server hears its clients once a TICK, as a dedicated server does (dot-server puts
	# max_fps on the tick rate). Sharing this process it would otherwise hear them once a
	# rendered frame, and at 60 frames a third of A's commands reached it after their tick
	# -- a measurement of this harness, not of the game.
	if _server_side != null:
		var api := get_tree().get_multiplayer(_server_side.get_path())
		if api != null and api.has_multiplayer_peer():
			api.poll()
	if not _driving:
		return
	if _bot != null:
		var move := DotFpsCommand.new()
		move.move = Vector2(0.0, 1.0)
		move.yaw = wrapf(float(_game.current_tick()) * BOT_TURN, -180.0, 180.0)
		_bot.controller.apply_command(move)
	if _client != null and _client.net != null:
		# A forced slip: a tick's time taken from or given to the clock's accumulator, so
		# this physics frame runs none or two, exactly as the drift does now and then.
		if _force_slip != 0:
			_client.net.clock.set(&"_accumulator",
				float(_client.net.clock.get(&"_accumulator")) + float(_force_slip) * _client.net.clock.tick_duration())
			_force_slip = 0
		_tick_before = _client.net.clock.tick


func _late_physics() -> void:
	# The control: the slip forgotten as soon as the clock counts it, which is the engine's
	# fraction alone -- how every game but arena drew its own player before render_alpha.
	if _forget_slip and _client != null and _client.net != null:
		_client.net.clock.set(&"_slip", 0.0)
	if not _driving:
		return
	var server_tick: int = _game.current_tick()
	if _bot != null:
		_bot_track[server_tick] = _bot.controller.state.position
	var me: G2GPlayer = _game.players.get(StringName("u%d" % _session()), null) if _session() > 0 else null
	if me != null:
		_a_track[server_tick] = me.controller.state.position
	if _client == null or _client.net == null or _client.player == null:
		return
	var ran: int = _client.net.clock.tick - _tick_before
	_physics_frames_since_render += 1
	if not _w.is_empty():
		_w["physics_frames"] += 1
		if ran == 0:
			_w["zero_tick_frames"] += 1
		elif ran >= 2:
			_w["multi_tick_frames"] += 1
	if ran > 0:
		_a_predicted[_client.net.clock.tick] = _client.player.controller.state.position
	_note_corrections()


## A correction the predictor made since the last physics frame: how far it moved the
## player, and where. Read off the predictor's own record of it.
func _note_corrections() -> void:
	if _w.is_empty():
		return
	var predictor := _client.net.predictor
	var applied := int(predictor.get("_corrections_applied"))
	var snaps := int(predictor.get("_snaps"))
	if applied == int(_w.get("seen_corrections", -1)) and snaps == int(_w.get("seen_snaps", -1)):
		return
	var first := not _w.has("seen_corrections")
	_w["seen_corrections"] = applied
	_w["seen_snaps"] = snaps
	if first:
		return
	var identity: DotNetIdentity = _client.bridge.behaviour_for(_session()).identity
	var offset := predictor.visual_offset(identity.net_id).length()
	_w["correction_sizes"].append(offset)
	if _verbose:
		print("      correction %.3f m at %s (tick %d, snaps %d)" % [
			offset, _client.player.controller.state.position, _client.net.clock.tick, snaps])


func _server_buffer() -> DotNetInput.Buffer:
	var server_net: DotNetManager = _module().get("net")
	return server_net.input_buffer_for(_link.multiplayer.get_unique_id())


func _session() -> int:
	return _client.bridge.local_player_id if _client != null and _client.bridge != null else 0


## Before the client's frame: the mouse, as a device delivers it -- once per frame.
func _early_process(delta: float) -> void:
	if not _driving or not _turning:
		return
	var motion := InputEventMouseMotion.new()
	var tunables: DotFpsTunables = _client.player.controller.tunables if _client.player != null else null
	var per_count := tunables.mouse_sensitivity * tunables.mouse_sensitivity_x if tunables != null else 0.022
	motion.relative = Vector2(TURN_RATE * delta / maxf(per_count, 1e-6), 0.0)
	_client._unhandled_input(motion)


## After everything that writes the camera: what this frame shows.
func _late_process(delta: float) -> void:
	if _frame_hook.is_valid() and _client != null and _client.player != null:
		_frame_hook.call(delta)
	if not _driving or _w.is_empty() or _client.player == null:
		return
	var camera: Camera3D = _client.player.camera.active() if _client.player.camera != null else null
	if camera == null:
		return

	var now := Time.get_ticks_usec()
	var eye := camera.global_position
	var forward := -camera.global_basis.z
	var yaw := rad_to_deg(atan2(-forward.x, -forward.z))
	var physics := _physics_frames_since_render
	_physics_frames_since_render = 0

	var last: Variant = _w.get("last")
	if last != null:
		var prev: Dictionary = last
		var step: Vector3 = eye - (prev["eye"] as Vector3)
		var velocity: Vector3 = _client.player.controller.state.velocity
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		var speed := flat.length()
		# The engine's own frame time, which is what it measured the interpolation
		# fraction against; a wall clock read here adds its own jitter to every frame.
		var dt := delta
		# A respawn is a teleport, not a stutter: half a metre in a frame is not motion.
		if speed > 1.0 and dt > 0.0 and step.length() < 0.5:
			var along := Vector3(step.x, 0.0, step.z).dot(flat / speed)
			var expected := speed * dt
			_w["ratios"].append(along / expected)
			if along < -0.0005:
				_w["backward"] += 1
				_w["backward_max"] = maxf(float(_w["backward_max"]), -along)
			# How far this frame's eye landed from where steady motion would have put it.
			var off := (Vector3(step.x, 0.0, step.z) - flat / speed * expected).length()
			_w["eye_offs"].append(off)
		if _turning and delta > 0.0:
			# As a share of what this frame's mouse motion asked for, which a long frame
			# legitimately asks more of: 1.0 is a frame that turned as far as the mouse.
			var turned := absf(wrapf(yaw - float(prev["yaw"]), -180.0, 180.0))
			_w["turns"].append(turned / (TURN_RATE * delta))
		_w["physics_per_frame"].append(physics)

	_w["last"] = {"eye": eye, "yaw": yaw, "us": now}
	_sample_remote()


## The runner as this client draws it, against where the server had it at that render
## time. The same arithmetic as `DotNetManager.interpolate_frame`.
func _sample_remote() -> void:
	var seen := _remote_bot()
	if seen == null:
		return
	var net: DotNetManager = _client.net
	# What `interpolate_frame` draws at: the clock's render alpha (the engine's fraction
	# plus what is left of a slip) and the receive timeline's re-anchoring not followed
	# yet. Recomputed with the engine's fraction alone, this measured the drawing against
	# a render time a slip away from the one it was drawn at. By name, for an older shell.
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	if net.clock.has_method(&"render_alpha"):
		alpha = float(net.clock.call(&"render_alpha"))
	var slip := float(net.clock.call(&"receive_slip")) if net.clock.has_method(&"receive_slip") else 0.0
	var render_tick := float(net.clock.received_tick()) + alpha + slip \
		- net.interpolator.delay_ticks()
	var last_render: Variant = _w.get("last_render")
	if last_render != null:
		var back := float(last_render) - render_tick
		if back > 0.01:
			_w["render_back"] += 1
			_w["render_back_max"] = maxf(float(_w["render_back_max"]), back)
	_w["last_render"] = render_tick
	var truth: Variant = _truth_at(_bot_track, render_tick)
	if truth != null and not _teleported_near(_bot_track, int(render_tick)):
		_w["remote_errors"].append(seen.global_position.distance_to(truth))


## A TCP proxy that delays a stream and stalls it, for the browser's case: WebSocket is
## TCP, so nothing is lost or reordered -- a lost segment holds everything behind it
## until the retransmit, and then it all arrives at once. Threaded, like dot-net's UDP
## relay, so a hitch in the game is not a burst in the network measuring it.
class TcpDelay extends RefCounted:
	var delay_ms := 40.0
	var stall_chance := 0.0
	var chunks: Array[int] = [0, 0]
	var stalls := 0

	var _server := TCPServer.new()
	var _target := 0
	var _pairs: Array = []
	var _thread: Thread = null
	var _running := false
	var _rng := RandomNumberGenerator.new()

	func start(listen_port: int, target_port: int) -> DotResult:
		_rng.seed = 20261010
		_target = target_port
		var err := _server.listen(listen_port, "127.0.0.1")
		if err != OK:
			return DotResult.fail(DotError.CODE_IO, "The proxy could not listen.", error_string(err))
		_running = true
		_thread = Thread.new()
		_thread.start(_loop)
		return DotResult.success(listen_port)

	func stop() -> void:
		_running = false
		if _thread != null:
			_thread.wait_to_finish()
			_thread = null
		_server.stop()

	func reset_counts() -> void:
		chunks = [0, 0]
		stalls = 0

	func _loop() -> void:
		while _running:
			_poll()
			OS.delay_usec(250)

	func _poll() -> void:
		while _server.is_connection_available():
			var client := _server.take_connection()
			var upstream := StreamPeerTCP.new()
			upstream.connect_to_host("127.0.0.1", _target)
			_pairs.append({"c": client, "u": upstream, "q": [[], []], "due": [0, 0]})
		var now := Time.get_ticks_usec()
		for pair in _pairs:
			var c: StreamPeerTCP = pair["c"]
			var u: StreamPeerTCP = pair["u"]
			c.poll()
			u.poll()
			if u.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			_pump(pair, c, u, 0, now)
			_pump(pair, u, c, 1, now)

	func _pump(pair: Dictionary, from: StreamPeerTCP, to: StreamPeerTCP, dir: int, now: int) -> void:
		var queue: Array = pair["q"][dir]
		var available := from.get_available_bytes()
		if available > 0:
			var got: Array = from.get_partial_data(available)
			if int(got[0]) == OK and (got[1] as PackedByteArray).size() > 0:
				var due := now + int(delay_ms * 1000.0)
				if _rng.randf() < stall_chance:
					due += int(TCP_STALL_MS * 1000.0)
					stalls += 1
				# In order, always: nothing overtakes a held segment.
				due = maxi(due, int(pair["due"][dir]))
				pair["due"][dir] = due
				queue.append([due, got[1]])
				chunks[dir] += 1
		while not queue.is_empty() and int(queue[0][0]) <= now:
			to.put_data(queue[0][1])
			queue.pop_front()




## Whether the runner was teleported (a pit) within a few snapshots of this tick, where
## any drawing is legitimately far from the truth for a moment.
static func _teleported_near(track: Dictionary, tick: int) -> bool:
	for t in range(tick - 16, tick + 16):
		if track.has(t) and track.has(t + 1) and (track[t] as Vector3).distance_to(track[t + 1]) > 0.5:
			return true
	return false


static func _truth_at(track: Dictionary, tick: float) -> Variant:
	var lo := int(floorf(tick))
	if not track.has(lo) or not track.has(lo + 1):
		return null
	return (track[lo] as Vector3).lerp(track[lo + 1], tick - float(lo))


# --- A window -----------------------------------------------------------------
