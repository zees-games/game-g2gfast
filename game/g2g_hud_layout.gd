extends "g2g_hud_state.gd"

## What the player chose to see: the four HUD switches in the menu's General page.
## The speed and splits are `DotTimerHud`'s own fields, so off removes the line rather than
## leaving a gap; the key display and the crosshair are this HUD's.
func apply_visibility(show_speed: bool, show_splits: bool, show_keys: bool, show_crosshair: bool) -> void:
	if timer_hud != null:
		timer_hud.show_speed = show_speed
		timer_hud.show_split = show_splits
	_show_keys = show_keys
	if _keys != null:
		_keys.visible = show_keys
	if _crosshair != null:
		_crosshair.visible = show_crosshair


## The timer's layout, from the `timer_*`, `show_status`, `show_spectators` and `hud_positions`
## settings. [param layout] is those keys without their prefix; a missing key keeps its value.
## Every line is a `DotTimerHud` field, so a line switched off is gone, not blank.
func apply_layout(layout: Dictionary) -> void:
	if timer_hud != null:
		timer_hud.show_time = bool(layout.get("show_time", timer_hud.show_time))
		timer_hud.show_track = bool(layout.get("show_track", timer_hud.show_track))
		timer_hud.show_stage = bool(layout.get("show_stage", timer_hud.show_stage))
		timer_hud.show_stats = bool(layout.get("show_stats", timer_hud.show_stats))
		timer_hud.show_standing = bool(layout.get("show_standing", timer_hud.show_standing))
		timer_hud.compact = bool(layout.get("compact", timer_hud.compact))
		timer_hud.clock_size = clampi(int(layout.get("size", timer_hud.clock_size)), 12, 96)
		if layout.has("comparison"):
			match StringName(str(layout["comparison"])):
				&"wr":
					timer_hud.comparison = DotTimerHud.Comparison.WORLD_RECORD
				&"none":
					timer_hud.comparison = DotTimerHud.Comparison.NONE
				_:
					timer_hud.comparison = DotTimerHud.Comparison.PERSONAL_BEST
		timer_hud.queue_redraw()

	var want_panel := bool(layout.get("show_stage_splits", _show_stage_splits))
	var compare := StringName(str(layout.get("comparison", _comparison)))
	if want_panel != _show_stage_splits or compare != _comparison:
		_show_stage_splits = want_panel
		_comparison = compare
		refresh_stage_reference()

	if layout.has("position"):
		var wanted := StringName(str(layout["position"]))
		_timer_placement = wanted if PLACEMENTS.has(wanted) else &"bottom_centre"
	_show_status = bool(layout.get("show_status", _show_status))
	_show_spectators = bool(layout.get("show_spectators", _show_spectators))
	if layout.has("positions"):
		positions = (layout["positions"] as Dictionary).duplicate()
	_refresh_spectators()
	place()


## [member positions] as the setting stores it, and back: JSON of `{"timer": [0.5, 0.82], ...}`.
## Anything but a known piece with two numbers in 0..1 is dropped: a player can edit the file
## by hand, and an off-screen piece cannot be found again to drag back.
static func positions_from_text(text: String) -> Dictionary:
	var out := {}
	if text.strip_edges() == "":
		return out
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return out
	for key: Variant in (json.data as Dictionary):
		var id := StringName(str(key))
		var at: Variant = (json.data as Dictionary)[key]
		if not ELEMENTS.has(id) or not (at is Array) or (at as Array).size() != 2:
			continue
		var x := float((at as Array)[0])
		var y := float((at as Array)[1])
		if is_finite(x) and is_finite(y):
			out[id] = Vector2(clampf(x, 0.0, 1.0), clampf(y, 0.0, 1.0))
	return out


static func positions_to_text(value: Dictionary) -> String:
	if value.is_empty():
		return ""
	var out := {}
	for id: Variant in value:
		var at := value[id] as Vector2
		out[String(id)] = [snappedf(at.x, 0.0001), snappedf(at.y, 0.0001)]
	return JSON.stringify(out)


