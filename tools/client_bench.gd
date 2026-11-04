extends DotGameClientBench

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## `--bots N` adds N course riders; `--play` supplies the movement.


func _configure() -> void:
	client_scene = "res://game/g2g.tscn"
	forward_action = &"dot_fps_forward"


func _boot_server(bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
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
	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = &"bhop_g2g_intro"
	var game := G2GGame.new()
	game.config = g2g_config
	add_child(game)
	for _i in 60:
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	(load("res://game/g2g_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/g2g_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for b in bots_wanted:
		if game.bots == null or game.bots.call("add_bot", "Bot%d" % b) == null:
			break
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
