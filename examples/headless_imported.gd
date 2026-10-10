extends Node

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GLighting := preload("../game/g2g_lighting.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GStockSubstitutes := preload("../game/g2g_stock_substitutes.gd")
const RouteBot := preload("../tools/route_bot.gd")
const ReplayFollow := preload("../tools/replay_follow.gd")

## Checks a map imported from a Source .bsp: it loads, it is the right size, it is
## lit, and — the only question that matters — a player put on it stays on it.
##
## [codeblock]
## godot --headless --path . res://examples/headless_imported.tscn
## [/codeblock]
##
## [b]Why collision is the check and geometry is not.[/b] Every number about an
## imported map can be right while the map is unplayable: the vertex count, the
## bounds, the material list and the manifest all pass if the triangles are wound
## inside out or the collision body was never built, and a player then falls through
## a map that renders perfectly. This file's own repeated lesson — a value produced
## correctly and consumed by nothing — reaches imported geometry through collision.
##
## Skips rather than fails when nothing has been imported: `maps/imported/` is
## optional content and a clone that has never run the importer is not broken.

## The imported maps that are deliberately NOT courses, and why each one is not.
##
## [b]This suite asserted that every imported map is runnable, and `maps/zones/README.md`
## says in so many words that three of them are not.[/b] The check and the decision
## contradicted each other for as long as both existed, and the suite was the one that was
## wrong: it had been exiting 1 on three maps that are behaving exactly as documented.
##
## - `buses_from_hell_fixed` is a vehicle map. No teleports, no destinations, eight
##   `func_rotating` and a `game_ui` — there is no route to time.
## - `bhop_lego2` is a section-chain map (`s_1`..`s_30`) whose sections are all labelled and
##   whose END is not. Nothing in the file distinguishes the last gate from the ones before
##   it, and guessing would produce a leaderboard that looks right and measures a route the
##   map does not have. `bhop_eazy` was here for the same reason until 2026-10-08, when its
##   teleport graph was read through (its last gate is the only arrival nothing in a section
##   leads back to: a hub of menu teleports) and it got a zones file.
## - `surf_grave_reloaded` is a combat surf map: weapon stashes behind doors in both spawn
##   rooms, a bomb target, and every teleport aims back at a spawn, the prison or the cliff
##   top. A loop to fight on, with no line anywhere that a run could end at.
## - The rest of gb-maps-1's first ranked batch (2026-10-05) is the same thing, which is what
##   the most-viewed surf maps on the download site turn out to be: `surf_10x_final`,
##   `surf_10x_reloaded_fixed`, `surf_forbidden_ways_reloaded`, `surf_mai_remix`,
##   `surf_greatriver_xdre4m`, `surf_ski_2` and `surf_110b_austinpowers` are combat surf
##   (buyzones or weapon buttons, jails, every teleport back to a spawn or a ramp top);
##   `surf_xiv_v2a` is a set of minigames the round picks between; and `surf_fruits` plays one
##   of ten stages a round and ends every one in a fight. Each zones file says which.
##
## [b]The exemption is checked in both directions, which is what stops it being a mute
## button.[/b] A map in here that turns out to HAVE a runnable main track fails — because
## the reason it is listed has stopped being true and the list is now the lie. That is the
## same bargain every skip in this family makes: it is allowed to skip a check, it is not
## allowed to stop asking the question.
const NOT_COURSES := ["buses_from_hell_fixed", "bhop_lego2", "surf_grave_reloaded",
	"surf_10x_final", "surf_10x_reloaded_fixed", "surf_forbidden_ways_reloaded", "surf_mai_remix",
	"surf_greatriver_xdre4m", "surf_ski_2", "surf_110b_austinpowers", "surf_xiv_v2a", "surf_fruits",
	"surf_legends", "kz_bhop_yonkoma", "surf_akai_final", "surf_bathroom_final", "surf_buck_wild",
	"surf_forbidden_ways_2nd", "surf_greatriver", "surf_greatriver_v4", "surf_rebel_resistance_final3", "bunnyhop_pro",
	"surf_29_12_06", "surf_dust2_2008_final", "surf_machine2", "surf_machine_remix_final", "surf_matrix_v8",
	"surf_ski_2_source", "surf_skyworld", "surf_the_gloaming", "surf_thriller", "surf_adverse", "surf_japan_ptad", "surf_animals"]

## The imported maps with no pit, which is a different question from having no finish.
##
## [b]A separate list of one, rather than reusing [constant NOT_COURSES], and the difference
## is the whole point.[/b] A surf or bhop map's `trigger_teleport` volumes ARE its pit, and
## losing them means a player who falls off falls for ever. `bhop_eazy` and `bhop_lego2`
## have pits and are checked for them; only `buses_from_hell_fixed` has none, because a
## vehicle map has nothing to fall off. Folding the two lists together would stop asking two
## maps a question they currently answer correctly, which is how an exemption quietly grows.
const NO_PIT := ["buses_from_hell_fixed"]

## Maps whose main spawn stands in a `trigger_push`, which since 2026-10-08 is run: the
## player is carried off the pad the moment they appear, as in Source. surf_quilavar's
## spawn is the foot of a 2000-unit updraft (1000 u/s, starting 40 units over the floor).
## For these the "comes to rest inside the start zone" check asks instead that the push
## moved the player UP and away, asserted both ways: a listed map whose player rests in
## its start fails, so the entry goes when the push does.
const SPAWNS_IN_A_PUSH := ["surf_quilavar"]

## Arrivals on these maps that DO land inside a pit on their own track, by label.
##
## [b]Known, not accepted[/b] (`[arrive-1]`). Two of the three that were here are fixed:
##
## - `surf_mesa`'s door landed 237 units over the SLOPED top of a teleport brush and
##   inside its bounding box -- a zone is a box and a brush is a hull. `trim_to_hull` in
##   `tools/bsp_import.py` asks `point_in_brush` of every arrival and cuts the box back.
## - `surf_summit` stage 3 landed on the floor beam of a gate whose far side is the fail
##   plane. Its zones file gives the stage a destination on the deck past the gate.
##
## - `surf_greensway` stage 2 was not a wedge: its arrival (the floor of `checkpoint_1`, a
##   plane 3,328 wide and 7,168 tall) is INSIDE the hull of the mapper's own teleport, and
##   so is every floor and both canyon rims within 1,700 units of the line. Its zones file
##   makes it a split with no restart (`restart: false`, `[arrive-2]`): `!s2` is refused
##   with the reason, and `_test_stands_where_it_sends_you` asserts that instead.
##
## Empty now, and kept so the next one has somewhere to go. Asserted both ways, like
## [constant NOT_COURSES]: a map in here whose arrival stops landing in a pit fails, so
## the list cannot outlive its reason.
const ARRIVES_IN_PIT := {}

## Arrivals the map drops a player from on purpose, by label: the line starts with a fall
## the player steers out of. surf_rookie's stage 2 puts you over a tube, with its own pit
## 340 units straight under the arrival returning you to the same arrival; a player who
## does not steer onto the tube's ramp falls through and is put back at the top. A bot
## standing still falls 8.2 m in the window this check waits, so for these the bound is
## 20 m -- a drop the map means, never a fall out of the world (2026-10-09, gb-maps-1).
const FALLING_ARRIVALS := {"surf_rookie": ["stage 2"]}

## Imported bonuses with no pit of their own, by track, which `route_problems()` reports.
##
## [b]Empty since `[track-zone-2]`, and kept so the next one has somewhere to go.[/b] The
## importer used to turn every leftover `trigger_teleport` into a RESPAWN on the MAIN
## track, and the timer acts only on the run's own, so bhop_pit's bonus, surf_arcade's,
## surf_beginner2's four and surf_summit's two had no pit: a player who fell off one fell
## for ever. `pit_tracks` in `tools/bsp_import.py` gives a teleport to the track whose
## START its destination is in -- a fail teleport sends a player back to the start of the
## route they fell off -- and every one of those bonuses has pits now.
##
## Asserted both ways, like [constant NOT_COURSES]: a listed map must report exactly
## these tracks and nothing else, and an unlisted map must report nothing, so a map
## that gains a pit or loses one fails here and the list cannot outlive its reason.
const BONUSES_WITHOUT_PITS := {}

## The share of a map's own triangles drawn in a real texture -- its pakfile's, or a Kenney
## stand-in for a stock one it did not carry (`G2GStockSubstitutes`) -- at least, for the
## maps whose stand-ins have been chosen and looked at (`[g2g-maps-stock-1]`). Measured
## 2026-10-04 with the first table; the grid share before it is in the comment.
const STOCK_DRAWN := {
	"bhop_aztec": 0.66,  # 69.5% on 2026-10-09; 0% before: sandstone courses, looked at along the route
	"surf_beginner2": 0.89,  # 94.7% on 2026-10-09; 2.6% before: planks, rock, sand, looked at along the route
	"bhop_interloper": 0.92,  # 96.9% on 2026-10-09; 50% before: the dirt walkways, looked at along the route
	"buses_from_hell_fixed": 0.96,  # 99.2% on 2026-10-10 (stand-ins from the reference sheet); 94.5% on 2026-10-09; 0% before: the sand floor, looked at from the spawn
	"bhop_monster_jam": 0.76,  # 79.3% on 2026-10-10 (stand-ins from the reference sheet); 77.5% on 2026-10-09; 1.9% before: dark rock, looked at from the finish
	"surf_year3000": 0.81,  # 86.1% on 2026-10-09; 0.8% before: CC0 concrete and metal (2026-10-09)
	"surf_mesa": 0.94,  # 99.9% on 2026-10-09; 91.8% before: concrete walls and ramps, against the WR run
	"surf_10x_final": 0.71,  # 74.1% on 2026-10-10 (stand-ins from the reference sheet); 58.1% on 2026-10-09; 0% before: grass, concrete, rock by name, looked at from the spawn
	"surf_10x_reloaded_fixed": 0.80,  # 83.8% on 2026-10-10 (stand-ins from the reference sheet); 76.2% on 2026-10-09; 0%: ground as dirt, stone, looked at from the spawn
	"surf_mai_remix": 0.67,  # 69.9% on 2026-10-10 (stand-ins from the reference sheet); 59.6% on 2026-10-09; 0%: tiles, rock, looked at from the spawn
	"surf_grave_reloaded": 0.82,  # 84.9% on 2026-10-10 (stand-ins from the reference sheet); 73.8% on 2026-10-09; 0%: cobbles, concrete, looked at from the spawn
	"bhop_exodus": 0.78,  # 81.3% on 2026-10-10 (stand-ins from the reference sheet); 74.7% on 2026-10-09; 10.7%: planks, concrete, looked at from the spawn
	"surf_greatriver_xdre4m": 0.34,  # 36.2% on 2026-10-09; 0%: wood, metal, looked at from the spawn
}

## The share of a map's triangles drawn in the texture its own pakfile carried, at least,
## for the maps where a parsing bug was measured taking it away (2026-09-27): a leading
## `/` on the material name and a `$basetexture` with a space in it. Measured after the
## fix at 99%, 97% and 100%; before it, 2%, 8% and 0%.
const OWN_TEXTURES := {
	"surf_interference": 0.9,
	"surf_aquaflow": 0.9,
	"bhop_eazy": 0.9,
}

## Maps whose terrain is mostly `WorldVertexTransition` blends with both textures in the
## pakfile, measured 2026-10-04: losing the second texture is the largest visible change
## any of them can have, and it fails nothing else.
const BLENDED := ["surf_mesa", "surf_summit", "surf_greensway", "bhop_evolve", "surf_aquaflow"]

## Checks every map gets. Tracks and stages add one each on top — see [member _expected].
const CHECKS_PER_MAP := 49

## Sections every map runs, entered against run to their last line. A runtime error inside
## a section aborts that function and nothing says so; a section that bailed out after a
## failed guard is counted as not finished on purpose, and the two that end early because
## a map legitimately has nothing to check (no course, no door) say so first.
const SECTIONS_PER_MAP := 11

## A script error inside a test aborts THAT TEST and not the run, so a suite that has
## quietly lost two checks still prints "0 failed" — which is what happened while this
## file was being written, to the zone section. The count is asserted, not trusted.
var _expected := 0
var _map_id: StringName = &""

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
	print("g2gfast — imported map")
	print("")

	# Every map under maps/imported/, not one this file names. A suite with its own
	# copy of the list is the bug the discovery in G2GGame exists to avoid.
	var ids := _imported_ids()
	if ids.is_empty():
		print("nothing in maps/imported/ — nothing to check")
		print("  tools/bsp_import.py <a .bsp> maps/imported --id <name>")
		get_tree().quit(0)
		return

	for id in ids:
		_map_id = id
		_expected += CHECKS_PER_MAP
		print("=== %s" % id)
		await _test_loads("res://maps/imported/%s/%s.json" % [id, id])
		await _test_geometry()
		await _test_lighting()
		_test_zones()
		_test_runnable()
		await _test_stands_on_it()
		await _test_stands_where_it_sends_you()
		_test_arrivals_miss_the_pits()
		_test_a_door_keeps_the_run()
		await _test_runs_its_route()
		await _test_follows_its_recording()
		if game != null:
			game.queue_free()
			game = null
			await get_tree().process_frame

	print("")
	if _passed + _failed != _expected:
		_failed += 1
		_failures.append("the suite ran %d checks and should run %d — one aborted"
			% [_passed + _failed, _expected])
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for line in _failures:
		print("  FAIL  %s" % line)
	var sections := SECTIONS_PER_MAP * ids.size()
	if _entered != sections or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, sections
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS_PER_MAP].
func _done() -> void:
	_completed += 1