## The theme's HUD colours onto everything this HUD draws. [param palette] is the menu's
## (dot-menu's `theme_changed`); null is the default theme, which is what a HUD built before
## any menu — a suite, a server's preview — draws in.
func apply_theme(palette: DotMenuPalette = null) -> void:
	var p := palette if palette != null else DotMenuPalette.new()
	if timer_hud != null:
		timer_hud.panel_colour = p.hud_plate
		timer_hud.neutral_colour = p.hud_text
		timer_hud.detail_colour = p.hud_detail
		timer_hud.ahead_colour = p.hud_ahead
		timer_hud.behind_colour = p.hud_behind
		timer_hud.queue_redraw()
	if splits_panel != null:
		# The plate stays the panel's own translucent one: it sits over the map, not over a
		# theme's opaque card, and a heavier plate would be the loudest thing on the left.
		splits_panel.neutral_colour = p.hud_text
		splits_panel.ahead_colour = p.hud_ahead
		splits_panel.behind_colour = p.hud_behind
		splits_panel.dim_colour = Color(p.hud_text, 0.5)
		splits_panel.queue_redraw()

	# Text drawn straight over the world gets an outline in the theme's ink: the keys and
	# the status line have no plate of their own, and white text over a pale sky, or a light
	# theme's dark text over a dark corridor, is otherwise not there.
	for label in [_keys, _status, _notice, _spectating, _loading_label]:
		if label == null:
			continue
		(label as Label).add_theme_color_override(&"font_color", p.hud_text)
		(label as Label).add_theme_color_override(&"font_outline_color", p.hud_ink)
		(label as Label).add_theme_constant_override(&"outline_size", 4)

	if _spectators != null:
		_spectators.add_theme_stylebox_override(&"panel",
			DotMenuKit.new(p).box(p.hud_plate, 6, Color(0, 0, 0, 0), 0, Vector4(12, 8, 12, 8)))
		_spectators_label.add_theme_color_override(&"font_color", p.hud_text)
		_spectators_label.add_theme_font_size_override(&"font_size", 15)


## Who this HUD's player is watching, by id and by name; an empty id is nobody.
## [param roam_hint] is the free-camera key's name when the server offers one ("" otherwise).
## [param roaming] replaces the "watching X" line with the controls: there is nobody to name.
func set_spectating(target: StringName, target_name: String = "", roam_hint: String = "",
		roaming: bool = false) -> void:
	followed_id = target
	if _spectating == null:
		return
	_spectating.visible = target != &"" or roaming
	if roaming:
		_spectating.text = "Free camera    WASD move   ·   Space / Ctrl up and down   ·   Shift fast   ·   Alt slow    %s to go back to the players" % (
			roam_hint if roam_hint != "" else "R or !spec off")
	elif target != &"":
		_spectating.text = "Spectating %s    ◀ left click   ·   right click ▶%s    R or !spec off to stop" % [
			target_name if target_name != "" else String(target),
			("   ·   %s free camera" % roam_hint) if roam_hint != "" else ""]
	refresh_stage_reference()


## The names of whoever is spectating the player this HUD shows (its owner, or the player
## they are watching). Empty hides the list; so does `show_spectators`.
func set_spectators(names: PackedStringArray) -> void:
	_spectator_names = names
	_refresh_spectators()


func spectator_names() -> PackedStringArray:
	return _spectator_names


func _refresh_spectators() -> void:
	if _spectators == null:
		return
	_spectators.visible = _show_spectators and not _spectator_names.is_empty()
	if _spectators.visible:
		_spectators_label.text = "Spectators (%d)\n%s" % [_spectator_names.size(), "\n".join(_spectator_names)]


## The player the clock describes.
func shown_id() -> StringName:
	return followed_id if followed_id != &"" else player_id


