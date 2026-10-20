extends Node

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

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
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


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_verbose = "--verbose" in args
	_ws = "--ws" in args
	var at := args.find("--only")
	if at >= 0 and at + 1 < args.size():
		_only = args[at + 1]
	DotLog.set_level(DotLog.Level.INFO if _verbose else DotLog.Level.ERROR)

	var early := Early.new()
	early.probe = self
	early.process_physics_priority = -1000
	early.process_priority = -1000
	add_child(early)
	var late := Late.new()
	late.probe = self
	late.process_physics_priority = 1000
	late.process_priority = 1000
	add_child(late)

	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: what a connected player sees, through a real socket")
	DotPaths.remove_tree(DATA)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA))

	if await _boot() and await _connect():
		_driving = true
		await _test_key_to_motion()
		await _test_a_correction_is_eased()
		await _test_a_clock_slip()
		for window in (WS_WINDOWS if _ws else WINDOWS):
			if _only != "" and not str(window[0]).contains(_only):
				continue
			await _play_window(window)

	_driving = false
	await _teardown()

	# The total the section counter cannot be: a script error aborts the rest of a section
	# after it announced itself. Boot 4 (+1 for the proxy), connect 4, the key 1, the
	# correction 3, the slip 2, and 2 a window that ran.
	var windows := 0
	for window in (WS_WINDOWS if _ws else WINDOWS):
		if _only == "" or str(window[0]).contains(_only):
			windows += 1
	var expected := (5 if _ws else 4) + 4 + 1 + 3 + 2 + 2 * windows
	if _completed == _entered and _entered > 2:
		_check(_passed + _failed + 1 == expected + 1, "every check ran (%d of %d)" % [_passed + _failed, expected])

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != _entered else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s -- %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


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

## From standing, W goes down, and the frames are counted until the eye moves. A
## prediction exists so that this is the next frame whatever the round trip is.
func _test_key_to_motion() -> void:
	_section("a key moves the eye on the next frame, whatever the round trip")
	_set_link(WINDOWS[1])
	Engine.max_fps = 144
	Input.action_release(&"dot_fps_forward")
	_turning = false
	await _until(func() -> bool: return false, 1.0)

	var eyes: Array[Vector3] = []
	var at_usec: Array[int] = []
	var ticks: Array[int] = []
	_frame_hook = func(_delta: float) -> void:
		eyes.append(_client.player.camera.active().global_position)
		at_usec.append(Time.get_ticks_usec())
		ticks.append(_client.net.clock.tick)
	await get_tree().process_frame
	await get_tree().process_frame
	var pressed_at := eyes.size()
	var pressed_usec := Time.get_ticks_usec()
	var pressed_tick := _client.net.clock.tick
	Input.action_press(&"dot_fps_forward")
	for _i in range(40):
		await get_tree().process_frame
	_frame_hook = Callable()
	Input.action_release(&"dot_fps_forward")

	var moved_at := -1
	for i in range(pressed_at, eyes.size()):
		# Any motion at all: the first tick from a standstill is a millimetre or two.
		if eyes[i].distance_to(eyes[pressed_at - 1]) > 0.00002:
			moved_at = i
			break
	# 0 is the frame the key went down in, whose physics had already run; 1 is the next.
	var frames := moved_at - pressed_at if moved_at >= 0 else -1
	var ms := float(at_usec[moved_at] - pressed_usec) / 1000.0 if moved_at >= 0 else -1.0
	# The first frame after the key whose physics ran a client tick. It is usually the next
	# one, but at 144 frames a second against 128 ticks about one frame in nine runs none,
	# and a predicted player only moves on a tick: the key landing just before one of those
	# moved the eye on the second frame, one tick later, and failed this one run in nine
	# with nothing wrong. The claim is that the prediction moves on the very next tick.
	#
	# And the eye is drawn at the clock's render alpha (see _fold_clock), not at the tick:
	# a first tick from standstill is 1.3 mm, so the eye's step on that frame is 1.3 mm x
	# alpha. Measured over 40 presses: alpha 0.03 -> 0.04 mm, and 0.004 -> 5 micrometres,
	# under the 20 um motion floor above; and when the clock is slipping the alpha is
	# negative (-0.14, -0.07 seen) and draws the frame between the two before, so the eye
	# has not moved at all on the tick's own frame. 3 of 40 presses read "moved 2 frames,
	# first tick 1" with the prediction working, and the next frame always moved. So the
	# eye gets that one frame of grace; a prediction that waits for the server is ~14
	# frames at the round trip below, which the second half of the check holds it to.
	var first_tick := -1
	for i in range(pressed_at + 1, ticks.size()):
		if ticks[i] > ticks[i - 1]:
			first_tick = i
			break
	_check(moved_at >= 0 and first_tick >= 0 and moved_at <= first_tick + 1
			and ms < _client.net.clock.rtt_ms() / 4.0,
		"the eye moved %d frame(s) after the key, %.1f ms, %d client ticks later, within a frame of the first that ran a tick (%d); the round trip is %d ms" % [
			frames, ms, (ticks[moved_at] - pressed_tick) if moved_at >= 0 else -1,
			first_tick - pressed_at if first_tick >= 0 else -1, int(_client.net.clock.rtt_ms())])
	_done()


