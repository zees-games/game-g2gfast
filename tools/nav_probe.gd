extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## Bakes and annotates a loaded map the way the bots do and prints counts and timings.
##
##     timeout 300 godot --headless --path . tools/nav_probe.tscn -- bhop_eazy

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var id := StringName(OS.get_cmdline_user_args()[0])
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = id
	var game := G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(240):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	print("loaded ", id)
	var map := game.current_map_node()
	var t := Time.get_ticks_usec()
	var nav := DotBotNav.new()
	var res := nav.bake(map, {"radius": 0.45, "height": 1.7, "climb": 0.4, "slope": 46.0})
	print("bake ok=%s %d polys %.0f ms" % [res.ok, nav.mesh.get_polygon_count() if nav.mesh != null else 0, (Time.get_ticks_usec() - t) / 1000.0])
	for _k in range(3):
		await get_tree().physics_frame
	var job := DotNpcAiNavAnnotator.new(nav.mesh, get_world_3d())
	job.agent_radius = 0.45
	job.stand_height = 1.7
	job.climb = 0.4
	job.jump_up = 1.25
	job.gap_max = float(OS.get_environment("GAP")) if OS.has_environment("GAP") else 3.0
	var spawn: Vector3 = map.spawn_for(DotTimerTrack.MAIN)
	job.seeds = PackedVector3Array([spawn])
	var slowest := 0.0
	var steps := 0
	t = Time.get_ticks_usec()
	while true:
		var s := Time.get_ticks_usec()
		var more := job.step()
		slowest = maxf(slowest, (Time.get_ticks_usec() - s) / 1000.0)
		steps += 1
		if not more:
			break
	print("annotate %.0f ms, %d slices, slowest %.1f ms" % [(Time.get_ticks_usec() - t) / 1000.0, steps, slowest])
	if job.result.ok:
		var a: DotNpcAiNavAnnotations = job.result.value
		for l in a.describe_lines():
			print(l)
		var n := 0
		for link in a.links:
			nav.add_ride(link["from"], link["to"], n, float(link.get("cost", 1.0)))
			n += 1
		for _k in range(3):
			await get_tree().process_frame
		var finish := Vector3.ZERO
		for z in game.timers.zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN):
			finish = z.centre()
		var r := nav.route(spawn, finish)
		print("stages %d, spawn %s finish %s -> route %d points, rides %d" % [game.timers.zones.stage_count(DotTimerTrack.MAIN), spawn, finish, r["points"].size(), (r["rides"] as PackedInt32Array).size() - (r["rides"] as PackedInt32Array).count(-1)])
		if r["points"].size() > 0:
			print("last point ", r["points"][r["points"].size() - 1], " dist to finish ", r["points"][r["points"].size() - 1].distance_to(finish))
		print("link sample ", a.links[0])
	else:
		print("failed: ", job.result.error.message)
	get_tree().quit(0)
