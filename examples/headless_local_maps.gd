extends DotGameCheckSuite

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")

## Maps copied in by hand: a raw dot-map convert folder under `res://addons/maps/` or `user://maps/` is listed as
## `<name>_local` only while `G2GMapCatalogue.list_local` is on (the offline client), and a game loads it with a spawn
## that stands on its floor. The fixture runs everywhere; `-- --source=<a map's convert folder>` repeats it on a real map.
##
## [codeblock]
## ./game.sh test headless_local_maps
## ./game.sh test headless_local_maps -- --source=/path/to/gm_fork/convert
## [/codeblock]

const FIXTURE_DIR := "res://examples/local_maps"
## Folder names no player would choose, so a run only ever removes what it copied.
const RES_FOLDER := "res://addons/maps/zz_local_maps_suite"
const USER_FOLDER := "user://maps/zz_local_maps_suite"

var _source := ""
var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--source="):
			_source = a.trim_prefix("--source=")
	_run.call_deferred()


func _run() -> void:
	var expected := 3
	_clean()
	_test_listing()
	_clean()
	_copy_tree(FIXTURE_DIR, RES_FOLDER.path_join("convert"), ["fixture.json", "fixture.bin"])
	await _test_load(&"fixture_local", "res://addons/maps")
	_clean()
	_copy_tree(FIXTURE_DIR, USER_FOLDER, ["fixture.json", "fixture.bin"])
	await _test_load(&"fixture_local", "user://maps")
	if not _source.is_empty():
		expected += 2
		var name := DotMapLocalMaps.prefix_in(_source).get_file()
		if _check(not name.is_empty(), "the source holds a converted map", _source):
			var id := StringName(name + DotMapLocalMaps.ID_SUFFIX)
			_clean()
			_copy_tree(_source, RES_FOLDER.path_join("convert"))
			await _test_load(id, "res://addons/maps")
			_clean()
			_copy_tree(_source, USER_FOLDER)
			await _test_load(id, "user://maps")
	_clean()
	G2GMapCatalogue.list_local = false
	_report_sections(_entered, _finished, expected)


func _test_listing() -> void:
	_entered += 1
	print("-- listed offline only")
	_copy_tree(FIXTURE_DIR, RES_FOLDER.path_join("convert"), ["fixture.json", "fixture.bin"])
	G2GMapCatalogue.list_local = false
	_check(not _ids().has(&"fixture_local"), "a server's catalogue never lists a local map")
	G2GMapCatalogue.list_local = true
	var def: DotMapDef = null
	for map in G2GMapCatalogue.scan():
		if map.id == &"fixture_local":
			def = map
	_check(def != null, "an offline catalogue lists the copy as fixture_local", str(_ids()))
	_check(def != null and def.display_name.ends_with(DotMapLocalMaps.TAG), "titled (local)",
		"" if def == null else def.display_name)
	_check(def != null and def.scene_path == G2GMapCatalogue.IMPORTED_SCENE, "built by the imported map scene")
	# user://maps holds legacy imported maps too, at <id>/<id>.json, the layout this copy also has.
	DirAccess.make_dir_recursive_absolute(USER_FOLDER)
	for ext in [".json", ".bin"]:
		DirAccess.copy_absolute(FIXTURE_DIR.path_join("fixture" + ext), USER_FOLDER.path_join("zz_local_maps_suite" + ext))
	_check(_ids().has(&"zz_local_maps_suite_local"), "a copy named like its folder is listed as local")
	var legacy_ids := G2GMapCatalogue.scan().filter(func(m: DotMapDef) -> bool: return m.id == &"zz_local_maps_suite")
	_check(legacy_ids.is_empty(), "the mesh folder is not read as a legacy imported map")
	_finished += 1


func _test_load(id: StringName, root: String) -> void:
	_entered += 1
	print("-- %s from %s" % [id, root])
	G2GMapCatalogue.list_local = true
	var found := DotMapLocalMaps.find(id)
	_check(str(found.get("root", "")) == root, "found under %s" % root, str(found))
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = id
	var game := G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(240):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	var loaded := game.maps != null and game.maps.current != null and game.maps.current.id == id
	_check(loaded, "the game loads it", "" if not loaded else String(game.maps.current.id))
	var bsp := game.current_map_node() as G2GBspMap
	_check(bsp != null and bsp.local_prefix == str(found.get("prefix", "")), "its world is the copied folder",
		"" if bsp == null else bsp.local_prefix)
	_check(bsp != null and bsp.global_world != null and bsp.global_world.get_child_count() > 0, "the world is built")
	if bsp != null:
		await get_tree().physics_frame
		await get_tree().physics_frame
		var at := bsp.spawn_for(DotTimerTrack.MAIN)
		var hit := bsp.get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(at + Vector3.UP, at + Vector3.DOWN * 50.0))
		_check(not hit.is_empty(), "the spawn stands over its floor", str(at))
	game.queue_free()
	await get_tree().process_frame
	_finished += 1


func _ids() -> Array:
	return G2GMapCatalogue.scan().map(func(m: DotMapDef) -> StringName: return m.id)


func _clean() -> void:
	_wipe(RES_FOLDER)
	_wipe(USER_FOLDER)
	var parent := "res://addons/maps"
	if DirAccess.dir_exists_absolute(parent) and DirAccess.get_directories_at(parent).is_empty() \
			and DirAccess.get_files_at(parent).is_empty():
		DirAccess.remove_absolute(parent)


func _copy_tree(from_dir: String, to_dir: String, only: Array = []) -> int:
	DirAccess.make_dir_recursive_absolute(to_dir)
	var count := 0
	for n in DirAccess.get_files_at(from_dir):
		if (only.is_empty() or only.has(n)) and DirAccess.copy_absolute(from_dir.path_join(n), to_dir.path_join(n)) == OK:
			count += 1
	if only.is_empty():
		for d in DirAccess.get_directories_at(from_dir):
			count += _copy_tree(from_dir.path_join(d), to_dir.path_join(d))
	return count


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
