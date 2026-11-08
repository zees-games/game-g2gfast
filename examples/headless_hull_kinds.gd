extends DotGameCheckSuite

## The importer's per-hull kinds reach the scene: a manifest with `collision.hull_kinds` tags those shapes (meta `hull_kind`) and an older manifest loads as all solid.
## Run: G2G_HULL_KIND_DIR=<dir of migrated maps, <id>/<id>.json> (or a copy in .hull_kinds_local/, never committed) godot --headless --path . res://examples/headless_hull_kinds.tscn
## The migrated maps are made locally by dot-map-convert/adapters/game-g2gfast/migrate_batch.py and never committed.

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const OLD := "res://maps/imported/bhop_eazy/bhop_eazy.json"
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: collision hull kinds")
	var root := OS.get_environment("G2G_HULL_KIND_DIR")
	# An offloaded run does not carry the environment: a local, uncommitted copy of the migrated maps can sit in the worktree instead.
	if root.is_empty() and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://.hull_kinds_local")):
		root = ProjectSettings.globalize_path("res://.hull_kinds_local")
	var ids: Array[String] = []
	if not root.is_empty():
		for id in DirAccess.get_directories_at(root):
			if FileAccess.file_exists(root.path_join(id).path_join("%s.json" % id)):
				ids.append(id)
	if ids.is_empty():
		print("SKIP: G2G_HULL_KIND_DIR names no migrated maps")
		get_tree().quit(0)
		return
	ids.sort()
	for id in ids:
		_section(id)
		var path := root.path_join(id).path_join("%s.json" % id)
		var info: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary).get("collision", {})
		var kinds: Dictionary = info.get("hull_kinds", {})
		_check(info.has("hull_kinds"), "%s: the manifest records hull_kinds" % id)
		var map := _build(path)
		var tagged := _tagged(map)
		var listed := 0
		var distinct := {}
		for kind: String in kinds:
			listed += (kinds[kind] as Array).size()
			for index: Variant in kinds[kind]:
				distinct[int(index)] = true
		_check(listed == distinct.size() and distinct.size() > 0, "%s: %d hulls are listed under a kind, none twice" % [id, listed])
		var max_index: int = distinct.keys().max() if not distinct.is_empty() else -1
		_check(max_index < int(info.get("hull_count", 0)), "%s: every listed index is a hull (of %d)" % [id, int(info.get("hull_count", 0))])
		_check(tagged.size() == listed, "%s: %d shapes carry a hull_kind (%d listed)" % [id, tagged.size(), listed])
		var by_kind := {}
		for s in tagged:
			by_kind[s.get_meta("hull_kind")] = int(by_kind.get(s.get_meta("hull_kind"), 0)) + 1
		var same := by_kind.size() == kinds.size()
		for kind: String in kinds:
			same = same and int(by_kind.get(kind, -1)) == (kinds[kind] as Array).size()
		_check(same and map.hull_kind_counts.size() == kinds.size(), "%s: the shapes per kind are the manifest's (%s)" % [id, str(by_kind)])
		var body := map.get_node("Solid") as StaticBody3D
		var expect := int(info.get("hull_count", 0)) + (1 if int(info.get("displacement_index_count", 0)) > 0 else 0)
		_check(body != null and body.get_child_count() == expect, "%s: one Solid body holds all %d shapes, as before" % [id, expect])
		map.free()
		_done()
	_section("an older manifest")
	if FileAccess.file_exists(OLD):
		var old: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string(OLD)) as Dictionary)
		var map := _build(OLD)
		if (old.get("collision", {}) as Dictionary).has("hull_kinds"):
			print("note: the linked bhop_eazy was already re-imported")
		else:
			_check(_tagged(map).is_empty() and map.hull_kind_counts.is_empty(), "no hull_kinds: every shape loads as solid")
		map.free()
	else:
		print("note: no linked maps/imported for the old-manifest case")
	_done()
	_report_sections(_entered, _completed, ids.size() + 1)


func _build(path: String) -> G2GBspMap:
	var map := (load("res://game/g2g_bsp_map.gd") as GDScript).new() as G2GBspMap
	map.build_from_path(path)
	add_child(map)
	return map


func _tagged(map: Node) -> Array:
	var out := []
	for s in map.find_children("*", "CollisionShape3D", true, false):
		if s.has_meta("hull_kind"):
			out.append(s)
	return out


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("== %s" % title)


func _done() -> void:
	_completed += 1