func _imported_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	var dir := DirAccess.open("res://maps/imported")
	if dir == null:
		return out
	# `-- <id> [<id>...]` checks only those, for arming a check on the map it is about
	# without the other twenty-five minutes. The full suite is still the one that counts.
	var only := OS.get_cmdline_user_args()
	for id in dir.get_directories():
		if not only.is_empty() and not only.has(id):
			continue
		if FileAccess.file_exists("res://maps/imported/%s/%s.json" % [id, id]):
			out.append(StringName(id))
	out.sort()
	return out


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
		print("  FAIL  %s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])


func _test_loads(manifest_path: String) -> void:
	_section("loading")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = _map_id

	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps != null and game.maps.current != null and game.maps.current.id == _map_id,
		"the imported map is in the catalogue and loads")
	# Discovery, not a list. If this fails the map was found by something naming it.
	_check(FileAccess.file_exists(manifest_path), "its manifest is beside it")
	_done()


func _test_geometry() -> void:
	_section("geometry")
	var node := game.current_map_node()
	_check(node is G2GBspMap, "the map node is a G2GBspMap")
	var mi := node.get_node_or_null("World") as MeshInstance3D
	_check(mi != null and mi.mesh != null, "it built a mesh")
	if mi == null or mi.mesh == null:
		return
	var mesh := mi.mesh
	_check(mesh.get_surface_count() > 1, "with a surface per material",
		"%d surfaces" % mesh.get_surface_count())

	# Every surface the manifest lists is drawn, across however many instances it took.
	# A mesh holds 256 and `bhop_monster_jam` has 311: in one mesh the last 55 were
	# refused by the engine and the map was drawn with holes in it while every
	# collision and standing check passed, because collision is built from the brushes.
	var drawn := 0
	for child in node.get_children():
		if child is MeshInstance3D and (String(child.name).begins_with("World")
				or String(child.name).begins_with("Props")
				or String(child.name).begins_with("Sky")) \
				and (child as MeshInstance3D).mesh != null:
			drawn += (child as MeshInstance3D).mesh.get_surface_count()
	var listed: int = (node as G2GBspMap).manifest.get("surfaces", []).size()
	_check(drawn == listed, "and every surface the manifest lists is drawn",
		"%d of %d" % [drawn, listed])

	# [b]A floor is drawn from above (2026-10-07).[/b] Every brush face was wound inside
	# out until then: culled from the side a player stands on and drawn from behind, so a
	# floor showed its slab's underside and a surf ramp with a nodraw underside showed
	# nothing at all -- surf_mesa's first ramp was clear from on top of it. Every check
	# here passed throughout, because a culled triangle is still a triangle in the mesh.
	# So the winding is asked directly: on every surface whose faces point up (PLATFORM),
	# most triangles must be front-facing from above. Godot's front face is clockwise from
	# the viewer, which is a right-hand cross product pointing AWAY from them -- down.
	var upside_down := PackedStringArray()
	var world_surfaces: Array[Dictionary] = []
	for s: Dictionary in (node as G2GBspMap).manifest.get("surfaces", []):
		if G2GBspMap._family(s) == "World" and int(s.get("index_count", 0)) > 0 \
				and int(s.get("vertex_count", 0)) > 0:
			world_surfaces.append(s)
	var at := 0
	for child in node.get_children():
		if not (child is MeshInstance3D and String(child.name).begins_with("World")):
			continue
		var m := (child as MeshInstance3D).mesh
		for i in range(m.get_surface_count()):
			var s: Dictionary = world_surfaces[at] if at < world_surfaces.size() else {}
			at += 1
			if str(s.get("role", "")) != "PLATFORM":
				continue
			var arrays := m.surface_get_arrays(i)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var up := 0
			var down := 0
			for t in range(0, idx.size() - 2, 3):
				var a := pos[idx[t]]
				var y := (pos[idx[t + 1]] - a).cross(pos[idx[t + 2]] - a).y
				if y < -1e-6:
					up += 1
				elif y > 1e-6:
					down += 1
			if down > up:
				upside_down.append("%s (%d of %d)" % [s.get("material", "?"), down, up + down])
	_check(upside_down.is_empty(), "and a floor is drawn from the side a player stands on",
		", ".join(upside_down))

	# [b]Static props are drawn (2026-09-27).[/b] 17 of the 26 maps place them and every
	# one was absent: surf_aquaflow's whole reef, surf_greensway's forest, surf_summit's
	# trees and arches. The count of props the importer DREW is from the models it read,
	# the count PLACED is from the lump; a map that placed props it carried and drew none
	# is an importer that stopped reading them.
	var manifest_props: Dictionary = (node as G2GBspMap).manifest.get("static_props", {})
	var carried := int(manifest_props.get("placed", 0)) - int(manifest_props.get("stock_models", 0))
	var prop_surfaces := 0
	for child in node.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Props") \
				and (child as MeshInstance3D).mesh != null:
			prop_surfaces += (child as MeshInstance3D).mesh.get_surface_count()
	_check(carried <= 0 or (int(manifest_props.get("drawn", 0)) > 0 and prop_surfaces > 0),
		"and the static props its pakfile carried are drawn",
		"%s; %d prop surfaces drawn" % [manifest_props, prop_surfaces])

	# [b]And a 3D skybox is a backdrop, not a miniature (2026-09-27).[/b] Ten maps have one;
	# its faces were drawn at a sixteenth of their size where they were compiled and no
	# backdrop at all. Drawn, they are their own `Sky` instances, scaled about the camera.
	var sky: Variant = (node as G2GBspMap).manifest.get("skybox", null)
	var sky_node := node.get_node_or_null("Sky") as MeshInstance3D
	# "Has one" is read from the lighting block's sky_camera, a second code path, so a
	# skybox the importer stopped handling at all is a failure and not a map without one.
	var has_camera := ((node as G2GBspMap).manifest.get("lighting", {}) as Dictionary) \
		.has("sky_camera")
	var told_off := sky is Dictionary and (not bool((sky as Dictionary).get("drawn", true))
		or int((sky as Dictionary).get("faces", 0)) == 0)
	var wants_sky := has_camera and not told_off
	_check(sky_node != null if wants_sky else sky_node == null,
		"and its 3D skybox is drawn as a backdrop exactly when it has one to draw",
		"skybox %s, Sky node %s" % [sky, sky_node != null])

	# [b]And a 3D skybox has something in it (2026-10-02).[/b] bhop_pandora2_fix and
	# bhop_supernova build theirs from `prop_dynamic`s alone, and a static-props-only
	# importer found the room and drew nothing in it: faces 0, props 0, an empty sky.
	var sky_things := 0
	if sky is Dictionary:
		sky_things = int((sky as Dictionary).get("faces", 0)) + int((sky as Dictionary).get("props", 0))
	_check(not (sky is Dictionary and bool((sky as Dictionary).get("drawn", true))) or sky_things > 0,
		"and a 3D skybox it draws has faces or props in it", str(sky))

	# [b]And it is in front of the camera's far plane (4000 m).[/b] Drawn at the sky
	# camera's own 512, pandora's nearest asteroid was 5 km out and its islands past 20 km:
	# imported and invisible. The importer measures where the nearest and farthest of the
	# sky land (`reach_units`); the nearest must be visible, and a scale it drew at may be
	# smaller than the mapper's but never larger.
	var visible := true
	var reach_detail := "no 3D skybox drawn"
	if sky is Dictionary and bool((sky as Dictionary).get("drawn", true)) and sky_things > 0:
		var reach: Array = (sky as Dictionary).get("reach_units", [])
		var drawn_scale := float((sky as Dictionary).get("drawn_scale", INF))
		visible = reach.size() == 2 and G2GUnits.to_metres(float(reach[0])) <= 4000.0 \
			and drawn_scale <= float((sky as Dictionary).get("scale", 0.0))
		reach_detail = "reach %s u at %s x (the mapper's %s)" % [
			str(reach), str(drawn_scale), str((sky as Dictionary).get("scale"))]
	_check(visible, "and its 3D skybox is drawn in front of the camera's far plane", reach_detail)

	var verts := 0
	var has_uv2 := true
	for i in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(i)
		verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if arrays[Mesh.ARRAY_TEX_UV2] == null:
			has_uv2 = false
	_check(verts > 1000, "and real geometry", "%d verts" % verts)
	# UV2 is the whole reason this is not a glTF import. If it is gone the map is lit
	# by whatever texel the atlas happens to have at (0,0).
	_check(has_uv2, "and a second UV set on every surface, for the baked lighting")

	var aabb := mi.get_aabb()
	var units := aabb.size / G2GUnits.METRES_PER_UNIT
	# Source's own limit is +/-16384 units, so a map is at most 32768 across. Ten
	# times that means the unit ratio was applied twice or not at all -- the one
	# mistake that makes an imported map silently unplayable rather than wrong.
	# The LONGEST side, not x: bhop_grove is one corridor 704 units across and 32,192
	# long, and asking its x of the unit ratio failed a map that is exactly right.
	var longest := maxf(units.x, maxf(units.y, units.z))
	_check(longest > 1000.0 and longest < 40000.0,
		"and is the size a Source map can be", "%.0f x %.0f x %.0f units" % [units.x, units.y, units.z])
	_done()


