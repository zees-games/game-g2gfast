extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## Bot soak on the real timer game: N bots ride one map for M simulated minutes through dot-bot's
## DotBotSoak, fed by dot-spawn's DotSpawnWatch. Bots here are the course riders of g2g_bots.gd.
##
## [codeblock]
## ./game.sh soak [map] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map surf_beginner --bots 4 --minutes 2
## [/codeblock]
##
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<map>.json, prints the SOAK line, exits 1 when the run fails.
## There is no combat here, so the harness's kill check is off and the kill columns stay 0.

const DEFAULT_MAP := &"bhop_g2g_intro"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 4
const TICK_RATE := 128

var _game: G2GGame
var _tick := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := StringName(_arg("map", String(DEFAULT_MAP)))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = &"bhop_g2g_intro"
	_game = G2GGame.new()
	_game.config = g2g_config
	_game.external_tick = true
	add_child(_game)
	for _i in range(120):
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break
	if _game.maps == null or _game.maps.current == null:
		_fail("the game never loaded a map")
		return
	if map_id != _game.maps.current.id:
		var changed: DotResult = await _game.change_map(map_id)
		if not changed.ok:
			_fail("map %s: %s" % [map_id, changed.error.message])
			return
	for i in range(cfg.bots):
		if _game.bots.call("add_bot", "bot%d" % (i + 1)) == null:
			_fail("bot %d refused" % (i + 1))
			return
	# Let the bots' route plan finish: they stand until it is done, which is not a stuck bot.
	for _i in range(40):
		await get_tree().process_frame

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	var course: Object = _game.bots.get("course")
	watch.rules.kill_y = (course.get("start") as Vector3).y - 400.0 if course != null else -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees and the background route plan run.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = String(map_id)
	report["bot_mode"] = String(_game.bots.get("mode"))
	report["rides"] = _game.bots.call("describe")["bots"].map(func(b: Dictionary) -> Dictionary:
		return {"rides": b.get("rides", 0), "arrived": b.get("arrived", 0), "stuck": b.get("stuck", 0), "fell": b.get("fell", 0)})
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a map still loaded at quit aborted the process on surf_greensway.
func _release_game() -> void:
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _step(_delta: float) -> void:
	_tick += 1
	_game.tick_once(_tick)


func _movers() -> Array:
	var out: Array = []
	for id: StringName in _game.bots.get("ids"):
		var player = _game.players.get(id)
		if player != null:
			out.append({"id": id, "position": player.controller.state.position, "kind": &"bot", "has_goal": true})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
