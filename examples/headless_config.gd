extends DotGameCheckSuite

## G2GConfig through DotGameConfigBinder: fields, cvars, the deathmatch rules reading them, strict refusal, the diff.
## Run: godot --headless --path . res://examples/headless_config.tscn

const G2GArsenal := preload("../game/g2g_arsenal.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapMechanics := preload("../game/g2g_map_mechanics.gd")
const ROOT := "user://g2g_cfgtest"
const GAME := "game-g2gfast"
const CHECKS := 26


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("g2gfast: config binder")
	var config := G2GConfig.new()
	var binder := G2GConfig.make_binder(config)
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
	var fall := G2GGame.make_fall_rules()
	var _made := fall.bind_cvars(console.cvar, DotConVar.FLAG_NOTIFY)
	_check(console.get_int("sv_falldamage") == 0 and not fall.enabled, "fall damage is off in this game by default")
	_check(fall.damage_for(60.0) == 0.0, "a 60 m/s landing costs nothing while it is off")
	console.set_cvar("sv_falldamage", "1")
	_check(fall.enabled and fall.damage_for(60.0) > 0.0, "the cvar is the only way on (and it works)")
	var manager := DotCombatManager.new()
	var ff_rules := DotDamageRules.new()
	ff_rules.friendly_fire = config.friendly_fire
	manager.rules = ff_rules
	var _ff := manager.bind_cvars(console.cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	_check(console.get_int("mp_friendlyfire") == 1, "mp_friendlyfire starts at the game's rule (on)")
	console.set_cvar("mp_friendlyfire", "0")
	_check(not ff_rules.friendly_fire, "the cvar drives the damage rules")
	manager.free()
	_layers()
	_templates(binder)
	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for e: Dictionary in binder.schema():
		if not listed.has(e["key"]):
			missing.append(e["key"])
	_check(missing.is_empty() and binder.profile_sets().size() == 4, "the workbench lists every key over 4 files: " + ",".join(missing))
	wb.free()
	print("%d passed, %d failed" % [_passed, _failed])
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := G2GConfig.new()
	var binder := G2GConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s grav=%s grav_src=%s score=%s score_src=%s cvar=%s delay=%s delay_src=%s" % [
		loaded.ok, config.gravity, binder.source_of("gravity"), config.score_limit, binder.source_of("score_limit"),
		console.find_cvar("g2g_score_limit").get_string(), config.respawn_delay, binder.source_of("respawn_delay")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--g2g-respawn-delay=3.0"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_movement/game.yml" % GAME, "gravity: 650.0\n")
	_write("game/%s/config_modes/game.yml" % GAME, "score_limit: 10\n")
	OS.set_environment("G2G_SCORE_LIMIT", "25")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process: " + text.right(300))
	_check(text.contains("grav=650") and text.contains("grav_src=yml"), "a cfg file reaches the live config")
	_check(text.contains("score=25") and text.contains("score_src=env") and text.contains("cvar=25"), "the environment beats a file and reaches the cvar")
	_check(text.contains("delay=3") and text.contains("delay_src=argv"), "argv alone reaches the config")
	OS.unset_environment("G2G_SCORE_LIMIT")
	_write("game/%s/config_modes/game.yml" % GAME, "gravity: 650.0\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_movement", "config_modes"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with G2GConfig.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 4, "four shipped cfg files: %d" % files.size())
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd): " + ",".join(stale))