## The server moves the local player 30 cm sideways, as a misprediction does, and the eye
## is watched frame by frame. The simulation must take the correction at once -- the
## predictor rewinds and replays -- and the eye must not: a jump of the whole correction
## in one frame is what the player sees as a hitch. See G2GPlayer.drawn_offset.
func _test_a_correction_is_eased() -> void:
	_section("a correction moves the simulation at once and the eye over a moment")
	_set_link(WINDOWS[1])
	Engine.max_fps = 144
	Input.action_press(&"dot_fps_forward")
	await _until(func() -> bool: return false, 1.0)

	var net: DotNetManager = _client.net
	var corrections_before := int(net.predictor.get("_corrections_applied"))
	var eyes: Array[Vector3] = []
	var velocities: Array[Vector3] = []
	var deltas: Array[float] = []
	var record := func(delta: float) -> void:
		eyes.append(_client.player.camera.active().global_position)
		velocities.append(_client.player.controller.state.velocity)
		deltas.append(delta)
		if _verbose:
			print("      frame eye %s offset %s" % [_client.player.camera.active().global_position, _client.player.drawn_offset])
	# Recorded after everything that writes the camera this frame -- read at the top of a
	# frame instead, the camera is wherever its parent node was dragged by a replay, which
	# is not what is drawn.
	_frame_hook = record
	for _i in range(30):
		await get_tree().process_frame

	var server_me: G2GPlayer = _game.players.get(StringName("u%d" % _session()), null)
	var nudge := Vector3.ZERO
	if server_me != null:
		var forward := Vector3(server_me.controller.state.velocity.x, 0.0, server_me.controller.state.velocity.z).normalized()
		nudge = forward.cross(Vector3.UP) * 0.3
		server_me.controller.state.position += nudge
		server_me.global_position = server_me.controller.state.position
	var nudged_at := eyes.size()

	for _i in range(90):
		await get_tree().process_frame
	_frame_hook = Callable()
	Input.action_release(&"dot_fps_forward")

	var worst := 0.0
	for i in range(nudged_at, eyes.size()):
		var step := eyes[i] - eyes[i - 1]
		# A respawn is a teleport, not a correction (as in a window): on a loaded machine
		# the 120 frames last long enough for the runner to reach the pit, and its 12 m
		# was reported as the worst frame of a 30 cm correction.
		if step.length() > 0.5:
			continue
		var v := velocities[i]
		var steady := Vector3(v.x, 0.0, v.z) * deltas[i]
		worst = maxf(worst, (Vector3(step.x, 0.0, step.z) - steady).length())
	var corrected := int(net.predictor.get("_corrections_applied")) - corrections_before
	# The prediction for the newest tick the server has also simulated, against the server's.
	var settled := INF
	var newest := -1
	for t in _a_predicted:
		if _a_track.has(t) and int(t) > newest:
			newest = int(t)
	if newest >= 0:
		settled = (_a_predicted[newest] as Vector3).distance_to(_a_track[newest])

	_check(server_me != null and corrected >= 1,
		"the server moved the player and the client's prediction was corrected",
		"%d corrections" % corrected)
	_check(worst < 0.12,
		"no frame moved the eye more than 12 cm off its motion for a 30 cm correction",
		"worst %.1f cm" % (worst * 100.0))
	_check(settled < 0.05,
		"and the prediction agrees with the server again, tick for tick", "%.3f m apart" % settled)
	_done()


