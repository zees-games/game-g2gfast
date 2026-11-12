extends DotGameCheckSuite

const G2GConfig := preload("../game/g2g_config.gd")
const G2GMovement := preload("../game/g2g_movement.gd")

## dot-sim's native motor held to the all-script motor on this game's own movement and maps, to the bit.
##
## [codeblock]
## godot --headless --path . res://examples/headless_native_motor.tscn
## [/codeblock]
##
## dot-player-controller's parity suites prove the library against the script on their own test world and
## tunables. This one replays seeded strafe-and-hop streams on the three maps built in code, with the
## movement `G2GMovement.tunables_for` gives a player (air acceleration 1000, auto-hop, the genre's gravity),
## at 128 Hz (the game's rate) and 64 Hz, four ways: all script; the native collision body
## (`DotFpsPhysicsBody.native_enabled`, the default wherever the library is linked); the native tick's start
## and end (`DotFpsMotor.native_tick` with `native_full` off); and the whole tick in the library
## (`native_tick` and `native_full`). Every tick's state and the motor's counters must be identical, because a
## web client runs the script while a native server and native clients run the library, and surf bots plan on
## the same motor. The ladder (`G2GLadderMode`, a custom mode) always runs in script and is not replayed here.
## Nothing here touches hit registration or lag compensation.
##
## With no dot-sim library it says the native half was skipped and passes; `DOT_SIM_REQUIRE_NATIVE=1` fails
## instead. Armed by nudging one native run's spawn by a millimetre: the first tick differs and the check says so.

const MAPS: Array[String] = ["res://maps/bhop_g2g_intro.tscn", "res://maps/bhop_g2g_stages.tscn", "res://maps/surf_g2g_intro.tscn"]
const RATES: Array[int] = [128, 64]
const SEEDS: Array[int] = [11, 29]
## About twenty seconds of riding at 128 Hz: long enough to leave the spawn and reach the first ramps.
const TICKS := 2600
## 0 all script, 1 the native body, 2 the native tick's start and end, 3 the whole tick native.
const WAYS: Array[String] = ["script", "native body", "native halves", "native full"]

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — native motor parity")
	var was_enabled := DotFpsPhysicsBody.native_enabled
	var was_tick := DotFpsMotor.native_tick
	var was_full := DotFpsMotor.native_full
	if not DotFpsPhysicsBody.native_full_available():
		print("SKIP: dot-sim's motor (motor_tick) is not loaded: the native half is skipped")
		if OS.get_environment("DOT_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library is loaded (DOT_SIM_REQUIRE_NATIVE=1)")
		_report_sections(0, 0, 0)
		return
	for path in MAPS:
		await _map_runs(path)
	DotFpsPhysicsBody.native_enabled = was_enabled
	DotFpsMotor.native_tick = was_tick
	DotFpsMotor.native_full = was_full
	_report_sections(_entered, _completed, MAPS.size())


