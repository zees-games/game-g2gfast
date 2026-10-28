extends Control

const G2GConfig := preload("g2g_config.gd")
const G2GGame := preload("g2g_game.gd")
const G2GMapCatalogue := preload("g2g_map_catalogue.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GArsenal := preload("g2g_arsenal.gd")
const G2GWeaponIcons := preload("g2g_weapon_icons.gd")

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
## The held weapon's sprite over [member ammo] (`cl_weapon_icons`); hidden when it has none.
var weapon_icon: TextureRect = null
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
