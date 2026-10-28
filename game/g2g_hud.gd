extends "g2g_hud_layout.gd"

## The competitive-shooter timer HUD: the clock, the speed in u/s, the keys, the strafes.
##
## Composed from [DotTimerHud] rather than replacing it. What this adds is the genre's
## conventions: speed in genre units, a key display, the stage, and PRACTICE the moment a
## checkpoint is used.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# set_anchors_preset does not set offsets; a Control built in code keeps zero size otherwise.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# First, so every widget below draws over it. Sized to the viewport in `present_blind`,
	# not to this HUD's rect: a safe-area inset would leave a frame of world round the edge.
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	# The whole rect, not a box in the corner: `DotTimerHud` places its own block inside it.
	timer_hud = DotTimerHud.new()
	timer_hud.name = "Timer"
	timer_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	timer_hud.offset_left = 0.0
	timer_hud.offset_top = 0.0
	timer_hud.offset_right = 0.0
	timer_hud.offset_bottom = 0.0
	timer_hud.corner = DotTimerHud.Placement.BOTTOM_CENTRE
	timer_hud.margin = Vector2(24.0, 92.0)
	timer_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(timer_hud)

	splits_panel = DotTimerSplitsPanel.new()
	splits_panel.name = "StageSplits"
	splits_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	splits_panel.offset_left = 0.0
	splits_panel.offset_top = 0.0
	splits_panel.offset_right = 0.0
	splits_panel.offset_bottom = 0.0
	splits_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splits_panel.visible = false
	add_child(splits_panel)
	_build_labels()
	_build_crosshair()
	_build_ammo_and_notice()
	_build_spectate_and_cover()
	apply_theme()


func _build_labels() -> void:
	# The key display, directly under the clock; centred, and padded rather than
	# proportional so the four keys do not jump sideways as they light up.
	_keys = _label("Keys", HORIZONTAL_ALIGNMENT_CENTER)
	_keys.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_keys.offset_left = 0.0
	_keys.offset_right = 0.0
	_keys.offset_top = -80.0
	_keys.offset_bottom = -52.0

	# Reference rather than gameplay (map, track, time limit, rules), along the top.
	_status = _label("Status", HORIZONTAL_ALIGNMENT_CENTER)
	_status.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_status.offset_left = 0.0
	_status.offset_right = 0.0
	_status.offset_top = 14.0
	_status.offset_bottom = 40.0
	# Quieter than the timer, but not see-through: at 0.62 it vanished over a pale sky.
	_status.modulate = Color(1.0, 1.0, 1.0, 0.88)


func _build_crosshair() -> void:
	# A first-person view with an empty centre reads as broken; dot-ui draws one without art.
	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.offset_left = 0.0
	_crosshair.offset_top = 0.0
	_crosshair.offset_right = 0.0
	_crosshair.offset_bottom = 0.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if DotAddonApi.build_level("dot_ui") >= 14:
		# Hidden while dead (dot-ui API 14); a client with no combat layer cannot tell, so shown.
		_crosshair.set(&"alive_source", _viewer_alive)
	add_child(_crosshair)

	# Hit feedback, from dot-ui: drawn only from a hit the authority applied (`confirm_hit`).
	damage_numbers = DotDamageNumbers.new()
	damage_numbers.name = "DamageNumbers"
	damage_numbers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	damage_numbers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(damage_numbers)

	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hit_marker)


func _build_ammo_and_notice() -> void:
	# Placed by `place()`, which knows where the clock is.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ammo)
	weapon_icon = TextureRect.new()
	weapon_icon.name = "WeaponIcon"
	weapon_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	weapon_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	weapon_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	weapon_icon.visible = false
	add_child(weapon_icon)

	# Things that just happened, above the clock. The offset derives from the clock's
	# (NOTICE_CLEARANCE): at -160 a finish time overprinted "0:00.000".
	_notice = _label("Notice", HORIZONTAL_ALIGNMENT_CENTER)
	_notice.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.offset_left = -600.0
	_notice.offset_right = 600.0
	_notice.offset_top = -(NOTICE_CLEARANCE + 26.0)
	_notice.offset_bottom = -NOTICE_CLEARANCE


