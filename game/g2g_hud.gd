extends Control

const G2GConfig := preload("g2g_config.gd")
const G2GGame := preload("g2g_game.gd")
const G2GMapCatalogue := preload("g2g_map_catalogue.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GArsenal := preload("g2g_arsenal.gd")

## The competitive-shooter timer HUD: the clock, the speed in u/s, the keys, the strafes.
##
## Composed from [DotTimerHud] rather than replacing it. What this adds is the genre's
## conventions: speed in genre units, a key display (the thing every bhop stream has
## in the corner), the stage, and PRACTICE the moment a checkpoint is used.

var timer_hud: DotTimerHud = null
## The per-section sidebar on a staged map: left edge, vertically centred, so it shares
## nothing with the clock's block (bottom centre by default) or the notice line.
var splits_panel: DotTimerSplitsPanel = null
## The `show_stage_splits` setting. Separate from `show_splits`, which is the clock block's
## one split line.
var _show_stage_splits: bool = true
## `timer_comparison` as the panel reads it: pb, wr or none.
var _comparison: StringName = &"pb"
## The splits comparison the server last sent this client, which has no store of its own.
## Offline the game's own store answers and this stays empty.
var _remote_reference: Dictionary = {}
var _keys: Label = null
var _status: Label = null
var _spectating: Label = null
var _spectators: PanelContainer = null
var _spectators_label: Label = null
var _notice: Label = null
var _crosshair: DotCrosshair = null
## Four ticks round the crosshair on a hit the server confirmed (combat maps only).
var hit_marker: DotHitMarker = null
## The weapon in hand under deathmatch, bottom right: its name alone, because both weapons
## have no magazine and an endless reserve (`G2GArsenal`), and "∞ | ∞" is a count that never
## moves. Nothing at all on a pure timer server.
var ammo: DotAmmoCounter = null
## The confirmed hits' numbers, on the bodies they landed on.
var damage_numbers: DotDamageNumbers = null
var _notice_until: float = 0.0

var game: G2GGame = null
var player_id: StringName = &"local"

## Whose run the clock, the speed and the keys describe: the player this HUD belongs to, or
## the one they are spectating. See [method set_spectating].
##
## [b]The watched player's, while watching.[/b] A spectator's own clock is a player standing
## in a start zone, and what they came to see is somebody else's time and speed. The
## standing line (the record, YOUR best, YOUR place) stays the HUD owner's: it is filed per
## player and a client is only ever told its own.
var followed_id: StringName = &""

# --- Layout -------------------------------------------------------------------

## The pieces a player can move, in the order the layout editor offers them.
const ELEMENTS: Array[StringName] = [&"timer", &"keys", &"status", &"spectators"]

## [code]timer_position[/code]'s values, onto `DotTimerHud`'s own placements.
const PLACEMENTS := {
	&"bottom_centre": DotTimerHud.Placement.BOTTOM_CENTRE,
	&"bottom_left": DotTimerHud.Placement.BOTTOM_LEFT,
	&"bottom_right": DotTimerHud.Placement.BOTTOM_RIGHT,
	&"top_left": DotTimerHud.Placement.TOP_LEFT,
	&"top_centre": DotTimerHud.Placement.TOP_CENTRE,
	&"top_right": DotTimerHud.Placement.TOP_RIGHT,
}

## The timer block's margin from the edge in a corner placement. The bottom one is the
## height the clock always had, which the notice line's clearance is derived from.
const TIMER_MARGIN := Vector2(24.0, 92.0)
const TIMER_MARGIN_TOP := Vector2(24.0, 56.0)

## Where each moved piece's CENTRE is, as a fraction of this HUD's size. A piece with no
## entry is where the layout puts it. Written by the layout editor, kept in the
## `hud_positions` setting; see [method positions_from_text].
var positions: Dictionary = {}

var _timer_placement: StringName = &"bottom_centre"
var _show_keys: bool = true
var _show_status: bool = true
var _show_spectators: bool = true
var _spectator_names := PackedStringArray()
## The map's time left as the server's vote last described it. Null, or never adopted,
## when nothing has told this HUD anything — offline, where the local map session IS the
## clock that ends the map, and the only case in which it is.
##
## [b]The map session's clock was what this drew, and on a client it is wrong.[/b] A
## client's session starts its own clock when it loads the map and nothing the server
## decides ever reaches it: an extend added ten minutes on the server and none here, and
## under `trigger: rtv_only` it counted down a limit the server did not have.
var clock_view: DotVoteClockView = null

## How far up from the bottom the notice line starts, in pixels.
##
## The clock block's own margin is 92 and it draws about 90 tall, so anything below 182
## is inside it. This is that plus a gap, in one place, so moving the clock moves this.
const NOTICE_CLEARANCE := 196.0

## An administrator's `blind`, over the world and under the rest of the HUD.
##
## [b]Under the widgets, on purpose.[/b] A blind takes the course away, not the runner's
## bearings: the clock still counts, the keys still light and the notice line still says
## what happened, which is what makes it read as "an admin did this" rather than as a
## client that stopped drawing. The chat box and the console are the presentation
## layer's, above this HUD altogether, so a blinded runner can still ask why.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and
## not instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## Over everything this HUD draws while the server is on a map this client has not loaded.
##
## [b]Over the widgets, unlike the blind.[/b] There is no run to read: the clock, the keys
## and the speed all describe a player the client is not simulating (see
## [method G2GNetBridge.in_transit]). What a player saw instead was the engine's clear
## colour with a live HUD on it — a grey screen that looked like a game that had broken —
## for as long as the map took to download and build. The chat box is the presentation
## layer's and stays above this, so the wait can still be talked through.
var loading_cover: ColorRect = null
var _loading_label: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# set_anchors_preset does NOT set offsets; a Control built in code keeps its zero
	# size otherwise and lays out inside nothing. Cost this family a day in dot-ui.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# First, so every widget added below draws over it. See [member blind_overlay].
	# Anchored to nothing and sized to the VIEWPORT in `present_blind`, not to this HUD's
	# rect: game-arena's first rendered blind left a sixteen-pixel frame of the world
	# round the edge because its HUD was inset by the safe area, and this one being the
	# full rect today is a property of its parent that nothing here promises.
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	# THE WHOLE RECT, not a box in the corner.
	#
	# `DotTimerHud` places its own block in a corner of whatever rect it is given, so
	# the rect is the AREA it lays out inside rather than the block. Handing it the
	# 360 x 200 it used to have would pin an overlay to the corner of a box in the
	# corner, which is the thing being fixed.
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

	# The key display, directly under the clock, which is where every bhop stream in
	# this genre has had it for fifteen years. Centred rather than left-aligned so it
	# reads as part of the same block; monospaced-by-padding, because a proportional
	# font makes the four keys jump sideways as they light up.
	_keys = _label("Keys", HORIZONTAL_ALIGNMENT_CENTER)
	_keys.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_keys.offset_left = 0.0
	_keys.offset_right = 0.0
	_keys.offset_top = -80.0
	_keys.offset_bottom = -52.0

	# Reference rather than gameplay: the map, the track, the time limit, the rules
	# in force. Along the top, out of the way of both the crosshair and the clock.
	_status = _label("Status", HORIZONTAL_ALIGNMENT_CENTER)
	_status.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_status.offset_left = 0.0
	_status.offset_right = 0.0
	_status.offset_top = 14.0
	_status.offset_bottom = 40.0
	# Quieter than the timer, but not see-through: at 0.62 it vanished over a pale sky
	# (rendered for the dark HUD, 2026-10-12).
	_status.modulate = Color(1.0, 1.0, 1.0, 0.88)

	# A crosshair, which this game did not have.
	#
	# It was survivable while the HUD was a column of text down the left: there was
	# something to look at. With the clock moved under the centre there is nothing at
	# all in the middle of the screen, and a first-person game with an empty centre
	# reads as broken rather than as clean. dot-ui draws one rather than shipping art,
	# which is why it can be used here without an asset.
	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.offset_left = 0.0
	_crosshair.offset_top = 0.0
	_crosshair.offset_right = 0.0
	_crosshair.offset_bottom = 0.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	# Hit feedback, from dot-ui: full rect, centred on the crosshair, and drawn only from a
	# hit the authority applied (`confirm_hit`). Neither draws anything until one lands, so a
	# timer map that never fires shows exactly what it did before.
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

	# Placed by `place()`, which knows where the clock is.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ammo)

	# Things that just happened: a finish, a rank, a map change, a cvar an admin
	# moved. Above the clock, where a player's eye already is.
	#
	# [b]Clear of the clock, and the number is derived from the clock rather than
	# guessed.[/b] It sat at -160 and the clock block is 92 up from the bottom and about
	# 90 tall, so a finish time was drawn straight through "0:00.000" — two numbers in
	# the same font at the same size overlapping to the pixel, which reads as a font
	# glitch rather than as a layout bug. Nothing could assert it: both Labels had the
	# right text, the right size and the right anchors, and a rect that overlaps another
	# rect is a legitimate rect. `tools/screenshot_hud.sh` found it on its first run.
	_notice = _label("Notice", HORIZONTAL_ALIGNMENT_CENTER)
	_notice.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.offset_left = -600.0
	_notice.offset_right = 600.0
	_notice.offset_top = -(NOTICE_CLEARANCE + 26.0)
	_notice.offset_bottom = -NOTICE_CLEARANCE

	# Who you are watching, under the status line. Not movable: it belongs to the status
	# line's place in the top centre, where a spectator looks for "what am I seeing".
	_spectating = _label("Spectating", HORIZONTAL_ALIGNMENT_CENTER)
	_spectating.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_spectating.offset_left = 0.0
	_spectating.offset_right = 0.0
	_spectating.offset_top = 44.0
	_spectating.offset_bottom = 70.0
	_spectating.visible = false

	# Who is watching you. Down the right-hand side by default, clear of the clock, the
	# chat box (bottom left) and the status line, and on a plate, because it is a list of
	# names drawn over arbitrary sky.
	_spectators = PanelContainer.new()
	_spectators.name = "Spectators"
	_spectators.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spectators.visible = false
	add_child(_spectators)
	_spectators_label = Label.new()
	_spectators_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spectators.add_child(_spectators_label)

	# Last, so it draws over every widget above. Sized to the viewport in
	# `show_loading`, for the reason the blind is. See [member loading_cover].
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

	apply_theme()


## What the player chose to see: the four HUD switches in the menu's General page.
##
## The speed and the splits are `DotTimerHud`'s own fields, so turning one off removes its
## line from the clock's block rather than leaving a gap; the key display and the
## crosshair are this HUD's.
func apply_visibility(show_speed: bool, show_splits: bool, show_keys: bool, show_crosshair: bool) -> void:
	if timer_hud != null:
		timer_hud.show_speed = show_speed
		timer_hud.show_split = show_splits
	_show_keys = show_keys
	if _keys != null:
		_keys.visible = show_keys
	if _crosshair != null:
		_crosshair.visible = show_crosshair


## The timer's layout, from the `timer_*`, `show_status`, `show_spectators` and
## `hud_positions` settings. [param layout] is those keys without their prefix; a key that
## is missing keeps its current value, so a caller can change one thing.
##
## [b]Every line is a `DotTimerHud` field[/b], so a line switched off is gone from the
## block rather than blank in it, and the block closes up around what is left.
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


## [member positions] as the setting stores it, and back. JSON of
## `{"timer": [0.5, 0.82], ...}`; anything that is not a known piece with two numbers in
## 0..1 is dropped, because the setting is a file a player can edit by hand and a piece
## put off-screen by a typo is a piece they cannot find again to drag back.
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


# --- Spectating -----------------------------------------------------------------

## Who this HUD's player is watching, by id and by name; an empty id is nobody.
##
## The line tells a spectator the two things nobody can guess: how to change who they are
## watching, and how to stop. Both are in the words a player would type or press.
##
## [param roam_hint] is the free-camera key's name when the server offers a free camera ("" when
## it does not, so no prompt for a key that would be refused). [param roaming] is a spectator
## who is flying: the "watching X" line is replaced by the controls, because there is nobody
## to name.
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


# --- Placing --------------------------------------------------------------------

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


## The clock's block, or the size of one when it draws nothing yet (no run, every line
## switched off): still a place to grab, so the editor never shows a piece that cannot be
## found — and the same size for placing it as for picking it, or a dragged clock with
## nothing on it would sit somewhere other than where it was dropped.
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
		return
	var def: DotWeaponDef = _weapon_defs().get(id)
	ammo.show_ammo(def.display_name if def != null else String(id), -1, -1, false, true)


static var _defs: Dictionary = {}


static func _weapon_defs() -> Dictionary:
	if _defs.is_empty():
		_defs = G2GArsenal.weapon_table()
	return _defs


## Re-reads what the stage line counts and compares against.
##
## Public because a net bridge changes the track under the HUD — a player pressing T
## for the bonus is on a different track with a different stage count — and there is
## no signal for that.
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


## Gives the splits panel its reference. Called from [method refresh_stage_reference]'s
## moments only — a map, a track, a filed run or section, a setting — never per frame.
##
## [b]Hidden while spectating.[/b] The reference is the owner's personal best and section
## bests, and a watched player's run against them is a comparison with nobody: every row
## would be red or green for a reason that has nothing to do with the person on screen.
## The clock still shows the watched run; the panel waits for the owner to be back.
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


## The comparison data for the owner's current track and style: the game's own store when the
## game is authoritative (offline, a listen host), else only what the server sent, and only if
## it was for this map, track and style. A message for another one is a moment late and says
## nothing true.
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
