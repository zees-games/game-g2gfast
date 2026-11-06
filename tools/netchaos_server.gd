extends DotGameNetchaosServer

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## g2gfast's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): a timer server, no bots.

var _game: G2GGame = null


func _configure() -> void:
	map_id = "bhop_g2g_intro"


func _boot_world() -> void:
	var cfg := G2GConfig.new()
	cfg.records_directory = ""
	cfg.records_database = ""
	cfg.map_seconds = 0.0
	cfg.initial_map = StringName(map_id)
	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = cfg
	add_child(_game)
	# A server defaults to 60 Hz while the client runs the project's 128, and the clock snaps against the mismatch.
	var cfg_path := "%s/server.cfg" % data_dir
	var rate_file := FileAccess.open(cfg_path, FileAccess.WRITE)
	rate_file.store_line("sv_tickrate %d" % ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 128))
	rate_file.close()
	if not (await boot_server(cfg_path)).ok:
		return
	var deadline := Time.get_ticks_msec() + 15000
	while (_game.maps == null or _game.maps.current == null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/g2g_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("g2gfast")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _game.players.values()
