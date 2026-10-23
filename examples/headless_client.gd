extends Node

const G2GClient := preload("../game/g2g_client.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GEvents := preload("../game/net/g2g_events.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GHud := preload("../game/g2g_hud.gd")
const G2GSoloMaps := preload("../game/g2g_solo_maps.gd")

## The real client, offline: what a player's keys do, rather than what the pieces do.
##
## [codeblock]
## godot --headless --path . res://examples/headless_client.tscn
## [/codeblock]
##
## [b]Every other suite here drives the pieces — a game, two bridges, a menu against a fake
## host — and none of them stands up `G2GClient`.[/b] So the offline chat box let a runner
## walk with W held for as long as the box has existed: the sampler that was suspended was
## the networked one, and offline the player's own sampler is the one that moves them. The
## presentation suite checked the box swallowed keys, and it did; nothing asked whether the
## player stood still. This suite holds a real key against the real client and measures.
##
## Exits non-zero on any failure.

const CHECKS := 81
const SECTIONS := 15

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _client: G2GClient = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: the client, offline")

	# A hand-built map, so the suite needs nothing imported.
	OS.set_environment("G2G_INITIAL_MAP", "bhop_g2g_intro")
	_client = (load("res://game/g2g.tscn") as PackedScene).instantiate() as G2GClient
	_client.force_offline = true
	add_child(_client)

	# A memory store, so nothing this suite changes reaches the player's own settings file
	# — and nothing in it changes what this suite sees.
	_client.presentation.settings.local_store = DotSettingsStoreMemory.new()
	_client.presentation.settings.load_now()
	_client.presentation.apply_all()

	for _i in range(90):
		await get_tree().physics_frame

	if _client.player == null:
		print("ERROR: the offline client has no player")
		get_tree().quit(1)
		return

	await _test_chat_stops_the_runner()
	await _test_the_console_stops_the_runner()
	await _test_a_new_player_starts_still()
	await _test_spectating_holds_the_runner()
	_test_r_once_and_twice()
	_test_p_cycles_the_theme()
	_test_tab_holds_the_board()
	await _test_the_layout_editor_is_an_overlay()
	await _test_the_camera_is_the_watched_players()
	await _test_a_dead_body_falls()
	await _test_the_map_menu()
	await _test_the_wheel_jumps()
	_test_solo_in_the_shell()
	await _test_the_stage_splits_panel()
	await _test_the_end_of_a_deathmatch()

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for f in _failures:
		print("  FAIL " + f)
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	# The total the section counter cannot be: a runtime error inside a section aborts that
	# function after it announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## Holds W for [param frames] physics frames and returns how far the player went, in metres.
func _hold_forward(frames: int) -> float:
	var from := _client.player.global_position
	Input.action_press(&"dot_fps_forward")
	for _i in range(frames):
		await get_tree().physics_frame
	Input.action_release(&"dot_fps_forward")
	return _client.player.global_position.distance_to(from)


func _test_chat_stops_the_runner() -> void:
	_section("Typing in chat stops the runner")
	var window := _client.presentation.chat_window

	window.open()
	await get_tree().process_frame
	_check(window.is_open() and _client.player.sampler.suspended,
		"the chat box opens and the player's own sampler is suspended")
	var typed: float = await _hold_forward(40)
	_check(typed < 0.001, "W held while typing moves nobody", "%.3f m" % typed)

	window.close()
	await get_tree().process_frame
	var walked: float = await _hold_forward(40)
	_check(not _client.player.sampler.suspended and walked > 0.1,
		"and closing it gives the keys back", "%.3f m" % walked)
	_done()


## The console is the chat box's bug again, and the fix is dot-console's kit registering the
## panel as one of the menu's overlays: the menu's "something is open" is what suspends the
## sampler. Before the kit, nothing here did, and `noclip` typed with W held walked.
func _test_the_console_stops_the_runner() -> void:
	_section("Typing at the console stops the runner")
	var console := _client.presentation.console
	# The last section walked; let that walk coast to a stop, or its friction is measured.
	for _i in range(90):
		await get_tree().physics_frame
	var _opened := console.open()
	await get_tree().process_frame
	_check(_client.overlay_open() and _client.player.sampler.suspended,
		"the console opens as one of the menu's overlays and the sampler is suspended")
	var typed: float = await _hold_forward(40)
	_check(typed < 0.001, "W held with the console open moves nobody", "%.3f m" % typed)

	console.close()
	await get_tree().process_frame
	_check(not _client.overlay_open(), "closing it closes the overlay")
	var walked: float = await _hold_forward(40)
	_check(not _client.player.sampler.suspended and walked > 0.1,
		"and gives the keys back", "%.3f m" % walked)
	_done()


## A respawn, a map change or a new session hands the client a new player, and offline a new
## player is a new sampler — which starts unsuspended unless somebody says otherwise.
func _test_a_new_player_starts_still() -> void:
	_section("A player adopted while the chat box is open starts still")
	_client.presentation.chat_window.open()
	await get_tree().process_frame
	_client.player.sampler.suspended = false
	_client._adopt(_client.player)
	_check(_client.player.sampler.suspended, "adopting a player puts its sampler where the client's state says")
	_client.presentation.chat_window.close()
	await get_tree().process_frame
	_check(not _client.player.sampler.suspended, "and closing the box still releases it")
	_done()


func _test_spectating_holds_the_runner() -> void:
	_section("Spectating holds the runner's body still")
	_client._on_spectate(&"u8", "Bea")
	_check(_client.is_spectating() and _client.player.sampler.suspended,
		"while watching somebody, this player's keys move nobody")
	_check(_client.hud.shown_id() == &"u8", "and the clock is the watched player's")
	# The last section walked; let that walk coast to a stop, or its friction is measured.
	for _i in range(90):
		await get_tree().physics_frame
	var watching: float = await _hold_forward(20)
	_check(watching < 0.001, "W held while spectating moves nobody", "%.3f m" % watching)
	_client._on_spectate(&"", "")
	_check(not _client.is_spectating() and not _client.player.sampler.suspended,
		"and stopping gives the keys back")
	# A free camera has no target; it still holds the keys, hides the "watching" line's
	# name, and names the key only while the server offers it.
	var pid: StringName = _client.player.player_id
	_client.game.spectate.manager.apply_wire({"k": String(pid), "v": {"m": DotSpectatorView.Mode.ROAMING, "t": "", "u": -1}})
	_client._on_spectate(&"", "")
	_check(_client.roaming and _client.is_spectating() and _client.player.sampler.suspended,
		"roaming counts as spectating and holds the runner still")
	_check(_client.hud._spectating.visible and _client.hud._spectating.text.begins_with("Free camera"),
		"and the HUD line is the free camera's controls", _client.hud._spectating.text)
	_client.game.spectate.manager.apply_wire({"k": String(pid), "v": {"m": DotSpectatorView.Mode.NONE, "t": "", "u": -1}})
	_client._on_spectate(&"", "")
	_check(not _client.roaming and not _client.is_spectating(), "and leaving it gives the keys back")
	_done()


func _test_r_once_and_twice() -> void:
	_section("R once, and R twice inside the window")
	var first := _client._restart_key(10000)
	var second := _client._restart_key(10000 + G2GClient.DOUBLE_TAP_MSEC - 50)
	_check(first == G2GEvents.RESTART_STAGE and second == G2GEvents.RESTART_MAIN,
		"one R is the stage and a second inside the window is the start")
	var third := _client._restart_key(10000 + G2GClient.DOUBLE_TAP_MSEC)
	_check(third == G2GEvents.RESTART_STAGE, "a double tap is spent: a third press starts again")
	var late := _client._restart_key(10000 + G2GClient.DOUBLE_TAP_MSEC * 3)
	_check(late == G2GEvents.RESTART_STAGE, "and two presses further apart are two single Rs")
	_done()


func _test_p_cycles_the_theme() -> void:
	_section("P cycles the theme")
	var settings := _client.presentation.settings
	var menu := _client.menu
	var before := StringName(str(settings.get_value(&"ui_theme")))
	var p := InputEventKey.new()
	p.physical_keycode = KEY_P
	p.keycode = KEY_P
	p.pressed = true
	var _took := menu.handle_event(p)
	var after := StringName(str(settings.get_value(&"ui_theme")))
	_check(after == menu.themes.next(before) and menu.palette().id == after,
		"the key writes the setting and the palette follows it", "%s -> %s" % [before, after])
	_check(_client.hud.timer_hud.panel_colour == menu.palette().hud_plate,
		"and the HUD is drawn in it")
	var _back := settings.set_value(&"ui_theme", before)
	_check(menu.palette().id == before, "and setting it back puts the palette back")
	_done()


## Tab, held, on the real client: the board, with this runner on it, and Escape over it.
func _test_tab_holds_the_board() -> void:
	_section("Tab holds the board, and the runner keeps their keys")
	var menu := _client.menu
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.keycode = KEY_TAB
	tab.pressed = true
	_check(menu.handle_event(tab) and menu.scoreboard.is_open(), "Tab puts the board up")
	var rows := menu.scoreboard.rows()
	_check(rows.any(func(r: Dictionary) -> bool: return bool(r.get("you", false)) and str(r.get("name", "")) == _client.player.display_name),
		"with this runner on it, picked out", str(rows))
	_check(not _client.overlay_open() and not _client.player.sampler.suspended,
		"and it is not a menu: the sampler is still the runner's")
	tab.pressed = false
	var _up := menu.handle_event(tab)
	_check(not menu.scoreboard.is_open(), "letting go puts it away")
	_done()


func _test_the_layout_editor_is_an_overlay() -> void:
	_section("Moving the HUD is an overlay, so the runner stands still")
	_client.open_hud_editor()
	await get_tree().process_frame
	_check(_client.overlay_open() and _client.player.sampler.suspended,
		"the layout editor counts as an overlay")
	_client.menu.layout_editor.close()
	await get_tree().process_frame
	_check(not _client.overlay_open() and not _client.player.sampler.suspended,
		"and closing it gives the keys back")
	_done()


## Where the camera IS, not where the spectator manager says it should be. The two
## disagreed for as long as spectating existed: the shake line wrote the camera's position
## after the spectator camera did, every frame.
func _test_the_camera_is_the_watched_players() -> void:
	_section("A spectator sees through the watched player's eyes")
	var bea = _client.game.add_player(&"u8", "Bea", false)
	_client.game.spawn_player(&"u8")
	bea.teleport(_client.player.global_position + Vector3(0.0, 0.0, -3.0), 0.0)
	for _i in range(10):
		await get_tree().physics_frame
	var watching := _client.game.spectate.watch(_client.player.player_id, &"u8")
	for _i in range(6):
		await get_tree().process_frame
	var camera: Camera3D = _client.player.camera.active()
	var eye: Vector3 = bea.eye_position()
	_check(watching.ok and camera.global_position.distance_to(eye) < 0.05,
		"the drawn camera is at the watched player's eyes",
		"%s against %s" % [camera.global_position, eye])
	_check(not bea.visible, "and their body is not drawn, because the camera is inside it")
	_client.game.spectate.stop(_client.player.player_id)
	for _i in range(4):
		await get_tree().process_frame
	_check(bea.visible and camera.global_position.distance_to(bea.eye_position()) > 1.0,
		"stopping puts the camera back in this player's own head, and Bea back on screen")
	_client.game.remove_player(&"u8")
	_done()


## A death copies a ragdoll from the rig this client draws and hides the rig until the
## player is back; the server's `sv_ragdoll 0` is the scripted topple (no physics). Armed by
## spawning from the player node instead of the rig (the hidden-rig check fails: the copy
## and the figure both stand there) and by ignoring the rules (the topple check fails).
func _test_a_dead_body_falls() -> void:
	_section("A dead body falls the way the server picked, and gets up")
	var game := _client.game
	# A Kenney body, whose parts are named (torso, arm-left, ...): the stock primitives are one
	# capsule, which is honestly one rigid piece.
	var dressed := DotAvatar.make(&"g2g_stock")
	dressed.set_part(&"body", &"body_kenney_c")
	dressed.set_part(&"head", &"head_kenney_c")
	var other: G2GPlayer = game.add_player(&"u91", "Fallen", false, dressed)
	other.teleport(_client.player.controller.state.position + Vector3(0.0, 0.0, -4.0))
	for _i in range(4):
		await get_tree().process_frame

	var crumple := DotPlayerDeath.new()
	crumple.reaction = DotPlayerDeathReactions.CRUMPLE
	crumple.roll_seed = 7
	var body := _client.fall(&"u91", crumple)
	_check(body != null and body.reaction.id == DotPlayerDeathReactions.CRUMPLE
			and body.part_count() > 1 and _client.ragdolls.live().size() == 1,
		"the server's reaction, as a jointed body copied from the drawn rig",
		str(body.describe()) if body != null else "no body")
	_check(not other.rig.visible, "and the standing figure is hidden while the body lies there")
	_client.rise(&"u91")
	_check(other.rig.visible, "a return draws the figure again")
	_client.ragdolls.clear()

	var _off := game.ragdoll_rules.set_cvar("sv_ragdoll", "0")
	var toppled := _client.fall(&"u91", crumple)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE,
		"the server's sv_ragdoll 0 is the topple fallback, no physics",
		str(toppled.describe()) if toppled != null else "no body")
	var _on := game.ragdoll_rules.set_cvar("sv_ragdoll", "1")
	_client.rise(&"u91")
	_client.ragdolls.clear()

	_check(_client.fall(_client.player.player_id, crumple) == null and _client.player.rig.visible,
		"no ragdoll of your own body in first person: the camera is inside its head")
	game.remove_player(&"u91")
	await get_tree().process_frame
	_done()