## Puts every movable piece where the layout says. Every frame, because two of them change
## size with what they show — the clock's block grows a line when a stage starts, and the
## spectator list with every name — and a piece anchored by its centre has to be re-centred.
func place() -> void:
	if timer_hud == null or not is_inside_tree():
		return
	var area := size

	# The clock: a corner placement, or a dragged centre.
	if positions.has(&"timer"):
		var block := _timer_block()
		timer_hud.corner = DotTimerHud.Placement.TOP_LEFT
		timer_hud.margin = _clamp_into(_centre_of(&"timer", area) - block * 0.5, block, area)
	else:
		timer_hud.corner = PLACEMENTS.get(_timer_placement, DotTimerHud.Placement.BOTTOM_CENTRE)
		timer_hud.margin = TIMER_MARGIN_TOP if String(_timer_placement).begins_with("top") else TIMER_MARGIN

	# The keys: under the clock wherever the clock is, and over it only when the clock sits
	# so low there is no room beneath.
	var keys_size := _keys.get_combined_minimum_size()
	keys_size.x = maxf(keys_size.x, 260.0)
	if positions.has(&"keys"):
		_put(_keys, _clamp_into(_centre_of(&"keys", area) - keys_size * 0.5, keys_size, area), keys_size)
	else:
		var clock := element_rect(&"timer")
		var below := clock.position.y + clock.size.y + 4.0
		var y := below if below + keys_size.y <= area.y - 8.0 else clock.position.y - keys_size.y - 4.0
		if clock.size == Vector2.ZERO:
			y = area.y - 80.0
		var x := clock.get_center().x - keys_size.x * 0.5 if clock.size != Vector2.ZERO \
			else (area.x - keys_size.x) * 0.5
		_put(_keys, _clamp_into(Vector2(x, y), keys_size, area), keys_size)
	_keys.visible = _show_keys

	# The status line: the whole top edge, or its own width where it was dragged.
	_status.visible = _show_status
	if positions.has(&"status"):
		var status_size := _status.get_combined_minimum_size()
		status_size.x = maxf(status_size.x, 200.0)
		_put(_status, _clamp_into(_centre_of(&"status", area) - status_size * 0.5, status_size, area), status_size)
	else:
		_put(_status, Vector2(0.0, 14.0), Vector2(area.x, 26.0))

	# The weapon: bottom right, and over the clock when the clock was put there. Not one of
	# the layout editor's ELEMENTS: it is empty on every server but a deathmatch one.
	# 24 in from the edge, not 10: the plate overhangs the control by 14 on the right.
	var ammo_size := Vector2(290.0, 70.0)
	var ammo_at := Vector2(area.x - ammo_size.x - 24.0, area.y - ammo_size.y - 14.0)
	var clock_rect := element_rect(&"timer")
	if clock_rect.intersects(Rect2(ammo_at, ammo_size)):
		ammo_at.y = clock_rect.position.y - ammo_size.y - 8.0
	_put(ammo, _clamp_into(ammo_at, ammo_size, area), ammo_size)
	var icon_size := Vector2(ammo_size.x, 56.0)
	_put(weapon_icon, _clamp_into(Vector2(ammo.position.x, ammo.position.y - icon_size.y - 2.0), icon_size, area), icon_size)

	# The spectator list: down the right, centred vertically.
	var list_size := _list_size()
	if positions.has(&"spectators"):
		_put(_spectators, _clamp_into(_centre_of(&"spectators", area) - list_size * 0.5, list_size, area), list_size)
	else:
		_put(_spectators, Vector2(area.x - list_size.x - 18.0, (area.y - list_size.y) * 0.42), list_size)


## Where piece [param id] is drawn now, in this HUD's coordinates. What the layout editor
## draws a frame round and picks with the mouse.
func element_rect(id: StringName) -> Rect2:
	match id:
		&"timer":
			if timer_hud == null:
				return Rect2()
			var block := _timer_block()
			return Rect2(_timer_origin(block), block)
		&"keys":
			return Rect2(_keys.position, _keys.size) if _keys != null else Rect2()
		&"status":
			if _status == null:
				return Rect2()
			if positions.has(&"status"):
				return Rect2(_status.position, _status.size)
			var width := maxf(_status.get_combined_minimum_size().x, 200.0)
			return Rect2(Vector2((size.x - width) * 0.5, _status.position.y), Vector2(width, _status.size.y))
		&"spectators":
			if _spectators == null:
				return Rect2()
			return Rect2(_spectators.position, _list_size())
	return Rect2()


## Moves piece [param id]'s centre to [param centre] (HUD coordinates).
func move_element(id: StringName, centre: Vector2) -> void:
	if not ELEMENTS.has(id) or size.x <= 0.0 or size.y <= 0.0:
		return
	positions[id] = Vector2(clampf(centre.x / size.x, 0.0, 1.0), clampf(centre.y / size.y, 0.0, 1.0))
	place()


## Puts piece [param id] back where the layout puts it.
func reset_element(id: StringName) -> void:
	positions.erase(id)
	place()


## The clock's block, or the size of one when it draws nothing yet: still a place to grab, and
## the same size for placing as for picking, or a dragged empty clock lands elsewhere.
func _timer_block() -> Vector2:
	var block := timer_hud.block_size() if timer_hud != null else Vector2.ZERO
	return block if block != Vector2.ZERO else Vector2(220.0, 64.0)


## The spectator list's size, or the size of a short one while nobody is watching — for the
## clock's reason: the layout editor has to be able to find it and place it before anybody
## is in it.
func _list_size() -> Vector2:
	if _spectators == null:
		return Vector2.ZERO
	return _spectators.get_combined_minimum_size() if not _spectator_names.is_empty() \
		else Vector2(150.0, 60.0)


