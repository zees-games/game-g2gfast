extends RefCounted

## What this game's Escape menu has on it: dot-menu's stock pages, rearranged, reworded for a
## timer server, and this game's own rows added.
##
## [b]Data, and that is all this file is.[/b] The menu itself — the sidebar, the cards, the
## switches, the key rebinder, the theme, Escape and the pointer — is dot-menu's since
## 2026-10-09; it was 1,600 lines across seven files here, and every other game wanted the
## same thing. What is left is what this game says: which settings go on which page, the
## genre's words for them, and the rows that are not settings at all.
##
## [b]The rows that are not settings stay live rows.[/b] The style, the flashlight and third
## person are state the server has a say in; a stored "flashlight on" would be a promise the
## next server is free to break. They ask the client (`menu_*` on [G2GClient]) and change it
## through the same methods the keys do.

const PAGE_ORDER := ["general", "hud", "gameplay", "video", "audio", "controls"]


## Puts this game's pages on [param menu]. [param client] answers the live rows.
static func install(menu: DotMenu, client: Node) -> void:
	var keys: DotMenuBindings = menu.bindings
	var key_for := func(action: StringName) -> String: return keys.key_for(action) if keys != null else "—"

	# --- General: what the HUD shows, and chat ---------------------------------------
	var general := menu.page(&"general")
	general.blurb = "What the HUD shows, and chat."
	var fps_row := general.take_row(&"show_fps")
	var _comfort := general.remove_section(&"comfort")
	var _interface := general.remove_section(&"interface")
	var hud_card := DotMenuSection.make("Heads-up display")
	hud_card.add(DotMenuRow.toggle(&"show_speed", "Speed", "Your speed in units per second, under the clock.")) \
		.add(DotMenuRow.toggle(&"show_splits", "Splits", "How each stage compares with your best and the record.")) \
		.add(DotMenuRow.toggle(&"show_stage_splits", "Stage splits", "A panel of every stage against your best or the record, on a map that has stages. What it compares with is Split against, under HUD & theme.")) \
		.add(DotMenuRow.toggle(&"show_zones", "Zones", "The start, stages and finish drawn as glowing boxes in the world.")) \
		.add(DotMenuRow.toggle(&"show_keys", "Key display", "Which movement keys the simulation saw this tick.")) \
		.add(DotMenuRow.toggle(&"show_crosshair", "Crosshair"))
	if fps_row != null:
		hud_card.add(fps_row)
	var _hud_first := general.insert_section(hud_card, &"chat")

	# --- HUD & theme ----------------------------------------------------------------
	var hud := DotMenuPage.make(&"hud", "HUD & theme",
		"The colours, the timer's lines, and where everything goes. Saved to your account.")
	hud.section("Theme").add(DotMenuRow.select(&"ui_theme", "Theme", "", menu.themes.options())
		.described_by(func() -> String: return "The menus and the HUD. %s cycles through them." % key_for.call(&"g2g_theme_next")))
	var layout := hud.section("Layout")
	layout.add(DotMenuRow.live_select("Start from", "Sets every switch below at once; change anything after.",
		[[&"", "Choose…"]] + (client.call("menu_layout_presets") as Array),
		func() -> StringName: return &"",
		func(id: Variant) -> void:
			if StringName(str(id)) == &"":
				return
			client.call("menu_apply_layout_preset", StringName(str(id)))
			menu.screen.toast("Layout applied.")
			menu.screen.refresh()).named(&"layout_preset"))
	layout.add(DotMenuRow.button("Arrange", "Drag the timer, the keys, the status line and the spectator list wherever you want them.",
		"Move HUD elements", func() -> void: client.call("menu_edit_layout")).named(&"arrange"))
	layout.add(DotMenuRow.select(&"timer_position", "Timer position", "Where the clock sits, unless you have dragged it.",
		[[&"bottom_centre", "Bottom centre"], [&"bottom_left", "Bottom left"], [&"bottom_right", "Bottom right"],
		[&"top_left", "Top left"], [&"top_centre", "Top centre"], [&"top_right", "Top right"]]))
	layout.add(DotMenuRow.slider(&"timer_size", "Timer size").formatted(DotMenuRow.FORMAT_INT))
	layout.add(DotMenuRow.toggle(&"timer_compact", "Compact", "Style, track, stage and statistics on one line."))
	hud.section("On the timer") \
		.add(DotMenuRow.toggle(&"timer_show_time", "Time", "The running time itself.")) \
		.add(DotMenuRow.toggle(&"timer_show_track", "Style & track")) \
		.add(DotMenuRow.toggle(&"timer_show_stage", "Stage", "Stage 2 / 5, on a map with stages.")) \
		.add(DotMenuRow.toggle(&"timer_show_stats", "Jumps, strafes & sync")) \
		.add(DotMenuRow.toggle(&"timer_show_standing", "Record & rank", "The record, your best and your place.")) \
		.add(DotMenuRow.select(&"timer_comparison", "Split against", "",
			[[&"pb", "Your best"], [&"wr", "The record"], [&"none", "Nothing"]]))
	hud.section("Around the screen") \
		.add(DotMenuRow.toggle(&"show_status", "Status line", "The map, time left and the rules, along the top.")) \
		.add(DotMenuRow.toggle(&"show_spectators", "Who is spectating you", "When the server shares it."))
	var _h := menu.add_page(hud, &"video")

	# --- Gameplay -------------------------------------------------------------------
	var gameplay := DotMenuPage.make(&"gameplay", "Gameplay", "Your style, your view, and what else is drawn on the course.")
	var run := gameplay.section("Your run")
	run.add(DotMenuRow.note("No styles yet — the server has not said which it runs.")
		.named(&"no_styles").shown_when(func() -> bool: return (client.call("menu_styles") as Array).is_empty()))
	run.add(DotMenuRow.custom("Style",
		"How you run: normal, sideways, half-sideways, W only and the rest. Changing it restarts your run.",
		func(_kit: DotMenuKit) -> Control: return _style_picker(client)).named(&"style")
		.shown_when(func() -> bool: return not (client.call("menu_styles") as Array).is_empty()))

	var view := gameplay.section("View")
	view.add(DotMenuRow.live_toggle("Flashlight", "",
		func() -> bool: return bool(client.call("menu_flashlight_on")),
		func(on: bool) -> void: client.call("menu_set_flashlight", on))
		.named(&"flashlight")
		.enabled_when(func() -> bool: return bool(client.call("menu_flashlight_allowed")))
		.described_by(func() -> String:
			if not bool(client.call("menu_flashlight_allowed")):
				return "This server has turned flashlights off (sv_flashlight 0)."
			return "Only you see it. %s toggles it." % key_for.call(&"g2g_flashlight")))
	view.add(DotMenuRow.live_toggle("Third person", "",
		func() -> bool: return bool(client.call("menu_third_person_on")),
		func(on: bool) -> void: client.call("menu_set_third_person", on))
		.named(&"third_person")
		.enabled_when(func() -> bool: return bool(client.call("menu_third_person_allowed")))
		.described_by(func() -> String:
			if not bool(client.call("menu_third_person_allowed")):
				return "This server keeps everybody in first person."
			return "Cosmetic — the run is the same movement either way. %s switches." % key_for.call(&"g2g_third_person")))
	view.add(DotMenuRow.toggle(&"show_own_body", "Your own body",
		"Draw your character's body in first person. The head is never drawn."))
	gameplay.section("Other players").add(DotMenuRow.toggle(&"hide_others", "Hide other players", "")
		.described_by(func() -> String:
			return "Hides every other runner, the record's ghost, and everything about them — beacons, their pings. %s toggles it." % key_for.call(&"g2g_hide_others")))
	gameplay.section("Comfort") \
		.add(DotMenuRow.slider(&"shake_scale", "Camera shake", "Zero by default: a shaken camera on a ramp is a lost run.")
			.formatted(DotMenuRow.FORMAT_PERCENT_OR_OFF)) \
		.add(DotMenuRow.toggle(&"allow_flashes", "Screen flashes", "A green tint on a personal best.")) \
		.add(DotMenuRow.toggle(&"reduce_motion", "Reduce motion", "The end-of-match announcement appears at once."))
	var _g := menu.add_page(gameplay, &"video")

	# --- Video, Audio, Controls: the stock pages in this game's words ---------------
	var fov := menu.find_row(&"field_of_view")
	if fov != null:
		fov.description = "Horizontal at 4:3, the genre's own measure — 90 is what you are used to."
	var effects := menu.find_row(&"fx_quality")
	if effects != null:
		effects.description = "Particles at the start and finish gates."
	var sfx := menu.find_row(&"sfx_volume")
	if sfx != null:
		sfx.description = "Jumps, landings, beacons."
	var ui := menu.find_row(&"ui_volume")
	if ui != null:
		ui.title = "Timer & interface"
		ui.description = "The start, the splits, the finish and the vote."
	var sensitivity := menu.find_row(&"sensitivity")
	if sensitivity != null:
		sensitivity.description = "The genre's own number: 0.022 degrees per count times this. Bring yours with you."

	menu.config.page_order = PackedStringArray(PAGE_ORDER)
	fill_help(menu.help, client, key_for)