## The end of a deathmatch: the last kill replayed from the killer's eye, then the winner on a
## podium, then the board, each skippable; 0 seconds goes straight to the winner and Reduce
## motion shows the reveal's last frame at once. The clock is the test's, so no wall time passes.
func _test_the_end_of_a_deathmatch() -> void:
	_section("A deathmatch's end: the final killcam, the winner, then the board")
	var game := _client.game
	var rival: G2GPlayer = game.add_player(&"u92", "Rival", false)
	var start := _client.player.controller.state.position + Vector3(0.0, 0.0, -6.0)
	var clock := [0.0]
	var kc := _client.killcam
	kc.now_fn = func() -> float: return clock[0]
	kc.killcam.auto_process = false
	_client.winner_reveal.auto_process = false
	var step := 1.0 / 60.0
	var before := get_viewport().get_camera_3d()
	while clock[0] < 9.5:
		clock[0] += step
		rival.teleport(start + Vector3(clock[0], 0.0, 0.0))
		kc.frame()
		if absf(clock[0] - 8.0) < step * 0.5:
			kc.note_kill(&"u92", _client.player.player_id, "deagle")
	_check(kc.buffer.frame_count() > 400 and StringName(kc.buffer.last_event(&"kill")["data"]["killer"]) == &"u92",
		"every frame drawn and the kill went into the buffer")

	var rows := [{"name": "Rival", "kills": 40, "deaths": 3}, {"name": "You", "kills": 12, "deaths": 20}]
	_client._match_over(7.0, rows)
	_check(kc.is_playing() and kc.camera.current and not _client.hud.visible,
		"the end starts the killcam, from its own camera, with the HUD hidden")
	kc.killcam.advance(step)
	_check(kc.killcam.banner != null and kc.killcam.banner.killer_label.text == "Rival",
		"under a banner naming the killer")
	var n := 0
	while kc.is_playing() and n < 1000:
		kc.killcam.advance(step)
		n += 1
	_check(not kc.is_playing() and n * step < 7.0 and get_viewport().get_camera_3d() == before,
		"it ends inside the budget and gives the view back (%.2f s)" % (n * step))
	_check(_client.winner_reveal.is_active() and _client.winner_reveal.name_label.text == "Rival",
		"then the winner is named over the podium")
	_check(not _client.hud.visible, "with the HUD still hidden")
	_client.winner_reveal.advance(30.0)
	_check(not _client.winner_reveal.is_active() and _client.hud.visible and _client.menu.scoreboard.is_open(),
		"and when it is done the HUD returns and the board comes up")
	_client._leave_match_end()
	_check(not _client.menu.scoreboard.is_open(), "the next match takes the board down again")

	_client._match_over(0.0, rows)
	_check(not kc.is_playing() and _client.winner_reveal.is_active(),
		"mp_killcam_time 0: no killcam, straight to the winner")
	_client._leave_match_end()
	_check(not _client.winner_reveal.is_active() and _client.hud.visible, "leaving the end skips what is up")

	_client.presentation.settings.set_value(&"reduce_motion", true)
	_client._match_over(0.0, rows)
	_check(_client.winner_reveal.reduced_motion, "Reduce motion is read from the settings")
	_client._leave_match_end()
	_client.presentation.settings.set_value(&"reduce_motion", false)
	game.remove_player(&"u92")
	await get_tree().process_frame
	_done()


