extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMap := preload("../game/g2g_map.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GMapSurvey := preload("../game/g2g_map_survey.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const SurfIntro := preload("res://maps/surf_g2g_intro.gd")
const BhopStages := preload("res://maps/bhop_g2g_stages.gd")

## Checks that maps are found rather than listed, and that dropping one in or out
## reaches a running game.
##
## [codeblock]
## godot --headless --path . res://examples/headless_maps.tscn
## [/codeblock]
##
## [b]The check that matters is the negative one.[/b] Discovery finding three maps
## proves nothing on its own — a hardcoded list of three finds three too. What says
## there is no list is that a map the catalogue holds and the disk does not is
## *removed*, and one the disk holds and the catalogue does not is *added*, without
## anybody naming either.

## Checks that do not depend on how many maps are on disk. `_test_zones_have_floor`
## adds one per hand-written map and `_test_maps_are_surveyed` six, which is a number
## this file deliberately does not write down -- see [method _test_zones_have_floor].
const EXPECTED_FIXED_CHECKS := 39

## Checks each hand-written map adds: one for its zones' floor, one for the collision audit, six for its survey.
const CHECKS_PER_MAP := 8

const CHECKS := 63

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 8

## Hand-written maps whose survey finds a tilted slab a player can STAND on, and how
## many. Asserted both ways, like `headless_imported`'s `ARRIVES_IN_PIT`: a map not
## listed must have none, and a listed one must still have exactly this many, so the
## entry goes stale the day the slab is fixed rather than excusing the next one.
##
## `bhop_g2g_stages`' surf bonus is two 45° slabs, and this game's slope limit is
## 45.57°: a player stands on both, so the bonus is a walk down a pair of steep floors
## rather than surf. It is a scored track and reshaping it is Christian's call, not a
## suite's (`[gate-sweep-2]`, 2026-09-27).
## Maps known to have a tilted slab a player can stand on. `bhop_g2g_stages`' surf bonus was
## two, until its slabs were steepened past 45.57 (`[stages-slabs-1]`); none now, and the
## check below fails the moment a map gains one.
const STANDABLE_RAMPS := {}

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — map discovery")
	print("")
	_test_discovery()
	_test_scan_order()
	_test_derivations()
	await _test_rescan()
	_test_rotation_file()
	await _test_client_config()
	await _test_zones_have_floor()
	_test_maps_are_surveyed()

	print("")
	var expected := EXPECTED_FIXED_CHECKS + _hand_written_map_ids().size() * CHECKS_PER_MAP
	if _passed + _failed != expected:
		_failed += 1
		_failures.append("the suite ran %d checks and should run %d — one aborted"
			% [_passed + _failed, expected])
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
		print("  FAIL  %s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])


func _test_discovery() -> void:
	_section("discovery")
	var catalogue := G2GMapCatalogue.discover()
	_check(catalogue.size() >= 3, "the hand-written maps are found without being named",
		"%d maps" % catalogue.size())
	_check(catalogue.has(&"surf_g2g_intro") and catalogue.has(&"bhop_g2g_intro")
		and catalogue.has(&"bhop_g2g_stages"), "all three of them")
	_check(catalogue.problems().is_empty(), "and the catalogue is well formed",
		", ".join(catalogue.problems()))

	var surf := catalogue.get_map(&"surf_g2g_intro")
	# The tier comes out of the map's own zones file, which is generated from the map.
	# A tier read from a list beside the map is a tier that can disagree with it.
	_check(surf != null and surf.tier == 3, "a map's tier comes from its own sidecar",
		"tier %d" % (surf.tier if surf else -1))
	_check(surf != null and surf.kind == DotMapDef.KIND_SURF, "and its kind")
	_check(surf != null and surf.scene_path == "res://maps/surf_g2g_intro.tscn",
		"and its scene path")

	var imported := 0
	for map in catalogue.maps:
		if bool(map.meta.get("imported", false)):
			imported += 1
	# Zero is legitimate: maps/imported/ is optional content.
	_check(imported >= 0, "imported maps are counted separately", "%d imported" % imported)
	if imported > 0:
		var one: DotMapDef = null
		for map in catalogue.maps:
			if bool(map.meta.get("imported", false)):
				one = map
				break
		# The invariant that makes a map droppable: its scene is the ONE that ships in
		# the build, and its identity is a manifest path. A per-map scene under
		# res://maps/imported/ would be baked in at export and could never arrive
		# afterwards, which is the whole failure this shape exists to avoid.
		_check(one.scene_path == G2GMapCatalogue.IMPORTED_SCENE
			and ResourceLoader.exists(one.scene_path),
			"an imported map uses the shared scene that ships in the build",
			one.scene_path)
		_check(not str(one.meta.get("manifest", "")).is_empty(),
			"and carries its manifest path instead of a script")
	else:
		_check(true, "an imported map uses the shared scene (none present)")
		_check(true, "and carries its manifest path instead of a script (none present)")
	_done()


## scan() promises maps "sorted by id so two scans agree", and a rotation with no file
## cycles in that order. It sorted with `a.id < b.id` on StringNames, which Godot 4.7.2
## orders by where each name was interned, not by text, so the order differed per process.
##
## [b]Armed on purpose.[/b] A clean checkout has three hand-written maps, and three names
## can fall in text order by luck. So twenty fresh random ids go into a root of their
## own, interned in a shuffled order before the scan sees them, and the first check says
## the StringName order of those ids really is not text order -- without it, a pass here
## would not prove the sort compares text.
func _test_scan_order() -> void:
	_section("scan order")
	var root := "user://g2g_scan_order_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261011
	# Which pointer a fresh name gets is the allocator's call, so a given interning order
	# can still come out in text order (it did, once in two runs, interning in reverse).
	# Fresh names each attempt -- one already interned keeps its place -- until the
	# StringName order is not text order, which the first check then states.
	var ids: Array[String] = []
	var by_text: Array[String] = []
	var interned: Array[StringName] = []
	var name_order: Array[String] = []
	for attempt in range(8):
		ids.clear()
		interned.clear()
		while ids.size() < 20:
			var id := "zz_order%d_" % attempt
			for _i in range(6):
				id += char(97 + rng.randi() % 26)
			if not ids.has(id):
				ids.append(id)
		by_text = ids.duplicate()
		by_text.sort()
		var shuffled := ids.duplicate()
		for i in range(shuffled.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var held: String = shuffled[i]
			shuffled[i] = shuffled[j]
			shuffled[j] = held
		for id: String in shuffled:
			interned.append(StringName(id))
		var as_names := interned.duplicate()
		as_names.sort_custom(func(a: StringName, b: StringName) -> bool: return a < b)
		name_order.clear()
		for id: StringName in as_names:
			name_order.append(String(id))
		if name_order != by_text:
			break
	for id in ids:
		DirAccess.make_dir_recursive_absolute("%s/%s" % [root, id])
		var manifest := FileAccess.open("%s/%s/%s.json" % [root, id, id], FileAccess.WRITE)
		manifest.store_string("{\"tier\": 1}")
		manifest.close()
		FileAccess.open("%s/%s/%s.bin" % [root, id, id], FileAccess.WRITE).close()

	_check(name_order != by_text,
		"armed: these ids compared as StringNames are not in text order",
		", ".join(name_order.slice(0, 4)))

	var scanned: Array[String] = []
	for map in G2GMapCatalogue.scan(PackedStringArray([root])):
		scanned.append(String(map.id))
	var sorted := scanned.duplicate()
	sorted.sort()
	_check(scanned == sorted, "scan() lists every map by id as text",
		", ".join(scanned.slice(0, 6)))
	var fixtures: Array[String] = []
	for id in scanned:
		if id.begins_with("zz_order"):
			fixtures.append(id)
	_check(fixtures == by_text, "and finds all twenty in a root of their own",
		"%d found" % fixtures.size())

	var listed: Array[String] = []
	for map in G2GMapCatalogue.discover(PackedStringArray([root])).maps:
		listed.append(String(map.id))
	_check(listed == scanned, "and the catalogue a rotation cycles keeps that order")

	for id in ids:
		DirAccess.remove_absolute("%s/%s/%s.json" % [root, id, id])
		DirAccess.remove_absolute("%s/%s/%s.bin" % [root, id, id])
		DirAccess.remove_absolute("%s/%s" % [root, id])
	DirAccess.remove_absolute(root)
	interned.clear()
	_done()


func _test_derivations() -> void:
	_section("derivations")
	_check(G2GMapCatalogue.kind_of(&"surf_kitsune") == DotMapDef.KIND_SURF,
		"a surf_ prefix means surf")
	_check(G2GMapCatalogue.kind_of(&"bhop_g2g_stages") == DotMapDef.KIND_BHOP,
		"a bhop_ prefix means bhop")
	# The fallback has to be a real kind, not the empty StringName: DotMapDef.kind
	# feeds the rotation's filter, and a map of kind "" is a map nothing selects.
	_check(G2GMapCatalogue.kind_of(&"something_else") != &"",
		"and an unprefixed id still gets a kind")
	_check(G2GMapCatalogue.default_name(&"surf_kitsune") == "surf: kitsune",
		"a name is derived when the map does not carry one",
		G2GMapCatalogue.default_name(&"surf_kitsune"))
	_done()


func _test_rescan() -> void:
	_section("rescan")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	# The default first map is an imported one, which a checkout without g2gfast-maps (CI)
	# does not hold; that logs an ERR for a map this section never looks at.
	config.initial_map = &"bhop_g2g_intro"
	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	_check(game.maps != null and game.maps.catalogue != null, "a game boots with a catalogue")

	var before := game.maps.catalogue.size()

	# Drop one OUT of the catalogue while it is still on disk. A rescan must put it
	# back, and it can only do that by looking.
	var victim: StringName = game.maps.catalogue.maps[0].id
	game.maps.catalogue.remove(victim)
	_check(not game.maps.catalogue.has(victim), "a map removed from the catalogue is gone")
	var change := game.rescan_maps()
	_check(game.maps.catalogue.has(victim), "and a rescan finds it on disk again",
		String(victim))
	_check((change["added"] as Array).has(victim), "and reports it as added")

	# Drop one IN that is not on disk. A rescan must take it away.
	var ghost := DotMapDef.new()
	ghost.id = &"surf_not_on_disk"
	ghost.scene_path = "res://maps/surf_not_on_disk.tscn"
	ghost.kind = DotMapDef.KIND_SURF
	game.maps.catalogue.add(ghost)
	_check(game.maps.catalogue.has(&"surf_not_on_disk"), "a map with no files can be added")
	change = game.rescan_maps()
	_check(not game.maps.catalogue.has(&"surf_not_on_disk"),
		"and a rescan takes it away again")
	_check((change["removed"] as Array).has(&"surf_not_on_disk"), "and reports it as removed")
	_check(game.maps.catalogue.size() == before, "leaving the catalogue where it started",
		"%d vs %d" % [game.maps.catalogue.size(), before])

	# The rotation reads the catalogue live. Replacing the object instead of mutating
	# it leaves the rotation offering exactly the maps that are no longer there.
	_check(game.maps.rotation != null and game.maps.rotation.catalogue == game.maps.catalogue,
		"and the rotation still points at the catalogue it was given")
	_done()


## `cfg/maps.yml`: the maps a server rotates and what it does to the catalogue -- the unlisted
## ones stay installed, out of rotation, and on the map list. The format's own checks are
## dot-map's selftest; this is what the GAME does with it.
func _test_rotation_file() -> void:
	_section("rotation file")
	# Applied to a game: listed in, unlisted out, nothing removed.
	var all_before := game.maps.catalogue.size()
	var parsed := DotMapRotationFile.from_trees([{"defaults": {"maps": ["bhop_g2g_intro"]}}], "game-g2gfast")
	game.rotation_file = parsed.value
	game.apply_rotation()
	var pool := game.maps.rotation.pool()
	_check(pool.size() == 1 and pool[0].id == &"bhop_g2g_intro" and game.maps.catalogue.size() == all_before,
		"a rotation file leaves the others installed and out of the pool", "%d in the pool" % pool.size())
	var rows := game.map_rows()
	var out_count := 0
	for row: Dictionary in rows:
		if not bool(row["rotation"]):
			out_count += 1
	_check(rows.size() == all_before and out_count == all_before - 1,
		"and the map list shows every map, the unlisted ones marked", "%d rows, %d out" % [rows.size(), out_count])

	# No file: everything rotates except a combat map.
	var arena := DotMapDef.new()
	arena.id = &"surf_combat_test"
	arena.kind = DotMapDef.KIND_ARENA
	game.maps.catalogue.add(arena)
	var empty := DotMapRotationFile.from_trees([{"defaults": {"maps": ["no_such_map_*"]}}], "game-g2gfast")
	game.rotation_file = empty.value
	game.apply_rotation()
	_check(not game.in_rotation(&"surf_combat_test") and game.in_rotation(&"bhop_g2g_intro"),
		"an empty rotation falls back to what no file does, so a combat map stays out")
	game.rotation_file = null
	game.apply_rotation()
	_check(not game.in_rotation(&"surf_combat_test") and game.in_rotation(&"bhop_g2g_intro"),
		"with no file, every map rotates but a combat one")
	game.maps.catalogue.remove(&"surf_combat_test")
	_check(game.config.offline_map_seconds == 0.0, "and a game played alone has no time limit by default")
	_done()


func _test_client_config() -> void:
	_section("client configuration")
	# The client used to build a bare G2GConfig and never read a layer, so it was the
	# one thing here that could not be configured. This asserts the layering runs at
	# all; which layer wins is DotConfig's own contract and is tested there.
	var config := G2GConfig.new()
	var before := config.initial_map
	var layered := config.load_layered()
	_check(layered.ok, "a G2GConfig loads its layers",
		layered.error.message if not layered.ok else "")
	_check(config.initial_map != &"" or before == &"",
		"and still names a map afterwards", String(config.initial_map))
	_done()


## Every zone a player has to STAND in has geometry under it.
##
## [b]This is the check that was missing, and a map shipped for months without it.[/b]
## `bhop_g2g_stages` drew its finish pad 384 units along world -Z and placed its finish
## zone 384 units along the COURSE HEADING, which is -X after the turn in stage 2 —
## 543 units apart, overlapping by a corner nothing lands on. The player ran the whole
## map, arrived on a pad drawn in the finish colour, stopped, and the timer counted on
## for ever. Every existing assertion passed: the zone set is well formed, the stages
## are numbered, the tier is right, the kind is right. **They are all about the zones
## and none of them was about the zones adding up to a run.**
##
## A raycast is what says so, because it is the only question that crosses from the
## zone set into the geometry: drop a ray down the middle of every START, END and STAGE
## volume and require it to land inside that volume. A zone hanging in the air over
## nothing is a zone the run never reaches, and it looks exactly like a map with a
## missing end zone from inside the game.
##
## Over the maps the catalogue FINDS, and not over a list of them. A list of three ids
## here is the bug the catalogue exists to prevent, one level up, and this tree has
## already had it in `setup.sh`, `tools/check.sh`, `tools/package_check.sh`, both
## bootstrap scripts, `tools/export_zones.gd` and `headless_run`'s sidecar check — where
## a fourth map would simply not have been looked at, silently.
func _test_zones_have_floor() -> void:
	_section("zones sit on the geometry")

	for id in _hand_written_map_ids():
		var scene: PackedScene = load("res://maps/%s.tscn" % id)
		var map := scene.instantiate() as G2GMap
		add_child(map)

		# Two, because `add_child` puts the bodies in the space and the space is
		# flushed at the next step: a ray cast in the same frame hits nothing at all,
		# which reads as every zone in the map being broken.
		await get_tree().physics_frame
		await get_tree().physics_frame

		var space := map.get_world_3d().direct_space_state

		var floating := PackedStringArray()

		for zone: DotTimerZone in map.timer_zones().zones:
			if zone.kind != DotTimerZone.Kind.START \
					and zone.kind != DotTimerZone.Kind.END \
					and zone.kind != DotTimerZone.Kind.STAGE:
				continue

			var centre := zone.centre()
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(centre.x, zone.to.y, centre.z),
				# A hair below the floor of the zone, because the pad's top surface IS
				# the zone's lower bound on every map here and a ray that stops exactly
				# on it is a coin toss in 32-bit.
				Vector3(centre.x, zone.from.y - 0.05, centre.z)
			)

			if not space.intersect_ray(query):
				floating.append("%s %d" % [
					DotTimerZone.kind_name(zone.kind), zone.track
				])

		_check(floating.is_empty(),
			"%s stands every zone on something" % id, ", ".join(floating))

		# dot-core's audit: drawn geometry with no shape near it, which a player walks through.
		# Lenient (`anywhere`), as the drawing and the solids may sit in different subtrees.
		var audit := DotCollisionAudit.audit(map, true)
		var report: DotCollisionAudit = audit.value if audit.ok else null
		if report != null and report.count() > 0:
			for line in report.describe_lines().slice(0, 12):
				print("    %s" % line)
		_check(report != null and report.examined > 0 and report.count() == 0,
			"%s: nothing drawn is walked through" % id,
			audit.error.message if not audit.ok else "%d findings of %d examined" % [report.count(), report.examined])

		map.queue_free()
		await get_tree().process_frame
	_done()


# --- The survey ---------------------------------------------------------------

## Every hand-written map, swept for slots narrower than a player, ground no spawn and no
## `!s<n>` reaches, ground that leads nowhere, and starts that stand on nothing
## (`[gate-sweep-1]`, `[gate-sweep-2]`). See [G2GMapSurvey] for what reach means here and
## why a surf ramp is a surface slid on rather than a floor.
##
## [b]The survey is asked about a fixture first, so a sweep that finds nothing is known to
## be looking.[/b] Three maps passing clean says nothing about a detector that cannot fire;
## the fixture has one of each thing it looks for, and each is asserted found.
func _test_maps_are_surveyed() -> void:
	_section("the hand-written maps, surveyed for slots, unreached ground and traps")
	var t := G2GMovement.tunables_for(G2GConfig.new())
	var tick_rate := Engine.physics_ticks_per_second

	_the_survey_sees_what_it_looks_for(t, tick_rate)

	for id: String in _hand_written_map_ids():
		var script := load("res://maps/%s.gd" % id) as GDScript
		var map: Node3D = script.new()
		map.call("_build")

		var zones: DotTimerZoneSet = script.build_zones()
		var starts: Array[Vector3] = []
		for zone in zones.zones:
			if zone.kind == DotTimerZone.Kind.SPAWN or zone.kind == DotTimerZone.Kind.STAGE:
				starts.append(G2GUnits.vector_to_units(zone.destination))

		var declared := _survey_declared(id)
		var started := Time.get_ticks_msec()
		var found: Dictionary = G2GMapSurvey.survey(map, zones, starts, declared, t, tick_rate)
		map.free()

		print("    %s: %d standable cells (%d reached) in %d regions, %d starts, %d declared, %d course links, %d ms" % [
			id, int(found["cells"]), int(found["reached_cells"]), int(found["regions"]),
			starts.size(), declared.size(), int(found["course_links"]),
			Time.get_ticks_msec() - started,
		])
		for line: String in found["standable_tilted"]:
			print("      a slab a player can stand on: %s" % line)

		_check((found["startless"] as Array).is_empty(),
			"%s: every spawn and stage destination lands on standable ground" % id,
			", ".join(found["startless"]))
		_check((found["slots"] as Array).is_empty(),
			"%s: no two solids leave a slot narrower than a player" % id,
			"; ".join(found["slots"]))
		_check((found["unreached"] as Array).is_empty()
				and (found["stale_declarations"] as Array).is_empty(),
			"%s: nothing standable is out of reach of every start, but what is declared" % id,
			"unreached: %s; declared and reached: %s" % [
				"; ".join(found["unreached"]), "; ".join(found["stale_declarations"]),
			])
		_check((found["trapped"] as Array).is_empty(),
			"%s: and nowhere a start reaches is a place with no way out" % id,
			"; ".join(found["trapped"]))
		_check((found["course_problems"] as Array).is_empty(),
			"%s: every course it declares is a way forward the survey can follow" % id,
			"; ".join(found["course_problems"]))
		var ramps := (found["standable_tilted"] as Array).size()
		_check(ramps == int(STANDABLE_RAMPS.get(id, 0)),
			"%s: stands on as many tilted slabs as STANDABLE_RAMPS says" % id,
			"%d found, %d listed" % [ramps, int(STANDABLE_RAMPS.get(id, 0))])

	_done()


## What a hand-written map knows no start reaches, in units, and why.
##
## [b]Here rather than on the map, for tonight.[/b] game-playground's maps carry their own
## `survey_declared()`; these three were being edited elsewhere when the survey arrived,
## so the declarations sit beside the check and are read off each map's own constants.
## Every one is asserted to still cover something unreached, so none can outlive the
## ground it excuses.
func _survey_declared(id: String) -> Array:
	if id == "bhop_g2g_stages":
		return _stages_declared()
	if id != "surf_g2g_intro":
		return []

	var angle := deg_to_rad(SurfIntro.RAMP_ANGLE)
	var out := cos(angle) * SurfIntro.BONUS_BANK_WIDTH * 0.5
	var lift := sin(angle) * SurfIntro.BONUS_BANK_WIDTH * 0.5
	var bank_high_x := SurfIntro.BONUS_BANK_X + out
	var bank_top := SurfIntro.BONUS_BANK_Y + lift
	var bank_z := SurfIntro.BONUS_BANK_Z
	# The transfer's first bank is literals in `_build`: centred (-1536, START_Y - 250),
	# 768 wide, 1600 long, banked the other way, so its high edge is its -X one.
	var transfer_high_x := -1536.0 - out
	var transfer_top := SurfIntro.START_Y - 250.0 + lift

	return [
		{
			"box": AABB(Vector3(-384.0, SurfIntro.START_Y + 136.0, SurfIntro.START_Z + 496.0),
				Vector3(768.0, 16.0, 48.0)),
			"why": "the top of the start pad's back wall, 144 u over the pad: a wall",
		},
		{
			"box": AABB(Vector3(bank_high_x - 32.0, bank_top - 32.0,
				bank_z - SurfIntro.BONUS_BANK_LENGTH * 0.5 - 16.0),
				Vector3(64.0, 64.0, SurfIntro.BONUS_BANK_LENGTH + 32.0)),
			"why": "bonus 1's bank, its high lip: the slab's 32-u edge face, 30° from level, above its pad",
		},
		{
			"box": AABB(Vector3(transfer_high_x - 32.0, transfer_top - 32.0, SurfIntro.START_Z - 1416.0),
				Vector3(64.0, 64.0, 1632.0)),
			"why": "the transfer's first bank, its high lip: the same edge face, above its pad",
		},
		{
			"box": AABB(Vector3(SurfIntro.BONUS_X - SurfIntro.BONUS_FINISH_SIZE * 0.5,
				SurfIntro.BONUS_FINISH_Y - 16.0,
				SurfIntro.BONUS_FINISH_Z - SurfIntro.BONUS_FINISH_LENGTH * 0.5),
				Vector3(SurfIntro.BONUS_FINISH_SIZE, 32.0, SurfIntro.BONUS_FINISH_LENGTH)),
			"why": "bonus 1's finish pad: reached by the flight off the bank's end, which is speed and so a rider's, not a survey's; `headless_run`'s single bank rides it into the finish with no reset",
		},
	]


## `bhop_g2g_stages`' surf bonus since its slabs were steepened past standing
## (`[stages-slabs-1]`): each slab's high lip (its 64-u end face, standable) and the finish
## pad, which is reached by the ride along the slabs' crease and so is speed, not a survey's.
## Read off the map's own constants, as the slabs are built.
func _stages_declared() -> Array:
	var out: Array = []
	var centre_z := BhopStages.START_Z - 1536.0
	for side in [1.0, -1.0]:
		var turn := Basis(Vector3.FORWARD, deg_to_rad(side * (90.0 - BhopStages.BONUS_RAMP_PITCH)))
		var centre := Vector3(BhopStages.BONUS_X + side * 384.0, BhopStages.FLOOR_Y + 320.0, centre_z)
		var lip := centre + turn * Vector3(0.0, 768.0, 0.0)
		out.append({
			"box": AABB(Vector3(lip.x - 64.0, lip.y - 64.0, centre_z - 1296.0), Vector3(128.0, 128.0, 2592.0)),
			"why": "the surf bonus's %s slab, its high lip: the slab's 64-u end face, above its pad" % ("east" if side > 0.0 else "west"),
		})
	out.append({
		"box": AABB(Vector3(BhopStages.BONUS_X - 384.0, BhopStages.FLOOR_Y - 384.0 - 32.0, BhopStages.START_Z - 3072.0 - 384.0),
			Vector3(768.0, 64.0, 768.0)),
		"why": "the surf bonus's finish pad: reached by riding the slabs' crease, which is speed and a rider's; `headless_run` rides it into the finish",
	})
	return out


## A floor with one of everything on it, in units: a 20-unit slot between two walls, a
## platform 300 units up, a cellar a player drops into and cannot climb out of, a start
## over nothing, a start over a 60° face that slides off it into a pit, and a 45° slab a
## player can stand on.
func _the_survey_sees_what_it_looks_for(t: DotFpsTunables, tick_rate: int) -> void:
	var tilt := func(degrees: float) -> Basis: return Basis(Vector3.FORWARD, deg_to_rad(degrees))
	var solids: Array[G2GMapSurvey.Solid] = [
		G2GMapSurvey.solid(Vector3(0.0, -16.0, 0.0), Vector3(1024.0, 32.0, 1024.0)),
		# The slot: two walls 20 units apart, side by side for 64.
		G2GMapSurvey.solid(Vector3(-200.0, 64.0, -300.0), Vector3(128.0, 128.0, 64.0)),
		G2GMapSurvey.solid(Vector3(-52.0, 64.0, -300.0), Vector3(128.0, 128.0, 64.0)),
		# Out of reach: 300 up, nothing to climb.
		G2GMapSurvey.solid(Vector3(-300.0, 300.0, 300.0), Vector3(192.0, 16.0, 192.0)),
		# The cellar: 200 under the floor's east edge, walled on its other three sides.
		G2GMapSurvey.solid(Vector3(704.0, -216.0, 0.0), Vector3(384.0, 32.0, 384.0)),
		G2GMapSurvey.solid(Vector3(912.0, -50.0, 0.0), Vector3(32.0, 300.0, 448.0)),
		G2GMapSurvey.solid(Vector3(704.0, -50.0, 208.0), Vector3(448.0, 300.0, 32.0)),
		G2GMapSurvey.solid(Vector3(704.0, -50.0, -208.0), Vector3(448.0, 300.0, 32.0)),
		# A surf face, far from everything, over a pit.
		G2GMapSurvey.solid(Vector3(3000.0, 0.0, 0.0), Vector3(512.0, 32.0, 512.0), tilt.call(60.0)),
		# A slab steep enough to look like one and shallow enough to stand on.
		G2GMapSurvey.solid(Vector3(-3000.0, 0.0, 0.0), Vector3(512.0, 32.0, 512.0), tilt.call(45.0)),
	]

	# Everything nobody is meant to reach — wall tops, both slabs' edges — declared the
	# way a map declares its walls, so the fixture asks only the questions it is about.
	var walls: Array = []
	for i in [1, 2, 5, 6, 7, 8, 9]:
		walls.append({"box": solids[i].bounds.grow(8.0), "why": "a fixture wall %d" % i})

	var spawn := Vector3(0.0, 8.0, 0.0)
	var starts: Array[Vector3] = [spawn, Vector3(0.0, 100.0, 5000.0), Vector3(3000.0, 400.0, 0.0)]
	var pits := DotTimerZoneSet.new()
	var under_ramp := DotTimerZone.make(DotTimerZone.Kind.RESPAWN)
	under_ramp.set_box(G2GUnits.vector_to_metres(Vector3(2000.0, -2000.0, -1000.0)),
		G2GUnits.vector_to_metres(Vector3(4000.0, -600.0, 1000.0)))
	pits.add(under_ramp)
	var found: Dictionary = G2GMapSurvey.survey_solids(solids, pits, starts, walls, t, tick_rate)

	_check((found["slots"] as Array).size() == 1 and str(found["slots"][0]).begins_with("20 u"),
		"the survey finds the fixture's one slot", "; ".join(found["slots"]))
	_check((found["unreached"] as Array).size() == 1
			and str((found["unreached"] as Array)[0]).contains(", 308, "),
		"and the platform nobody can reach", "; ".join(found["unreached"]))
	_check((found["trapped"] as Array).size() == 1
			and str((found["trapped"] as Array)[0]).contains("-200"),
		"and the cellar nobody can leave", "; ".join(found["trapped"]))
	var startless: Array = found["startless"]
	_check(startless.size() == 2 and str(startless[0]).ends_with("over nothing")
			and str(startless[1]).ends_with("falls into a pit"),
		"and a start over nothing, and one on a 60° face, which slides off it into the pit",
		"; ".join(startless))
	var tilted: Array = found["standable_tilted"]
	_check(tilted.size() == 1 and str(tilted[0]).contains("(-3000,") and str(tilted[0]).contains("45.0°"),
		"a 45° slab is one a player stands on, and a 60° one is not",
		"; ".join(tilted))

	# Declared, the platform is not reported; a reset in the cellar is a way out of it.
	var declared: Array = walls.duplicate()
	declared.append({"box": AABB(Vector3(-400.0, 290.0, 200.0), Vector3(200.0, 30.0, 200.0)), "why": "fixture"})
	var reset := DotTimerZoneSet.new()
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN)
	pit.set_box(G2GUnits.vector_to_metres(Vector3(520.0, -200.0, -190.0)),
		G2GUnits.vector_to_metres(Vector3(890.0, 0.0, 190.0)))
	reset.add(pit)
	var just_spawn: Array[Vector3] = [spawn]
	var quiet: Dictionary = G2GMapSurvey.survey_solids(solids, reset, just_spawn, declared, t, tick_rate)

	_check((quiet["unreached"] as Array).is_empty() and (quiet["trapped"] as Array).is_empty()
			and (quiet["startless"] as Array).is_empty(),
		"and none of those once the platform is declared, the cellar has a reset and every start stands",
		"unreached %s; trapped %s; startless %s" % [
			str(quiet["unreached"]), str(quiet["trapped"]), str(quiet["startless"]),
		])


## The hand-written maps: the ones with a script of their own, discovered rather than
## named. An imported map has no geometry until `build_from` runs and is covered by
## `headless_imported`, which drives a timer over each one's own zone set.
func _hand_written_map_ids() -> Array:
	var out: Array = []
	for map in G2GMapCatalogue.scan():
		if not bool(map.meta.get("imported", false)):
			out.append(String(map.id))
	out.sort()
	return out
