extends SceneTree

const G2GClient := preload("../game/g2g_client.gd")

## The real offline client's map menu (M) with a Workshop map in it, to
## `screenshots/workshop_maplist_<page>.png`.
##
## The map is a fixture in a [DotContentIndex] this script registers as the shared one before
## the client is built, so the rows are the ones `G2GGame.map_rows` makes from a catalogue
## that followed it; nothing is drawn by hand. The fixture is `examples/workshop_fixture`.
## Run: `xvfb-run -a godot --path . --resolution 1600x900 --script tools/screenshot_workshop.gd`.
## Not `--headless`: a null renderer saves empty frames.

const OUT_DIR := "res://screenshots"
const SETTLE := 6
const FIRST_PAGE := 3

var _client: G2GClient = null
var _wait := 0
var _loaded := 0
var _step := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var index := DotContentIndex.new()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var _added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0",
		"prefix": "res://examples/workshop_fixture/",
		"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
		"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "fixture_hill", "name": "Fixture Hill", "scene": "map.tscn",
				"zones": "zones.json", "map_kind": "surf"},
			{"kind": "map", "id": "fixture_sandbox", "name": "Fixture Sandbox", "scene": "map.tscn",
				"map_kind": "sandbox"},
		]},
	})
	DotRegistry.register(DotContentIndex.SERVICE, index)
	OS.set_environment("G2G_INITIAL_MAP", "bhop_g2g_intro")
	_client = (load("res://game/g2g.tscn") as PackedScene).instantiate() as G2GClient
	_client.force_offline = true
	root.add_child(_client)


func _process(_delta: float) -> bool:
	if _client.player == null or _client.game == null or _client.game.maps.current == null:
		return false
	if _loaded < 60:
		_loaded += 1
		return false
	if _wait > 0:
		_wait -= 1
		return false
	match _step:
		0:
			_client.presentation.settings.local_store = DotSettingsStoreMemory.new()
			_client.presentation.settings.load_now()
			_client.presentation.apply_all()
			_client.open_map_list()
			# The game's own bhop maps fill the first pages; the menu opens on the current map's page, and a pack's map sorts in between bhop and surf.
			_client.menu.picker.turn(FIRST_PAGE)
		1, 2, 3:
			_capture("workshop_maplist_%d" % (_step - 1))
			_client.menu.picker.turn(1)
		_:
			quit(0)
			return true
	_step += 1
	_wait = SETTLE
	return false


func _capture(name: String) -> void:
	var image := root.get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT_DIR, name])
	print("wrote %s (%d x %d)" % [name, image.get_width(), image.get_height()])