## No item switching here, so the wheel jumps: two extra rows on the jump action, and a tick
## (pressed and released inside one frame) reaches the next command as a press.
func _test_the_wheel_jumps() -> void:
	_section("the mouse wheel jumps, one press per tick")
	var keys: DotMenuBindings = _client.menu.bindings
	var wheel_rows := keys.rows.filter(func(r: Dictionary) -> bool:
		return r["action"] == &"dot_fps_jump" and bool(r.get("extra", false)))
	_check(wheel_rows.size() == 2 and keys.row_for_action(&"dot_fps_jump")["default"] == "Space",
		"Space stays and two extra rows (wheel up, wheel down) sit on dot_fps_jump", str(wheel_rows.size()))
	var sampler: DotFpsSampler = _client._active_sampler()
	var _flush := sampler.sample(0.0)
	for button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var down := InputEventMouseButton.new()
		down.button_index = button
		down.pressed = true
		sampler.handle_event(down)
		var up := InputEventMouseButton.new()
		up.button_index = button
		up.pressed = false
		sampler.handle_event(up)
		_check(sampler.sample(0.0).is_pressed(DotFpsCommand.BUTTON_JUMP),
			"wheel %s is a jump in the next command" % ("up" if button == MOUSE_BUTTON_WHEEL_UP else "down"))
		_check(not sampler.sample(0.0).is_pressed(DotFpsCommand.BUTTON_JUMP),
			"and only that one command")
	_done()


