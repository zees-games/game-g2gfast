extends SceneTree
## Splits `maps/routes/<id>.surf.json` into one file per stage under `maps/routes/<id>.surf/`:
## `godot --headless --path . --script tools/split_surf_cache.gd -- <id>`. Leaves the legacy file.

const G2GSurfCourse := preload("../game/g2g_surf_course.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: split_surf_cache.gd -- <map id>")
		quit(2)
		return
	var id := StringName(args[0])
	var count := G2GSurfCourse.split_cache(G2GSurfCourse.cache_path(id), G2GSurfCourse.cache_dir(id))
	print("[split] %s: %d stage files in %s" % [id, count, G2GSurfCourse.cache_dir(id)])
	quit(0 if count > 0 else 1)
