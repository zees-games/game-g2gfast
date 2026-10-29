extends Node

const G2GArsenal := preload("g2g_arsenal.gd")
const G2GBindings := preload("g2g_bindings.gd")
const G2GBrowser := preload("g2g_browser.gd")
const G2GMapConfig := preload("g2g_map_config.gd")
const G2GCamera := preload("g2g_camera.gd")
const G2GClientExtras := preload("g2g_client_extras.gd")
const G2GConfig := preload("g2g_config.gd")
const G2GFlashlight := preload("g2g_flashlight.gd")
const G2GGame := preload("g2g_game.gd")
const G2GZoneEditor := preload("g2g_zone_editor.gd")
const G2GZoneOutlines := preload("g2g_zone_outlines.gd")
const G2GHud := preload("g2g_hud.gd")
const G2GKillcamBodies := preload("g2g_killcam_bodies.gd")
const G2GEvents := preload("net/g2g_events.gd")
const G2GMenuPages := preload("ui/g2g_menu_pages.gd")
const G2GNetBridge := preload("net/g2g_net_bridge.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GPresentation := preload("g2g_presentation.gd")
const G2GSoloMaps := preload("g2g_solo_maps.gd")
const G2GUnits := preload("g2g_units.gd")
const G2GWeaponIcons := preload("g2g_weapon_icons.gd")

## A playable g2gfast: one local player, a camera, a HUD, and the keys. Separate from [G2GGame], the headless simulation; a dedicated server never loads this.
## Keys are whatever [G2GBindings] says (WASD, space, Ctrl, N style, M maps, Tab board, R restart, C/V checkpoints, F flashlight, O hide others, F5 view, H help).
## Escape opens the menu and frees the mouse; a click takes it back, which is how a browser player captures it (pointer lock needs a user gesture). See [method _grab_mouse].

var game: G2GGame = null
var player: G2GPlayer = null
var hud: G2GHud = null
## The last standing the server sent this player, for a HUD made after it arrived.
var _standing: Dictionary = {}
## The last splits comparison the server sent this player, kept for the same reason.
var _stage_reference: Dictionary = {}
var net: DotNetManager = null
var bridge: G2GNetBridge = null
var link: Node = null

## Keeps the screen covered, and the local body, the keys and the timer still, until the level,
## the local player and its camera are all in. See [method _build_gate].
var gate: DotLoadGate = null

## dot-game's client platform: the loading cover (and the server told when it lifts), the link
## and whether this client is offline. See [DotGameClient].
var platform: DotGameClient = null

## dot-workbench's tuning window. See [method _build_workbench].
var workbench: DotGameWorkbench = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var _workbench_remote: DotGameWorkbenchRemoteClient = null
## The profile rows the server broadcasts (an admin's edit reaches every client); null offline.
var _profile_link: DotNetProfileLink = null
var _profile_runtime: DotProfileRuntime = null

## The server browser: dot-browser's client half.
##
## Built whether or not this client is connected, because you look for a server when you are not on one.
var servers: G2GBrowser = null

## Chat and voice: the client halves of what [G2GServices] runs on the server.
## Null offline: an offline game has nobody to be told by, and building them would open a microphone.
var extras: G2GClientExtras = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the run.
var presentation: G2GPresentation = null

## The player's own light. Drawn here and nowhere else; see [G2GFlashlight].
var flashlight: G2GFlashlight = null

## Every menu this client draws (Escape, H, the map list, "Move HUD elements", the scoreboard), all dot-menu's,
## above the HUD and chat and below the console, which an operator must always reach. Pages: [G2GMenuPages].
var menu: DotMenu = null

## Every zone drawn as a glowing box. See [G2GZoneOutlines].
var zone_outlines: G2GZoneOutlines = null

## Z: drawing zones in the world. See [G2GZoneEditor].
var zone_editor: G2GZoneEditor = null

## Where the dead lie: dot-player-char's ragdolls, built from each death (the server's pick)
## under [member G2GGame.ragdoll_rules]. See [method fall].
var ragdolls: DotPlayerRagdolls = null

## What the server last said about this client's own screen: `sv_flashlight`,
## `sv_allow_thirdperson` and the chat commands. See [method _on_rules].
var rules: Dictionary = {"flashlight": true, "thirdperson": true, "commands": []}

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## What this client wears, if a launcher chose one. Published on hello.
@export var avatar: DotAvatar = null

var _offline := true
var _style_index := 0
var _sampler: DotFpsSampler = null

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## When this client started, for an offline board's time connected.
var _started_msec: int = Time.get_ticks_msec()



## Whether the preferred style has been asked for this session. Once: after that the
## player's own choices are the ones that count.
var _style_restored := false

## Players whose beacon this client already listens to, by instance id.
var _beacons_heard: Dictionary = {}

## When R was last pressed, for the double tap. See [method _restart_key].
var _last_restart_msec := -100000

## How close two presses of R have to be to count as one double tap, in milliseconds.
## Short, because the first press has already acted; a long window would read two stage restarts as a full one.
const DOUBLE_TAP_MSEC := 350

## Whom this client is watching, by player key, or empty. The server's word, from the
## SPECTATE event; offline, nobody.
var spectating: StringName = &""

## Whether this client flies a free camera (the server's mirror is in ROAMING). It has no
## target, so [member spectating] stays empty and [method is_spectating] counts it separately.
var roaming: bool = false

## The pose the free camera holds between frames; seeded from the camera as it was the frame
## the roam began, so the spectator starts where they were looking.
var _free_cam: DotSpectatorFreeCam = null
var _roam_seeded := false
var _roam_look := Vector2.ZERO

## Who is watching whom, as the server last said: player key -> names. Kept for every key
## rather than only the one on screen, so switching whom you watch shows their list at
## once instead of after the next change to it.
var spectator_lists: Dictionary = {}

## Who [member player] should be, whether or not that player exists yet.
## See [method _watch]: on a networked client the id is known one message before its player.
var _watch_id: StringName = &""


# Spectating

## The server said whom this client watches. The camera follows on its own (the bridge
## has told the mirror); this is the rest: the HUD's line and clock, the sampler, and the
## list of who else is watching.
func _on_spectate(target: StringName, target_name: String) -> void:
	var was := spectating
	var was_roaming := roaming
	spectating = target
	_spectate_name = target_name
	roaming = _mirror_roaming()
	if roaming and not was_roaming:
		_roam_seeded = false
	_refresh_spectator_hud()
	_show_spectator_list()
	_refresh_suspended()
	if (was != &"" or was_roaming) and target == &"" and not roaming and hud != null:
		hud.notice("Back to your own view.")


## The list for whoever the HUD is showing: the player being watched, or this player.
func _show_spectator_list() -> void:
	if hud == null:
		return
	var shown := spectating if spectating != &"" else (player.player_id if player != null else _watch_id)
	hud.set_spectators(spectator_lists.get(shown, PackedStringArray()))


## Whether this client is watching somebody. While it is, the left and right buttons cycle
## whom, and movement is suspended: the body stays where it was, and the keys a spectator
## presses are not walking it off a ramp nobody is looking at.
func is_spectating() -> bool:
	return spectating != &"" or roaming


var _spectate_name := ""


## Whether the server's word, as the mirror holds it, is a free camera.
func _mirror_roaming() -> bool:
	if game == null or game.spectate == null or game.spectate.manager == null or player == null:
		return false
	return game.spectate.is_roaming(player.player_id)


## Whether the server offers this spectator a free camera now (mp_freeroam, mp_forcecamera).
func can_roam() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.can_roam(player.player_id)


## The HUD line for whatever this client is doing as a spectator, with the free-camera key
## named only while the server offers one.
func _refresh_spectator_hud() -> void:
	if hud == null:
		return
	var key := ""
	if can_roam() and presentation != null and presentation.bindings != null:
		key = str(presentation.bindings.key_for(&"g2g_roam"))
	hud.set_spectating(spectating, _spectate_name, key, roaming)


## The free-camera key (or `!spec free`): into a free camera from watching, back onto a
## player from one. Online only, and only for somebody already watching; a runner's stray
## press must not turn them into a spectator.
func toggle_roam() -> void:
	if _offline or bridge == null or not is_spectating():
		return
	if not roaming and not can_roam():
		if hud != null:
			hud.notice("Free camera is off on this server.")
		return
	bridge.ask_spectate(G2GEvents.SPECTATE_ROAM)


## Left click: the previous player; right click: the next. Online only — the server's
## manager decides, and a client that cycled its own mirror would be watching somebody the
## server does not think it is.
func cycle_spectate(forward: bool) -> void:
	if _offline or bridge == null:
		return
	bridge.ask_spectate(G2GEvents.SPECTATE_NEXT if forward else G2GEvents.SPECTATE_PREVIOUS)


## Inside the browser shell's solo session (`dot_solo`), a pack's courses are named by the
## stock list and fetched from the shell's origin on demand, under its owner. A no-op
## anywhere else, so a desktop offline game lists what it holds.
func _offer_solo_maps() -> void:
	if G2GSoloMaps.session() == null:
		return
	if game.config.map_content_owner.strip_edges().is_empty():
		game.config.map_content_owner = G2GSoloMaps.OWNER
	game.offered_maps = G2GSoloMaps.IDS


func _leave() -> void:
	# Solo in the shell: the way back is the shell's menu. A page cannot close its tab, and
	# a quit there is a frozen canvas.
	var solo := G2GSoloMaps.session()
	if _offline and solo != null and solo.has_method(&"leave"):
		solo.call(&"leave")
		return
	if not _offline and link != null and link.has_method("disconnect_from_server"):
		link.call("disconnect_from_server", "Left the server")
		return
	get_tree().quit()


## The sampler that turns this client's keys into commands: the player's own offline, the
## netcode's online.
func _active_sampler() -> DotFpsSampler:
	return player.sampler if _offline and player != null else _sampler


## Something other than the cover has the keyboard or the screen.
func _input_busy() -> bool:
	return overlay_open() or (presentation != null and presentation.swallows_input()) \
		or is_spectating()


## Movement stops while anything is taking the keyboard: the chat box, the console, the
## menu or the help screen. `DotFpsSampler` POLLS the keys, so swallowing events is not
## enough — see [method _wire_chat_window] for what that costs on a timer server.
func _refresh_suspended() -> void:
	var busy := _input_busy() or (platform != null and platform.is_input_blocked())
	for sampler in [_sampler, player.sampler if player != null else null]:
		if sampler != null:
			(sampler as DotFpsSampler).suspended = busy


# Flashlight and the others

func toggle_flashlight() -> void:
	if flashlight == null:
		return
	if not flashlight.allowed:
		if hud != null:
			hud.notice("Flashlights are off on this server.")
		return
	var _ok := flashlight.toggle()


func toggle_hide_others() -> void:
	if presentation == null or presentation.settings == null:
		return
	var hide := not presentation.settings.get_bool(&"hide_others", false)
	var _set := presentation.settings.set_value(&"hide_others", hide)
	if hud != null:
		hud.notice("Other players hidden" if hide else "Other players shown")


## Whether [param body] is somebody this client is not drawing.
## Everybody but the local player, the ghost included, and never the one being spectated.
func _hidden(body: G2GPlayer) -> bool:
	if body == null or body == player:
		return false
	if presentation == null or not presentation.settings.get_bool(&"hide_others", false):
		return false
	if player != null and game.spectate != null and game.spectate.is_spectating(player.player_id) \
			and game.spectate.target_of(player.player_id) == body.player_id:
		return false
	return true


func _present_others() -> void:
	var inside := _watched_from_inside()
	for id in game.players:
		var body := game.players[id] as G2GPlayer
		if body != null and body != player:
			body.visible = not _hidden(body) and body.player_id != inside


## The player whose eyes this client's camera is at: watched in first person, or nobody.
## Their body is not drawn, for the reason the local player's own head is culled — the
## camera would be inside it, and the screen one flat colour.
func _watched_from_inside() -> StringName:
	if game == null or game.spectate == null or player == null \
			or not game.spectate.is_spectating(player.player_id):
		return &""
	var view := game.spectate.manager.view(String(player.player_id))
	if view.mode != DotSpectatorView.Mode.FIRST_PERSON:
		return &""
	return StringName(view.target)


# Settings that land on the client

## Everything in the settings document that is the client's to apply rather than the
## presentation layer's: the HUD switches, the view, the mouse. Cheap, and called on any
## change and whenever a player or a HUD appears — both arrive after the settings do.
func apply_client_settings() -> void:
	if presentation == null or presentation.settings == null:
		return
	var st := presentation.settings

	if hud != null:
		hud.apply_visibility(st.get_bool(&"show_speed", true), st.get_bool(&"show_splits", true),
			st.get_bool(&"show_keys", true), st.get_bool(&"show_crosshair", true))
		hud.apply_layout(_hud_layout(st))

	if zone_outlines != null:
		zone_outlines.visible = st.get_bool(&"show_zones", true)

	if player != null and player.camera != null:
		player.camera.fov_desired = float(st.get_int(&"field_of_view", 90))

	_apply_look()


## The mouse, onto whichever tunables the sampler is reading. Neither field is in the
## movement fingerprint (`DotFpsTunables` leaves every `mouse_` key and `invert_look_y`
## out of it), so a client changing them can never disagree with the server.
func _apply_look() -> void:
	if presentation == null or presentation.settings == null:
		return
	var sampler := _active_sampler()
	if sampler == null or sampler.tunables == null:
		return
	sampler.tunables.mouse_sensitivity = G2GUnits.sensitivity_to_degrees(
		presentation.settings.get_float(&"sensitivity", 2.5))
	sampler.tunables.invert_look_y = presentation.settings.get_bool(&"invert_mouse", false)


## The server said what it allows on this client's screen.
func _on_rules(new_rules: Dictionary) -> void:
	var light_was_allowed := bool(rules.get("flashlight", true))
	rules = new_rules

	if flashlight != null:
		flashlight.allowed = bool(rules.get("flashlight", true))
		if light_was_allowed and not flashlight.allowed and hud != null:
			hud.notice("The server turned flashlights off.")

	if menu != null:
		menu.help.commands = rules.get("commands", [])

	_apply_rules_to_player()


func _apply_rules_to_player() -> void:
	if player == null or player.camera == null:
		return
	# RULES' `thirdperson` is an older server's word; mp_forceview, followed through the link,
	# is a newer one's. Both have to allow it.
	player.camera.follow_view_rules(game.view_rules)
	player.camera.allow_third_person = bool(rules.get("thirdperson", true)) and game.view_rules.allows_third()
	if not player.camera.allow_third_person and player.camera.is_third_person():
		var _first := player.camera.set_mode(G2GCamera.Mode.FIRST_PERSON)


## Asks once, on the first player this client gets, for the style the player last chose.
func _restore_style() -> void:
	if _style_restored or player == null or presentation == null or game == null:
		return
	_style_restored = true

	var wanted := StringName(presentation.settings.get_string(&"preferred_style", "normal"))
	if wanted == &"" or wanted == menu_style():
		return

	for style in game.timers.styles_in_order():
		if style.id == wanted:
			menu_choose_style(wanted, false)
			return


# What the menu asks the client (see G2GMenu.host)

func menu_where() -> String:
	var map_name := game.maps.current.label() if game != null and game.maps != null \
		and game.maps.current != null else "no map yet"
	return "%s  ·  %s" % [map_name, "offline" if _offline else "online"]


func menu_leave_label() -> String:
	if not _offline:
		return "Disconnect"
	var solo := G2GSoloMaps.session()
	if solo != null and solo.has_method(&"leave"):
		return "Back to menu"
	# A browser tab cannot be closed by the page in it, and a quit there is a frozen canvas.
	return "" if DotPlatform.is_web() else "Quit game"


func menu_styles() -> Array:
	var out: Array = []
	if game == null or game.timers == null:
		return out
	for style in game.timers.styles_in_order():
		out.append({"id": style.id, "name": style.display_name})
	return out


func menu_style() -> StringName:
	if player != null and player.timer_style != null:
		return player.timer_style.id
	return &"normal"


## Asks for a style: the server online, the game offline. Remembered as the preferred style
## unless [param remember] is false — which is only the restore itself.
func menu_choose_style(id: StringName, remember: bool = true) -> void:
	var styles := game.timers.styles_in_order()
	for i in range(styles.size()):
		if styles[i].id == id:
			_style_index = i

	if not _offline:
		if bridge != null:
			bridge.ask_style(id)
	elif game.set_player_style(&"local", id):
		var shown := id
		for style in styles:
			if style.id == id:
				shown = StringName(style.display_name)
		if hud != null:
			hud.notice("Style: %s" % shown)

	if remember and presentation != null:
		var _kept := presentation.settings.set_value(&"preferred_style", String(id))


func menu_flashlight_allowed() -> bool:
	return flashlight == null or flashlight.allowed


func menu_flashlight_on() -> bool:
	return flashlight != null and flashlight.on


func menu_set_flashlight(on: bool) -> void:
	if flashlight != null:
		var _ok := flashlight.set_on(on)


func menu_third_person_allowed() -> bool:
	return bool(rules.get("thirdperson", true))


func menu_third_person_on() -> bool:
	return player != null and player.camera != null and player.camera.is_third_person()


func menu_set_third_person(on: bool) -> void:
	if player == null or player.camera == null:
		return
	var _ok := player.camera.set_mode(
		G2GCamera.Mode.THIRD_PERSON if on else G2GCamera.Mode.FIRST_PERSON)


## Where a roster row's player stands, for dot-game's look-to-gag key (J, L).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: G2GPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null


func _hud_layout(st: DotSettingsManager) -> Dictionary:
	## Overridden by the client script.
	return {}

func overlay_open() -> bool:
	## Overridden by the client script.
	return false
