extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GVoteMapSource := preload("../game/g2g_vote_map_source.gd")

## What a subscribed map pack does to this game, against a fixture [DotContentIndex]
## registered as the process's shared one for the length of the run.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workshop.tscn
## [/codeblock]
##
## The points: a solo map is listed as "Name [Pack]" (catalogue, M rows, ballot), an online
## session lists none of it, a map kind the game does not accept is left out, a pack cannot
## take the id of a map the game has, and a chosen pack map actually loads: the scene is the
## world, the timer holds the pack's zones file and the player stands on its spawn zone.

const SECTIONS := 5
const CHECKS := 32
const MAP := &"fixture_hill"
const OTHER_KIND := &"fixture_sandbox"
const PREFIX := "res://examples/workshop_fixture/"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: Array[String] = []
var _index: DotContentIndex = null
var _game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — Workshop maps")
	_index = _make_index(DotContentIndex.SESSION_SOLO)
	DotRegistry.register(DotContentIndex.SERVICE, _index)
	_test_accepts()
	_test_catalogue()
	await _test_game()
	await _test_load()
	_test_online()
	DotRegistry.unregister(DotContentIndex.SERVICE)

	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var total_ok := _passed + _failed == CHECKS + 1
	if not total_ok:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS + 1])
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS or not total_ok else 0)


## A pack with a surf map, a sandbox map the game does not accept, and a map that claims the
## id of one of the game's own.
func _make_index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": PREFIX,
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Hill", "scene": "map.tscn",
				"zones": "zones.json", "map_kind": "surf"},
			{"kind": "map", "id": String(OTHER_KIND), "name": "Fixture Sandbox", "scene": "map.tscn",
				"map_kind": "sandbox"},
			{"kind": "map", "id": "surf_g2g_intro", "name": "Not The Intro", "scene": "map.tscn",
				"map_kind": "surf"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


func _names(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row: Dictionary in rows:
		out.append(str(row["name"]))
	return out


func _ballot_labels(catalogue: DotMapCatalogue) -> PackedStringArray:
	var out := PackedStringArray()
	var source := G2GVoteMapSource.new()
	source.catalogue = catalogue
	for choice in source.choices():
		out.append(choice.label())
	return out


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	var kinds := G2GMapCatalogue.accepted_map_kinds()
	_check(kinds == PackedStringArray(["surf", "bhop", "kz", "race"]), "provides.json accepts surf, bhop, kz and race", str(kinds))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "and only maps", str(accepts))
	_check((parsed as Dictionary).get("kinds") == ["game"], "and is a game pack")
	_completed += 1


func _test_catalogue() -> void:
	_entered += 1
	print("")
	print("solo catalogue and ballot")
	var catalogue := G2GMapCatalogue.discover(PackedStringArray(), _index)
	var def := catalogue.get_map(MAP)
	_check(def != null, "the accepted map is in the catalogue")
	_check(def != null and def.label() == "Fixture Hill [Fixture Pack]", "its label names the pack")
	_check(def != null and def.kind == &"surf" and G2GMapCatalogue.is_workshop(def), "it is a surf Workshop map")
	_check(def != null and def.zones_path == PREFIX + "zones.json", "its zones file is the pack's own")
	_check(catalogue.get_map(OTHER_KIND) == null, "a map kind the game does not accept is filtered out")
	var own := catalogue.get_map(&"surf_g2g_intro")
	_check(own != null and not G2GMapCatalogue.is_workshop(own) and own.label() == own.name_or_id(),
		"a pack map claiming a built-in id does not replace it")
	var labels := _ballot_labels(catalogue)
	_check(labels.has("Fixture Hill [Fixture Pack]"), "the ballot lists it as Name [Pack]", str(labels))
	_check(not labels.has("Fixture Sandbox [Fixture Pack]"), "and not the other kind")
	var rescan := G2GMapCatalogue.rescan(catalogue)
	_check(catalogue.has(MAP) and not (rescan["removed"] as Array).has(MAP),
		"a disk rescan does not drop a Workshop map for not being on disk")
	_completed += 1


func _boot() -> void:
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	_game = G2GGame.new()
	_game.config = config
	add_child(_game)
	for _i in range(120):
		await get_tree().process_frame
		if _game.maps != null and _game.maps.current != null:
			break


func _test_game() -> void:
	_entered += 1
	print("")
	print("the game's lists, solo")
	await _boot()
	_check(_game.maps != null and _game.maps.catalogue != null, "a game boots with a catalogue")
	var rows := _game.map_rows()
	_check(_names(rows).has("Fixture Hill [Fixture Pack]"), "the M rows name it Name [Pack]")
	_check(not _names(rows).has("Fixture Sandbox [Fixture Pack]"), "and not the other kind")
	var menu := G2GGame.menu_rows(rows)
	var tagged := menu.filter(func(r: Dictionary) -> bool: return str(r["name"]).begins_with("Fixture Hill"))
	_check(tagged.size() == 1 and (tagged[0]["tags"] as Array).has("Workshop"), "the menu tags it Workshop")
	_check(_ballot_labels(_game.maps.catalogue).has("Fixture Hill [Fixture Pack]"), "the game's ballot lists it")
	_completed += 1


func _test_load() -> void:
	_entered += 1
	print("")
	print("choosing a pack map")
	var player := _game.add_player(&"p1", "Tester", true)
	_check(player != null, "a player joins")
	var changed: DotResult = await _game.change_map(MAP)
	_check(changed.ok, "change_map succeeds", "" if changed.ok else changed.error.message)
	_check(_game.maps.current != null and _game.maps.current.id == MAP, "the map is current")
	var world := _game.maps.world
	_check(world != null and world.get_node_or_null("Floor") != null, "the pack's scene is the world")
	_check(_game.timers.zones != null and _game.timers.zones.first_of_kind(DotTimerZone.Kind.START, 0) != null
		and _game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0) != null,
		"the timer holds the pack's zones file (start and end)")
	var spawn := _game.timers.zones.first_of_kind(DotTimerZone.Kind.SPAWN, 0) if _game.timers.zones != null else null
	_check(spawn != null, "the zones file's spawn zone is there")
	var at: Vector3 = player.controller.state.position
	_check(spawn != null and at.distance_to(spawn.destination) < 0.01,
		"the player stands on the spawn zone", "%s vs %s" % [at, spawn.destination if spawn != null else "-"])
	_check(spawn != null and is_equal_approx(player.controller.state.yaw, spawn.destination_yaw),
		"and faces its yaw")
	for _i in range(30):
		await get_tree().physics_frame
	_check(player.controller.state.position.y > -0.5, "and the pack's collision holds them up",
		str(player.controller.state.position))
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var catalogue := G2GMapCatalogue.discover(PackedStringArray(), _index)
	_check(catalogue.get_map(MAP) != null, "listed while the index is solo")
	_index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(catalogue.get_map(MAP) == null, "gone from the same catalogue when the session turns online")
	_check(not _ballot_labels(catalogue).has("Fixture Hill [Fixture Pack]"), "gone from the ballot")
	var late := _make_index(DotContentIndex.SESSION_SOLO)
	late.set_session(DotContentIndex.SESSION_ONLINE)
	_check(G2GMapCatalogue.discover(PackedStringArray(), late).get_map(MAP) == null,
		"a catalogue built online never lists it")
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition
