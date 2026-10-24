extends Node

## The arena's config through the workbench: DotGameWorkbench over the binder's set, an edit, and the
## "Export changes as defaults" diff in the cfg/ layout.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workbench.tscn
## [/codeblock]

const G2GConfig := preload("../game/g2g_config.gd")
const CHECKS := 9

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
	print("g2gfast: workbench")
	var config := G2GConfig.new()
	var binder := DotGameConfigBinder.create(config, "game-g2gfast", "g2g")
	_check(binder.load_layers().ok, "defaults load")
	var wb := DotGameWorkbench.new()
	wb.panel_mode = 2
	wb.config = {"enabled": false}
	wb.add_set(binder.profile_set(), "Game settings")
	add_child(wb)
	var started := wb.start()
	_check(started.ok and started.value == true, "the workbench starts with a panel")
	binder.attach(wb.api.runtime)
	_check(wb.overlay != null and not wb.is_open(), "the window is built and closed")
	wb.open()
	_check(wb.is_open(), "F9 or the command opens it")
	_check(wb.console_command(PackedStringArray(["close"])) == "workbench closed", "the console command closes it")
	var set: DotProfileSet = binder.profile_set()
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "score_limit", "value": 25})
	_check(res.ok and config.score_limit == 25, "an edit in the window reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/game-g2gfast/config/game.yml", "")
	_check(text == "score_limit: 25\n", "the export holds just the changed field in the cfg layout")
	var other: Variant = wb.api.handle("somebody", {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "score_limit", "value": 26})
	_check(not other.ok, "another actor is refused without a permit")
	wb.permit_fn = func(actor: Variant, _flag: String) -> bool: return actor == "mod"
	_check(wb.api.handle("mod", {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "score_limit", "value": 27}).ok, "a permitted actor edits")
	print("%d passed, %d failed" % [_passed, _failed])
	wb.free()
	
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)
