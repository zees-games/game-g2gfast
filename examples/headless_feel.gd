extends "headless_feel_base.gd"
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
	_report_sections(_entered, _completed, _entered)


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
	# Recorded after everything that writes the camera, not at the top of a frame, where it
	# is wherever a replay dragged the parent node.
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
	var worst_delta := 0.0
	for i in range(nudged_at, eyes.size()):
		var step := eyes[i] - eyes[i - 1]
		# A respawn is a teleport, not a correction: skip it.
		if step.length() > 0.5:
			continue
		var v := velocities[i]
		var steady := Vector3(v.x, 0.0, v.z) * deltas[i]
		var off := (Vector3(step.x, 0.0, step.z) - steady).length()
		if off > worst:
			worst = off
			worst_delta = deltas[i]
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
		"worst %.1f cm, on a %.0f ms frame" % [worst * 100.0, worst_delta * 1000.0])
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
