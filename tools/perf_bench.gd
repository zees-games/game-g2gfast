extends DotGamePerfBench

## The windowed solo-client benchmark (dot-game's DotGamePerfBench; see that class and `tools/perf_bench.sh` for the flags).
## The real offline client on `--map` (default `surf_mesa`, the offline default) with `--bots` route bots added through the
## game's own bot layer. `--motor-tick 1|0` sets `DotFpsMotor.native_tick` before the client loads, so
## `tools/perf_bench.sh --ab DIR::--motor-tick 0 DIR::--motor-tick 1 -n 3 --box staging02` prices dot-sim's native tick.
## The bots ride and fire nothing, so the inert check needs `PERF_BENCH_INERT_PER_TICK=0`.


func _configure() -> void:
	client_scene = "res://game/g2g.tscn"
	map = "surf_mesa"
	bots = 15


func _setup_client(c: Node) -> void:
	c.set("force_offline", true)
	# The client's own layered configuration reads G2G_* before it starts the offline map.
	OS.set_environment("G2G_INITIAL_MAP", map)
	if args.has("motor-tick"):
		DotFpsMotor.native_tick = String(args["motor-tick"]) == "1"


func _select(game: Object) -> void:
	# No loading gate on this client: wait for the offline map itself (it loads inside the game's _ready).
	var limit := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < limit:
		var maps: Variant = game.get("maps")
		if maps != null and (maps as Object).get("current") != null:
			break
		await get_tree().process_frame
	var layer: Node = game.get("bots")
	if layer == null:
		say("perf_bench: the game has no bot layer")
		return
	var added := 0
	for i in range(bots):
		if layer.call("add_bot", "Bench %d" % (i + 1)) != null:
			added += 1
	say("perf_bench: %d of %d bots on %s, native tick %s" % [added, bots, map, DotFpsMotor.native_tick])


func _sidecar_extra(_game: Object) -> Dictionary:
	return {"motor_native_tick": DotFpsMotor.native_tick, "motor_native_full": DotFpsMotor.native_full,
		"motor_native_available": DotFpsPhysicsBody.native_full_available()}
