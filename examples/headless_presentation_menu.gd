extends "headless_presentation_base.gd"

## The settings, menu and HUD sections of headless_presentation.


func _test_settings_reach_the_engine() -> void:
	_section("A setting in the menu is a setting that does something")

	var p := _make()
	_check(Engine.max_fps == 0, "the frame rate is unlimited by default")
	p.settings.set_value(&"fps_max", 144)
	_check(Engine.max_fps == 144, "and capping it caps the engine")
	p.settings.set_value(&"fps_max", 0)

	p.settings.set_value(&"ui_volume", 0.3)
	_check(is_equal_approx(p.audio.mixer.ui, 0.3), "the timer's volume is the UI bus's")

	_check(p.settings.get_int(&"field_of_view", 0) == 90,
		"the field of view starts at 90, the genre's fov_desired, rather than 110")
	_check(not p.settings.get_bool(&"hide_others", true) and not p.settings.get_bool(&"vsync", true),
		"other players are shown and V-Sync is off until somebody says otherwise")

	# Every document on disk stores 110, the old default that nothing read.
	var step: Callable = G2GPresentation.migrations()[1]
	_check(not (step.call({"field_of_view": 110, "sensitivity": 3.0}) as Dictionary).has("field_of_view"),
		"a stored 110 from before the camera read it is dropped, so the player gets 90")
	_check(int((step.call({"field_of_view": 100}) as Dictionary)["field_of_view"]) == 100,
		"and any other value is somebody's choice, and kept")
	_done()


func _test_the_menu_is_a_view_of_the_settings() -> void:
	_section("The Escape menu writes the settings and keeps no copy of them")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame

	var order: Array = menu.screen.visible_pages().map(func(page: DotMenuPage) -> StringName: return page.id)
	# dot-menu may append its own optional `advanced` page (the connection overlay) after
	# this game's six; it is the addon's, not a reordering of ours, so both shapes pass and
	# anything else -- a page missing, moved or added elsewhere -- does not.
	var ours: Array = [&"general", &"hud", &"gameplay", &"video", &"audio", &"controls"]
	_check(order == ours or order == ours + [&"advanced"],
		"six pages, in this game's order, then dot-menu's optional advanced page if it has one", str(order))

	menu.open(&"general")
	await get_tree().process_frame
	_check(menu.is_open() and menu.screen.visible, "it opens")
	var switches := _live(menu.screen, "DotMenuSwitch")
	# dot-menu adds its Scoreboard section (one switch per hideable column) to General.
	var board_switches := menu.scoreboard_column_rows().size()
	_check(switches.size() == 7 + board_switches, "the General page has a switch per HUD setting, zones and the counter included, plus dot-menu's scoreboard columns (%d)" % switches.size())

	(_row(menu, "show_speed") as Button).button_pressed = false
	_check(not p.settings.get_bool(&"show_speed", true), "flipping one writes the setting it shows")

	p.settings.set_value(&"show_speed", true)
	menu.open(&"general")
	await get_tree().process_frame
	_check((_row(menu, "show_speed") as Button).button_pressed,
		"and a change made elsewhere (the console) is what it shows next time")

	menu.open(&"gameplay")
	await get_tree().process_frame
	var pick := _row(menu, "style").find_children("*", "OptionButton", true, false)
	var styles: OptionButton = pick[0] if not pick.is_empty() else _row(menu, "style") as OptionButton
	_check(styles != null and styles.item_count == 2, "the style list is the host's, not one the menu keeps")
	if styles != null:
		styles.select(1)
		styles.item_selected.emit(1)
	_check(host.style == &"sideways", "and choosing one asks the host for it")
	_check((_row(menu, "third_person") as Button).disabled,
		"a server that keeps everybody in first person greys the switch out, and says why")
	(_row(menu, "flashlight") as Button).button_pressed = true
	_check(host.light, "the flashlight is the host's, never a stored setting")

	menu.open(&"controls")
	await get_tree().process_frame
	var keys := _live(menu.screen, "DotMenuKeyButton")
	_check(keys.size() == G2GBindings.ROWS.size() + 2, "the Controls page has a key per action (plus the wheel's two) (%d)" % keys.size())

	# Flashlight onto R: R was Restart, so Restart gets F rather than nothing.
	var _r := p.bindings.rebind(p.bindings.row_for_action(&"g2g_flashlight"), "R", p.settings)
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "R"
		and DotInputBinding.describe_action(&"g2g_restart") == "F",
		"binding a key that is taken swaps the two, so nothing is left unbound")
	p.bindings.reset_all(p.settings)
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "F"
		and DotInputBinding.describe_action(&"g2g_restart") == "R",
		"and Reset puts every key back")

	var changes: Array = []
	menu.overlays_changed.connect(func(open: bool) -> void: changes.append(open))
	menu.close()
	_check(not menu.screen.visible and changes == [false], "it closes, and says so, so the client can take the mouse back")

	menu.queue_free()
	host.queue_free()
	_done()