func _test_lighting() -> void:
	_section("lighting")
	var node := game.current_map_node() as G2GBspMap
	var lm: Dictionary = node.manifest.get("lightmap", {})
	var path: String = "res://maps/imported/%s/%s" % [_map_id, lm.get("file", "")]
	_check(ResourceLoader.exists(path), "the baked lightmap atlas is an imported resource", path)

	var mi := node.get_node_or_null("World") as MeshInstance3D
	var mat := mi.get_surface_override_material(0) as ShaderMaterial if mi != null else null
	_check(mat != null, "surfaces carry a ShaderMaterial")
	if mat == null:
		return
	_check(mat.get_shader_parameter("lightmap_tex") is Texture2D,
		"and the atlas is bound to every one of them")

	# A texture the map did not carry is painted its own measured colour, not a role grey.
	# Most of a map is such surfaces, so a regression here turns every map back into the
	# four greys it looked like before -- a thing no other check in this suite can see,
	# because every greyscale surface is still a correctly configured material. Most rather
	# than all: a light panel vrad measured as black keeps its role colour on purpose.
	var prototype := 0
	var coloured := 0
	for entry: Dictionary in node.manifest.get("surfaces", []):
		if bool(entry.get("prototype", false)):
			prototype += 1
			if entry.get("colour", null) is Array:
				coloured += 1
	# A jump map's blocks are brush entities, and for as long as there were imported maps
	# only the world was drawn: every block was solid and invisible (47% of bhop_eazy).
	var ents: Dictionary = node.manifest.get("brush_entities", {})
	_check(int(ents.get("solid", 0)) == 0 or int(ents.get("faces_drawn", 0)) > 0,
		"and a map with solid brush entities draws them, not only the world",
		"%s" % ents)
	_check(prototype == 0 or coloured * 2 >= prototype,
		"and a surface whose texture did not ship is painted the map's own colour for it",
		"%d of %d prototype surfaces coloured" % [coloured, prototype])

	# [b]A texture the pakfile carried is drawn, not replaced by the prototype grid.[/b]
	# Two spellings the importer did not read: a material typed with a leading `/`
	# (`/SURFACE`, looked up as `materials//surface.vmt`) and a `$basetexture` with a
	# space in it (`"hammer textures/..."`, cut at the space). Between them they cost
	# surf_interference 97% of its own textures, surf_aquaflow a third and bhop_eazy all
	# of them, and nothing said so: a prototype surface is a correctly configured
	# material. A name with the slash still on it fails every map; the share is asserted
	# for the maps it was measured on, see [constant OWN_TEXTURES].
	var tris := 0
	var own := 0
	var slashed := PackedStringArray()
	for entry: Dictionary in node.manifest.get("surfaces", []):
		# The map's own faces: a static prop's stock texture is a different question.
		if bool(entry.get("prop", false)):
			continue
		var n := int(entry.get("index_count", 0)) / 3
		tris += n
		if entry.get("texture", null) is String and not str(entry["texture"]).is_empty():
			own += n
		if str(entry.get("material", "")).begins_with("/"):
			slashed.append(str(entry["material"]))
	var share := float(own) / float(maxi(tris, 1))
	var floor_share: float = OWN_TEXTURES.get(String(_map_id), 0.0)

	# Own texture or a stand-in, which is what a player sees as textured. The material
	# names are the manifest's; a stand-in applies only where nothing shipped.
	var stood_in := 0
	for entry: Dictionary in node.manifest.get("surfaces", []):
		if bool(entry.get("prop", false)) or not bool(entry.get("prototype", false)):
			continue
		if not G2GStockSubstitutes.for_material(str(entry.get("material", ""))).is_empty():
			stood_in += int(entry.get("index_count", 0)) / 3
	var drawn := float(own + stood_in) / float(maxi(tris, 1))
	var drawn_floor: float = STOCK_DRAWN.get(String(_map_id), 0.0)
	print("  stock %s: own %.1f%%, with stand-ins %.1f%%" % [_map_id, share * 100.0, drawn * 100.0])
	_check(drawn >= drawn_floor,
		"and a stock texture it did not carry has its Kenney stand-in",
		"%.1f%% drawn textured, %.0f%% expected" % [drawn * 100.0, drawn_floor * 100.0])
	# [b]Water that shipped no texture is drawn as water[/b], see g2g_bsp_water.gdshader:
	# every such surface in the manifest has the water material on the mesh, and nothing
	# else does. Armed by skipping the water branch in G2GBspMap._material_for.
	var water_wanted := 0
	for entry: Dictionary in node.manifest.get("surfaces", []):
		if bool(entry.get("prop", false)) or (entry.get("texture", null) is String and not str(entry["texture"]).is_empty()):
			continue
		if G2GBspMap.is_water_material(str(entry.get("material", ""))):
			water_wanted += 1
	var water_drawn := 0
	for drawn_node: Node in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := drawn_node as MeshInstance3D
		for i in range(mesh_instance.get_surface_override_material_count()):
			var m := mesh_instance.get_surface_override_material(i)
			if m != null and m.has_meta(&"water"):
				water_drawn += 1
	_check(water_drawn == water_wanted,
		"and its untextured water is drawn as water",
		"%d water materials on the mesh, %d water surfaces in the manifest" % [water_drawn, water_wanted])
	_check(slashed.is_empty() and share >= floor_share,
		"and the textures its pakfile carried are drawn",
		"%.0f%% of triangles in their own texture, %.0f%% expected; names with a leading '/': %s"
			% [share * 100.0, floor_share * 100.0, slashed])

	# [b]A blend material draws both its textures.[/b] `WorldVertexTransition` paints a
	# second texture by vertex alpha, and the importer took only the first: grey rock where
	# surf_mesa's reference footage has warm orange, on 67% of its triangles. The alpha
	# travels in its own block (`alpha_offset`) and reaches the shader as COLOR.a, so a
	# drawn blend surface has to have both the texture and a colour array that varies.
	# [constant BLENDED] names maps that must have one, which is what catches an importer
	# that stopped finding them.
	var listed := 0
	for entry: Dictionary in node.manifest.get("surfaces", []):
		if entry.has("texture2") and entry.has("alpha_offset"):
			listed += 1
	var drawn_ok := 0
	var drawn_bad := PackedStringArray()
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var each := child as MeshInstance3D
		if each.mesh == null:
			continue
		for i in range(each.mesh.get_surface_count()):
			var smat := each.get_surface_override_material(i) as ShaderMaterial
			if smat == null or smat.get_shader_parameter("has_albedo2") != true:
				continue
			var colours: Variant = each.mesh.surface_get_arrays(i)[Mesh.ARRAY_COLOR]
			var most := 0.0
			if colours is PackedColorArray:
				for c in colours:
					most = maxf(most, c.a)
			if smat.get_shader_parameter("albedo2_tex") is Texture2D and most > 0.05:
				drawn_ok += 1
			else:
				drawn_bad.append("%s#%d" % [each.name, i])
	_check(drawn_bad.is_empty() and drawn_ok >= mini(listed, 1)
			and (listed > 0 or not BLENDED.has(String(_map_id))),
		"and a material that blends two textures draws both",
		"%d listed, %d drawn with a varying alpha, broken: %s" % [listed, drawn_ok, drawn_bad])

	# [b]No sky is a blank white dome.[/b] The procedural sky's top is the map's `_ambient`,
	# and four maps never set theirs and carry the editor's default 255 255 255 (surf_beginner2,
	# bhop_aztec, bhop_mario_fxd, bhop_evolve); G2GLighting looks those up by sky name.
	# Armed by taking that out: it fires on exactly those four.
	var top := Color(0, 0, 0)
	var world := node.get_node_or_null("Lighting") as WorldEnvironment
	if world != null and world.environment != null and world.environment.sky != null:
		var sky_mat := world.environment.sky.sky_material as ProceduralSkyMaterial
		if sky_mat != null:
			top = sky_mat.sky_top_color
	_check(minf(top.r, minf(top.g, top.b)) < 0.99,
		"and its sky is not a blank white dome", "sky top %s, sky name '%s'"
			% [top, node.manifest.get("lighting", {}).get("sky_name", "")])

	# [b]A sky the map packed is the sky drawn.[/b] 36 of the held maps carry their own six
	# faces (`lighting.sky_faces`), and every one was drawn as a colour from a table of sky
	# names. Passes on a map with none by asking nothing of it. Armed by taking
	# `_apply_packed_sky` out of G2GBspMap: it fires on every map that packs one.
	var faces: Variant = node.manifest.get("lighting", {}).get("sky_faces", null)
	var packed_ok := true
	var packed_why := "no packed sky"
	if faces is Dictionary and not (faces as Dictionary).is_empty():
		var shader_mat: ShaderMaterial = null
		if world != null and world.environment != null and world.environment.sky != null:
			shader_mat = world.environment.sky.sky_material as ShaderMaterial
		var bound := 0
		if shader_mat != null:
			for suffix: String in ["rt", "lf", "bk", "ft", "up", "dn"]:
				if shader_mat.get_shader_parameter("face_" + suffix) is Texture2D:
					bound += 1
		packed_ok = bound == 6 and world.environment.background_mode == Environment.BG_SKY
		packed_why = "%d of 6 faces bound" % bound
	_check(packed_ok, "and a sky it packed is the sky drawn", packed_why)

	# [b]And a sky named black is black, horizon included.[/b] surf_kitsune names `blacksky`
	# and sets nothing else, and was drawn under dot-lighting's pale default dome. Passes on
	# every map whose sky is not named black. Armed by taking `_darken_black_sky` out of
	# G2GLighting.apply: it fires on surf_kitsune alone.
	var lit: Dictionary = node.manifest.get("lighting", {})
	var dark := true
	var seen := "no sky material"
	if G2GLighting.is_black_sky(lit) and world != null and world.environment != null:
		var env := world.environment
		var smat := env.sky.sky_material as ProceduralSkyMaterial if env.sky != null else null
		var colours: Array[Color] = [env.background_color]
		if smat != null:
			colours.append_array([smat.sky_top_color, smat.sky_horizon_color,
				smat.ground_horizon_color, smat.ground_bottom_color])
		seen = str(colours)
		for c: Color in colours:
			dark = dark and c.get_luminance() < 0.02
	_check(dark, "and a sky named black is drawn black",
		"sky name '%s': %s" % [lit.get("sky_name", ""), seen])
	_done()


