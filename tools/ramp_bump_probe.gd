extends Node3D

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GUnits := preload("../game/g2g_units.gd")

## Rides ramps with the real motor and counts the ticks a camera would see JUMP.
##
## surf_run asks whether a ride ends; this asks whether it is smooth. A ride that keeps
## its speed can still throw the eye a few units off the face and back on one tick,
## which is a single displaced frame in a recording and reads as "the ramps are jumpy".
## Every tick's position step is compared with the one before: a smooth ride changes
## it by gravity and by the slow turn of the face, a bump changes it by far more and
## points off the face. Each bump is attributed to whatever corrected the hull that
## tick -- depenetration, the crease search giving up, the duplicate-plane early-out.
##
##     godot --headless --path . tools/ramp_bump_probe.tscn -- surf_mesa [runs] [entry u/s] [strafe 0|1]

const SECONDS := 3.0
const BUMP_UNITS := 1.0       ## a position step off its smooth line by more than this is a pop


var strafe := false
var entry := 900.0
var tunables: DotFpsTunables
var motor: DotFpsMotor
var ticks_on_ramp := 0
var bumps := 0
var by_cause := {}
var worst: Array = []
var depth_hist := {}
var dep_kinds := {}
var trace_ride := -1
var trace_until := 400
var skipped := 0
var rides := 0
var rides_deep := 0
var deep := 0
var deep_where: Array = []
var dep_push := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_mesa"
	var runs := int(args[1]) if args.size() > 1 else 200
	entry = float(args[2]) if args.size() > 2 else 900.0
	strafe = args.size() > 3 and args[3] == "1"

	var map := G2GBspMap.new()
	add_child(map)
	map.build_from_path("res://maps/imported/%s/%s.json" % [id, id])
	await get_tree().physics_frame
	await get_tree().physics_frame

	tunables = G2GMovement.tunables_for(G2GConfig.new())
	motor = DotFpsMotor.new(tunables, DotFpsPhysicsBody.for_node(self))
	var samples := _ramp_samples(map)
	samples.resize(mini(runs, samples.size()))

	trace_ride = int(OS.get_environment("TRACE_RIDE")) if OS.get_environment("TRACE_RIDE") != "" else -1
	trace_until = int(OS.get_environment("TRACE_UNTIL")) if OS.get_environment("TRACE_UNTIL") != "" else 400
	for sample: Array in samples:
		_ride(sample)
	_report(id, samples.size())
	get_tree().quit(0)


func _ride(sample: Array) -> void:
	var step := 1.0 / 128.0
	var state := DotFpsState.new()
	var n: Vector3 = sample[1]
	state.position = sample[0] + n * G2GUnits.to_metres(8.0)
	var along := (Vector3.DOWN - n * n.dot(Vector3.DOWN))
	along.y = 0.0
	if along.length_squared() < 1e-9:
		return
	# Across the slope, the way a rider meets it.
	var across := Vector3(-along.z, 0.0, along.x).normalized()
	state.velocity = across * G2GUnits.to_metres(entry)
	var command := DotFpsCommand.new()
	var prev := state.position
	var prev_step := Vector3.ZERO
	var h0 := motor._height(state)
	if motor.body.rest_contact(motor._capsule_centre(state.position, h0), h0, tunables.radius).depth > G2GUnits.to_metres(1.0):
		skipped += 1
		return
	rides += 1
	var ride_deep := false
	for t in range(int(SECONDS / step)):
		var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
		if strafe and flat.length() > 0.01:
			# Facing the travel, holding the strafe that leans into the ramp.
			command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
			var b := motor._view_basis(command.yaw, 0.0)
			var into := -Vector3(n.x, 0.0, n.z)
			command.move = Vector2(signf(b.right.dot(into)), 0.0)
		var dep := motor.depenetrated_ticks
		var h := motor._height(state)
		var pre := motor.body.rest_contact(motor._capsule_centre(state.position, h), h, tunables.radius)
		var pre_kind := ""
		if pre.hit and pre.depth > 0.0:
			pre_kind = _shape_kind(motor)
		var dup := motor.duplicate_plane_ticks
		var stuck := motor.stuck_ticks
		motor.simulate(state, command, step)
		var moved := state.position - prev
		if rides == trace_ride and t < trace_until:
			_trace_tick(t, state, n, pre, dep, dup)
		if motor.depenetrated_ticks > dep and pre.hit:
			ride_deep = _count_depenetration(pre, pre_kind, n, t, prev, state, ride_deep)
		if t > 2 and _touching(motor, state, n):
			ticks_on_ramp += 1
			# The step this tick against the last one, less what gravity adds.
			var jerk := G2GUnits.to_units((moved - prev_step).length())
			if jerk > BUMP_UNITS:
				_count_bump(jerk, state, sample, dep, stuck, dup)
		prev_step = moved
		prev = state.position