func _build_spectate_and_cover() -> void:
	# Who you are watching, under the status line; not movable.
	_spectating = _label("Spectating", HORIZONTAL_ALIGNMENT_CENTER)
	_spectating.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_spectating.offset_left = 0.0
	_spectating.offset_right = 0.0
	_spectating.offset_top = 44.0
	_spectating.offset_bottom = 70.0
	_spectating.visible = false

	# Who is watching you: on a plate, because it is names drawn over arbitrary sky.
	_spectators = PanelContainer.new()
	_spectators.name = "Spectators"
	_spectators.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spectators.visible = false
	add_child(_spectators)
	_spectators_label = Label.new()
	_spectators_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spectators.add_child(_spectators_label)

	# Last, so it draws over every widget above; sized to the viewport in `show_loading`.
	loading_cover = ColorRect.new()
	loading_cover.name = "Loading"
	loading_cover.color = BLIND_COLOUR
	loading_cover.set_anchors_preset(Control.PRESET_TOP_LEFT)
	loading_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loading_cover.visible = false
	add_child(loading_cover)

	_loading_label = Label.new()
	_loading_label.name = "Text"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_label.offset_left = 0.0
	_loading_label.offset_top = 0.0
	_loading_label.offset_right = 0.0
	_loading_label.offset_bottom = 0.0
	_loading_label.add_theme_font_size_override("font_size", 22)
	_loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loading_cover.add_child(_loading_label)