func _test_zones() -> void:
	_section("zones")
	var zones := game.timers.zones
	_check(zones != null, "the map produced a zone set")
	if zones == null:
		return
	_check(zones.problems().is_empty(), "which is well formed", ", ".join(zones.problems()))
	var respawns := zones.of_kind(DotTimerZone.Kind.RESPAWN).size()
	# A surf map's trigger_teleport volumes are its pit. Losing them means a player
	# who falls off falls for ever, which is the bug dot-timer's effect_requested was.
	if NO_PIT.has(_map_id):
		_check(respawns == 0, "has no pit, and still has none",
			"listed in NO_PIT; %d respawn zones" % respawns)
	else:
		_check(respawns > 0, "with the pit volumes carried across as RESPAWN zones",
			"%d respawn zones" % respawns)

	# Source sweeps its trigger tests; dot-timer samples a point per tick. A pit drawn
	# as a 16-unit plane -- which is how every one of them is drawn, because in Source
	# that is enough -- is stepped clean over by a player falling at genre speed, and
	# they then fall for ever. 48 of surf_kitsune's 53 were that thin on import.
	var thin := zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate)
	_check(thin.is_empty(), "and no zone a 3500 u/s player passes through between ticks",
		"%d thin" % thin.size())

	# The two zones without which a map is scenery. Every one of these maps had them
	# in its entity lump or in maps/zones/ before it was offered as a level; a map
	# that reaches here without them is one the importer stopped reading.
	var tracks := zones.playable_tracks()

	if NOT_COURSES.has(_map_id):
		# Asserted the other way round. See [constant NOT_COURSES]: if this map has grown a
		# finish, the list is out of date and that is worth a failure, because the next
		# person to read it would believe it.
		_check(not tracks.has(DotTimerTrack.MAIN),
			"is not a course, and still is not",
			"listed in NOT_COURSES; runnable tracks: %s" % str(tracks))
	else:
		_check(tracks.has(DotTimerTrack.MAIN),
			"the main track has both a start line and a finish",
			"runnable tracks: %s" % str(tracks))

	# A track a player cannot be put on is a track nobody plays. `spawn_for` falls
	# back to `fallback_spawn_units` for a missing one, which is the main track's
	# spawn -- so a bonus with no spawn of its own silently starts at the map's start,
	# and looks like a bonus that does not work rather than like a missing zone.
	var without := PackedStringArray()
	for track in tracks:
		if zones.first_of_kind(DotTimerZone.Kind.SPAWN, track) == null:
			without.append(DotTimerTrack.name_of(track))
	_check(without.is_empty(), "and every runnable track has somewhere to spawn",
		", ".join(without))

	# `[track-zone-1]`: every route, per track — a start, a finish, a spawn and a pit of
	# its own. See [constant BONUSES_WITHOUT_PITS] for the ones known not to have one.
	var expected := PackedStringArray()
	for track: int in BONUSES_WITHOUT_PITS.get(String(_map_id), []):
		expected.append("%s has no respawn zone" % DotTimerTrack.name_of(track))
	var reported := PackedStringArray()
	for problem in zones.route_problems():
		var cut := problem.find(",")
		reported.append(problem.substr(0, cut) if cut > 0 else problem)
	_check(reported == expected,
		"every route has a start, a finish, a spawn and a pit" if expected.is_empty()
			else "its bonuses without a pit are the ones listed, and only those",
		"reported %s, listed %s" % [reported, expected])
	_done()