func _trace_tick(t: int, state: DotFpsState, n: Vector3, pre, dep: int, dup: int) -> void:
	var sp := get_world_3d().direct_space_state
	var foot := state.position + Vector3.UP * 0.3
	var q := PhysicsRayQueryParameters3D.create(foot + n * 2.0, foot - n * 4.0)
	var hit := sp.intersect_ray(q)
	var gap := -1.0
	if not hit.is_empty():
		gap = G2GUnits.to_units((foot + n * 2.0).distance_to(hit["position"])) - G2GUnits.to_units(2.0)
	print("[trace] t%d pos %s vel %s pre_depth %.2f pre_n %s dep %s dup %s grounded %s face_gap %.1f" % [t,
		G2GUnits.vector_to_units(state.position).round(), G2GUnits.vector_to_units(state.velocity).round(),
		G2GUnits.to_units(pre.depth) if pre.hit else -1.0, pre.normal.snapped(Vector3.ONE * 0.01),
		motor.depenetrated_ticks > dep, motor.duplicate_plane_ticks > dup, state.is_grounded(), gap])


## Returns whether this ride has now gone deeper than a unit into something.
func _count_depenetration(pre, pre_kind: String, n: Vector3, t: int, prev: Vector3,
		state: DotFpsState, ride_deep: bool) -> bool:
	var push := minf(pre.depth + tunables.skin_width, maxf(tunables.step_height, tunables.skin_width * 2.0))
	var key := "%s depth<%s normal_vs_face=%s" % [pre_kind,
		_bucket(G2GUnits.to_units(pre.depth), [0.1, 1.0, 5.0, 17.0]),
		_bucket(rad_to_deg(pre.normal.angle_to(n)), [3.0, 20.0, 60.0, 120.0])]
	dep_kinds[key] = int(dep_kinds.get(key, 0)) + 1
	dep_push += G2GUnits.to_units(push)
	if G2GUnits.to_units(pre.depth) <= 1.0:
		return ride_deep
	deep += 1
	if ride_deep:
		return true
	rides_deep += 1
	if deep_where.size() < 15:
		deep_where.append("ride %d tick %d: %s depth %.1f u, normal %s vs face %s (%.0f deg), from %s, v %s u/s" % [
			rides, t, pre_kind, G2GUnits.to_units(pre.depth), pre.normal.snapped(Vector3.ONE * 0.01),
			n.snapped(Vector3.ONE * 0.01), rad_to_deg(pre.normal.angle_to(n)),
			G2GUnits.vector_to_units(prev).round(), G2GUnits.vector_to_units(state.velocity).round()])
	return true


func _count_bump(jerk: float, state: DotFpsState, sample: Array, dep: int, stuck: int, dup: int) -> void:
	bumps += 1
	var cause := "other"
	if motor.depenetrated_ticks > dep:
		cause = "depenetrate"
	elif motor.stuck_ticks > stuck:
		cause = "ran_out"
	elif motor.duplicate_plane_ticks > dup:
		cause = "duplicate_plane"
	by_cause[cause] = int(by_cause.get(cause, 0)) + 1
	var bucket := mini(int(jerk), 20)
	depth_hist[bucket] = int(depth_hist.get(bucket, 0)) + 1
	if worst.size() < 12:
		worst.append("%s jerk %.1f u at %s (%s) v=%d u/s" % [cause, jerk,
			G2GUnits.vector_to_units(state.position).round(),
			sample[2], int(G2GUnits.to_units(state.velocity.length()))])


