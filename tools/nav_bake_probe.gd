extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GBotNav := preload("../game/g2g_bot_nav.gd")

## Plans a route on a loaded map three times and prints the phases of each: pass 0 with the bake cache off, pass 1 writing it, pass 2 as a round change would, from it.
##
##     timeout 600 godot --headless --path . tools/nav_bake_probe.tscn -- surf_rookie

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
	var map := game.current_map_node()
	var spawn: Vector3 = map.spawn_for(DotTimerTrack.MAIN)
	var finish := Vector3.ZERO
	for z in game.timers.zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN):
		finish = z.centre()
	var body: DotFpsTunables = DotFpsTunables.new()
	for pass_no in range(3):
		var nav := G2GBotNav.new()
		var t := Time.get_ticks_usec()
		nav.begin(map, map.get_world_3d(), body, spawn, finish, PackedVector3Array([spawn]), "user://nav_probe_ann", Callable(), String(id) if pass_no > 0 else "")
		while nav.step(2000):
			await get_tree().physics_frame
		print("pass %d: %s total %.0f ms, phases %s, mesh_cached %s, annotations_cached %s, points %d" % [pass_no, id, (Time.get_ticks_usec() - t) / 1000.0, nav.phase_ms, nav.mesh_from_cache, nav.from_cache, nav.points.size()])
	get_tree().quit()