func _test_runnable() -> void:
	_section("runnable")
	var zones := game.timers.zones
	if zones == null:
		_check(false, "a run can be started, split and finished")
		_check(false, "and its stages come out in order")
		return

	# [b]Drive the timer over the map's own zones and see a time come out.[/b] Every
	# other check here is about a zone existing; this is the only one about the zones
	# adding up to a run. A start with no reachable finish, a stage numbered past the
	# end, a finish inside the start -- all of them pass `problems()` and none of them
	# produces a time.
	var timer := DotTimer.new()
	timer.bind(zones, game.tick_rate)
	var finished: Array[DotTimerRun] = []
	timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))

	var start := zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)

	if NOT_COURSES.has(_map_id):
		# Both checks still run and still count; what changes is what the right answer is.
		# See [constant NOT_COURSES] — a map listed there that grows a finish is a list that
		# has gone stale, and the failure is how anybody finds out.
		_check(start == null or finish == null,
			"has no run to time, as documented",
			"listed in NOT_COURSES")
		_check(true, "and no stages to order")
		_done()
		return

	if start == null or finish == null:
		_check(false, "a run can be started, split and finished", "no start or no end")
		_check(false, "and its stages come out in order")
		return

	# [b]A tick outside every zone, between the start and everything after it.[/b] The
	# run begins on the tick the player LEAVES the start line, and that happens after
	# the zone handling for the same tick -- so a route that steps straight from the
	# start into the first stage arrives while the run is still IDLE and the split is
	# dropped. It is an artifact of stepping a timer by hand rather than walking a
	# map, and it cost every staged map here exactly one split until the gap was put
	# back in.
	var bounds: Dictionary = (game.current_map_node() as G2GBspMap).manifest.get("bounds", {})
	var away := G2GUnits.vector_to_metres(Vector3(
		float((bounds.get("max", [0, 0, 0]) as Array)[0]),
		float((bounds.get("max", [0, 0, 0]) as Array)[1]),
		float((bounds.get("max", [0, 0, 0]) as Array)[2]))) + Vector3(0.0, 128.0, 0.0)

	# From stage 2, because stage 1 IS the start line on every map that numbers its
	# own stages -- and stepping back into the start zone mid-route makes the timer do
	# what it should: treat leaving it again as a new attempt, wiping the splits.
	var route: Array[Vector3] = [start.centre(), start.centre(), away]
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		var stage := zones.stage_zone(DotTimerTrack.MAIN, n)
		if stage != null:
			route.append(stage.centre())
	route.append(finish.centre())

	var sample := DotTimerSample.new()
	for point in route:
		sample.previous_position = sample.position
		sample.position = point
		sample.grounded = true
		timer.tick(sample)

	_check(finished.size() == 1, "a run can be started, split and finished",
		"%d finishes" % finished.size())
	if finished.is_empty():
		_check(false, "and its stages come out in order")
		return

	# Stage 1 is the start line, and a run begins by LEAVING it -- so its split is the
	# one that legitimately never arrives. Every stage after it must.
	var wanted := maxi(0, zones.stage_count(DotTimerTrack.MAIN) - 1)

	var got := 0
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		if finished[0].splits.has(n):
			got += 1
	_check(got == wanted, "and its stages come out in order",
		"%d of %d splits" % [got, wanted])
	_done()


