extends Node

## G2GConfig through DotGameConfigBinder: fields, cvars, the deathmatch rules reading them, strict refusal, the diff.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const G2GArsenal := preload("../game/g2g_arsenal.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GMapMechanics := preload("../game/g2g_map_mechanics.gd")
const CHECKS := 12

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)


func _run() -> void:
	print("g2gfast: config binder")
	var config := G2GConfig.new()
	var binder := DotGameConfigBinder.create(config, "game-g2gfast", "g2g")
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	_check(binder.schema().size() >= 55, "every exported field is in the schema")
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	_check(console.get_int("g2g_score_limit") == 40 and console.get_int("g2g_max_players") == 64, "cvars start at the defaults")
	console.set_cvar("g2g_respawn_delay", "4")
	_check(config.respawn_delay == 4.0 and binder.source_of("respawn_delay") == "cvar", "a cvar writes the field")
	var rules := G2GArsenal.match_rules(config.score_limit, config.respawn_delay, config.spawn_protection)
	_check(rules.respawn_delay_sec == 4.0 and rules.spawn_protection_sec == 2.0, "the match rules read the config")
	_check(G2GArsenal.match_rules().respawn_delay_sec == 1.0, "and keep the old defaults without it")
	var mechanics := G2GMapMechanics.new()
	_check(mechanics.lethal_damage == config.lethal_damage, "the map mechanics start at the configured lethal damage")
	_check(binder.diff_yaml().contains("respawn_delay: 4"), "the diff names the edit")
	config.max_velocity = 10.0
	_check(not config.validate().ok, "validate refuses a max_velocity below max_speed")
	_check(binder.schema()[0]["description"].length() > 5, "doc comments reach the schema")
	_check(binder.write_schema("user://g2g_schema_check.json").ok, "write_schema works")
	print("%d passed, %d failed" % [_passed, _failed])
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)