## The family's rule since the first play test: M opens the map list (every map, not the
## rotation), and solo a choice changes the map now. The server's half is dot-vote's map menu
## (`dedicated`, dot-vote's suite).
func _test_the_map_menu() -> void:
	_section("M opens the map list, and solo a choice changes the map")
	var menu: DotMenu = _client.menu
	var keys: DotMenuBindings = menu.bindings

	# M, the family's rule since the first play test: the map list, and solo a choice
	# changes it now. The server's half (the owner's flag, the vote) is in `dedicated`.
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# Closed right before the key: an offline client with no captured pointer (headless) may
	# have put its menu back up, and while anything is open every key is the menu's.
	menu.close_all()
	var map_before: StringName = _client.game.maps.current.id
	var m_key := InputEventKey.new()
	m_key.physical_keycode = KEY_M
	m_key.keycode = KEY_M
	m_key.pressed = true
	_check(menu.handle_event(m_key) and menu.picker.is_open() and menu.picker.items.size() > 1,
		"M opens the map list, more than one to choose", str(menu.picker.items.size()))
	var wanted_map: StringName = &""
	var map_key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted_map = StringName(str((it as Dictionary)["id"]))
			map_key = KEY_0 + row
			break
	var digit_key := InputEventKey.new()
	digit_key.physical_keycode = map_key
	digit_key.keycode = map_key
	digit_key.pressed = true
	var _picked := menu.handle_event(digit_key)
	for _i in 90:
		await get_tree().physics_frame
	_check(wanted_map != &"" and _client.game.maps.current.id == wanted_map and not menu.picker.is_open(),
		"choosing one changes the map now", "%s, now %s" % [wanted_map, _client.game.maps.current.id])
	# Back where it was, for the checks after this one.
	var _back_map: Variant = await menu.maps.change_fn.call(map_before)
	for _i in 90:
		await get_tree().physics_frame
	_done()