func _test_stands_on_it() -> void:
	_section("collision")
	var node := game.current_map_node()
	# Anywhere under the map, not under the MeshInstance3D. The solid used to BE the
	# mesh -- `create_trimesh_collision()` parents a `World_col` to it -- and it is not
	# any more: it is built from the .bsp's brushes, which is a different set of
	# geometry from the drawn faces and belongs to the map rather than to the drawing of
	# it. The old shape is still what a pre-collision manifest falls back to, so this
	# has to find both.
	var body: Node = null
	for c in node.find_children("*", "StaticBody3D", true, false):
		body = c
		break
	_check(body is StaticBody3D, "the world has a static body")
	var shape_count := 0
	if body != null:
		for c in body.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
				shape_count += 1
	_check(shape_count > 0, "with a collision shape on it", "%d shapes" % shape_count)

	var bot := game.add_player(&"bot", "Bot", true)
	_check(bot != null, "a player joins")
	if bot == null:
		return
	bot.sampler = null

	var start := node.spawn_for(0)
	await get_tree().physics_frame
	_check(bot.global_position.distance_to(start) < 2.0, "at the map's own spawn",
		"%.1f m away" % bot.global_position.distance_to(start))

	# Let it fall. On a map whose collision never got built this is the only check in
	# the file that fails, and it fails by hundreds of metres rather than marginally.
	var floor_y := start.y
	for _i in range(180):
		await get_tree().physics_frame
	var drop := floor_y - bot.global_position.y
	_check(drop < 8.0, "and is still standing on the map three seconds later",
		"fell %.1f m" % drop)

	# [b]And where it came to rest is inside the start zone (2026-09-27).[/b] The timer asks
	# the zone about the player's own position every tick; a start box that stops short of
	# the floor contains the spawn in mid-air and not the player standing under it, so the
	# run starts as they fall out of it and a player on the pad can never be "in the
	# start". surf_arcade was that: its start is a box around `s1_reset`, which stands
	# 240 units over the pad, and at +/-128 the player rested 112 units under it. Armed
	# by putting the old box back.
	var start_zone := game.timers.zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN) \
		if game.timers.zones != null else null
	if start_zone == null:
		_check(NOT_COURSES.has(_map_id), "and comes to rest inside the start zone",
			"no start zone on the main track")
	elif SPAWNS_IN_A_PUSH.has(String(_map_id)):
		var at := bot.controller.state.position
		_check(not start_zone.contains(at) and at.y > start.y,
			"and is carried up off its spawn by the push it stands in (SPAWNS_IN_A_PUSH)",
			"at %s" % [at / G2GUnits.METRES_PER_UNIT])
	else:
		var at := bot.controller.state.position
		_check(start_zone.contains(at), "and comes to rest inside the start zone",
			"at %s, zone %s..%s" % [at / G2GUnits.METRES_PER_UNIT,
				start_zone.from / G2GUnits.METRES_PER_UNIT, start_zone.to / G2GUnits.METRES_PER_UNIT])

	# [b]And it is not shut in (2026-10-09).[/b] surf_year3000's spawn was a sealed
	# 240 x 128 unit void between two arrival booths: the player stood on a floor, inside
	# the start zone, and could go nowhere, and every check above passed. Sixteen rays at
	# waist height from where it came to rest; one has to run 5 m before it meets anything.
	# The void's longest was 3.2 m. 5 and not more because a start room a mapper leaves by
	# a teleport is a closed room too, and the smallest of those here are kz_bhop_badg3s's
	# (6.9 m) and bhop_tesquo_v2's (7.4 m): rays cannot tell a room with a teleport in it
	# from one without. Armed by taking surf_year3000's "remove" back out of its zones file.
	var space := bot.get_world_3d().direct_space_state
	var waist := bot.global_position + Vector3.UP * 0.9
	var longest := 0.0
	for k in range(16):
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 16.0)
		var ray := PhysicsRayQueryParameters3D.create(waist, waist + dir * 5.0)
		var hit := space.intersect_ray(ray)
		longest = maxf(longest, 5.0 if hit.is_empty() else waist.distance_to(hit["position"]))
	_check(longest >= 5.0, "and is not shut in where it stands",
		"the longest of 16 rays from the spawn runs %.1f m" % longest)

	var bounds: Dictionary = (node as G2GBspMap).manifest.get("bounds", {})
	var min_y: float = float((bounds.get("min", [0, -16384, 0]) as Array)[1]) * G2GUnits.METRES_PER_UNIT
	_check(bot.global_position.y > min_y, "and has not left the world",
		"y=%.1f, world floor %.1f" % [bot.global_position.y, min_y])
	_done()