func _report(id: String, sample_count: int) -> void:
	print("[bump] %s: %d rides at %d u/s%s, %d ticks touching a ramp, %d BUMPS > %.1f u (%.2f%%)"
		% [id, sample_count, int(entry), " strafing" if strafe else "", ticks_on_ramp, bumps,
			BUMP_UNITS, 100.0 * bumps / maxf(1.0, ticks_on_ramp)])
	print("[bump]   by cause: %s" % [by_cause])
	var keys := depth_hist.keys()
	keys.sort()
	print("[bump]   jerk histogram (u): %s" % [", ".join(keys.map(func(k): return "%d:%d" % [k, depth_hist[k]]))])
	print("[bump]   flipped normals turned round: %d" % motor.body.flipped_normals)
	print("[bump]   counters: depenetrated %d, duplicate_plane %d, ran_out %d" % [
		motor.depenetrated_ticks, motor.duplicate_plane_ticks, motor.stuck_ticks])
	var dk := dep_kinds.keys()
	dk.sort_custom(func(a, b): return int(dep_kinds[a]) > int(dep_kinds[b]))
	for k in dk:
		print("[bump]   depenetrate %5d  %s" % [dep_kinds[k], k])
	print("[bump]   total depenetration push %.0f u" % dep_push)
	print("[bump]   %d rides started clear (%d skipped embedded); %d of them went DEEPER THAN 1 u into something (%d ticks)" % [rides, skipped, rides_deep, deep])
	for w in deep_where:
		print("[bump]     " + w)
	for w in worst:
		print("[bump]     " + w)


## Near a face steeper than a floor: within a few units of it along the sample's normal.
func _touching(_motor: DotFpsMotor, state: DotFpsState, _n: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var from := state.position + Vector3.UP * 0.5
	for dir: Vector3 in [Vector3.DOWN, -_n]:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 1.2)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var normal: Vector3 = hit["normal"]
			if normal.angle_to(Vector3.UP) > deg_to_rad(46.0) and normal.y > 0.05:
				return true
	return false


func _ramp_samples(map: G2GBspMap) -> Array:
	var mi := map.get_node_or_null("World") as MeshInstance3D
	var out: Array = []
	var surfaces: Array = map.manifest.get("surfaces", [])
	for s in range(mi.mesh.get_surface_count()):
		if s >= surfaces.size() or str(surfaces[s].get("role", "")) != "RAMP":
			continue
		var key := str(surfaces[s].get("material", "?"))
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size() - 2, 3):
			var normal := (normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]])
			if normal.length_squared() < 1e-9:
				continue
			normal = normal.normalized()
			if normal.y <= 0.05 or normal.angle_to(Vector3.UP) < deg_to_rad(46.0):
				continue
			out.append([(verts[indices[i]] + verts[indices[i + 1]] + verts[indices[i + 2]]) / 3.0,
				normal, key])
	seed(20261008)
	out.shuffle()
	return out


func _bucket(v: float, edges: Array) -> String:
	for e in edges:
		if v < e:
			return str(e)
	return ">" + str(edges[-1])


## What the last rest query touched: a convex hull (a brush) or loose triangles (terrain).
func _shape_kind(motor: DotFpsMotor) -> String:
	var info: Dictionary = get_world_3d().direct_space_state.get_rest_info(motor.body._shape_params)
	if info.is_empty():
		return "none"
	var rid: RID = info["rid"]
	var idx: int = info["shape"]
	var shape_rid := PhysicsServer3D.body_get_shape(rid, idx)
	match PhysicsServer3D.shape_get_type(shape_rid):
		PhysicsServer3D.SHAPE_CONVEX_POLYGON:
			return "convex"
		PhysicsServer3D.SHAPE_CONCAVE_POLYGON:
			return "trimesh"
		_:
			return "other"