## Stands on a staged map's panel: hidden where there are no stages, one row per section where
## there are, gone with its setting, gone while watching somebody, and fed a personal best and
## a section best through the game's own store (the offline path, which is the same HUD code the
## server's STAGE_REF feeds online; the wire half is in `headless_net`).
func _test_the_stage_splits_panel() -> void:
	_section("The stage splits panel: stages, setting, spectating and a comparison")
	var hud: G2GHud = _client.hud
	var panel: DotTimerSplitsPanel = hud.splits_panel
	var settings: DotSettingsManager = _client.presentation.settings
	var _first: Variant = await _client.menu.maps.change_fn.call(&"bhop_g2g_intro")
	for _i in 30:
		await get_tree().physics_frame
	var intro_stages: int = _client.game.timers.stage_count(_client.player.timer.track)
	_check(panel != null and (intro_stages > 0 or not panel.visible),
		"a map with no stage lines has no panel", "stages %d" % intro_stages)

	var _second: Variant = await _client.menu.maps.change_fn.call(&"bhop_g2g_stages")
	for _i in 60:
		await get_tree().physics_frame
	var stages: int = _client.game.timers.stage_count(_client.player.timer.track)
	_check(stages > 0 and panel.visible and panel.section_count == stages + 1,
		"a staged map shows the panel with stages + 1 sections", "stages %d, sections %d" % [stages, panel.section_count])
	_check(panel.rows_shown() == mini(panel.max_rows, stages + 1), "and a row for each", str(panel.rows_shown()))
	_check(panel.get_parent() == hud and panel.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"on the HUD, ignoring the mouse")

	var _off := settings.set_value(&"show_stage_splits", false)
	_check(not panel.visible and panel.section_count == 0, "show_stage_splits off hides it")
	var _on := settings.set_value(&"show_stage_splits", true)
	_check(panel.visible and panel.section_count == stages + 1, "and on brings it back")

	# Spectating: the owner's best against somebody else's run compares nobody with nobody.
	hud.set_spectating(&"somebody")
	_check(not panel.visible, "watching somebody else hides it")
	hud.set_spectating(&"")
	_check(panel.visible, "and it returns when watching stops")

	# A comparison from the game's own store: a personal best with splits and a best section.
	var game: G2GGame = _client.game
	var timer: DotTimer = _client.player.timer
	var key: StringName = game.record_key(hud.player_id)
	var record := DotTimerRecord.new()
	record.map_id = game.maps.current.id
	record.track = timer.track
	record.style_id = timer.run.style_id
	record.player_id = key
	record.player_name = "Test"
	record.time = 60.0
	for k in range(1, stages + 1):
		record.splits[k] = 10.0 * float(k)
	var _put := await game.timers.store.put(record)
	var section := DotTimerRecord.new()
	section.map_id = record.map_id
	section.track = record.track
	section.style_id = record.style_id
	section.player_id = key
	section.player_name = "Test"
	section.stage = 1
	section.time = 9.5
	var _put_section := await game.timers.store.put(section)
	await game.refresh_stage_reference(hud.player_id)
	_check(is_equal_approx(panel.comparison_total, 60.0) and panel.comparison_name == "PB",
		"a stored personal best is the panel's comparison", "%s %s" % [panel.comparison_name, panel.comparison_total])
	var _wr := settings.set_value(&"timer_comparison", &"wr")
	_check(panel.comparison_name == "WR", "and Split against = the record switches it", panel.comparison_name)
	var _pb := settings.set_value(&"timer_comparison", &"pb")

	# Online the server's STAGE_REF wins over the local store (which holds a different PB,
	# 60 s, from solo play), and a reference for another map is not accepted.
	game.authoritative = false
	var remote := {
		"map": str(game.maps.current.id), "track": timer.track, "style": timer.run.style_id,
		"stages": stages, "pb": {"splits": {}, "total": 42.0}, "wr": {"splits": {}, "total": 40.0},
		"bests": {},
	}
	hud.apply_stage_reference(remote)
	_check(is_equal_approx(panel.comparison_total, 42.0),
		"a non-authoritative client compares with the server's STAGE_REF, not its own store",
		str(panel.comparison_total))
	var stale := remote.duplicate(true)
	stale["map"] = "some_other_map"
	hud.apply_stage_reference(stale)
	_check(is_equal_approx(panel.comparison_total, 0.0),
		"and a reference for another map is not shown", str(panel.comparison_total))
	hud.apply_stage_reference(remote)
	game.map_ready.emit(game.maps.current)
	_check(is_equal_approx(panel.comparison_total, 42.0), "a map_ready on the same map keeps it")
	stale["map"] = "some_other_map"
	hud._remote_reference = stale
	game.map_ready.emit(game.maps.current)
	_check(hud._remote_reference.is_empty(), "and a map change drops one for the map just left")
	game.authoritative = true
	hud._remote_reference = {}
	hud.refresh_stage_reference()
	_check(is_equal_approx(panel.comparison_total, 60.0),
		"while an authoritative game still reads its own store", str(panel.comparison_total))

	# A section crossing refreshes the reference only when it improved a best.
	var sent: Array[int] = [0]
	var counter := func(_id: StringName, _ref: Dictionary) -> void: sent[0] += 1
	game.stage_reference_changed.connect(counter)
	game.timers.section_filed.emit({"player": key, "improved": false})
	for _i in 5:
		await get_tree().physics_frame
	var after_slower: int = sent[0]
	game.timers.section_filed.emit({"player": key, "improved": true})
	for _i in 5:
		await get_tree().physics_frame
	game.stage_reference_changed.disconnect(counter)
	_check(after_slower == 0 and sent[0] == 1, "a section that improved nothing sends no reference; one that did does",
		"%d then %d" % [after_slower, sent[0]])
	_done()


