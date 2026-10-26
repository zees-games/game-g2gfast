extends SceneTree

## Rewrites cfg/game/game-g2gfast/config_*/game.yml from G2GConfig's fields: godot --headless --path . --script tools/cfg_templates.gd
## (cfg/ is tracked in this repository.)

const G2GConfig := preload("../game/g2g_config.gd")


func _init() -> void:
	var binder := G2GConfig.make_binder(G2GConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
