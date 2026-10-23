extends Node

## A map gets its shipped movement settings and the next map restores them, on the server's cvars and on a client's config.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]

const G2GMapConfig := preload("../game/g2g_map_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GConfig := preload("../game/g2g_config.gd")

const CHECKS := 10

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: per-map settings from cfg/game/game-g2gfast/dot_map/map")
	var console := DotConsole.new()
	add_child(console)
	console.cvar("sv_airaccelerate", "77", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_gravity", "800", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_replay_bot", "1", "", DotConVar.FLAG_ARCHIVE)
	var cfg := G2GMapConfig.build(console)
	var air := console.find_cvar("sv_airaccelerate")

	cfg.apply("surf_beginner")
	_check(air.get_float() == 150.0, "a surf map gets the game default 150 (%s)" % air.get_string())
	cfg.apply("surf_thriller")
	_check(air.get_float() == 100.0, "a map's own file beats the default")
	cfg.apply("bhop_eazy")
	_check(air.get_float() == 1000.0, "a bhop map gets 1000")
	cfg.apply("kz_bhop_lucid")
	_check(air.get_float() == 1000.0, "a kz_bhop map gets 1000")
	cfg.apply("something_else")
	_check(air.get_float() == 150.0, "any other map gets 150")
	_check(console.find_cvar("sv_replay_bot").get_int() == 1, "a cvar outside the whitelist is untouched")
	cfg.restore()
	_check(air.get_float() == 77.0, "restore puts the operator's value back")

	var game := G2GGame.new()
	game.config = G2GConfig.new()
	var client := DotGameClient.new()
	G2GMapConfig.wire_client(client, game)
	client.map_changed("surf_beginner")
	_check(game.config.air_accelerate == 150.0, "the client's config gets 150 on a surf map")
	client.map_changed("bhop_eazy")
	_check(game.config.air_accelerate == 1000.0, "the next map's value replaces it")
	client.map_changed("surf_thriller")
	_check(game.config.air_accelerate == 100.0, "and a map's own file wins on the client too")

	client.free()
	game.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s" % what)
