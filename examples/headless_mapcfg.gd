extends DotGameCheckSuite

## A map gets its shipped movement settings and the next map restores them, on the server's cvars and on a client's config.
## Run: godot --headless --path . res://examples/headless_mapcfg.tscn

const G2GMapConfig := preload("../game/g2g_map_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GConfig := preload("../game/g2g_config.gd")

const CHECKS := 14


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: per-map settings from cfg/game/game-g2gfast/dot_map/map")
	var console := DotConsole.new()
	add_child(console)
	console.cvar("sv_airaccelerate", "1000", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_gravity", "800", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_replay_bot", "1", "", DotConVar.FLAG_ARCHIVE)
	var cfg := G2GMapConfig.build(console)
	var air := console.find_cvar("sv_airaccelerate")

	cfg.apply("surf_beginner")
	_check(air.get_float() == 1000.0, "a surf map with no file of its own keeps the game default 1000 (%s)" % air.get_string())
	cfg.apply("surf_thriller")
	_check(air.get_float() == 100.0, "a map's own file beats the default")
	cfg.apply("bhop_eazy")
	_check(air.get_float() == 1000.0, "a bhop map gets 1000")
	cfg.apply("kz_bhop_lucid")
	_check(air.get_float() == 1000.0, "a kz_bhop map gets 1000")
	cfg.apply("something_else")
	_check(air.get_float() == 1000.0, "any other map keeps 1000")
	air.set_value("600")
	cfg.apply("something_else")
	_check(air.get_float() == 600.0, "the fallback does not clobber an operator's cvar value")
	cfg.apply("surf_thriller")
	_check(air.get_float() == 100.0, "armed: a map's own file does lower it")
	air.set_value("1000")
	var dir := "res://cfg/server/game/%s/dot_map/map" % G2GMapConfig.GAME_ID
	DirAccess.make_dir_recursive_absolute(dir)
	var op := "%s/zz_operator_test.yml" % dir
	var f := FileAccess.open(op, FileAccess.WRITE)
	f.store_string("sv_airaccelerate: 321\n")
	f.close()
	cfg.apply("zz_operator_test")
	var op_won := air.get_float() == 321.0
	DirAccess.remove_absolute(op)
	DirAccess.remove_absolute("res://cfg/server/game/%s/dot_map/map" % G2GMapConfig.GAME_ID)
	_check(op_won, "a cfg/server file beats the shipped default (%s)" % air.get_string())
	cfg.apply("something_else")
	_check(air.get_float() == 1000.0, "and the next map restores 1000")
	_check(console.find_cvar("sv_replay_bot").get_int() == 1, "a cvar outside the whitelist is untouched")
	cfg.restore()
	_check(air.get_float() == 1000.0, "restore puts the operator's value back")

	var game := G2GGame.new()
	game.config = G2GConfig.new()
	var client := DotGameClient.new()
	G2GMapConfig.wire_client(client, game)
	client.map_changed("surf_beginner")
	_check(game.config.air_accelerate == 1000.0, "the client's config keeps 1000 on a surf map with no file")
	client.map_changed("bhop_eazy")
	_check(game.config.air_accelerate == 1000.0, "the next map's value replaces it")
	client.map_changed("surf_thriller")
	_check(game.config.air_accelerate == 100.0, "and a map's own file wins on the client too")

	client.free()
	game.free()
	_report(CHECKS)
