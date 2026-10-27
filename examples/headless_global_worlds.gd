extends DotGameCheckSuite

## The pilot of drawing imported maps through dot-map's world document (`g2g_global_worlds`): the switch is off by default and changes nothing; on, a map is drawn from `worlds/<id>` while its zones, spawns and collision stay the manifest's.
##
## [codeblock]
## godot --headless --path . res://examples/headless_global_worlds.tscn
## [/codeblock]

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GUnits := preload("../game/g2g_units.gd")

const PILOT := ["bhop_training_fun", "bhop_eazy", "bhop_aztec", "bunnyhop_pro", "bhop_amor", "bhop_eazy_v2", "bhop_grove", "surf_eclipse", "surf_year3000", "surf_greensway", "surf_beginner", "surf_kitsune"]
const CHECKS := 108
## A drawn share below this is a map that went back to flat colours; water and foliage cards are generated on purpose (aztec and beginner are a quarter water).
const MIN_PHOTO_SHARE := 0.7



func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: maps drawn from the dot-map world document")
	if not FileAccess.file_exists("res://worlds/%s.json" % PILOT[0]):
		print("SKIP: no worlds/ (g2gfast-maps/worlds is not linked)")
		get_tree().quit(0)
		return
	var catalogue := G2GMapCatalogue.discover()
	for id: String in PILOT:
		var def := catalogue.get_map(StringName(id))
		_check(def != null, "%s is in the catalogue" % id)
		if def == null:
			continue
		var legacy := _build(def, false)
		var global := _build(def, true)
		_check(legacy.global_world == null, "%s: the switch off draws nothing from the world document" % id)
		_check(global.global_world != null, "%s: the switch on builds the world document" % id)
		if global.global_world == null:
			continue
		var spawns: Array = global.global_world.spawn_points()
		var old: Array = global.manifest.get("spawns", [])
		var matched := 0
		for o: Dictionary in old:
			var at: Vector3 = G2GUnits.vector_to_metres(Vector3(o["origin"][0], o["origin"][1], o["origin"][2]))
			for s: Dictionary in spawns:
				if (s["origin"] as Vector3).distance_to(at) < 0.02:
					matched += 1
					break
		_check(spawns.size() == old.size() and matched == old.size(),
			"%s: the world's %d spawns are the manifest's %d, each within 2 cm (%d matched)" % [id, spawns.size(), old.size(), matched])
		var zl := legacy.timer_zones()
		var zg := global.timer_zones()
		_check(zl.zones.size() == zg.zones.size(), "%s: zones are the manifest's either way (%d)" % [id, zg.zones.size()])
		var start := zg.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
		if start != null:
			var inside := 0
			for s: Dictionary in spawns:
				if start.contains(s["origin"]):
					inside += 1
			var inside_old := 0
			for o: Dictionary in old:
				if start.contains(G2GUnits.vector_to_metres(Vector3(o["origin"][0], o["origin"][1], o["origin"][2]))):
					inside_old += 1
			# Surf maps spawn on every stage and some zones sit off the spawns: the world must agree with the manifest, not hold them all.
			_check(inside == inside_old, "%s: the START zone holds as many world spawns as the manifest's (%d of %d)" % [id, inside, spawns.size()])
		else:
			_check(true, "%s: a credit-only map has no START to hold spawns" % id)
		var seen := 0
		for mi in global.global_world.visual.find_children("*", "MeshInstance3D", true, false):
			seen += 1
		_check(seen > 0, "%s: the world document draws %d mesh instances" % [id, seen])
		var hidden_ok := true
		for mi in global.find_children("World*", "MeshInstance3D", false, false):
			hidden_ok = hidden_ok and not (mi as MeshInstance3D).visible
		_check(hidden_ok, "%s: the manifest's own meshes are hidden, not removed" % id)
		var share := _photo_share("res://worlds/%s.json" % id)
		_check(share >= MIN_PHOTO_SHARE, "%s: %d%% of the drawn area is a library photo set (not a flat colour)" % [id, roundi(share * 100.0)])
		legacy.free()
		global.free()
	print("")
	_report(CHECKS)


func _build(def: DotMapDef, on: bool) -> G2GBspMap:
	var map := (load(def.scene_path) as PackedScene).instantiate() as G2GBspMap
	map.global_worlds = on
	map.build_from(def)
	add_child(map)
	return map


## The share of a world document's surface area drawn from a `pbr:` set.
func _photo_share(path: String) -> float:
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var all := 0.0
	var photo := 0.0
	for s: Dictionary in doc.get("surfaces", []):
		var area := float(s.get("area", 0.0))
		all += area
		if str(s.get("free", "")).begins_with("pbr:"):
			photo += area
	return photo / all if all > 0.0 else 0.0

