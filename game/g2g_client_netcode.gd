extends "g2g_client_boot.gd"

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = G2GGame.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 0
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()
	if not ready_result.ok:
		return ready_result

	bridge = G2GNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net, link)
	if not attached.ok:
		return attached

	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result("g2g.client", "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again: the remote workbench's frame and the profile rows.
	_workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	_profile_runtime = DotProfileRuntime.new()
	_profile_link = DotNetProfileLink.attach(net, _profile_runtime)
	net.messages.seal()

	# The client halves. Built here rather than in `_ready` because both need the
	# bridge, and there is no bridge offline.
	extras = G2GClientExtras.new()
	extras.name = "Extras"
	add_child(extras)

	var extra := extras.attach(bridge, game)
	DotLog.result("g2g.client", "the client's chat and voice", extra)
	platform.look_voice = extras.voice
	platform.look_chat = extras.chat
	platform.look_position_fn = _look_position
	platform.build_look_mute()

	extras.said.connect(_on_said)

	# What the server says is carrying chat. It decides whether the box is drawn at all
	# when the player's setting is `auto`.
	extras.chat_relay_changed.connect(func(relayed: bool) -> void:
		if presentation != null:
			presentation.set_chat_relayed(relayed)
	)

	# [b]Where chat actually arrives.[/b] `G2GServices` routes a line through dot-chat
	# and then hands it to dot-server's manager to put on the wire, so on this end it
	# lands on `DotClientLink.chat_received` — not on anything dot-chat owns. Without
	# this connection the client's `DotChatClient` is a history nothing feeds.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)

	_wire_bridge_feedback()
	_wire_bridge_world()

	# A touch sampler on a phone or tablet: the same keys, plus the stick and drag-look G2GTouch forwards.
	_sampler = DotFpsTouchSampler.new(game.tunables) if DotPlatform.has_touch() else DotFpsSampler.new(game.tunables)
	DotFpsSampler.register_default_actions(_sampler)

	if link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	# ENet's own round trip on UDP and the early heartbeats' on WebSocket (dot-server's
	# `rtt_ms`); the plain heartbeat on a link older than that. Duck-typed, because a pack
	# runs on whatever dot-server the shell carries.
	if link.has_method("rtt_ms"):
		bridge.rtt_source = func() -> float:
			return float(link.call("rtt_ms"))
	elif link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	return net.start()

## The bridge's signals that reach the HUD, the rules and the spectator lists.
func _wire_bridge_feedback() -> void:
	bridge.hello_received.connect(_on_hello)
	bridge.rules_received.connect(_on_rules)
	bridge.spectate_received.connect(_on_spectate)
	bridge.spectators_received.connect(func(target: StringName, names: PackedStringArray) -> void:
		spectator_lists[target] = names
		_show_spectator_list()
	)
	bridge.map_refused.connect(_on_map_refused)
	bridge.finish_received.connect(func(pid: int, time: float, rank: int) -> void:
		if hud != null and pid == bridge.local_player_id:
			hud.notice("%s%s" % [DotTimerRun.format_time(time), " — rank %d" % rank if rank > 0 else ""])
	)
	bridge.notice_received.connect(func(_pid: int, text: String) -> void:
		if hud != null:
			hud.notice(text)
	)
	bridge.standing_received.connect(func(pid: int, standing: Dictionary) -> void:
		if pid != bridge.local_player_id:
			return
		_standing = standing
		if hud != null:
			hud.apply_standing(standing)
	)
	bridge.stage_reference_received.connect(func(pid: int, reference: Dictionary) -> void:
		if pid != bridge.local_player_id:
			return
		_stage_reference = reference
		if hud != null:
			hud.apply_stage_reference(reference)
	)
	# A hit of ours the server applied: the marker and the number on the body. Only sent to
	# the one who fired, so there is no player to check.
	bridge.hit_received.connect(func(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
		if hud != null:
			hud.confirm_hit(victim, amount, point, killed, headshot)
	)


var _use_was_down: bool = false


## The use key: tells the server when it changes, and draws the pickup panel and the crosshair ring.
func _use_key_frame(delta: float) -> void:
	if game.weapon_layer == null or player == null or bridge == null or hud == null:
		return
	var down := Input.is_action_pressed(&"g2g_use") and InputMap.has_action(&"g2g_use")
	if down != _use_was_down:
		_use_was_down = down
		bridge.ask_use_key(down)
	var arsenal: Object = game.combat.arsenal_of(bridge._player_key(bridge.local_player_id)) if game.combat != null else null
	hud.set_hold_progress(game.weapon_layer.update_prompt(player, arsenal, down, delta))


## Whether the trigger is down: the left button while the pointer is the view's (the click that captures it
## is not a shot, and a menu or the console has released it), or a finger on the touch FIRE button.
## [member G2GNetBridgeWire.attack_wanted] is set from this every frame.
func fire_wanted() -> bool:
	if touch != null and touch.fire_held():
		return true
	return mouse_drives_view() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _process(delta: float) -> void:
	if net != null and not _offline:
		net.interpolate_frame()

	if bridge != null:
		_cover_transit(bridge.transit_text())

	if touch != null:
		touch.sync()
	_fold_look()
	_fold_correction()
	_fold_clock()

	for id in (game.players if game != null else {}):
		(game.players[id] as G2GPlayer).present(delta)

	if game != null:
		_present_others()
		_use_key_frame(delta)
	if bridge != null:
		bridge.attack_wanted = fire_wanted()
	# Every frame rather than on change: a style change hands the player new tunables, and
	# two assignments a frame are cheaper than tracking which object the sampler holds.
	_apply_look()

	if flashlight != null and flashlight.on and player != null and player.camera != null \
			and player.camera.first != null:
		# The first-person camera is the eye in both views: in third person it still sits at
		# the eye and pitches with the view, it simply is not the one drawing.
		flashlight.present(delta, player.camera.first.global_transform)

	if presentation != null:
		var camera: Camera3D = player.camera.active() \
			if player != null and player.camera != null else null
		var eye := camera.global_position if camera != null else Vector3.ZERO
		var forward := -camera.global_transform.basis.z if camera != null else Vector3.FORWARD
		if platform != null and platform.slide_sounds != null and presentation.steps != null:
			presentation.steps.surf_rules = platform.slide_sounds.get(&"surf_rules")
		presentation.present(delta, eye, forward)
		var stack_now := game.player_stack
		if stack_now != null and stack_now.physics != null and stack_now.physics.layout != null and player != null:
			presentation.follow_roof(delta, eye, player.get_world_3d().direct_space_state,
				stack_now.physics.layout.mask_of([&"world"]))

		if hud != null:
			presentation.fit_chat_beside(hud.timer_rect())

		# Watched rather than listened for. A landing fires on the authority, which on a
		# netted client is somewhere else -- so a client that hooked a signal would be
		# silent online and perfectly noisy offline, which is the kind of difference
		# nothing catches. What a player perceives is their own feet touching the ground.
		if player != null and player.controller != null:
			var st := player.controller.state
			# `is_grounded()`, not `grounded`: [DotFpsState] has no such property and
			# never did. This threw once a frame, so `watch_movement` never ran and the
			# client had no landing effect and no footsteps at all -- in a `_process`,
			# where a script error aborts the call and the game keeps running.
			presentation.watch_movement(
				st.is_grounded(), Vector2(st.velocity.x, st.velocity.z).length(),
				st.position
			)
		presentation.keep_walkers(game.players.values())

		if camera != null:
			# Zero by default: a shaken camera on a surf ramp is a lost run. One writer moves the camera.
			camera.position = presentation.camera_shake()

	# Last: the shake above sets the active camera's position every frame and would undo the spectator view.
	_drive_spectator_camera()
	if killcam != null:
		killcam.hide_while_playing = [hud]
		killcam.frame()


## Where a spectator looks.
##
## Once a FRAME, not once a tick. A camera moved on the tick timeline steps at the tick
## rate however smoothly the runner it is following is interpolated, and this game
## measured that at a 47% change in apparent speed eight times a second — the whole
## reason `jitter_probe.tscn` exists.
##
## The rig's own camera is left where it is and only its transform is overwritten, so
## turning spectating off puts the player straight back in their own view with no
## rebuild.
func _drive_spectator_camera() -> void:
	if game == null or game.spectate == null or player == null:
		return

	var camera: Camera3D = player.camera.active() if player.camera != null else null

	if camera == null:
		return

	if not game.spectate.is_spectating(player.player_id):
		return

	if game.spectate.is_roaming(player.player_id):
		_drive_free_camera(camera)
		return

	_roam_seeded = false

	# The chase camera pulled out of the walls by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = 1

	var where := game.spectate.camera_for(player.player_id)

	if where == Transform3D.IDENTITY:
		return

	camera.global_transform = where


## The free camera, once a frame: WASD along the view, Space and Ctrl up and down, Shift fast,
## Alt slow, the mouse to look. The player's body is never touched (its sampler is suspended
## while spectating); only the camera's transform is set, from [DotSpectatorFreeCam].
##
## [b]The speed is the server's[/b] (`mp_freeroam_speed`, through the mirror's rules), so a
## client cannot fly faster than it was told to. The server holds only the mode.
func _drive_free_camera(camera: Camera3D) -> void:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
	_free_cam.rules = game.spectate.manager.rules
	if not _roam_seeded:
		# The camera still holds last frame's pose: where this spectator was looking.
		_free_cam.seed_from(camera.global_transform)
		_roam_seeded = true
		_roam_look = Vector2.ZERO
	_free_cam.look(_roam_look)
	_roam_look = Vector2.ZERO
	var move := Vector3.ZERO
	if not (overlay_open() or (presentation != null and presentation.swallows_input())):
		move = Vector3(
			Input.get_axis(&"dot_fps_left", &"dot_fps_right"),
			Input.get_axis(&"dot_fps_crouch", &"dot_fps_jump"),
			Input.get_axis(&"dot_fps_back", &"dot_fps_forward"))
	var shift := Input.is_physical_key_pressed(KEY_SHIFT)
	var alt := Input.is_physical_key_pressed(KEY_ALT)
	camera.global_transform = _free_cam.step(move, shift, alt and not shift,
		get_process_delta_time())


func _unhandled_input(event: InputEvent) -> void:
	# The release goes first and past every cover: a menu opened mid-hold must not leave the key down on the server.
	if bridge != null and event.is_action_released(&"g2g_drop_weapon"):
		bridge.ask_drop_weapon(false)
		return

	if _covered():
		return

	# [b]An open menu or help screen owns the keyboard[/b], ahead of everything below: its
	# own controls have already had the event, and what reaches here is only ever a key to
	# close it or a key that must NOT fall through to the run — R behind a menu is a restart
	# nobody asked for.
	if overlay_open():
		return

	# [b]The console first.[/b] This client reads bare letters -- F5, N, R, C, V, M --
	# so without this, typing at the console reloads the map, opens the scoreboard and
	# changes style at the same time. It is the line every game that ships a console
	# forgets, and this project already lost a whole keyboard once to a guard in the
	# wrong place.
	if presentation != null and presentation.swallows_input():
		return

	# A finger is the touch overlay's, and so is the mouse Godot emulates from it: a tap neither captures the pointer
	# (there is none to capture on a phone) nor turns the view twice. The first tap is the "click" that starts play.
	if touch != null and touch.takes(event):
		if _awaiting_click and event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			_awaiting_click = false
			if hud != null:
				hud.notice("")
		return

	# [b]Before the `player == null` guard, deliberately.[/b] A browser player clicks
	# while the world is still loading more often than not, and a click swallowed
	# because no player exists yet is a click that never captures the cursor — after
	# which the only affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and click_may_capture():
			_awaiting_click = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			if hud != null:
				hud.notice("")
			return

	# Escape closes the zone editor. Every other Escape, H, P and Tab is the menu's own
	# (it sits under this node, so it hears them first), which is how they work with no
	# player too: the menu is how somebody stuck on a loading map leaves it.
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			if zone_editor != null and zone_editor.is_open():
				zone_editor.close()
				return

	if player == null:
		return

	if _editor_or_spectate_input(event):
		return

	if event is InputEventMouseMotion:
		if not mouse_drives_view():
			return

		if roaming:
			_roam_mouse(event as InputEventMouseMotion)
			return

		var sampler := _active_sampler()
		if sampler != null:
			sampler.handle_event(event)
		return

	# Push to talk, before the "is a press" filter: a talk key needs its release too, or the
	# microphone never closes. K by default, because V is the second checkpoint key.
	if event.is_action(DotVoiceManager.TALK_ACTION) and not event.is_echo():
		if extras != null:
			extras.set_talking(event.is_pressed())

		return

	# The wheel's jump: a tick is a press and a release in one frame, which polling never sees,
	# so the sampler latches it. Here, after the zone editor (whose wheel sets a height) and
	# behind the menu, console and gate guards above, so none of those jump.
	if event is InputEventMouseButton and mouse_drives_view():
		var wheel_sampler := _active_sampler()
		if wheel_sampler != null:
			wheel_sampler.handle_event(event)

	if not event.is_pressed() or event.is_echo():
		return

	_press_action(event)


## True when the zone editor or spectating took the event.
func _editor_or_spectate_input(event: InputEvent) -> bool:
	# The zone editor takes its own keys and the left button while it is open; mouse look
	# and movement carry on, because aiming IS how a corner is placed.
	if zone_editor != null and zone_editor.is_open():
		if event is InputEventKey and zone_editor.handle_key(event as InputEventKey):
			get_viewport().set_input_as_handled()
			return true
		if event is InputEventMouseButton and zone_editor.handle_click(event as InputEventMouseButton):
			get_viewport().set_input_as_handled()
			return true

	# Spectating: the two buttons cycle whom. Pressed only — a release is not a second
	# click — and only once the pointer is the view's, so the click that captures it in a
	# browser is not also a change of target.
	if is_spectating() and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button := (event as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_LEFT or button == MOUSE_BUTTON_RIGHT:
			cycle_spectate(button == MOUSE_BUTTON_RIGHT)
			get_viewport().set_input_as_handled()
			return true
	return false


## Actions rather than keycodes, so each is the player's own key (a mouse button too).
func _press_action(event: InputEvent) -> void:
	if event.is_action_pressed(&"g2g_servers"):
		show_servers()
	elif event.is_action_pressed(&"g2g_roam"):
		toggle_roam()
	elif event.is_action_pressed(&"g2g_third_person"):
		if player.camera != null and not player.camera.toggle():
			hud.notice(game.view_rules.refusal() if game.view_rules.refusal() != "" else "Third person is not allowed on this server.")
	elif event.is_action_pressed(&"g2g_flashlight"):
		toggle_flashlight()
	elif event.is_action_pressed(&"g2g_hide_others"):
		toggle_hide_others()
	elif event.is_action_pressed(&"g2g_style_next"):
		var styles := game.timers.styles_in_order()
		_style_index = (_style_index + 1) % styles.size()
		menu_choose_style(styles[_style_index].id)
	elif event.is_action_pressed(&"g2g_restart"):
		_restart_key()
	elif event.is_action_pressed(&"g2g_drop_weapon"):
		bridge.ask_drop_weapon(true)
	elif event.is_action_pressed(&"g2g_zones"):
		if zone_editor != null:
			zone_editor.toggle()
	elif event.is_action_pressed(&"g2g_checkpoint_save"):
		if not _offline:
			bridge.ask_checkpoint(0)
		else:
			var s := player.controller.state
			var saved := game.timers.checkpoints_for(&"local").save(
				s.position, s.velocity, s.yaw, s.pitch, s.is_grounded(), s.is_crouched())
			hud.notice("Checkpoint saved" if saved.ok else saved.error.message)
	elif event.is_action_pressed(&"g2g_checkpoint_load"):
		if not _offline:
			bridge.ask_checkpoint(1)
		else:
			var cp := game.timers.checkpoints_for(&"local").load_current()
			if cp == null:
				hud.notice("No checkpoints. %s saves one." % presentation.bindings.key_for(&"g2g_checkpoint_save"))
			else:
				player.teleport(cp.position, cp.yaw)
				player.controller.state.velocity = cp.velocity
				player.controller.state.pitch = cp.pitch


func apply_theme(palette: DotMenuPalette) -> void:
	if hud != null:
		hud.apply_theme(palette)
	if zone_editor != null and menu != null:
		zone_editor.kit = menu.kit


## The layout editor, from the menu's "Move HUD elements".
func open_hud_editor() -> void:
	if menu == null or hud == null:
		return
	# Here rather than when the menu is built: offline the HUD is made a few lines later,
	# and online it is a JOIN away.
	menu.open_layout_editor(hud, HUD_PIECES)


## The HUD's layout settings as one dictionary, the shape [method G2GHud.apply_layout]
## takes.
func _hud_layout(st: DotSettingsManager) -> Dictionary:
	return {
		"show_time": st.get_bool(&"timer_show_time", true),
		"show_track": st.get_bool(&"timer_show_track", true),
		"show_stage": st.get_bool(&"timer_show_stage", true),
		"show_stats": st.get_bool(&"timer_show_stats", true),
		"show_standing": st.get_bool(&"timer_show_standing", true),
		"comparison": st.get_string(&"timer_comparison", "pb"),
		"show_stage_splits": st.get_bool(&"show_stage_splits", true),
		"compact": st.get_bool(&"timer_compact", true),
		"size": st.get_int(&"timer_size", 30),
		"position": st.get_string(&"timer_position", "bottom_centre"),
		"show_status": st.get_bool(&"show_status", true),
		"show_spectators": st.get_bool(&"show_spectators", true),
		"positions": G2GHud.positions_from_text(st.get_string(&"hud_positions", "")),
	}


## Layouts a player can start from, as setting values. A preset writes settings and is
## not one itself, so a player who picks one and then moves one thing has their own.
const LAYOUT_PRESETS := {
	&"classic": {
		"timer_show_time": true, "timer_show_track": true, "timer_show_stage": true,
		"timer_show_stats": true, "timer_show_standing": true, "timer_compact": true,
		"timer_size": 30, "timer_position": &"bottom_centre", "show_speed": true,
		"show_splits": true, "show_keys": true, "show_status": true, "hud_positions": "",
	},
	&"minimal": {
		"timer_show_time": true, "timer_show_track": false, "timer_show_stage": false,
		"timer_show_stats": false, "timer_show_standing": false, "timer_compact": true,
		"timer_size": 34, "timer_position": &"bottom_centre", "show_speed": true,
		"show_splits": false, "show_keys": false, "show_status": false, "hud_positions": "",
	},
	&"everything": {
		"timer_show_time": true, "timer_show_track": true, "timer_show_stage": true,
		"timer_show_stats": true, "timer_show_standing": true, "timer_compact": false,
		"timer_size": 28, "timer_position": &"bottom_centre", "show_speed": true,
		"show_splits": true, "show_keys": true, "show_status": true, "hud_positions": "",
	},
	&"corner": {
		"timer_show_time": true, "timer_show_track": true, "timer_show_stage": true,
		"timer_show_stats": false, "timer_show_standing": true, "timer_compact": true,
		"timer_size": 26, "timer_position": &"top_left", "show_speed": true,
		"show_splits": true, "show_keys": true, "show_status": true, "hud_positions": "",
	},
}


func menu_layout_presets() -> Array:
	return [[&"classic", "Classic"], [&"minimal", "Minimal"], [&"everything", "Everything"], [&"corner", "Top-left corner"]]


func menu_apply_layout_preset(id: StringName) -> void:
	if presentation == null or presentation.settings == null or not LAYOUT_PRESETS.has(id):
		return
	var preset: Dictionary = LAYOUT_PRESETS[id]
	for key: Variant in preset:
		var _set := presentation.settings.set_value(StringName(str(key)), preset[key])


func menu_edit_layout() -> void:
	open_hud_editor()


# Menus

## The pieces of the HUD a player can move, and what the editor calls them.
const HUD_PIECES := {
	&"timer": "Timer",
	&"keys": "Keys",
	&"status": "Status line",
	&"spectators": "Spectators",
}


## The menus: dot-menu's, with this game's pages, keys and scoreboard. See [G2GMenuPages].
func _build_overlays() -> void:
	menu = DotMenu.new()
	menu.name = "Menu"
	menu.settings = presentation.settings if presentation != null else null
	menu.bindings = presentation.bindings if presentation != null else G2GBindings.make()
	var config := DotMenuConfig.new()
	config.brand_mark = "g2g"
	config.brand_name = "fast"
	config.leave_text = "Quit game"
	var _layered := config.load_layered()
	menu.config = config
	menu.help_action = &"g2g_help"
	menu.theme_action = &"g2g_theme_next"
	menu.scoreboard_action = &"g2g_scoreboard"
	# The console has the keyboard while it is open, and so does the zone editor's Escape.
	menu.busy = func() -> bool:
		return (presentation != null and presentation.swallows_input()) \
			or (zone_editor != null and zone_editor.is_open())
	add_child(menu)
	var _set := menu.setup()
	G2GMenuPages.install(menu, self)
	_follow_hud()
	# The console after the menu, so DotConsoleKit registers it as one of the menu's
	# overlays: opening it then stops the runner through `overlays_changed` below.
	if presentation != null:
		presentation.build_console(menu)

	menu.overlays_changed.connect(func(_open: bool) -> void: _refresh_suspended())
	menu.click_to_play.connect(func() -> void:
		_awaiting_click = true
		_say_click_to_play())
	menu.action_requested.connect(func(id: StringName) -> void:
		if id == &"leave":
			_leave())
	# M: the map list (dot-menu's map menu). Solo a choice changes the map here; connected the
	# server decides, by the owner's `sv_map_menu_flag`, and anybody without it gets a vote
	# (dot-vote's map menu, wired in [G2GModule]). By name, so a client shell older than the
	# map menu still runs the game without it.
	if menu.has_method(&"use_maps"):
		var maps: Variant = menu.call(&"use_maps", func() -> Array: return G2GGame.menu_rows(game.map_rows()) if game != null else [],
			change_from_menu)
		if maps is Object:
			(maps as Object).set(&"title", "Change map")
	menu.layout_editor.saved.connect(func(text: String) -> void:
		if presentation != null and presentation.settings != null:
			var _saved := presentation.settings.set_value(&"hud_positions", text)
	)
	menu.theme_changed.connect(func(palette: DotMenuPalette) -> void:
		apply_theme(palette)
		if hud != null:
			hud.notice("Theme: %s" % palette.display_name)
	)
	_wire_scoreboard()
	if zone_editor != null:
		zone_editor.kit = menu.kit
	_refresh_menu_words()

	flashlight = G2GFlashlight.new()
	flashlight.name = "Flashlight"
	flashlight.toggled.connect(func(on: bool) -> void:
		if presentation != null:
			presentation.on_flashlight(on)
	)
	add_child(flashlight)

	if presentation != null and presentation.settings != null:
		presentation.settings.changed.connect(
			func(_key: StringName, _value: Variant, _why: StringName) -> void: apply_client_settings()
		)


## The Tab board. A timer server's board is not kills and deaths: it is each runner's style,
## their best time here and where it places them, beside how long they have been on and their
## ping. Online those come from the server (dot-server's roster, with this game's columns
## added by [G2GModule]); offline, from the local game, which works them out the same way.
##
## [b]A server from before the roster sends nothing[/b], and a board waiting on a feed that
## never comes is an empty box; with a link that has no roster the board draws what this
## client knows instead, which is every player and none of their pings.
func _wire_scoreboard() -> void:
	var board := menu.scoreboard
	board.title_text = "Zee's Airdrift"
	board.columns = [
		{"key": &"name", "title": "Runner", "width": 3.0},
		{"key": &"style", "title": "Style", "width": 1.4},
		{"key": &"best", "title": "Best", "width": 1.3, "align": HORIZONTAL_ALIGNMENT_RIGHT,
			"format": func(v: Variant, _row: Dictionary) -> String:
				return DotTimerRun.format_time(float(v)) if v != null and float(v) > 0.0 else "—"},
		{"key": &"rank", "title": "Rank", "align": HORIZONTAL_ALIGNMENT_RIGHT,
			"format": func(v: Variant, row: Dictionary) -> String:
				if v == null or int(v) <= 0:
					return "—"
				return "%d / %d" % [int(v), int(row.get("of", 0))] if int(row.get("of", 0)) > 0 else str(int(v))},
		# Seconds connected, not a run: titled "Time" next to Best and Rank it read as the run timer.
		{"key": &"seconds", "title": "Played", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	# Fastest first; nobody with a time after everybody with one.
	board.sort_with = func(a: Dictionary, b: Dictionary) -> bool:
		var ta := float(a.get("best", -1.0))
		var tb := float(b.get("best", -1.0))
		if (ta > 0.0) != (tb > 0.0):
			return ta > 0.0
		if ta > 0.0 and not is_equal_approx(ta, tb):
			return ta < tb
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0
	board.decorate = func(row: Dictionary) -> void:
		if bool(row.get("ghost", false)):
			row["name"] = "%s  (the record)" % str(row.get("name", ""))
	if not _offline and link != null and link.has_signal(&"scoreboard_received"):
		board.feed_from(link)
	else:
		board.source = board_snapshot


## The board from this client's own world: offline, and against a server with no roster.
## Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	var here := int((Time.get_ticks_msec() - _started_msec) / 1000)
	if game != null:
		for id: StringName in game.players:
			var who: G2GPlayer = game.players[id]
			var row := game.board_fields(id) if game.authoritative else {}
			row.merge({"id": String(id), "name": who.display_name, "seconds": here if who == player else -1,
				"ping": -1, "you": who == player, "bot": who.replay != null}, true)
			rows.append(row)
	var map_name := game.maps.current.label() if game != null and game.maps != null and game.maps.current != null else ""
	return {"server": {"name": "Airdrift", "game": "offline" if _offline else "", "map": map_name}, "players": rows}


func overlay_open() -> bool:
	return menu != null and menu.any_open()


## M, as the key does: dot-menu's map menu. Solo it is this game's catalogue (every map, not
## the rotation); connected the server's list, which a player without the owner's flag sees as
## a vote. For the menu screenshots.
func open_map_list() -> void:
	if menu != null and menu.has_method(&"open_maps"):
		menu.call(&"open_maps")


## Solo: [param id] now, fetched first when it is delivered content. Connected a client never
## changes its own world (the server would correct it back every tick); the server's map menu
## decides there.
func change_from_menu(id: StringName) -> DotResult:
	if not _offline:
		return DotResult.fail(DotError.CODE_STATE, "The server changes the map.")
	return await game.change_map(id)


## Opens help, over the menu if the menu is open — closing it goes back there.
func open_help() -> void:
	if menu == null:
		return
	menu.open_help(rules.get("commands", []), not _offline)


## Where the player is, and what Leave says, for the menu's sidebar.
func _refresh_menu_words() -> void:
	if menu == null or menu.screen == null:
		return
	menu.screen.subtitle = menu_where()
	menu.screen.set_action_text(&"leave", menu_leave_label())