func _map_runs(path: String) -> void:
	_entered += 1
	var id := path.get_file().get_basename()
	print("")
	print("== %s" % id)
	var map := (load(path) as PackedScene).instantiate() as Node3D
	add_child(map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var spawn: Vector3 = map.call("spawn_for", 0)
	var yaw: float = map.call("spawn_yaw_for", 0)
	var farthest := 0.0
	for hz in RATES:
		for seed in SEEDS:
			var stream := _stream(seed * 131 + hz, yaw, TICKS)
			var label := "%s @%d Hz seed %d" % [id, hz, seed]
			var a := _replay(0, map, spawn, stream, 1.0 / float(hz))
			print("  %-36s end %s  top speed %.1f  ground ticks %d" % [label, a["end"], a["top"], a["ground"]])
			_check(a["native_ticks"] == 0 and not a["native_body"], label + ": the script run stayed out of the library")
			_check(a["ground"] > 0, label + ": the run stood on the map (%d ground ticks)" % a["ground"])
			farthest = maxf(farthest, a["moved"])
			for way in range(1, WAYS.size()):
				var b := _replay(way, map, spawn, stream, 1.0 / float(hz))
				var lw := "%s %s" % [label, WAYS[way]]
				var engaged: bool = b["native_body"]
				if way == 3:
					engaged = engaged and b["native_ticks"] == stream.size()
				elif way == 2:
					engaged = engaged and b["native_ticks"] > 0
				_check(engaged, lw + ": ran in the library (%d native ticks)" % b["native_ticks"])
				var first := -1
				for i in range(a["ticks"].size()):
					if a["ticks"][i] != b["ticks"][i]:
						first = i
						break
				_check(first < 0, lw + ": every one of %d ticks identical%s" % [stream.size(),
					"" if first < 0 else " (first differs at tick %d: script %s native %s)" % [
						first, bytes_to_var(a["ticks"][first]), bytes_to_var(b["ticks"][first])]])
				_check(a["counters"] == b["counters"], lw + ": the same motor counters %s (native %s)" % [a["counters"], b["counters"]])
	# One stream can circle near the spawn (surf_g2g_intro at 128 Hz, seed 29, ends 3 m out); the map's runs together must not.
	_check(farthest > 5.0, "%s: some run left the spawn (farthest %.0f m)" % [id, farthest])
	map.queue_free()
	await get_tree().physics_frame
	_completed += 1


## Strafe-and-hop input: forward with a side key held while the view turns the same way, the jump held
## (auto-hop rides it), now and then a crouch, a stop or a turn the other way; a new choice every few ticks.
func _stream(seed: int, start_yaw: float, ticks: int) -> Array[DotFpsCommand]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[DotFpsCommand] = []
	var yaw := start_yaw
	var side := 1.0
	var forward := -1.0
	var buttons := DotFpsCommand.BUTTON_JUMP
	for tick in range(ticks):
		if tick % 40 == 0 or rng.randf() < 0.02:
			side = -side if rng.randf() < 0.7 else 0.0
			if side == 0.0 and rng.randf() < 0.5:
				side = 1.0
			forward = -1.0 if rng.randf() < 0.6 else float(rng.randi_range(-1, 1))
			buttons = 0
			if rng.randf() < 0.75:
				buttons |= DotFpsCommand.BUTTON_JUMP
			if rng.randf() < 0.12:
				buttons |= DotFpsCommand.BUTTON_CROUCH
		yaw = wrapf(yaw + side * rng.randf_range(0.0, 0.03), -PI, PI)
		var c := DotFpsCommand.new()
		c.move = Vector2(side, forward)
		c.buttons = buttons
		c.yaw = yaw
		out.append(c)
	return out


func _replay(way: int, map: Node3D, spawn: Vector3, stream: Array[DotFpsCommand], step: float) -> Dictionary:
	DotFpsPhysicsBody.native_enabled = way > 0
	DotFpsMotor.native_tick = way >= 2
	DotFpsMotor.native_full = way == 3
	var tunables := G2GMovement.tunables_for(G2GConfig.new())
	tunables.collision_mask = 1
	var physics := DotFpsPhysicsBody.for_node(map)
	var motor := DotFpsMotor.new(tunables, physics)
	var s := DotFpsState.new()
	s.position = spawn
	s.mode = DotFpsState.Mode.AIR
	var ticks: Array[PackedByteArray] = []
	var before := DotFpsPhysicsBody.native_ticks
	var top := 0.0
	var ground := 0
	for c in stream:
		motor.simulate(s, c, step)
		top = maxf(top, Vector2(s.velocity.x, s.velocity.z).length())
		ground += 1 if s.mode == DotFpsState.Mode.GROUND else 0
		ticks.append(var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
			s.crouch_held, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.previous_buttons]))
	var counters := [motor.stuck_ticks, motor.duplicate_plane_ticks, motor.crease_leg_ticks, motor.split_leg_ticks,
		motor.depenetrated_ticks, motor.embedded_ticks, motor.lifted_ticks, motor.settled_ground_ticks, motor.reused_ground_ticks]
	return {"ticks": ticks, "counters": counters, "end": s.position, "top": top, "ground": ground,
		"moved": s.position.distance_to(spawn), "native_body": physics.uses_native(),
		"native_ticks": DotFpsPhysicsBody.native_ticks - before}