func _timer_origin(block: Vector2) -> Vector2:
	# DotTimerHud's own rule, asked rather than copied would need a method it does not
	# have; this is `_plate_origin`, which is three lines and is checked against the
	# drawn block by the presentation suite.
	var out := timer_hud.margin
	match timer_hud.corner:
		DotTimerHud.Placement.TOP_CENTRE, DotTimerHud.Placement.BOTTOM_CENTRE:
			out.x = (size.x - block.x) * 0.5
		DotTimerHud.Placement.TOP_RIGHT, DotTimerHud.Placement.BOTTOM_RIGHT:
			out.x = size.x - block.x - timer_hud.margin.x
	match timer_hud.corner:
		DotTimerHud.Placement.BOTTOM_LEFT, DotTimerHud.Placement.BOTTOM_CENTRE, DotTimerHud.Placement.BOTTOM_RIGHT:
			out.y = size.y - block.y - timer_hud.margin.y
	return out


func _centre_of(id: StringName, area: Vector2) -> Vector2:
	var at := positions[id] as Vector2
	return Vector2(at.x * area.x, at.y * area.y)


static func _clamp_into(origin: Vector2, piece: Vector2, area: Vector2) -> Vector2:
	return Vector2(
		clampf(origin.x, 0.0, maxf(area.x - piece.x, 0.0)),
		clampf(origin.y, 0.0, maxf(area.y - piece.y, 0.0))
	)


## A Control placed by hand: top-left anchors, then the position and size. Offsets are set
## through `position`/`size`, which with all four anchors at zero is the same thing.
static func _put(c: Control, at: Vector2, extent: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = at
	c.size = extent


func _label(p_name: String, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.name = p_name
	label.horizontal_alignment = align
	# `set_anchors_preset` does NOT set offsets — every caller above sets its own four
	# — and a Label that never got them keeps the zero size it was created with while
	# every one of its properties reads correctly. This family has shipped that twice.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label


## Re-reads what the stage line counts and compares against. Public because a net bridge
## changes the track under the HUD (T for the bonus) and no signal says so.
func refresh_stage_reference() -> void:
	if game == null or game.timers == null:
		return

	var timer := game.timers.timer_for(shown_id())

	if timer == null:
		timer_hud.set_stage_reference(0, {})
		_feed_panel(null)
		return

	# The stage count is the watched player's track; the splits are this HUD's owner's own
	# bests, which say nothing about somebody else's run.
	timer_hud.set_stage_reference(
		game.timers.stage_count(timer.track),
		game.timers.stage_splits_for(player_id) if shown_id() == player_id else {}
	)
	_feed_panel(timer)


## The server's splits comparison for this HUD's player (a client has no store to read one
## from). Kept, so a refresh from a map change or a track change finds it, and applied now.
func apply_stage_reference(reference: Dictionary) -> void:
	_remote_reference = reference
	refresh_stage_reference()


## Gives the splits panel its reference, at map, track, filed-run and setting moments, never per
## frame. Hidden while spectating: the reference is the owner's bests, and a watched run against
## them is a comparison with nobody.
func _feed_panel(timer: DotTimer) -> void:
	if splits_panel == null:
		return
	var stages := game.timers.stage_count(timer.track) if timer != null else 0
	if stages <= 0 or not _show_stage_splits or shown_id() != player_id:
		splits_panel.set_reference(0, {}, 0.0, {})
		return

	var reference := _reference_for(timer)
	var set: Dictionary = {}
	var label := "PB"
	match _comparison:
		&"wr":
			set = reference.get("wr", {})
			label = "WR"
		&"none":
			label = "-"
		_:
			set = reference.get("pb", {})
	splits_panel.set_reference(
		stages, set.get("splits", {}), float(set.get("total", 0.0)),
		reference.get("bests", {}), label
	)


## The comparison data for the owner's current track and style: the game's own store when
## authoritative, else only what the server sent for this map, track and style.
func _reference_for(timer: DotTimer) -> Dictionary:
	# Only an authoritative game's store is the player's truth. A client has a store too (a
	# file store under user://), holding solo or other servers' bests, and letting it win
	# over the server's STAGE_REF showed stale numbers online.
	if game.authoritative:
		return game.stage_reference(player_id)
	if (
		not _remote_reference.is_empty()
		and int(_remote_reference.get("track", -1)) == timer.track
		and StringName(str(_remote_reference.get("style", ""))) == timer.run.style_id
		and _remote_is_for_this_map()
	):
		return _remote_reference
	return {}


func _remote_is_for_this_map() -> bool:
	return game.maps != null and game.maps.current != null \
		and str(_remote_reference.get("map", "")) == str(game.maps.current.id)
