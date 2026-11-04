extends "headless_presentation_stubs.gd"

## Preloads, state and helpers shared by the presentation suite files.

const G2GParty := preload("../game/g2g_party.gd")
const G2GWeaponIcons := preload("../game/g2g_weapon_icons.gd")
const G2GPresentation := preload("../game/g2g_presentation.gd")
const G2GVote := preload("../game/g2g_vote.gd")
const G2GRig := preload("../game/g2g_rig.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GHud := preload("../game/g2g_hud.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GBindings := preload("../game/g2g_bindings.gd")
const G2GFlashlight := preload("../game/g2g_flashlight.gd")
const G2GMenuPages := preload("../game/ui/g2g_menu_pages.gd")
const G2GClient := preload("../game/g2g_client.gd")

## Checks a section declined to run, counted so the total still adds up to [constant CHECKS].
var _skipped := 0
var _entered := 0
var _completed := 0


func _make() -> G2GPresentation:
	var p := G2GPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	# The client builds the console after its menu; there is no menu here.
	p.build_console()
	# A memory store. A suite that writes to `user://` is one whose result depends on
	# what the last run left there -- which this family already shipped once, as a
	# dedicated suite that began failing on its ninth run.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


## Stands in for a dot-server in this process: all the kit asks of one is a `console`.
class FakeServer extends RefCounted:
	var console := FakeConsole.new()


class FakeConsole extends RefCounted:
	var ran := PackedStringArray()

	func execute(line: String) -> DotResult:
		ran.append(line)
		return DotResult.success("")

	func command_names() -> PackedStringArray:
		return PackedStringArray(["s3", "quit"])


# --- 5 ----------------------------------------------------------------------

## How many of [param node]'s visuals a camera with [param mask] would draw.
func _drawn_by(node: Node, mask: int) -> int:
	var count := 0

	if node is VisualInstance3D and (node as VisualInstance3D).layers & mask != 0:
		count += 1

	for child in node.get_children():
		count += _drawn_by(child, mask)

	return count


## The real menu as the client builds it: dot-menu's, with this game's keys and pages.
func _menu_for(p: G2GPresentation, host: Node) -> DotMenu:
	var menu := DotMenu.new()
	menu.settings = p.settings
	menu.bindings = p.bindings
	menu.config = DotMenuConfig.new()
	menu.config.escape_grace_ms = 0
	menu.manage_pointer = false
	menu.help_action = &"g2g_help"
	menu.theme_action = &"g2g_theme_next"
	menu.scoreboard_action = &"g2g_scoreboard"
	add_child(menu)
	var _set := menu.setup()
	G2GMenuPages.install(menu, host)
	return menu


func _live(root: Node, type: String) -> Array:
	return root.find_children("*", type, true, false).filter(
		func(n: Node) -> bool: return n.is_inside_tree() and not n.is_queued_for_deletion())


func _row(menu: DotMenu, id: String) -> Node:
	return menu.screen.find_child("Row_%s" % id, true, false)


## Every .gd file under [param dir], recursively.
func _scripts_under(dir: String) -> Array[String]:
	var out: Array[String] = []
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_scripts_under(dir.path_join(sub)))
	return out


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _skip(count: int, why: String) -> void:
	_skipped += count
	print("  skip  %d check(s): %s" % [count, why])