## Stands in for the browser shell's solo session: a node under `dot_solo` with `leave()`.
class FakeSolo extends Node:
	var left := 0

	func leave() -> void:
		left += 1


## Inside the shell's solo session Leave goes back to the shell's menu and M offers every
## course the stock list names; outside it nothing changes.
func _test_solo_in_the_shell() -> void:
	_section("solo in the browser shell: Leave and the course list")
	var before_label := _client.menu_leave_label()
	_check(_client.game.offered_maps.is_empty() and G2GSoloMaps.session() == null,
		"outside a solo session nothing is offered on M", str(_client.game.offered_maps.size()))

	var solo := FakeSolo.new()
	add_child(solo)
	DotRegistry.register(G2GSoloMaps.SERVICE, solo)
	_check(_client.menu_leave_label() == "Back to menu", "in a solo session Leave reads Back to menu",
		_client.menu_leave_label())
	_client._leave()
	_check(solo.left == 1, "Leave in a solo session asks the shell to leave once", str(solo.left))

	_client._offer_solo_maps()
	# A checkout with the maps linked holds every stock course, so add one nothing holds.
	var ghost := PackedStringArray(G2GSoloMaps.IDS)
	ghost.append("zz_unfetched_course")
	_client.game.offered_maps = ghost
	var rows: Array = _client.game.map_rows()
	var offered := PackedStringArray()
	for row: Dictionary in rows:
		if bool(row.get("download", false)):
			offered.append(str(row["id"]))
	# Linked imported maps are already held and need no download, so count what is missing.
	var missing := PackedStringArray()
	for id in G2GSoloMaps.IDS:
		if not _client.game.maps.catalogue.has(StringName(id)):
			missing.append(id)
	missing.append("zz_unfetched_course")
	# map_rows() sorts by id; with no maps linked (CI) every id is missing, so match the order.
	missing.sort()
	_check(offered == missing and "zz_unfetched_course" in offered and G2GSoloMaps.IDS.size() == 26,
		"M offers every stock course the catalogue lacks", "%d offered, %d missing" % [offered.size(), missing.size()])
	var held := 0
	for row: Dictionary in rows:
		if str(row["id"]) in G2GSoloMaps.IDS:
			held += 1
	_check(held == G2GSoloMaps.IDS.size(), "and every stock course is on the list, held or not", "%d" % held)
	_check(_client.game.config.map_content_id(&"surf_kitsune") == "gamemann/surf_kitsune",
		"a pick is fetched under the stock owner", _client.game.config.map_content_id(&"surf_kitsune"))
	var shown: Array = G2GGame.menu_rows(rows)
	var tagged := 0
	for row: Dictionary in shown:
		if "downloads when chosen" in (row["tags"] as Array):
			tagged += 1
	_check(tagged == offered.size(), "the menu says an unfetched course downloads when chosen")

	# The list in dot-server-deploy's stock configuration, when that checkout is beside this one.
	var stock := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../dot-server-deploy/cfg.example/content.yml"))
	if stock == "":
		_check(true, "(dot-server-deploy is not beside this checkout: drift not checked)")
	else:
		var block := stock.split("  game-g2gfast:")[1].split("\n  mg-")[0].split("\n  game-")[0]
		var re := RegEx.new()
		re.compile("-\\s+gamemann/([a-z0-9_]+)\\s*$")
		var named := PackedStringArray()
		for line in block.split("\n"):
			var hit := re.search(line)
			if hit != null:
				named.append(hit.get_string(1))
		var a := Array(named)
		var b := Array(G2GSoloMaps.IDS)
		a.sort()
		b.sort()
		_check(a == b, "the list is the stock content.yml's g2gfast list", "%d vs %d" % [a.size(), b.size()])

	DotRegistry.unregister(G2GSoloMaps.SERVICE)
	solo.queue_free()
	_client.game.offered_maps = PackedStringArray()
	_client.game.config.map_content_owner = ""
	_check(_client.menu_leave_label() == before_label, "after the session ends Leave reads as before", _client.menu_leave_label())
	_check(_client.game.map_rows().size() == rows.size() - offered.size(), "and the extra courses are gone from M")
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- " + title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("   ok   " + what)
	else:
		_failed += 1
		_failures.append(what + (" (" + detail + ")" if detail != "" else ""))
		print("   FAIL " + what + (" (" + detail + ")" if detail != "" else ""))