## The clock is made to run a physics frame with no tick, and later one with two, as its
## drift does now and then while it settles on the server (dot-net's `MAX_DRIFT_RATE`, and
## the input lead's steering at up to 12%), and the eye is watched frame by frame while the
## player runs. First the control, with the clock's slip forgotten as soon as it is counted
## (the engine's fraction alone, how the eye was drawn before `G2GClient._fold_clock`), then
## as the client draws it. A stalled frame moved under half of what its time asked, a
## doubled one over one and a half.
func _test_a_clock_slip() -> void:
	_section("a physics frame with no tick, or two, is drawn through, not stalled or doubled")
	_set_link(WINDOWS[1])
	Engine.max_fps = 144
	Input.action_press(&"dot_fps_forward")
	_turning = false
	await _until(func() -> bool: return false, 1.0)

	var control := await _slip_frames(true)
	var drawn := await _slip_frames(false)
	Input.action_release(&"dot_fps_forward")
	print("    %d and %d slips judged on a steady run: control %d stalled, %d doubled, worst %.1f cm (%d%% of a frame's step) off; drawn %d stalled, %d doubled, worst %.1f cm (%d%%) off" % [
		control[3], drawn[3], control[0], control[1], control[2] * 100.0, roundi(control[4] * 100.0),
		drawn[0], drawn[1], drawn[2] * 100.0, roundi(drawn[4] * 100.0)])
	_check(control[3] == SLIPS and control[0] + control[1] >= 6,
		"the control (the engine's fraction alone) stalls or doubles the eye after the slips",
		"%d stalled, %d doubled" % [control[0], control[1]])
	# Off its motion by a share of the frame's own step, not by a distance: a frame is as long
	# as the machine makes it, and on a loaded one (16 frames a second, eight ticks each) a
	# frame drawn 10% long is 3 cm off. Half a step is 1.7 cm at 144 frames, where the old
	# 2 cm bound was set.
	_check(drawn[3] == SLIPS and drawn[0] == 0 and drawn[1] == 0 and drawn[4] < 0.5,
		"drawn at the clock's render alpha, no frame stalls, doubles, or lands half a step off its motion",
		"%d of %d slips, %d stalled, %d doubled, worst %.1f cm, %d%% of its step" % [
			drawn[3], SLIPS, drawn[0], drawn[1], drawn[2] * 100.0, roundi(drawn[4] * 100.0)])
	_done()


## Twelve forced slips, alternately none and two ticks, at least 24 frames apart, each
## judged over the 20 frames after it; what the eye did on those frames: [stalled, doubled,
## worst metres off steady motion].
##
## [b]Only slips on a steady run are judged.[/b] The runner holds W for the whole section,
## which is longer than the course before its first pit, so a pass falls in, respawns at the
## start and runs up from a standstill. A respawn is a snap, the frames after it ease the
## replays that follow it, and a run-up moves the eye a little more each frame: at 1 m/s a
## correction easing a few millimetres a frame is half the motion, and those frames read as
## stalled or doubled with no slip near them (logged: slip 0, render alpha the engine's
## fraction, `drawn_offset` decaying). Judged anyway, the check failed about every other run,
## on whichever pass the pit fell in. So a slip is forced only at full running speed, a window
## the runner leaves it in (the pit, the respawn) is not counted, and the pass goes on until
## twelve have been counted, never fewer.
func _slip_frames(forget: bool) -> Array:
	_forget_slip = forget
	var eyes: Array[Vector3] = []
	var velocities: Array[Vector3] = []
	var deltas: Array[float] = []
	_frame_hook = func(delta: float) -> void:
		eyes.append(_client.player.camera.active().global_position)
		velocities.append(_client.player.controller.state.velocity)
		deltas.append(delta)
	var tunables: DotFpsTunables = _client.player.controller.tunables
	var steady := 0.95 * tunables.max_speed
	var is_steady := func(i: int) -> bool:
		var v: Vector3 = velocities[i]
		return Vector2(v.x, v.z).length() >= steady
	var forced_at: Array[int] = []
	var counted: Array[int] = []
	var since := 0
	var limit := eyes.size() + 3000
	while counted.size() < SLIPS and eyes.size() < limit:
		await get_tree().process_frame
		since += 1
		# A window is counted once its 20 frames have been drawn, and only if the runner
		# kept its speed through all of them.
		while not forced_at.is_empty() and eyes.size() >= forced_at[0] + 21:
			var at: int = forced_at.pop_front()
			var kept := true
			for i in range(at, at + 20):
				if not is_steady.call(i) or eyes[i].distance_to(eyes[i - 1]) > 0.5:
					kept = false
					break
			if kept:
				counted.append(at)
		if since >= 24 and forced_at.is_empty() and eyes.size() > 1 and is_steady.call(eyes.size() - 1):
			forced_at.append(eyes.size())
			_force_slip = -1 if (counted.size() + forced_at.size()) % 2 == 1 else 1
			since = 0
	_frame_hook = Callable()
	_forget_slip = false

	var stalled := 0
	var doubled := 0
	var worst := 0.0
	var worst_share := 0.0
	var corrections := int(_client.net.predictor.get("_corrections_applied"))
	for at in counted:
		for i in range(at, at + 20):
			var step := eyes[i] - eyes[i - 1]
			var flat := Vector3(velocities[i].x, 0.0, velocities[i].z)
			var speed := flat.length()
			var expected := speed * deltas[i]
			var along := Vector3(step.x, 0.0, step.z).dot(flat / speed)
			if along < expected * 0.5:
				stalled += 1
			elif along > expected * 1.5:
				doubled += 1
			var off := (Vector3(step.x, 0.0, step.z) - flat / speed * expected).length()
			worst = maxf(worst, off)
			worst_share = maxf(worst_share, off / expected)
	if _verbose:
		print("      %s: %d corrections so far" % ["control" if forget else "drawn", corrections])
	return [stalled, doubled, worst, counted.size(), worst_share]


