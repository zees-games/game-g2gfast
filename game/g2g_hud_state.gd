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

## Whose run the clock, the speed and the keys describe: this HUD's player, or the one they are
## spectating ([method set_spectating]). The standing line (record, best, place) stays the
## owner's: it is filed per player and a client is only told its own.
var followed_id: StringName = &""

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
## The map's time left as the server's vote last described it; null when nothing has told this HUD.
## A client's own session clock ignores what the server decides (an extend, `rtv_only`), so it is
## wrong there and only right offline.
var clock_view: DotVoteClockView = null

## How far up from the bottom the notice line starts, in pixels: the clock block (92 up, about
## 90 tall) plus a gap, in one place so moving the clock moves this.
const NOTICE_CLEARANCE := 196.0

## An administrator's `blind`, over the world and under the rest of the HUD: it takes the course
## away, not the runner's bearings, and chat and the console stay above it. Black, not white,
## which can hurt in a dark room.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and
## not instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## Over everything this HUD draws while the server is on a map this client has not loaded: there
## is no run to read ([method G2GNetBridge.in_transit]). The chat box stays above it, so the wait
## can still be talked through.
var loading_cover: ColorRect = null
var _loading_label: Label = null