func bind(p_game: G2GGame, p_player: StringName) -> void:
	game = p_game
	player_id = p_player

	game.run_filed.connect(_on_run_filed)
	# Offline (and on a listen server) the combat layer is in this process and says it
	# itself; a client is told by the server instead (G2GClient, the bridge's HIT).
	if game.combat != null:
		game.combat.hit_landed.connect(
			func(id: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
				if id == player_id:
					confirm_hit(victim, amount, point, killed, headshot)
		)
	# Where an authoritative game is in this process (offline, a listen server), it says
	# these itself; on a client they arrive from the server instead (G2GClient).
	game.standing_changed.connect(
		func(id: StringName, standing: Dictionary) -> void:
			if id == player_id:
				apply_standing(standing)
	)
	game.announced.connect(
		func(id: StringName, text: String, everyone: bool) -> void:
			if everyone or id == player_id:
				notice(text)
	)
	game.map_ready.connect(func(map: DotMapDef) -> void: notice(now_playing_text(map)))
	game.movement_changed.connect(
		func(config: G2GConfig) -> void:
			notice("Movement changed: autobhop %s, airaccel %.0f" % [
				"on" if config.auto_bhop else "off", config.air_accelerate
			])
	)
	game.timers.player_staged.connect(
		func(id: StringName, number: int, split: float) -> void:
			if id == player_id:
				notice("Stage %d — %s" % [number, DotTimerRun.format_time(split)])
	)

	# How many stages this map's track has, and the player's own best split at each,
	# so the clock block can say "Stage 2 / 5  -0.42" rather than only "Stage 2".
	#
	# Refreshed on a map change and on a filed run, which are the only two things that
	# change either — NOT per frame. `stage_splits_for` goes to the store, and a store
	# is a database handle behind an interface written to be asynchronous; asking it
	# 128 times a second for a number that changes twice an hour is the cost this HUD
	# would never notice locally and a server would.
	game.map_ready.connect(func(_map: DotMapDef) -> void:
		# A comparison for the map just left is not this one's; the server sends the new
		# one, and one that already arrived for this map stays.
		if not _remote_reference.is_empty() and not _remote_is_for_this_map():
			_remote_reference = {}
		refresh_stage_reference()
	)
	# The authoritative game says when a comparison moved (a section filed, a style
	# changed); a client's game never does, and the server's message takes this path instead.
	game.stage_reference_changed.connect(
		func(id: StringName, _reference: Dictionary) -> void:
			if id == player_id:
				refresh_stage_reference()
	)
	game.run_filed.connect(
		func(id: StringName, _run: DotTimerRun, _rank: int, _reason: String) -> void:
			if id == player_id:
				refresh_stage_reference()
	)

	refresh_stage_reference()


## A hit of this HUD's player that the authority applied: the marker round the crosshair
## and the number on the body. Never called from a prediction.
func confirm_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
	if hit_marker == null:
		return
	hit_marker.flash(killed, headshot)
	damage_numbers.add(victim, amount, point, headshot)


## The counter for [param player]'s weapon in hand; cleared for null (watching somebody
## else, whose weapon this client is never sent) or empty hands.
func show_weapon(player: G2GPlayer) -> void:
	if ammo == null:
		return
	var id: StringName = player.held_weapon if player != null else &""
	if id == &"":
		ammo.clear()
		weapon_icon.visible = false
		return
	var sprite := G2GWeaponIcons.shared.texture(id)
	weapon_icon.texture = sprite
	weapon_icon.visible = sprite != null
	G2GWeaponIcons.shared.filter(weapon_icon, true)
	var def: DotWeaponDef = _weapon_defs().get(id)
	ammo.show_ammo(def.display_name if def != null else String(id), -1, -1, false, true)


static var _defs: Dictionary = {}


static func _weapon_defs() -> Dictionary:
	if _defs.is_empty():
		_defs = G2GArsenal.weapon_table()
	return _defs


func notice(text: String) -> void:
	_notice.text = text
	_notice_until = Time.get_ticks_msec() / 1000.0 + 4.0


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null:
		return

	if Time.get_ticks_msec() / 1000.0 > _notice_until:
		_notice.text = ""

	place()

	var player: G2GPlayer = game.players.get(shown_id())
	if player == null:
		player = game.players.get(player_id)
	if player == null:
		return

	var state := player.controller.state

	show_weapon(game.players.get(player_id) if shown_id() == player_id else null)

	timer_hud.style_name = player.timer_style.display_name if player.timer_style != null else ""
	timer_hud.show_run(player.timer.run if player.timer != null else null, player.speed(),
		player.controller.stats.to_dictionary())
	if splits_panel != null and splits_panel.visible:
		splits_panel.show_run(player.timer.run if player.timer != null else null)

	# The key display. Read from the state's own buttons — what the SIMULATION saw —
	# rather than from Input, so it shows what the server would show for a replay.
	var cmd := player.controller.current_command
	var move := cmd.move if cmd != null else Vector2.ZERO
	var buttons := cmd.buttons if cmd != null else 0

	# The speed is NOT repeated here. `DotTimerHud` draws it in the block this line
	# sits under, and the same number twice, six pixels apart, in two different
	# formats, is the shape the old layout had.
	_keys.text = "%s %s %s %s    %s  %s" % [
		"W" if move.y > 0.1 else "·",
		"A" if move.x < -0.1 else "·",
		"S" if move.y < -0.1 else "·",
		"D" if move.x > 0.1 else "·",
		"JUMP" if buttons & DotFpsCommand.BUTTON_JUMP else "····",
		"DUCK" if buttons & DotFpsCommand.BUTTON_CROUCH else "····",
	]

	# The track is not repeated here either — `DotTimerHud` draws it beside the style,
	# where a player reads the two together.
	var parts := PackedStringArray([
		game.maps.current.label() if game.maps.current != null else "-",
	])

	# No limit (offline, by default) is no clock, not "0:00": the same rule as a vote with none.
	var local := game.maps.time_limit.formatted_remaining() if game.maps.time_limit.duration > 0.0 else ""
	var time_left := time_left_text(clock_view, local, Time.get_ticks_msec() / 1000.0)

	# Nothing at all when the vote has no clock, rather than "no limit": a status line
	# spending a slot on something that is not happening is a slot a player learns to skip.
	if time_left != "":
		parts.append(time_left)

	parts.append("autobhop %s" % ("on" if game.config.auto_bhop else "off"))
	# In words: the enum's own name ("FIRST_PERSON") is a debug string on a player's screen.
	if player.camera != null:
		parts.append("third person" if player.camera.is_third_person() else "first person")

	if player.timer != null and player.timer.run.used_checkpoints:
		parts.append("PRACTICE")

	if state.is_grounded():
		parts.append("ground")

	_status.text = "   ·   ".join(parts)


## Covers the screen with [param text], or uncovers it when [param text] is empty.
##
## Pushed by the client every frame from [method G2GNetBridge.transit_text] rather than
## read off the game, because whether the server is somewhere this client is not is a
## fact about the connection, and offline there is no connection to ask.
func show_loading(text: String) -> void:
	if loading_cover == null:
		return

	loading_cover.visible = text != ""

	if not loading_cover.visible:
		return

	_loading_label.text = text

	if is_inside_tree():
		var inverse := get_global_transform().affine_inverse()
		loading_cover.position = inverse * Vector2.ZERO
		loading_cover.size = inverse.basis_xform(get_viewport_rect().size)


## Fades [member blind_overlay] toward whether the followed player is blinded.
##
## Read off the player rather than pushed by anybody, because the flag arrives in a
## snapshot on a networked client and is set directly offline, and a HUD that had to be
## told would need telling from two places. Public so a check can step it.
## Where the timer's plate is drawn, in screen pixels, or an empty rect while it draws none.
##
## For the chat box, which sits on its own unscaled layer bottom-left and has to stay out of
## a plate that this HUD's scale and the player's placement decide.
func timer_rect() -> Rect2:
	if timer_hud == null or not timer_hud.is_visible_in_tree():
		return Rect2()

	var plate := timer_hud.block_size()

	if plate == Vector2.ZERO:
		return Rect2()

	var origin: Vector2 = timer_hud.call("_plate_origin", plate)
	var xf := timer_hud.get_global_transform_with_canvas()
	return Rect2(xf * origin, xf.basis_xform(plate))


func _viewer_alive() -> bool:
	var health: DotHealth = game.combat.health_of(player_id) if game != null and game.combat != null else null
	return health == null or health.alive


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var player: G2GPlayer = game.players.get(player_id) if game != null else null
	var want := 1.0 if player != null and player.blinded else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	if blind_overlay.visible and is_inside_tree():
		# The whole viewport, in this HUD's own coordinates — whatever its parent and the
		# interface scale did to where this HUD starts.
		var inverse := get_global_transform().affine_inverse()
		blind_overlay.position = inverse * Vector2.ZERO
		blind_overlay.size = inverse.basis_xform(get_viewport_rect().size)


## The line a map change puts on screen: the map, and who made it when that is known.
##
## [b]The credit is the point.[/b] The imported maps are other people's work, kept on the
## condition that their authors are credited, and `DotMapDef.author` carried each name
## from its zones file into the catalogue while nothing ever drew it (`[credit-1]`). A
## credit nobody can see is not a credit. A hand-built map has no author field and reads
## as it always did, and so does an import nobody has credited yet.
static func now_playing_text(map: DotMapDef) -> String:
	if map == null:
		return ""
	var line := "Now playing %s" % map.label()
	var who := G2GMapCatalogue.credit(map)
	if not who.is_empty():
		line += ", by %s" % who
	return line


## What the status line says about the map's time left: the server's clock when it has
## said anything — empty when that clock does not exist — and [param local] otherwise.
static func time_left_text(view: DotVoteClockView, local: String, now: float) -> String:
	if view != null and view.known:
		return view.formatted_at(now)

	return local


## The standing line: the record, the player's best and their place.
func apply_standing(standing: Dictionary) -> void:
	timer_hud.set_comparisons(float(standing.get("pb", 0.0)), float(standing.get("wr", 0.0)))
	timer_hud.set_standing(int(standing.get("rank", 0)), int(standing.get("total", 0)))
	# The stage splits come from the store's cache (`stage_splits_for` peeks, it never
	# waits), and a standing update is what has just filled it. Without this, the first
	# read after a map change on a database-backed server finds nothing cached and the
	# stage line shows no gap until the next finish.
	refresh_stage_reference()


func _on_run_filed(id: StringName, run: DotTimerRun, rank: int, reason: String) -> void:
	if id != player_id:
		return
	# A game with a store says more through `announced` (the personal best, the gap, the
	# place a refused run would have taken); this line is for one without.
	if game.timers != null and game.timers.store != null:
		return
	if reason != "":
		notice("%s — not recorded: %s" % [run.formatted_time(), reason])
	else:
		notice("%s — rank %d" % [run.formatted_time(), rank])