func _test_help_lists_what_it_is_told() -> void:
	_section("The help screen lists the player's keys and the server's commands")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame

	var texts := func() -> PackedStringArray:
		var out := PackedStringArray()
		for n in _live(menu.help, "Label"):
			out.append((n as Label).text)
		return out

	menu.help.show_browser_tips = false
	menu.open_help([["spec", "Watch somebody"], ["wr", "Fastest times here"]], true)
	await get_tree().process_frame
	var shown: PackedStringArray = texts.call()
	_check(menu.help.visible and shown.has("!spec") and shown.has("!wr"), "online, it lists the commands the server sent")
	_check(shown.has("Flashlight") and shown.has(p.bindings.key_for(&"g2g_flashlight")) and shown.has("Scoreboard (hold)"),
		"and every key, as it is bound now")
	_check(not shown.has("Ctrl + W"), "the browser's tips are for a browser, and this is not one")

	menu.help.close()
	menu.open_help(null, false)
	await get_tree().process_frame
	shown = texts.call()
	_check(not shown.has("!spec"), "offline there is no server, so no commands are offered")
	menu.help.close()

	# The family's rule since the first play test: H is help, nothing else is on H, the help
	# says what the game is, and the Escape menu has Help & commands and Leave.
	_check(p.bindings.key_for(&"g2g_help") == "H" and p.bindings.defaults_on("H").size() == 1
		and p.bindings.key_for(DotMenuBindings.MAPS_ACTION) == "M" and p.bindings.defaults_on("M").size() == 1,
		"help is on H and the map menu on M, and nothing else in the table is on either",
		str(p.bindings.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(menu.handle_event(h) and menu.help.is_open(), "H opens the help screen")
	await get_tree().process_frame
	_check(menu.help.about != "" and texts.call().has("How to play g2g fast") and texts.call().has("RUNS"),
		"which says what the game is before the keys")
	menu.help.close()
	menu.open()
	var leave := menu.screen.find_child("Action_leave", true, false) as Button
	_check(menu.screen.find_child("Action_help", true, false) != null, "the Escape menu has Help & commands")
	_check(leave != null and leave.visible, "and Leave")
	menu.close()

	menu.queue_free()
	host.queue_free()
	_done()


func _test_a_theme_is_every_screen() -> void:
	_section("A theme reaches the menus and the HUD, and switches while they are open")

	var s := G2GPresentation.schema()
	var themes := DotMenuThemes.stock()
	_check(themes.size() == 7 and s.find(&"ui_theme") != null
		and StringName(str(s.find(&"ui_theme").default_value)) == &"midnight",
		"seven themes, offered by a setting whose default is the palette the menus always had")
	var row := G2GBindings.make().row_for_action(&"g2g_theme_next")
	_check(not row.is_empty() and str(row["default"]) == "P", "and a key that cycles them, P unless rebound")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame
	menu.open(&"hud")
	await get_tree().process_frame

	var seen: Array = []
	menu.theme_changed.connect(func(palette: DotMenuPalette) -> void: seen.append(palette))
	p.settings.set_value(&"ui_theme", &"ember")
	await get_tree().process_frame
	var resume := menu.screen.find_child("Resume", true, false) as Button
	var fill := (resume.get_theme_stylebox(&"normal") as StyleBoxFlat).bg_color if resume != null else Color.BLACK
	var ember := themes.named(&"ember")
	_check(fill == ember.accent_deep, "a menu open when the theme changes is rebuilt in it",
		"%s against %s" % [fill, ember.accent_deep])
	_check(menu.is_open() and menu.screen.current_page() == &"hud", "on the page it was showing, still open")

	var hud := G2GHud.new()
	add_child(hud)
	hud.apply_theme(seen[0] if not seen.is_empty() else null)
	_check(hud.timer_hud.panel_colour == ember.hud_plate and hud.timer_hud.neutral_colour == ember.hud_text,
		"and the clock's plate and text are the theme's")
	menu.follow_hud(hud, null, false)
	_check(hud.hit_marker.colour(&"plate") == ember.hud_plate and hud.damage_numbers.colour(&"text") == ember.hud_text,
		"and dot-ui's pieces on it (the hit marker, the damage numbers) are in the theme too")

	p.settings.set_value(&"ui_theme", &"midnight")
	menu.queue_free()
	hud.queue_free()
	host.queue_free()
	_done()


func _test_the_board_is_a_timer_servers() -> void:
	_section("Tab holds a board of styles, best times and ranks")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	var client := G2GClient.new()
	client.menu = menu
	client.call("_wire_scoreboard")
	await get_tree().process_frame

	var board := menu.scoreboard
	board.source = func() -> Dictionary:
		return {"server": {"name": "g2g test", "map": "surf_test", "players": 3, "max": 24}, "you": 7,
			"players": [
				{"id": 5, "name": "Ada", "style": "Normal", "best": 61.234, "rank": 2, "of": 9, "seconds": 300, "ping": 40},
				{"id": 6, "name": "Bea", "style": "Sideways", "best": 58.5, "rank": 1, "of": 9, "seconds": 1200, "ping": 90},
				{"id": 7, "name": "Cy", "style": "Normal", "best": -1.0, "rank": 0, "seconds": 20, "ping": 15},
			]}
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.keycode = KEY_TAB
	tab.pressed = true
	_check(menu.handle_event(tab) and board.is_open(), "Tab held puts it up")
	await get_tree().process_frame
	var order: Array = board.rows().map(func(r: Dictionary) -> String: return str(r["name"]))
	_check(order == ["Bea", "Ada", "Cy"], "fastest first, and nobody with a time after everybody with one", str(order))
	var texts: Array = _live(board, "Label").map(func(l: Node) -> String: return (l as Label).text)
	_check(texts.has("0:58.500") or texts.any(func(t: String) -> bool: return t.contains("58.5")),
		"a best time is drawn as a time", str(texts))
	_check(texts.has("1 / 9") and texts.has("—"), "a rank out of how many, and a dash for no time")
	_check(not menu.any_open(), "and it is not a menu: the runner keeps moving")
	tab.pressed = false
	var _up := menu.handle_event(tab)
	_check(not board.is_open(), "letting go puts it away")

	client.free()
	menu.queue_free()
	host.queue_free()
	_done()


func _test_the_timer_is_the_players_layout() -> void:
	_section("The timer's lines and where everything goes are the player's")

	var hud := G2GHud.new()
	add_child(hud)
	await get_tree().process_frame
	if hud.size.x <= 0.0:
		hud.size = Vector2(1600, 900)

	hud.apply_layout({
		"show_stats": false, "show_track": false, "size": 40, "comparison": "wr",
		"position": "top_left", "compact": false,
	})
	var t := hud.timer_hud
	_check(not t.show_stats and not t.show_track and t.show_time and t.clock_size == 40
		and t.comparison == DotTimerHud.Comparison.WORLD_RECORD and not t.compact,
		"every timer line is the timer's own switch, so an off line closes up rather than leaving a gap")
	hud.place()
	_check(t.corner == DotTimerHud.Placement.TOP_LEFT, "and the block goes where the player put it")

	_check(G2GHud.positions_from_text("not json").is_empty() and G2GHud.positions_from_text("").is_empty(),
		"a positions setting that is not a layout is the default layout")
	var read := G2GHud.positions_from_text('{"timer":[0.25,0.5],"bogus":[1,1],"keys":[2,-1]}')
	_check(read.size() == 2 and read[&"timer"] == Vector2(0.25, 0.5) and read[&"keys"] == Vector2(1, 0),
		"unknown pieces are dropped and a piece off the screen is put back on it", str(read))
	_check(G2GHud.positions_from_text(G2GHud.positions_to_text(read)) == read, "and it round-trips")

	hud.move_element(&"timer", Vector2(300, 200))
	var clock := hud.element_rect(&"timer")
	_check(clock.get_center().distance_to(Vector2(300, 200)) < 1.0,
		"a dragged clock is drawn where it was dropped, with or without a run on it", str(clock))
	var keys := hud.element_rect(&"keys")
	_check(keys.position.y >= clock.end.y - 0.5 and absf(keys.get_center().x - clock.get_center().x) < 1.0,
		"and the keys follow it, centred underneath", "%s under %s" % [keys, clock])
	hud.reset_element(&"timer")
	hud.place()
	_check(not hud.positions.has(&"timer") and t.corner == DotTimerHud.Placement.TOP_LEFT,
		"putting it back is the layout's place again")

	hud.set_spectators(PackedStringArray(["Ada", "Bea"]))
	hud.place()
	var listed := hud.find_child("Spectators", true, false) as Control
	_check(listed != null and listed.visible and hud.element_rect(&"spectators").size.x > 0.0,
		"who is spectating is drawn when somebody is")
	hud.apply_layout({"show_spectators": false})
	_check(listed != null and not listed.visible, "and not when the player turned it off")

	hud.set_spectating(&"u8", "Bea")
	_check(hud.shown_id() == &"u8", "while spectating, the clock is the watched player's")
	hud.set_spectating(&"")
	_check(hud.shown_id() == hud.player_id, "and back to your own when you stop")

	var editor := DotMenuLayoutEditor.new()
	editor.target = hud
	editor.pieces = G2GClient.HUD_PIECES
	add_child(editor)
	var saved: Array[String] = ["unset"]
	editor.saved.connect(func(text: String) -> void: saved[0] = text)
	var status := hud.element_rect(&"status")
	editor.drag(&"status", status.get_center(), Vector2(400, 500))
	_check(hud.element_rect(&"status").get_center().distance_to(Vector2(400, 500)) < 1.0
		and saved[0].contains("status"),
		"the editor moves a piece and saves where it went", saved[0])
	_check(G2GHud.positions_from_text(saved[0]).has(&"status"),
		"in the shape the HUD reads back")
	_check(editor.piece_at(Vector2(400, 500)) == &"status", "and the piece is picked up where it is drawn")
	editor.reset_all()
	_check(saved[0] == "" and hud.positions.is_empty(), "Reset all is the default layout, saved as nothing")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame
	menu.open(&"hud")
	await get_tree().process_frame
	var switches := _live(menu.screen, "DotMenuSwitch")
	_check(switches.size() == 8, "the HUD page has a switch per timer line and piece (%d)" % switches.size())
	(_row(menu, "timer_show_stats") as Button).button_pressed = false
	_check(not p.settings.get_bool(&"timer_show_stats", true), "and flipping one writes its setting")
	(_row(menu, "arrange") as Button).pressed.emit()
	_check(host.edited == 1, "and Move HUD elements asks the client to open the editor")

	menu.queue_free()
	host.queue_free()
	editor.queue_free()
	hud.queue_free()
	_done()


## Hit feedback on a combat map, from dot-ui: the marker and the number come from a hit the
## authority applied (`confirm_hit`), and nothing is drawn before one.
func _test_a_confirmed_hit_is_drawn() -> void:
	_section("A hit the server confirmed is drawn, and nothing before it")

	var hud := G2GHud.new()
	add_child(hud)
	await get_tree().process_frame

	_check(hud.hit_marker != null and hud.damage_numbers != null,
		"the HUD carries dot-ui's hit marker and damage numbers")
	_check(hud.hit_marker.alpha() == 0.0 and hud.damage_numbers.texts().is_empty(),
		"and neither draws anything until a hit lands", str(hud.hit_marker.describe()))
	hud.confirm_hit(7, 27.0, Vector3(0.0, 1.0, -4.0), false, true)
	_check(hud.hit_marker.alpha() > 0.0, "a confirmed hit flashes the marker", str(hud.hit_marker.describe()))
	_check(hud.damage_numbers.texts().size() == 1 and hud.damage_numbers.texts()[0].contains("27"),
		"and puts its number up", str(hud.damage_numbers.texts()))
	hud.queue_free()
	_done()


## The ammunition counter on an offline deathmatch: the combat layer writes the weapon in
## hand onto the player and the HUD names it, with no count (both weapons are endless). Armed
## by dropping `_note_held` (the first check fails) and by showing the count (the last does).
## Connected, the same field arrives by `net_weapon`: `headless_net`'s blind-and-beacon section.
func _test_the_weapon_in_hand_is_named() -> void:
	_section("The weapon in hand is named on a deathmatch, and nothing on a timer server")

	var config := G2GConfig.new()
	config.records_directory = ""
	config.initial_map = &"bhop_g2g_intro"
	config.deathmatch = true
	var game := G2GGame.new()
	game.name = "AmmoGame"
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	var ada: G2GPlayer = game.add_player(&"u1", "Ada")
	var hud := G2GHud.new()
	hud.size = Vector2(1280.0, 720.0)
	add_child(hud)
	hud.bind(game, &"u1")
	for _i in range(60):
		await get_tree().physics_frame
		if ada.held_weapon != &"":
			break

	_check(ada.held_weapon in [&"knife", &"deagle"], "the combat layer puts a weapon in hand", str(ada.held_weapon))
	hud._process(1.0 / 60.0)
	_check(hud.ammo.weapon_name == String(ada.held_weapon).capitalize() and hud.ammo.count_text() == "",
		"and the counter names it with no count, because it has no magazine", str(hud.ammo.describe()))
	_check(hud.ammo.footprint().size != Vector2.ZERO
			and not hud.ammo.get_global_rect().intersects(hud.element_rect(&"timer")),
		"drawn bottom right, clear of the clock", "%s / %s" % [hud.ammo.get_global_rect(), hud.element_rect(&"timer")])

	var icons: DotWeaponIconStyle = G2GWeaponIcons.shared
	var unmapped := PackedStringArray()
	for weapon in G2GWeaponIcons.TAGS:
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and hud.weapon_icon.visible and hud.weapon_icon.texture == icons.texture(ada.held_weapon),
		"the HUD draws the held weapon's sprite, and every mapped weapon has one", ", ".join(unmapped))
	_check(hud.weapon_icon.get_global_rect().end.y <= hud.ammo.get_global_rect().position.y + 4.0
			and not hud.weapon_icon.get_global_rect().intersects(hud.element_rect(&"timer")),
		"the sprite sits over the counter, clear of the clock", str(hud.weapon_icon.get_global_rect()))
	var _silhouette := icons.set_style(&"silhouette")
	hud._process(1.0 / 60.0)
	_check(not hud.weapon_icon.visible, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")

	game.combat.enabled = false
	for _i in range(4):
		await get_tree().physics_frame
	hud._process(1.0 / 60.0)
	_check(ada.held_weapon == &"" and hud.ammo.weapon_name == "",
		"with deathmatch off the hand is empty and the counter draws nothing", str(hud.ammo.describe()))

	hud.show_weapon(null)
	_check(hud.ammo.footprint() == Rect2(), "and watching somebody else shows nothing")

	hud.queue_free()
	game.queue_free()
	_done()
