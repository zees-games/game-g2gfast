extends DotGameClientBench

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## The world is the timer server and module a dedicated server loads, on bhop_g2g_intro; there are no server bots, so `--bots` is ignored.


func _configure() -> void:
	client_scene = "res://game/g2g.tscn"
	tick_rate = ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 128)


func _boot_server(_bots_wanted: int, data_dir: String) -> DotNetManager:
	var cfg := G2GConfig.new()
	cfg.records_directory = ""
	cfg.records_database = ""
	cfg.map_seconds = 0.0
	cfg.initial_map = &"bhop_g2g_intro"
	var game := G2GGame.new()
	game.name = "Game"
	game.config = cfg
	add_child(game)
	var config := make_server_config(data_dir)
	config.max_players = 16
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var deadline := Time.get_ticks_msec() + 15000
	while (game.maps == null or game.maps.current == null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/g2g_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
