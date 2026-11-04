extends DotGameCheckSuite

## Constants, state and the lighting section of headless_imported.

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GLighting := preload("../game/g2g_lighting.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GStockSubstitutes := preload("../game/g2g_stock_substitutes.gd")
const RouteBot := preload("../game/g2g_route_bot.gd")
const ReplayFollow := preload("../tools/replay_follow.gd")
const G2GSurfCourse := preload("../game/g2g_surf_course.gd")
const SurfPlan := preload("../tools/surf_plan.gd")

## Checks a map imported from a Source .bsp: it loads, it is the right size, it is lit, and a player put on it stays on it.
## Collision is the check, not geometry: every count and bound can pass while triangles are wound inside out or the collision body was never built, and the player falls through a map that renders perfectly.
## Skips rather than fails when nothing is imported: `maps/imported/` is optional content.

## The imported maps that are deliberately NOT courses (see `maps/zones/README.md`).
## `buses_from_hell_fixed` is a vehicle map with no route to time. `bhop_lego2` is a section chain whose END is not labelled, and guessing would give a leaderboard that measures a route the map does not have.
## Checked both ways so it is not a mute button: a listed map that turns out to HAVE a runnable main track fails, because the list is then the lie. Combat surf maps live in `../arena-surf-dm-maps`.
const NOT_COURSES := ["buses_from_hell_fixed", "bhop_lego2", "kz_bhop_yonkoma", "bunnyhop_pro", "surf_animals",
	"kz_bhop_lucid", "bhop_training_fun"]

## The imported maps with no pit, a different question from having no finish.
## A separate list from [constant NOT_COURSES] on purpose: a surf or bhop map's `trigger_teleport` volumes ARE its pit and losing them means falling for ever.
## Only `buses_from_hell_fixed` has none (nothing to fall off); folding the lists together is how an exemption quietly grows.
const NO_PIT := ["buses_from_hell_fixed"]

## Maps whose main spawn stands in a `trigger_push`, which is run: the player is carried off the pad on appearing (surf_quilavar's is the foot of a 2000-unit updraft).
## For these the "comes to rest inside the start zone" check asks that the push moved the player UP and away, both ways: a listed map whose player rests in its start fails.
const SPAWNS_IN_A_PUSH := ["surf_quilavar"]

## Arrivals on these maps that DO land inside a pit on their own track, by label (`[arrive-1]`: known, not accepted).
## surf_greensway stage 2 is the standing case: its arrival is inside the hull of the mapper's own teleport, so its zones file makes it a split with no restart (`restart: false`, `[arrive-2]`) and `!s2` is refused with the reason.
## Empty-able, asserted both ways like [constant NOT_COURSES]: a map whose arrival stops landing in a pit fails.
const ARRIVES_IN_PIT := {}

## Arrivals the map drops a player from on purpose, by label: surf_rookie's stage 2 puts you over a tube whose own pit returns you to the same arrival.
## A bot standing still falls 8.2 m in the window this check waits, so the bound is 20 m: a drop the map means, never a fall out of the world.
const FALLING_ARRIVALS := {"surf_rookie": ["stage 2"]}

## Imported bonuses with no pit of their own, by track, which `route_problems()` reports; empty, kept so the next one has somewhere to go.
## `pit_tracks` in `tools/bsp_import.py` gives a teleport to the track whose START its destination is in.
## Asserted both ways: a listed map must report exactly these tracks, an unlisted map none.
const BONUSES_WITHOUT_PITS := {}

## The least share of a map's triangles drawn in a real texture (its pakfile's, or a Kenney stand-in from `G2GStockSubstitutes`), for the maps whose stand-ins have been chosen and looked at (`[g2g-maps-stock-1]`).
const STOCK_DRAWN := {
	"bhop_aztec": 0.66,  # 69.5% on 2026-10-09; 0% before: sandstone courses, looked at along the route
	"surf_beginner2": 0.89,  # 94.7% on 2026-10-09; 2.6% before: planks, rock, sand, looked at along the route
	"bhop_interloper": 0.92,  # 96.9% on 2026-10-09; 50% before: the dirt walkways, looked at along the route
	"buses_from_hell_fixed": 0.96,  # 99.2% on 2026-10-10 (stand-ins from the reference sheet); 94.5% on 2026-10-09; 0% before: the sand floor, looked at from the spawn
	"bhop_monster_jam": 0.76,  # 79.3% on 2026-10-10 (stand-ins from the reference sheet); 77.5% on 2026-10-09; 1.9% before: dark rock, looked at from the finish
	"surf_year3000": 0.81,  # 86.1% on 2026-10-09; 0.8% before: CC0 concrete and metal (2026-10-09)
	"surf_mesa": 0.94,  # 99.9% on 2026-10-09; 91.8% before: concrete walls and ramps, against the WR run
	"bhop_exodus": 0.84,  # 87.5% on 2026-10-11 (sixth batch: its aoki dev blends listed, stone floors); 81.3% on 2026-10-10 (stand-ins from the reference sheet); 74.7% on 2026-10-09; 10.7%: planks, concrete, looked at from the spawn
	"bunnyhop_pro": 0.66,  # 69.7% on 2026-10-10 (glass fence see-through); 66.1% before the fifth batch; 53.1% before: sand floor, stone walls, concrete courtyard, looked at from the spawn
	"surf_eclipse": 0.95,  # 98.7% on 2026-10-10 (fifth batch); 96.7% before it; 0% own: tiles, metal, glass walls over the sky, looked at from the spawn
	"surf_beginner": 0.88,  # 91.4% on 2026-10-10 (fifth batch); 91.3% before it; 0% own: plank floor, concrete walls, looked at from the spawn
	"surf_lore": 0.83,  # 86.3% on 2026-10-10 (fifth batch); 84.5% before it; 1.5% own: metal panels, concrete, sandstone steps, looked at from the spawn
	"bhop_ananas": 0.67,  # 70.2% on 2026-10-11; 3.6% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_arcane_v2": 0.91,  # 94.1% on 2026-10-11 after its packed copies of the source game's textures were dropped (54.2% own; 96.3% own before): dirt, plaster, stone as stand-ins, the stock trees listed; looked at from the spawn (sheet stock_packed_dropped_before_after)
	"bhop_badges": 0.66,  # 69.6% on 2026-10-11; 68.3% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_badges2": 0.03,  # 6.2% on 2026-10-11; 6.2% own: flat developer textures held on purpose, UNLISTED_LIMIT is its check (sheet stock_floors_before_0)
	"bhop_badges_mini": 0.72,  # 75.3% on 2026-10-11; 73.9% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_crash_egypt": 0.93,  # 96.7% on 2026-10-11; 96.7% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_eazy": 0.97,  # 100.0% on 2026-10-11; 100.0% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_eazy_v2": 0.97,  # 100.0% on 2026-10-11; 100.0% own: looked at from the spawn (sheet stock_floors_before_0)
	"bhop_evolve": 0.96,  # 99.9% on 2026-10-11; 99.9% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_frotinity2": 0.92,  # 95.7% on 2026-10-11; 62.8% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_fur": 0.86,  # 89.4% on 2026-10-11; 89.4% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_fury_2": 0.97,  # 100.0% on 2026-10-11; 99.9% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_grove": 0.97,  # 100.0% on 2026-10-11 (sixth batch: the forest floor as dirt from its own VMT); 17.9% before it; 0.0% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_japan": 0.94,  # 97.4% on 2026-10-11; 55.9% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_lego2": 0.96,  # 99.0% on 2026-10-11; 99.0% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_lego3": 0.91,  # 94.7% on 2026-10-11; 94.7% own: looked at from the spawn (sheet stock_floors_before_1)
	"bhop_platformer_fxd": 0.89,  # 92.9% on 2026-10-11; 87.5% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_ocean": 0.96,  # 99.2% on 2026-10-11; 31.1% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_overthinker": 0.88,  # 91.2% on 2026-10-11; 91.2% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_pandora2_fix": 0.96,  # 99.4% on 2026-10-11; 99.3% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_pit": 0.97,  # 100.0% on 2026-10-11; 100.0% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_sqee": 0.97,  # 100.0% on 2026-10-11; 98.0% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_supernova": 0.95,  # 98.9% on 2026-10-11; 98.9% own: looked at from the spawn (sheet stock_floors_before_2)
	"bhop_tesquo_v2": 0.92,  # 95.2% on 2026-10-11; 55.5% own: looked at from the spawn (sheet stock_floors_before_2)
	"kz_bhop_badg3s": 0.88,  # 91.3% on 2026-10-11; 83.8% own: looked at from the spawn (sheet stock_floors_before_3)
	"kz_bhop_lucid": 0.88,  # 91.8% on 2026-10-11; 57.5% own: looked at from the spawn (sheet stock_floors_before_3)
	"kz_bhop_yonkoma": 0.08,  # 11.2% on 2026-10-11; 11.2% own: flat developer textures held on purpose, UNLISTED_LIMIT is its check (sheet stock_floors_before_3)
	"surf_animals": 0.95,  # 98.0% on 2026-10-11; 2.2% own: looked at from the spawn (sheet stock_floors_before_3)
	"surf_aquaflow": 0.95,  # 98.6% on 2026-10-11; 97.8% own: looked at from the spawn (sheet stock_floors_before_3)
	"surf_arcade": 0.56,  # 59.1% on 2026-10-11; 55.1% own: looked at from the spawn (sheet stock_floors_before_4)
	"surf_greensway": 0.95,  # 98.5% on 2026-10-11; 98.5% own: looked at from the spawn (sheet stock_floors_before_4)
	"surf_interference": 0.97,  # 100.0% on 2026-10-11 (sixth batch: boundary wall and crystals as glass); 100.0% before it; 99.7% own: looked at from the spawn (sheet stock_floors_before_4)
	"surf_kitsune": 0.59,  # 62.4% on 2026-10-11; 47.8% own: looked at from the spawn (sheet stock_floors_before_4)
	"surf_life_of_duck": 0.96,  # 99.4% on 2026-10-11; 64.8% own: looked at from the spawn (sheet stock_floors_before_4)
	"surf_lt_omnific": 0.94,  # 97.8% on 2026-10-11; 97.8% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_lt_unicorn": 0.93,  # 96.1% on 2026-10-11; 96.1% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_omnibus": 0.92,  # 95.9% on 2026-10-11; 16.5% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_quilavar": 0.93,  # 96.8% on 2026-10-11; 38.5% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_rookie": 0.93,  # 96.9% on 2026-10-11 (sixth batch: waterfall sheets see-through); 95.7% before it; 27.7% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_stonework3": 0.96,  # 99.9% on 2026-10-11; 56.8% own: looked at from the spawn (sheet stock_floors_before_5)
	"surf_summit": 0.95,  # 98.9% on 2026-10-11; 93.8% own: looked at from the spawn (sheet stock_floors_before_6)
	"surf_vegetables": 0.85,  # 88.5% on 2026-10-11 (sixth batch: its own Früchte textures read); 75.3% before it; 30.7% own: looked at from the spawn (sheet stock_floors_before_6)
	"bhop_elate": 0.97,  # 100% on 2026-10-19 (stock_survey); armed late, imported after the floors sweep: looked at from the spawn
	"bhop_nature": 0.97,  # 99.6% on 2026-10-19; the 0.4% is color/black, flat black on purpose: looked at from the spawn
	"bhop_underground_crypt": 0.97,  # 100% on 2026-10-19 (batch8 stand-ins): looked at from the spawn
	"bhop_epiphany": 0.90,  # 94.2% on 2026-10-20 (stand-ins; 21% own); the rest is de_nuke beams and dev/light textures held on the grid: looked at from the spawn
	"surf_hologram": 0.14,  # 15.5% on 2026-10-19: a Source 2 map, its ramp materials are its own flat colours (none), no stock textures to stand in for
}

## The most of a map, by triangles, that may draw the prototype grid with neither a
## stand-in nor a `none` entry saying why (g2g-maps-stock-1's done-when). Every map was
## under 3% when it was set; armed by setting it to 0.1%: bhop_lego3, at 0.5%, failed.
const UNLISTED_LIMIT := 0.10

## The least share of a map's triangles drawn in the texture its own pakfile carried, for the maps where a parsing bug was measured taking it away:
## a leading `/` on the material name and a `$basetexture` with a space in it (99%, 97% and 100% after the fix; 2%, 8% and 0% before).
const OWN_TEXTURES := {
	"surf_interference": 0.9,
	"surf_aquaflow": 0.9,
	"bhop_eazy": 0.9,
}

## Maps whose terrain is mostly `WorldVertexTransition` blends with both textures in the
## pakfile: losing the second texture is the largest visible change
## any of them can have, and it fails nothing else.
const BLENDED := ["surf_mesa", "surf_summit", "surf_greensway", "bhop_evolve", "surf_aquaflow"]

## The least estimated linear luminance the view from a map's main spawn may have (`_spawn_view_luminance`), about 30 of 255 on screen.
## Set from the spread of all 87 maps: the black holding rooms measured 0.000, the lit maps 0.014 and up.
const SPAWN_VIEW_FLOOR := 0.012

## Maps whose spawn view is dark on purpose, each with why, asserted both ways: a listed map whose view clears [constant SPAWN_VIEW_FLOOR] fails.
## Listed only after it was rendered and compared with the map's own screenshots; "the importer drew it wrong" is never a reason.
const DARK_SPAWNS := {
	"kz_bhop_lucid": "the hub is a tools/toolsblack box round a lit floor with neon route markers; the map's own screenshots are neon on dark brick (rendered 2026-10-11)",
	"bhop_fury_2": "dark rooms lit by green and cyan neon, as its screenshots are (rendered 2026-10-11)",
	"bhop_fury": "the first fury, same mapper and look as bhop_fury_2: dark rooms lit by coloured light (its page screenshots are green, blue and yellow on near-black); the room at dest1 is lit red, 0.008 against the 0.012 floor (rendered 2026-10-23, chk-maps run 74)",
	"surf_kitsune": "black panels with neon lines under a sky named blacksky (map-rendering.md, black on purpose)",
	"surf_stonework3": "a torch-lit stone hall, as dim as its screenshots (rendered 2026-10-11)",
	"bhop_monster_jam": "the 24 spawns hang in a black void 2700 units over the lit platform and a player falls onto it (the map filters fall damage); looking down from there is the map's own first screenshot, spotlight pools and red carpet included, and only its tower, a stock building model, is not drawn (rendered 2026-10-11)",
	"kz_bhop_badg3s": "checkpoint `1`, where the spawn room sends you, is walled in stock cs_italy/black (reflectivity 0 in the .bsp, black in the source archive) round a lit concrete floor and unlit orange hologram blocks; the lightmap there is lit, and its screenshots are of the later concrete rooms (rendered 2026-10-11)",
}

## The maps with `$additive` surfaces the importer must find, asserted both ways (a map
## that loses them, or one not listed that gains them, fails).
const ADDITIVE := ["bhop_angst", "bhop_arcane_v2", "bhop_crash_egypt", "bhop_elate", "bhop_forgotten", "bhop_ocean",
	"bhop_overthinker", "bhop_tesquo_v2", "surf_aquaflow", "surf_greensway", "surf_interference",
	"surf_lt_omnific", "surf_lt_unicorn", "surf_quilavar", "surf_vegetables"]

## Checks every map gets. Tracks and stages add one each on top — see [member _expected].
const CHECKS_PER_MAP := 58

## Sections every map runs, entered against run to their last line.
## A runtime error aborts that function silently, so a section that bailed out after a failed guard counts as not finished; the two that end early because a map has nothing to check say so first.
const SECTIONS_PER_MAP := 13

## A script error inside a test aborts THAT TEST and not the run, so a suite that has
## quietly lost two checks still prints "0 failed" — which is what happened while this
## file was being written, to the zone section. The count is asserted, not trusted.
var _expected := 0
var _map_id: StringName = &""

var _entered := 0
var _completed := 0
var game: G2GGame = null


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
	# By text: sort() orders StringNames by interning, so the run order changed per process.
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


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

	_light_prototype(node)
	var tex_result := _light_textures(node)
	var share: float = tex_result[0]
	var floor_share: float = tex_result[1]
	var slashed: PackedStringArray = tex_result[2]
	_light_unlisted_and_water(node)
	_check(slashed.is_empty() and share >= floor_share,
		"and the textures its pakfile carried are drawn",
		"%.0f%% of triangles in their own texture, %.0f%% expected; names with a leading '/': %s"
			% [share * 100.0, floor_share * 100.0, slashed])

	_light_blend_additive(node)
	var world := node.get_node_or_null("Lighting") as WorldEnvironment
	_light_sky(node, world)

	# And what a player sees from the spawn is lit. No headless run can render, so this estimates the frame: rays from the eye
	# through the drawn meshes, each hit what the shader would draw there (albedo, baked light, ambient), each miss the sky.
	# See [constant DARK_SPAWNS]. An estimate cannot tell bhop_badges' dark spawn room from its lit black-walled sections, so its zones file names the start.
	var view := _spawn_view_luminance(node as G2GBspMap, world)
	var listed_dark := DARK_SPAWNS.has(String(_map_id))
	print("  spawn view %s: %.3f (display %.0f of 255)" % [_map_id, view, pow(view, 1.0 / 2.2) * 255.0])
	_check((view >= SPAWN_VIEW_FLOOR) != listed_dark,
		"and the view from its spawn is lit" if not listed_dark
			else "and the view from its spawn is dark, as DARK_SPAWNS says",
		"estimated linear luminance %.3f, floor %.3f%s" % [view, SPAWN_VIEW_FLOOR,
			"; listed: " + str(DARK_SPAWNS[String(_map_id)]) if listed_dark else ""])
	_done()


## Painted colours, and brush entities drawn.
func _light_prototype(node: G2GBspMap) -> void:
	# A texture the map did not carry is painted its own measured colour, not a role grey.
	# Most of a map is such surfaces, so a regression turns every map back into four greys, which no other
	# check sees (a grey surface is a correctly configured material). Most, not all: a light panel vrad measured as black keeps its role colour.
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


## Own textures and Kenney stand-ins; returns [share, floor_share, slashed].
func _light_textures(node: G2GBspMap) -> Array:
	# A texture the pakfile carried is drawn, not replaced by the prototype grid.
	# Two spellings were unread (a leading `/`, and a `$basetexture` with a space) and nothing said so, since a prototype surface is a correctly configured material.
	# A name with the slash still on it fails every map; the share is asserted for the maps in [constant OWN_TEXTURES].
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
	return [share, floor_share, slashed]


## Nothing on the grid without a reason, and untextured water drawn as water.
func _light_unlisted_and_water(node: G2GBspMap) -> void:
	# And what is still on the grid is there for a written reason: every triangle with no texture, not water, no stand-in
	# and no `none` entry in textures/stock/substitutes.json is a material nobody looked at, under
	# [constant UNLISTED_LIMIT] of the map. A new unknown material family fails here, not on somebody's screen.
	var all_tris := 0
	var unlisted := 0
	var worst := {}
	for entry: Dictionary in node.manifest.get("surfaces", []):
		var n := int(entry.get("index_count", 0)) / 3
		all_tris += n
		if entry.get("texture", null) is String and not str(entry["texture"]).is_empty():
			continue
		var material := str(entry.get("material", ""))
		if G2GBspMap.is_water_material(material) \
				or not G2GStockSubstitutes.for_material(material).is_empty() \
				or G2GStockSubstitutes.is_listed(material):
			continue
		unlisted += n
		worst[material] = int(worst.get(material, 0)) + n
	var unlisted_share := float(unlisted) / float(maxi(all_tris, 1))
	var names := worst.keys()
	names.sort_custom(func(a: String, b: String) -> bool: return int(worst[a]) > int(worst[b]))
	_check(unlisted_share < UNLISTED_LIMIT,
		"and nothing it did not carry is on the grid without a reason",
		"%.1f%% of triangles unlisted, under %.0f%% wanted; most: %s"
			% [unlisted_share * 100.0, UNLISTED_LIMIT * 100.0, names.slice(0, 4)])
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


## Blend and additive surfaces are drawn as such.
func _light_blend_additive(node: G2GBspMap) -> void:
	# A blend material draws both its textures: `WorldVertexTransition` paints a second texture by vertex alpha,
	# which travels in its own block (`alpha_offset`) and reaches the shader as COLOR.a, so a drawn blend surface
	# needs the texture and a varying colour array. [constant BLENDED] names maps that must have one.
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

	# An `$additive` surface is drawn added: drawn opaque, surf_lt_unicorn's see-through rainbow bands were black sheets
	# with every value correct. Every manifest surface marked `additive` is on the additive shader; [constant ADDITIVE]
	# names maps that must have some. Armed by taking the additive branch out of G2GBspMap._material_for.
	var additive_wanted := 0
	for entry: Dictionary in node.manifest.get("surfaces", []):
		if bool(entry.get("additive", false)):
			additive_wanted += 1
	var additive_drawn := 0
	for drawn_node: Node in node.find_children("*", "MeshInstance3D", true, false):
		var each_mi := drawn_node as MeshInstance3D
		for i in range(each_mi.get_surface_override_material_count()):
			var am := each_mi.get_surface_override_material(i) as ShaderMaterial
			if am != null and am.shader != null and am.shader.resource_path.contains("additive"):
				additive_drawn += 1
	_check(additive_drawn == additive_wanted and (additive_wanted > 0) == ADDITIVE.has(String(_map_id)),
		"and its additive surfaces are drawn added",
		"%d drawn added, %d marked additive, listed in ADDITIVE: %s"
			% [additive_drawn, additive_wanted, ADDITIVE.has(String(_map_id))])


## The sky is not a blank dome, a packed sky is bound, a black sky is black.
func _light_sky(node: G2GBspMap, world: WorldEnvironment) -> void:
	# No blank white dome: the procedural sky's top is the map's `_ambient`; G2GLighting looks up the editor-default ones by sky name.
	var top := Color(0, 0, 0)
	if world != null and world.environment != null and world.environment.sky != null:
		var sky_mat := world.environment.sky.sky_material as ProceduralSkyMaterial
		if sky_mat != null:
			top = sky_mat.sky_top_color
	_check(minf(top.r, minf(top.g, top.b)) < 0.99,
		"and its sky is not a blank white dome", "sky top %s, sky name '%s'"
			% [top, node.manifest.get("lighting", {}).get("sky_name", "")])

	# A sky the map packed is the sky drawn: 36 held maps carry their own six faces (`lighting.sky_faces`).
	# Passes on a map with none. Armed by taking `_apply_packed_sky` out of G2GBspMap.
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

	# And a sky named black is black, horizon included: surf_kitsune names `blacksky` and was drawn under the pale default dome.
	# Armed by taking `_darken_black_sky` out of G2GLighting.apply; fires on surf_kitsune alone.
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


## The estimated linear luminance of the view from a map's main spawn: 8 headings by 3 pitches from eye height, through every drawn World and Props surface.
## A hit is what the material draws ([method _surface_albedo]) under the atlas's light; see-through surfaces are passed through; a miss is the sky.
## No fog and no tone map, so it reads a little bright, the safe side for a floor.
func _spawn_view_luminance(node: G2GBspMap, world: WorldEnvironment) -> float:
	var meshes: Array[MeshInstance3D] = []
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh != null and (String(mi.name).begins_with("World") or String(mi.name).begins_with("Props")):
			meshes.append(mi)
	var lightmap: Image = null
	var tris: Array = []        # per mesh: TriangleMesh
	var firsts: Array = []      # per mesh: the first face index of each surface
	for mi in meshes:
		tris.append(mi.mesh.generate_triangle_mesh())
		var starts := PackedInt32Array()
		var at := 0
		for i in range(mi.mesh.get_surface_count()):
			starts.append(at)
			at += mi.mesh.surface_get_array_index_len(i) / 3
			if lightmap == null:
				var m := mi.get_surface_override_material(i) as ShaderMaterial
				var lm_tex: Variant = m.get_shader_parameter("lightmap_tex") if m != null else null
				if lm_tex is Texture2D:
					lightmap = (lm_tex as Texture2D).get_image()
					if lightmap != null and lightmap.is_compressed():
						lightmap.decompress()
		firsts.append(starts)
	var sky := _sky_luminance(node, world)
	var eye := node.spawn_for(0) + Vector3.UP * 1.2
	var total := 0.0
	var rays := 0
	for pitch: float in [-0.3, -0.1, 0.1]:
		for k in range(8):
			var dir := Vector3.FORWARD.rotated(Vector3.RIGHT, pitch).rotated(Vector3.UP, TAU * k / 8.0)
			total += _ray_luminance(meshes, tris, firsts, lightmap, eye, dir, sky)
			rays += 1
	return total / float(rays)


func _ray_luminance(meshes: Array[MeshInstance3D], tris: Array, firsts: Array,
		lightmap: Image, eye: Vector3, dir: Vector3, sky: float) -> float:
	var from := eye
	for _pass in range(24):
		var best := {}
		var best_mesh := -1
		for m in range(meshes.size()):
			var tm := tris[m] as TriangleMesh
			if tm == null:
				continue
			# The meshes sit at the map's origin; a mesh moved off it would want its
			# transform here, and none is.
			var hit: Dictionary = tm.intersect_ray(from, dir)
			if hit.is_empty():
				continue
			if best.is_empty() or from.distance_to(hit["position"]) < from.distance_to(best["position"]):
				best = hit
				best_mesh = m
		if best.is_empty():
			return sky
		var mi := meshes[best_mesh]
		var starts: PackedInt32Array = firsts[best_mesh]
		var face := int(best["face_index"])
		var surface := starts.bsearch(face, false) - 1
		var mat := mi.get_surface_override_material(surface) as ShaderMaterial
		var albedo := _surface_albedo(mat)
		var two_sided := mat != null and mat.shader != null and mat.shader.resource_path.contains("water")
		var facing := (best["normal"] as Vector3).dot(dir) < 0.0
		if albedo < 0.0 or (not facing and not two_sided):
			from = (best["position"] as Vector3) + dir * 0.01
			continue
		var light := 1.0
		var boost := 1.0
		var lift := 0.0
		if mat != null and mat.shader != null and not mat.shader.resource_path.contains("additive"):
			light = _lightmap_at(mi, surface, face - starts[surface], best["position"], lightmap)
			boost = float(mat.get_shader_parameter("light_boost")) if mat.get_shader_parameter("light_boost") != null else 1.35
			lift = float(mat.get_shader_parameter("ambient")) if mat.get_shader_parameter("ambient") != null else 0.10
		return albedo * (light * boost + lift)
	return sky


## The linear luminance a material draws before light, or -1 for one a player sees
## through. The texture it samples, averaged, times its tint, both decoded from sRGB as
## the shader's `source_color` does.
func _surface_albedo(mat: ShaderMaterial) -> float:
	if mat == null or mat.shader == null:
		return 0.5
	var path := mat.shader.resource_path
	if path.contains("additive") or path.contains("translucent"):
		return -1.0
	var tint: Variant = mat.get_shader_parameter("tint")
	var colour: Color = (tint as Color) if tint is Color else Color.WHITE
	var tex: Variant = null
	if mat.get_shader_parameter("pixel_art") == true:
		tex = mat.get_shader_parameter("pixel_tex")
	elif mat.get_shader_parameter("has_albedo") != false:
		tex = mat.get_shader_parameter("albedo_tex")
	var base := _texture_mean(tex as Texture2D) if tex is Texture2D else Color.WHITE
	return (base * colour).srgb_to_linear().get_luminance()


var _texture_means := {}

func _texture_mean(tex: Texture2D) -> Color:
	var key := tex.get_rid()
	if _texture_means.has(key):
		return _texture_means[key]
	var img := tex.get_image()
	var mean := Color(0.5, 0.5, 0.5)
	if img != null:
		img = img.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		# Halving with a bilinear filter averages each 2x2 exactly, so this is the mean of
		# the whole picture rather than a few samples of it -- a rainbow band is stripes.
		while img.get_width() > 4 or img.get_height() > 4:
			img.resize(maxi(img.get_width() / 2, 1), maxi(img.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
		var sum := Color(0, 0, 0, 0)
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				sum += img.get_pixel(x, y)
		mean = sum / float(img.get_width() * img.get_height())
	_texture_means[key] = mean
	return mean


## The baked light on a hit, linear: the atlas texel under the hit's UV2, interpolated
## across the triangle.
func _lightmap_at(mi: MeshInstance3D, surface: int, triangle: int, at: Vector3, lightmap: Image) -> float:
	if lightmap == null:
		return 1.0
	var arrays := mi.mesh.surface_get_arrays(surface)
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2s: Variant = arrays[Mesh.ARRAY_TEX_UV2]
	if not (uv2s is PackedVector2Array) or index.size() < triangle * 3 + 3:
		return 1.0
	var a := verts[index[triangle * 3]]
	var b := verts[index[triangle * 3 + 1]]
	var c := verts[index[triangle * 3 + 2]]
	var w := Geometry3D.get_triangle_barycentric_coords(at, a, b, c)
	var uv := (uv2s as PackedVector2Array)[index[triangle * 3]] * w.x \
		+ (uv2s as PackedVector2Array)[index[triangle * 3 + 1]] * w.y \
		+ (uv2s as PackedVector2Array)[index[triangle * 3 + 2]] * w.z
	var x := clampi(int(uv.x * lightmap.get_width()), 0, lightmap.get_width() - 1)
	var y := clampi(int(uv.y * lightmap.get_height()), 0, lightmap.get_height() - 1)
	return lightmap.get_pixel(x, y).srgb_to_linear().get_luminance()


## What a ray that hits nothing sees: the packed sky's six faces averaged, or the
## procedural sky's top and horizon, or the background colour.
func _sky_luminance(node: G2GBspMap, world: WorldEnvironment) -> float:
	if world == null or world.environment == null:
		return 0.0
	var env := world.environment
	if env.background_mode != Environment.BG_SKY or env.sky == null:
		return env.background_color.srgb_to_linear().get_luminance()
	var shader_sky := env.sky.sky_material as ShaderMaterial
	if shader_sky != null:
		var sum := 0.0
		var n := 0
		for suffix: String in ["rt", "lf", "bk", "ft", "up"]:
			var face: Variant = shader_sky.get_shader_parameter("face_" + suffix)
			if face is Texture2D:
				sum += _texture_mean(face as Texture2D).srgb_to_linear().get_luminance()
				n += 1
		return sum / float(maxi(n, 1))
	var procedural := env.sky.sky_material as ProceduralSkyMaterial
	if procedural != null:
		return (procedural.sky_top_color.srgb_to_linear().get_luminance()
			+ procedural.sky_horizon_color.srgb_to_linear().get_luminance()) * 0.5
	return 0.3
