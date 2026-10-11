extends Node

## What a server tick costs with N players on it, and what each of them is sent.
##
##     godot --headless --path . tools/load_probe.tscn                      # surf_mesa, 1 8 16 32 64
##     godot --headless --path . tools/load_probe.tscn -- surf_mesa 32 64 100
##     LOAD_TICKRATE=64 / LOAD_STAGGER=1 / LOAD_PHASES=1 godot ... -- surf_mesa 32
##
## [b]Nothing in this repository had ever put more than two players on a server.[/b]
## Every suite is one client and one server, so a cost that grows with the square of
## the player count -- every snapshot carries every player, to every player -- is
## invisible to all of them, and "can it hold a full server" had no number at all.
##
## This is the real server half: [G2GGame] on an imported map, a [DotNetManager] and a
## [G2GNetBridge], with the socket replaced by a counter. Each player is admitted the way
## a real peer is (`add_player`, then `_admit`) and holds a command every tick, running
## and turning, so the motor, the zones and the replication all do the work they would.
## The budget is one tick at the server's own rate: 7.8 ms at 128.

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GNetBridge := preload("../game/net/g2g_net_bridge.gd")

const WARMUP_TICKS := 128
const MEASURED_TICKS := 640
const SNAPSHOT_RATE := 32

var _bytes: Dictionary = {}       ## method -> bytes sent to one watched peer
var phase: Dictionary = {}        ## LOAD_PHASES=1: microseconds per step of a snapshot
var _watched_peer := 2


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var map_id := StringName(args[0]) if args.size() > 0 else &"surf_mesa"
	var counts: Array[int] = []
	for a in args.slice(1):
		if a.is_valid_int():
			counts.append(int(a))
	if counts.is_empty():
		counts = [1, 8, 16, 32, 64]

	print("[load] %s, %d measured ticks per row" % [map_id, MEASURED_TICKS])
	print("[load]  players  tick mean   p99    worst  budget  snap B/s/peer  (mean split)")
	for n in counts:
		await _measure(map_id, n)
	get_tree().quit(0)


func _measure(map_id: StringName, players: int) -> void:
	# LOAD_TICKRATE=64: the row at another server tick rate. The game takes its rate from
	# the engine (as sv_tickrate does on a real server) and puts the engine back on its own
	# when it is built, so this is set before every row.
	var rate := OS.get_environment("LOAD_TICKRATE")
	if rate.is_valid_int() and int(rate) > 0:
		Engine.physics_ticks_per_second = int(rate)
	var side := Node.new()
	add_child(side)

	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = map_id
	config.authoritative = true
	var game := G2GGame.new()
	game.config = config
	game.service_scope = StringName("load%d" % players)
	side.add_child(game)
	for _i in range(600):
		await get_tree().process_frame
		if game.maps.current != null:
			break
	if game.maps.current == null:
		push_error("map %s never loaded" % map_id)
		side.queue_free()
		return

	var net := DotNetManager.new()
	net.name = "Server"
	net.is_server = true
	net.local_peer_id = 1
	net.service_scope = game.service_scope
	net.auto_tick = false
	net.config_file = ""
	var nc := DotNetConfig.new()
	nc.tick_rate = game.tick_rate
	nc.snapshot_rate = SNAPSHOT_RATE
	nc.enable_lag_compensation = false
	nc.enable_prediction = true
	nc.world_extent = 512.0
	# LOAD_STAGGER=1: snapshots spread over the ticks between them (DotNetConfig.stagger_snapshots),
	# so a row can be compared both ways.
	nc.stagger_snapshots = OS.get_environment("LOAD_STAGGER") == "1"
	net.config = nc
	side.add_child(net)
	net.setup()

	var bridge := G2GNetBridge.new()
	side.add_child(bridge)
	var attached := bridge.attach(game, net, net)
	if not attached.ok:
		push_error("bridge refused: %s" % attached.error)
		side.queue_free()
		return
	net.messages.seal()
	_bytes = {}
	bridge.link.loopback = _on_send

	for i in range(players):
		var peer := i + 2
		var added: DotResult = bridge.add_player(peer, peer, "load%d" % i)
		if not added.ok:
			push_error("player %d refused: %s" % [i, added.error])
			continue
		bridge._admit(peer)

	var commands: Array[DotFpsCommand] = []
	for i in range(players):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = TAU * float(i) / float(maxi(1, players))
		commands.append(c)

	var times := PackedFloat64Array()
	var net_ms := 0.0
	var game_ms := 0.0
	var tick := 0
	for t in range(WARMUP_TICKS + MEASURED_TICKS):
		tick += 1
		var k := 0
		for session_id in bridge._behaviours:
			var behaviour = bridge._behaviours[session_id]
			var c := commands[k % commands.size()]
			# Turning steadily, as a player strafing a ramp does; a still command is
			# a player the motor has nothing to do for.
			c.yaw = wrapf(c.yaw + 0.02, -PI, PI)
			behaviour.last_move = c
			k += 1
		if t == WARMUP_TICKS:
			_bytes = {}
		# The bridge's server_tick with DotNetManager.server_tick's phases taken apart,
		# so a row says where its cost is: simulating the entities (the motor, the
		# zones, the timers -- the game) or building and sending snapshots.
		var started := Time.get_ticks_usec()
		bridge._tick = tick
		bridge._game_ticked_for = -1
		bridge._watch_hunters()
		net.clock.tick = maxi(net.clock.tick, tick)
		var identities := net.registry.all()
		var step := net.clock.tick_duration()
		for identity in identities:
			if identity.can_simulate():
				for behaviour in identity.behaviours:
					behaviour._net_simulate(tick, step)
		bridge.ensure_game_ticked(tick)
		var mid := Time.get_ticks_usec()
		var period := net.config.ticks_per_snapshot()
		if net.config.stagger_snapshots and period > 1:
			# What DotNetManager.server_tick does when staggered: some peers every tick.
			net.history.record(identities, tick)
			net._send_snapshots(tick, identities, posmod(tick, period), period)
		net._ticks_since_snapshot += 1
		if not (net.config.stagger_snapshots and period > 1) \
				and net._ticks_since_snapshot >= net.config.ticks_per_snapshot():
			net._ticks_since_snapshot = 0
			var h0 := Time.get_ticks_usec()
			net.history.record(identities, tick)
			phase["history"] = float(phase.get("history", 0.0)) + float(Time.get_ticks_usec() - h0)
			if OS.get_environment("LOAD_PHASES") == "":
				net._send_snapshots(tick, identities)
			else:
				_send_snapshots_timed(net, tick, identities)
		var ended := Time.get_ticks_usec()
		if t >= WARMUP_TICKS:
			times.append(float(ended - started) / 1000.0)
			net_ms += float(ended - mid) / 1000.0
			game_ms += float(mid - started) / 1000.0
		# One frame every so often, so whatever the tree does per frame still happens.
		if t % 16 == 0:
			await get_tree().process_frame

	var sorted := Array(times)
	sorted.sort()
	var mean := 0.0
	for x in times:
		mean += x
	mean /= maxf(1.0, float(times.size()))
	var p99: float = sorted[int(sorted.size() * 0.99)] if not sorted.is_empty() else 0.0
	var worst: float = sorted.back() if not sorted.is_empty() else 0.0
	var seconds := float(MEASURED_TICKS) / float(game.tick_rate)
	var snap := float(_bytes.get(&"snapshot", 0)) / seconds
	print("[load]  %7d  %6.2f ms %6.2f %6.2f  %5.2f   %7d   game %.2f snapshots %.2f" % [
		players, mean, p99, worst, 1000.0 / float(game.tick_rate), int(snap),
		game_ms / float(MEASURED_TICKS), net_ms / float(MEASURED_TICKS)])

	if not phase.is_empty():
		var parts := PackedStringArray()
		for k in phase:
			parts.append("%s %.2f" % [k, float(phase[k]) / 1000.0 / float(MEASURED_TICKS)])
		print("[load]           per tick, ms: ", ", ".join(parts))
		phase = {}

	side.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## DotNetManager._send_snapshots, step by step, timed. A copy on purpose and only behind