## Every place the map can put a player: each track's spawn, and each `!s<n>`.
##
## [b]A destination is the one field nothing else checks.[/b] `DotTimerManager`
## resolves "go to stage 3" to a zone's [member DotTimerZone.destination] and hands it
## to the host, which teleports; a destination that is in the sky, inside a wall, or
## left at the origin succeeds at every step and drops the player out of the world.
## Standing on it for a second is the whole test, and it is the same test as the one
## above with somewhere else to stand.
func _test_stands_where_it_sends_you() -> void:
	_section("destinations")
	var node := game.current_map_node()
	var zones := game.timers.zones
	var spots: Array = []
	var splits: Array[int] = []
	if zones != null:
		for track in zones.playable_tracks():
			var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
			if spawn != null:
				spots.append([DotTimerTrack.short_name_of(track) + " spawn", spawn.destination, spawn.destination_yaw])
			for n in range(1, zones.stage_count(track) + 1):
				var stage := zones.stage_zone(track, n)
				if stage == null:
					continue
				if stage.payload.has(G2GBspMap.NO_RESTART):
					# A split with no restart has no spot; what is asserted is that
					# nobody is sent to it. Main track only: that is the bot's.
					if track == DotTimerTrack.MAIN:
						splits.append(n)
					continue
				spots.append(["stage %d" % n, stage.destination, stage.destination_yaw])
	_expected += spots.size() + splits.size() * 2

	# [b]A stage faces a player the way the map's own door into it does (2026-10-09).[/b]
	# A stage built `around` a destination used to put the player there facing yaw 0, so on
	# surf_kitsune every `!s<n>` and stage restart faced a wall side-on while the door into
	# the same section faced down it: two reference runs never showed those walls, and
	# ours showed one at every stage. Where a door (a TELEPORT on the track) lands inside a
	# stage's own volume, the stage must agree with one of them within ten degrees. Armed by re-importing
	# without bsp_import.py's around_yaw.
	var facings := 0
	var disagree: Array[String] = []
	if zones != null:
		for track in zones.playable_tracks():
			for n in range(1, zones.stage_count(track) + 1):
				var stage := zones.stage_zone(track, n)
				if stage == null or stage.payload.has(G2GBspMap.NO_RESTART):
					continue
				# Agreeing with ONE door is enough: a map built for two teams mirrors its
				# arrivals (surf_year3000's start room takes both teams' booths, facing
				# opposite ways), and a stage can face only one of them.
				var door_yaws: Array[float] = []
				for door: DotTimerZone in zones.of_kind(DotTimerZone.Kind.TELEPORT, track):
					if stage.contains(door.destination + Vector3.UP * 0.1):
						door_yaws.append(door.destination_yaw)
				if door_yaws.is_empty():
					continue
				facings += 1
				var agrees := false
				for y in door_yaws:
					agrees = agrees or absf(wrapf(stage.destination_yaw - y, -180.0, 180.0)) <= 10.0
				if not agrees:
					disagree.append("stage %d %.0f vs doors %s" % [n, stage.destination_yaw, door_yaws])
	_check(disagree.is_empty(),
		"every stage faces a player the way the map's own door into it does (%d compared)" % facings,
		", ".join(disagree))

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	for spot: Array in spots:
		var at: Vector3 = spot[1]
		bot.teleport(at, 0.0)
		for _i in range(90):
			await get_tree().physics_frame
		var drop := at.y - bot.global_position.y
		var falls: Array = FALLING_ARRIVALS.get(String(_map_id), [])
		_check(drop < (20.0 if falls.has(spot[0]) else 8.0),
			"%s is somewhere a player can stand%s" % [spot[0], " (or a drop the map means, FALLING_ARRIVALS)" if falls.has(spot[0]) else ""],
			"fell %.1f m from %s" % [drop, str(at / G2GUnits.METRES_PER_UNIT)])

	for n in splits:
		var before := bot.global_position
		var refused := game.request_stage(&"bot", n)
		_check(not refused.ok and refused.error.code == DotError.CODE_UNSUPPORTED,
			"stage %d, a split with no restart, refuses !s%d with the reason" % [n, n],
			str(refused.error.message) if not refused.ok else "it was sent")
		# `!rs` from inside it goes to the stage it splits, which IS somewhere to stand.
		var who := game.timers.player(&"bot")
		if who != null:
			who.timer.run.stage = n
		var back := game.restart_stage(&"bot")
		_check(back.ok and bot.global_position.distance_to(before) > 1.0,
			"and !rs inside stage %d goes back to the stage before it" % n,
			str(back.error.message) if not back.ok else "did not move")
	_done()


## Every place the map puts a player -- a spawn, a stage, the far side of a door -- is
## outside every pit on that track.
##
## [b]A pit that contains its own arrival is a loop nobody can see from the zone list.[/b]
## A respawn fires on ENTRY, so a player put inside one is sent back to the start the
## first time they move -- which from the player's side is a `!s2` that does nothing and
## a stage nobody can reach. bhop_pandora2_fix spawned every player inside its first pit
## because the importer thickened a 16-unit plane 48 units under the start room into a
## 192-unit slab reaching up through the floor; `tools/bsp_import.py` `inflate_pit` is the
## fix and this is the check that fails without it. `_test_stands_where_it_sends_you`
## could not see it: it teleports a bot to each arrival and measures how far it FELL,
## and a bot the pit put back at a higher spawn has fallen a negative distance.
func _test_arrivals_miss_the_pits() -> void:
	_section("arrivals")
	var zones := game.timers.zones
	var inside := PackedStringArray()
	if zones != null:
		var pits := zones.of_kind(DotTimerZone.Kind.RESPAWN)
		for zone: DotTimerZone in zones.zones:
			var label := ""
			match zone.kind:
				DotTimerZone.Kind.SPAWN:
					label = "%s spawn" % DotTimerTrack.short_name_of(zone.track)
				DotTimerZone.Kind.STAGE:
					if zone.payload.has(G2GBspMap.NO_RESTART):
						continue    # nobody is ever put there; see ARRIVES_IN_PIT
					label = "stage %d" % int(zone.number)
				DotTimerZone.Kind.TELEPORT:
					label = "door"
				_:
					continue
			for pit: DotTimerZone in pits:
				if pit.track == zone.track and pit.contains(zone.destination):
					if not inside.has(label):
						inside.append(label)
					break
	var known: Array = ARRIVES_IN_PIT.get(String(_map_id), [])
	if known.is_empty():
		_check(inside.is_empty(), "no spawn, stage or door puts a player inside a pit",
			", ".join(inside))
	else:
		# Both ways: the listed ones still do, and nothing else does.
		var listed := PackedStringArray(known)
		_check(inside == listed,
			"lands in a pit exactly where ARRIVES_IN_PIT says it does",
			"listed %s, found %s" % [str(listed), str(inside)])
	_done()


## Walking through one of the map's doors does not end the run.
##
## [b]`doorways` in a map's zone file exists so that a door is a TELEPORT, which keeps
## the run, rather than a RESPAWN, which ends it -- and the game's handler for TELEPORT
## called `G2GPlayer.teleport`, which ends it.[/b] So every door the importer ever
## made ended the run anyway, on surf_kitsune (the map the rule was written for), on
## bhop_interloper's three parts, on bhop_badges_mini's hundred and eighty sections. The
## zone list was exactly right and the only symptom was a timer that stopped at the
## first door. Driven through the real handler: the manager's signal, which is what the
## timer emits when a player walks in.
func _test_a_door_keeps_the_run() -> void:
	_section("doors")
	var zones := game.timers.zones
	var door: DotTimerZone = null
	var start: DotTimerZone = null
	if zones != null:
		door = zones.first_of_kind(DotTimerZone.Kind.TELEPORT, DotTimerTrack.MAIN)
		start = zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	if door == null or start == null:
		_check(true, "a door keeps the run", "no door on the main track")
		_done()
		return

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	var timer := bot.timer
	if timer == null:
		_check(false, "a door keeps the run", "the bot has no timer")
		return
	timer.stop()

	# Leave the start line, so there is a run to lose. Synchronously, inside one frame,
	# so the game's own tick cannot feed the timer the bot's real position in between.
	var sample := DotTimerSample.new()
	sample.grounded = true
	var away := start.centre() + Vector3(0.0, start.size().y + 8.0, 0.0)
	for point in [start.centre(), start.centre(), away]:
		sample.previous_position = sample.position
		sample.position = point
		timer.tick(sample)
	var was_running := timer.run.is_running()

	game.timers.effect_requested.emit(&"bot", door)

	var moved := bot.global_position.distance_to(door.destination) < 0.01
	_check(was_running and moved and timer.run.is_running(), "a door keeps the run",
		"running before %s, moved %s, running after %s"
		% [was_running, moved, timer.run.is_running()])
	timer.stop()
	_done()