func _play_window(window: Array) -> void:
	_section("%s" % window[0])
	_set_link(window)
	Engine.max_fps = int(window[1])

	# Settle at the new rate and link before measuring.
	Input.action_press(&"dot_fps_forward")
	_turning = true
	await _until(func() -> bool: return false, 1.5)

	var net: DotNetManager = _client.net
	_relay.reset_counts()
	if _tcp != null:
		_tcp.reset_counts()
	net.interpolator.reset_counts()
	_w = {
		"started": Time.get_ticks_msec(),
		"frames": 0,
		"physics_frames": 0,
		"zero_tick_frames": 0,
		"multi_tick_frames": 0,
		"physics_per_frame": [],
		"ratios": [],
		"turns": [],
		"backward": 0,
		"backward_max": 0.0,
		"eye_snap_max": 0.0,
		"render_back": 0,
		"render_back_max": 0.0,
		"remote_errors": [],
		"correction_sizes": [],
		"eye_offs": [],
		"replays": int(net.predictor.get("_replays")),
		"corrections": int(net.predictor.get("_corrections_applied")),
		"first_tick": net.clock.tick,
		"server_first_tick": _game.current_tick(),
		"starved": _server_buffer().starved_count,
		"late": _server_buffer().late_count,
		"snaps": int(net.clock.get("_snap_count")),
		"catch_ups": int(net.clock.get("_catch_up_count")),
	}
	await _until(func() -> bool: return false, float(window[5]))
	var w := _w
	_w = {}
	Input.action_release(&"dot_fps_forward")
	_turning = false

	var frames: int = (w["physics_per_frame"] as Array).size()
	var seconds := float(Time.get_ticks_msec() - int(w["started"])) / 1000.0
	print("    %d frames in %.1f s (%.0f fps), %d physics frames, %d with no client tick, %d with two or more" % [
		frames, seconds, frames / maxf(seconds, 0.001), w["physics_frames"], w["zero_tick_frames"], w["multi_tick_frames"]])

	var ratios: Array = w["ratios"]
	ratios.sort()
	var offs: Array = w["eye_offs"]
	offs.sort()
	var jumps := 0
	for o in offs:
		if float(o) > 0.02:
			jumps += 1
	var turns: Array = w["turns"]
	var expected_turn := _median(turns)
	var stalled := 0
	var doubled := 0
	for t in turns:
		if float(t) < 0.5:
			stalled += 1
		elif float(t) > 1.5:
			doubled += 1
	var replays := int(net.predictor.get("_replays")) - int(w["replays"])
	var corrections := int(net.predictor.get("_corrections_applied")) - int(w["corrections"])
	var errors: Array = w["remote_errors"]
	errors.sort()
	var described: Dictionary = net.interpolator.describe()
	var sizes: Array = w["correction_sizes"]
	sizes.sort()
	var predicted_errors: Array = []
	for t in _a_predicted:
		if _a_track.has(t) and int(t) >= int(w["first_tick"]):
			predicted_errors.append((_a_predicted[t] as Vector3).distance_to(_a_track[t]))
	predicted_errors.sort()
	if _verbose:
		var shown := 0
		var ticks: Array = _a_predicted.keys()
		ticks.sort()
		for t in ticks:
			if _a_track.has(t) and int(t) >= int(w["first_tick"]) and shown < 40:
				var d := (_a_predicted[t] as Vector3).distance_to(_a_track[t])
				if d > 0.01:
					shown += 1
					print("      tick %d predicted %s server %s (%.3f m)" % [t, _a_predicted[t], _a_track[t], d])

	print("    local: eye motion per frame / expected p5 %.2f  p50 %.2f  p95 %.2f; backward %d (max %.1f mm)" % [
		_pct(ratios, 0.05), _pct(ratios, 0.5), _pct(ratios, 0.95), w["backward"], float(w["backward_max"]) * 1000.0])
	print("    eye off steady motion: p50 %.1f mm  p99 %.1f mm  max %.1f mm; %d frames more than 2 cm off" % [
		_pct(offs, 0.5) * 1000.0, _pct(offs, 0.99) * 1000.0, _pct(offs, 1.0) * 1000.0, jumps])
	print("    view: turned %.2f of the mouse a frame (median); %d of %d frames did not turn, %d turned double" % [
		expected_turn, stalled, turns.size(), doubled])
	print("    prediction: %d replays, %d corrected (worst %.3f m so far); clock snaps %d, catch-ups %d" % [
		replays, corrections, float(net.predictor.get("_worst_error")),
		int(net.clock.get("_snap_count")) - int(w["snaps"]), int(net.clock.get("_catch_up_count")) - int(w["catch_ups"])])
	var buffer := _server_buffer()
	var server_ticks := _game.current_tick() - int(w["server_first_tick"])
	print("    server had A's command for %.1f%% of %d ticks (%d starved, %d late); clock rtt %d ms, lead %d" % [
		100.0 * (1.0 - float(buffer.starved_count - int(w["starved"])) / float(maxi(1, server_ticks))), server_ticks,
		buffer.starved_count - int(w["starved"]), buffer.late_count - int(w["late"]), int(net.clock.rtt_ms()),
		net.clock.tick - _game.current_tick()])
	print("    corrections this window: %d, size p50 %.3f m  max %.3f m; prediction vs server same tick p50 %.4f  p95 %.4f  max %.3f m" % [
		sizes.size(), _pct(sizes, 0.5), _pct(sizes, 1.0), _pct(predicted_errors, 0.5), _pct(predicted_errors, 0.95), _pct(predicted_errors, 1.0)])
	print("    remote: drawn vs server p50 %.3f m  p95 %.3f m  max %.3f m; render timeline back %d (max %.2f tick); interpolator %s" % [
		_pct(errors, 0.5), _pct(errors, 0.95), _pct(errors, 1.0), w["render_back"], w["render_back_max"], described])
	if _tcp != null:
		print("    proxy: %d chunks up, %d down, %d held for a retransmit" % [_tcp.chunks[0], _tcp.chunks[1], _tcp.stalls])
	else:
		print("    relay: %s" % _relay.describe())

	_check(frames > int(window[5]) * 20, "frames were drawn", "%d" % frames)
	# Every frame turns while the mouse moves. The view was the last tick's, so a frame
	# that ran no tick -- one in nine at 144 Hz against 128 -- stood still and the next
	# turned double. See G2GPlayer.view_now.
	_check(stalled == 0 and doubled == 0,
		"the view turned on every frame the mouse moved, and never double",
		"%d of %d frames still, %d double" % [stalled, turns.size(), doubled])
	_done()


static func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


static func _pct(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	return float(sorted[clampi(int(roundf(p * float(sorted.size() - 1))), 0, sorted.size() - 1)])


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