## LOAD_PHASES: it is how a row is broken down, not how the probe measures one.
func _send_snapshots_timed(net: DotNetManager, tick: int, identities: Array[DotNetIdentity]) -> void:
	var context := {"tick": tick, "config": net.config}
	var t := Time.get_ticks_usec()
	net.interest._prepare(identities, context)
	t = _lap("prepare", t)
	net._last_snapshot_tick = tick
	for identity in identities:
		for behaviour in identity.behaviours:
			behaviour.begin_snapshot_reads()
	for peer_id in net._peers:
		net.budget.begin_tick(peer_id)
		var observer := net._observer_for(peer_id)
		var relevant := net.interest.relevant_for(observer, identities, peer_id, context)
		t = _lap("relevant_for", t)
		var scores := {}
		for identity in relevant:
			scores[identity.net_id] = net.interest._score(observer, identity, context)
		t = _lap("score", t)
		relevant = net.interest.prioritise(observer, relevant, net.config.entity_cap(), context, peer_id)
		t = _lap("prioritise", t)
		relevant = net.budget.accumulate(peer_id, relevant, scores)
		t = _lap("budget", t)
		t = _send_to_peer_timed(net, peer_id, tick, relevant, t)
	for identity in identities:
		for behaviour in identity.behaviours:
			behaviour.end_snapshot_reads()


func _send_to_peer_timed(net: DotNetManager, peer_id: int, tick: int,
		relevant: Array[DotNetIdentity], t: int) -> int:
	var writer := DotNetWriter.new()
	writer.write_uint(tick, 32)
	writer.write_uint(0, 12)
	var acked_tick := int(net._acks.get(peer_id, 0))
	var strict := bool(net._ack_wired.get(peer_id, false))
	var oldest_pending: int = tick - net.config.ack_window_snapshots * net.config.ticks_per_snapshot()
	for identity in relevant:
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		t = _lap("  estimated_bits", t)
		var predicted_by_peer := identity.owner_peer_id == peer_id \
			and identity.authority == DotNetIdentity.Authority.SHARED
		writer.write_uint(identity.net_id, DotNetRegistry.ID_BITS)
		writer.write_uint(identity.behaviours.size(), 6)
		for behaviour in identity.behaviours:
			behaviour.sync_peer_acks(peer_id, acked_tick, strict)
			t = _lap("  sync_peer_acks", t)
			behaviour.trim_pending(peer_id, oldest_pending)
			t = _lap("  trim_pending", t)
			var dirty := behaviour.collect_dirty(peer_id, false, predicted_by_peer)
			t = _lap("  collect_dirty", t)
			behaviour.write_state(writer, dirty, peer_id, tick)
			t = _lap("  write_state", t)
	var payload := writer.to_bytes()
	_on_send(&"snapshot", peer_id, payload)
	return _lap("  to_bytes+send", t)


func _lap(name: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	phase[name] = float(phase.get(name, 0.0)) + float(now - since)
	return now


func _on_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if peer_id == _watched_peer or peer_id == 0:
		_bytes[method] = int(_bytes.get(method, 0)) + payload.size()