## Longest a route may take, in simulated seconds, before the bot is said not to finish.
const ROUTE_SECONDS := 300.0


## A bot runs the map from its main spawn to its finish, on the imported collision,
## following the route written down for it in `maps/routes/<id>.json` (`g2g-maps-1`).
##
## [b]Every other section here asks about a place; this one asks about the whole way.[/b]
## `_test_runnable` drives a timer over the zones, `_test_stands_where_it_sends_you` drops
## a player at each arrival, and a map can pass all of it with a block missing, a gap
## nobody can clear, or a solid that is not where it is drawn. A run that starts in the
## start zone, crosses everything in between and is timed by the finish -- the timer the
## game itself feeds, with no put-back by a pit on the way -- is the one check that a
## block moved or a brush lost fails. A map with no route file says so and passes: a
## route is data written per map (`tools/route_plan.py`), and most maps do not have one
## yet. See route_bot.gd for how the bot drives it.
func _test_runs_its_route() -> void:
	_section("route")
	# The route bot lands on a block and runs to its lip, and the recording is that bot's:
	# both are a test of the collision line, and a sinking block (a door, or a map's
	# anti-standing trap, 0.09 s on bhop_grove) sends a player who does that straight
	# back. In Source too: a person hops every block. `headless_mechanics` asks the blocks.
	if game.mechanics != null:
		game.mechanics.blocks.clear()
	var why: Array = []
	var points := RouteBot.load_points(_map_id, why)
	var zones := game.timers.zones if game != null else null
	var finish: DotTimerZone = null
	if zones != null:
		for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.END):
			if zone.track == DotTimerTrack.MAIN:
				finish = zone
	if points.is_empty():
		_check(true, "a bot runs it start to finish on its route", why[0] if not why.is_empty() else "no route")
		_done()
		return
	if finish == null:
		_check(false, "a bot runs it start to finish on its route", "it has a route and no finish")
		_done()
		return

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	var node := game.current_map_node()
	var router := RouteBot.new(points, finish.centre())
	var put_back: Array[String] = []
	var finished: Array[float] = []
	var on_effect := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid != &"bot":
			return
		match zone.kind:
			DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
				if put_back.is_empty():
					put_back.append(str(G2GUnits.vector_to_units(bot.global_position).round()))
			DotTimerZone.Kind.TELEPORT:
				router.teleported.call_deferred()
	var on_finish := func(run: DotTimerRun) -> void:
		finished.append(run.time())
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finish)
	bot.timer.stop()
	bot.teleport(node.spawn_for(DotTimerTrack.MAIN), node.spawn_yaw_for(DotTimerTrack.MAIN))
	await get_tree().physics_frame

	var delta := 1.0 / float(game.tick_rate)
	var space := node.get_world_3d().direct_space_state
	var ticks := int(ROUTE_SECONDS * float(game.tick_rate))
	var t := 0
	while t < ticks and finished.is_empty() and put_back.is_empty():
		bot.controller.apply_command(router.command(bot.controller.state, space, bot.controller.tunables, delta))
		await get_tree().physics_frame
		t += 1
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finish)

	var at := str(G2GUnits.vector_to_units(bot.controller.state.position).round())
	if not finished.is_empty():
		print("        finished in %.2f s over %d points, %d ticks surfing" % [finished[0], points.size(), router.surfed])
	_check(not finished.is_empty() and put_back.is_empty(), "a bot runs it start to finish on its route",
		("finished in %.2f s over %d points" % [finished[0], points.size()]) if not finished.is_empty()
		else ("put back by a pit (sent to %s u), aiming at point %d of %d" % [put_back[0], router.index + 1, points.size()])
			if not put_back.is_empty()
		else ("not finished after %.0f s at %s u, aiming at point %d of %d" % [ROUTE_SECONDS, at, router.index + 1, points.size()]))
	bot.timer.stop()
	_done()


## The frame a recording is lifted off the map from, in the check that a run which cannot
## be followed is reported where it stops being followable.
const LIFT_FROM_FRAME := 2000
const LIFT_UNITS := 200.0


## A bot drives the REAL movement along the run recorded for the map
## (`maps/routes/<id>.replay`, a dot-timer replay) and the game's own timer finishes it
## (`g2gfast-route-bot-1`). See replay_follow.gd.
##
## [b]This and the route section ask different things.[/b] The route is points a planner
## or a person wrote down and a bot that finds its own way between them; a recording is
## the way one run actually went, tick by tick, and following it is the check that the
## collision is still the collision that run was made on. When it is not, the answer
## is a place: "left the recorded line at frame N, (x, y, z)". The second check proves
## that report, on a copy of the recording lifted off the map from [constant
## LIFT_FROM_FRAME]: it must say the line was left there, not that a pit fired or that
## time ran out. A map with no recording passes both and says so: a recording is a
## person's ride (or `stage_ride`'s, saved with RIDE_SAVE_REPLAY), one per map.
func _test_follows_its_recording() -> void:
	_section("recording")
	# The route bot lands on a block and runs to its lip, and the recording is that bot's:
	# both are a test of the collision line, and a sinking block (a door, or a map's
	# anti-standing trap, 0.09 s on bhop_grove) sends a player who does that straight
	# back. In Source too: a person hops every block. `headless_mechanics` asks the blocks.
	if game.mechanics != null:
		game.mechanics.blocks.clear()
	var why: Array = []
	var replay := ReplayFollow.load_for(_map_id, why)
	if replay == null:
		_check(true, "a bot follows its recorded run start to finish", why[0])
		_check(true, "and a recording it cannot follow is reported where it leaves the line", why[0])
		_done()
		return
	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null

	var result: Dictionary = await ReplayFollow.drive(game, bot, replay, replay.duration() * 1.2)
	print("        %s" % ReplayFollow.summary(result))
	_check(float(result["finished"]) >= 0.0, "a bot follows its recorded run start to finish",
		ReplayFollow.summary(result))

	var lifted := DotTimerReplay.from_bytes(replay.to_bytes()).value as DotTimerReplay
	for i in range(LIFT_FROM_FRAME, lifted.frames.size()):
		lifted.frames[i].position.y += G2GUnits.to_metres(LIFT_UNITS)
	var off: Dictionary = await ReplayFollow.drive(game, bot, lifted, replay.duration() * 1.2)
	var left: Dictionary = off["left_at"]
	print("        lifted from frame %d: %s" % [LIFT_FROM_FRAME, ReplayFollow.summary(off)])
	_check(not left.is_empty() and int(left["frame"]) >= LIFT_FROM_FRAME - ReplayFollow.SEARCH_BEHIND
			and int(left["frame"]) < LIFT_FROM_FRAME + ReplayFollow.LEAD_FRAMES * 4,
		"and a recording it cannot follow is reported where it leaves the line",
		ReplayFollow.summary(off))
	bot.timer.stop()
	_done()