## The help screen's goal, styles and the timer's rules; the keys come from [G2GBindings].
## The styles are read from the client's timer, so a style a server adds is on it as well.
static func fill_help(help: DotMenuHelp, client: Node, key_for: Callable) -> void:
	if help == null:
		return
	help.title_text = "How to play g2g fast"
	help.about = "Get from the start zone to the end zone as fast as you can. Hop by jumping as you land and steering with the mouse while you hold a strafe key; surf by holding into a ramp. The timer starts when you leave the start and stops in the end zone."
	help.add_text("Runs", "%s restarts your run. Stages and bonuses have zones of their own, and every stage is timed against your best and the record. %s saves a checkpoint and %s goes back to it; a run that used one is practice, not a record." % [
		key_for.call(&"g2g_restart"), key_for.call(&"g2g_checkpoint_save"), key_for.call(&"g2g_checkpoint_load")])
	var names: Array = []
	if client != null and client.has_method(&"menu_styles"):
		for style in (client.call(&"menu_styles") as Array):
			names.append(str(style["name"]))
	if not names.is_empty():
		help.add_text("Styles", "%s. A style changes the rules of a run (which keys count, the gravity, a hop before the start) and keeps its own records; %s picks the next one." % [", ".join(names), key_for.call(&"g2g_style_next")])


## The style list, as an option button that asks the client for the style it picks. Built
## here rather than as a live select because the options are the server's and change with it.
static func _style_picker(client: Node) -> Control:
	var styles: Array = client.call("menu_styles")
	var current := StringName(str(client.call("menu_style")))
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(200, 36)
	pick.fit_to_longest_item = true
	for i in range(styles.size()):
		pick.add_item(str(styles[i]["name"]), i)
		if StringName(str(styles[i]["id"])) == current:
			pick.select(i)
	pick.item_selected.connect(func(index: int) -> void:
		client.call("menu_choose_style", StringName(str(styles[index]["id"]))))
	return pick
