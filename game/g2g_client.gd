extends Node

const G2GArsenal := preload("g2g_arsenal.gd")
const G2GBindings := preload("g2g_bindings.gd")
const G2GBrowser := preload("g2g_browser.gd")
const G2GCamera := preload("g2g_camera.gd")
const G2GClientExtras := preload("g2g_client_extras.gd")
const G2GConfig := preload("g2g_config.gd")
const G2GFlashlight := preload("g2g_flashlight.gd")
const G2GGame := preload("g2g_game.gd")
const G2GZoneEditor := preload("g2g_zone_editor.gd")
const G2GZoneOutlines := preload("g2g_zone_outlines.gd")
const G2GHud := preload("g2g_hud.gd")
const G2GKillcam := preload("g2g_killcam.gd")
const G2GEvents := preload("net/g2g_events.gd")
const G2GMenuPages := preload("ui/g2g_menu_pages.gd")
const G2GNetBridge := preload("net/g2g_net_bridge.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GPresentation := preload("g2g_presentation.gd")
const G2GSoloMaps := preload("g2g_solo_maps.gd")
const G2GUnits := preload("g2g_units.gd")

## A playable g2gfast: one local player, a camera, a HUD, and the keys.
##
## Separate from [G2GGame], which is the simulation and runs headless. A dedicated
## server never loads this.
##
## Keys: whatever [G2GBindings] says, as the player has bound them — WASD, space (hold, if
## the server allows auto-bhop), Ctrl to duck, N to cycle style, M for the map list, Tab
## held for the scoreboard, R to restart, C / V for practice checkpoints, F for the
## flashlight, O to hide everybody else, F5 for first and third person, H for help. Escape
## opens the menu and
## frees the mouse; a click, or Resume, takes it back — which is also how a browser player
## captures it in the first place, because pointer lock needs a real user gesture. See
## [method _grab_mouse].

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

## The server browser: dot-browser's client half.
##
## Built whether or not this client is connected, because looking for a server is what
## you do when you are not on one. `!servers` lists what it found.
var servers: G2GBrowser = null

## Chat and voice: the client halves of what [G2GServices] runs on the server.
##
## Null offline, deliberately. Both are about a server telling this client something,
## and an offline game has nobody to be told by — building them anyway would open a
## microphone in a single-player run.
var extras: G2GClientExtras = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the run.
var presentation: G2GPresentation = null

## The player's own light. Drawn here and nowhere else; see [G2GFlashlight].
var flashlight: G2GFlashlight = null

## Every menu this client draws: Escape, H, the map list (M), "Move HUD elements" and the
## Tab scoreboard, all dot-menu's, on a layer above the HUD and the chat and below the
## console — the console is the one thing an operator must always be able to reach. What is
## on its pages is [G2GMenuPages].
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
##
## Short, because the first press has already acted: one R puts a runner back at the start
## of their stage the moment it lands, and only a second inside this window widens it to the
## whole course. A long window would make "R, then R again after a fall" — two stage
## restarts — read as a full restart.
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
##
## See [method _watch]: on a networked client the id is known one message before the
## player it names.
var _watch_id: StringName = &""


func _ready() -> void:
	# First, before anything can be drawn: the map arrives after this node is in the tree.
	_build_gate()

	link = platform.link as Node
	_offline = platform.offline

	game = G2GGame.new()
	game.name = "Game"
	var config := G2GConfig.new()
	# The family's layered configuration: exported defaults < JSON < environment < argv.
	# It was missing here, so a client was the one thing in this repository that could
	# not be configured at all -- `--g2g-initial-map surf_kitsune` reached the server
	# and the suites and went nowhere on the client, which always played whatever the
	# export happened to default to. The layers are read BEFORE the two lines below,
	# because those two are not preferences: a client is not the authority whatever a
	# config file says.
	var layered := config.load_layered()
	if not layered.ok:
		DotLog.warn("g2g.client", "the configuration did not load cleanly",
			{"why": layered.error.message})

	# Alone, nobody is waiting for the next map: no clock, unless one was configured.
	if _offline:
		config.map_seconds = config.offline_map_seconds

	# A client is never the authority. Its timer is a display; its records go nowhere.
	config.authoritative = _offline
	config.initial_map = config.initial_map if _offline else &""
	game.config = config
	if _offline:
		_offer_solo_maps()
	game.covered = _covered
	add_child(game)
	_wire_gate_to_maps()

	# Connected before anything can create a player. `JOIN` is what creates the local
	# one and it arrives after `HELLO` has already said who we are — see [method _watch].
	game.player_added.connect(_on_player_added)

	presentation = G2GPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result("g2g.client", "the presentation layer", presentation.setup())
	_wire_chat_window()
	_build_overlays()

	# Every effect drawn is somewhere on the map that just went away, and the landing
	# watcher would otherwise read the first frame on the new one as a fall.
	game.map_ready.connect(func(map: DotMapDef) -> void: presentation.on_map_changed(map.id if map != null else &""))

	_build_ragdolls()
	_build_killcam()

	zone_outlines = G2GZoneOutlines.new()
	zone_outlines.name = "ZoneOutlines"
	add_child(zone_outlines)
	game.map_ready.connect(func(_map: DotMapDef) -> void: zone_outlines.refresh(game.timers.zones))
	# The first map may already be up: an offline game loads it inside its own _ready.
	if game.maps != null and game.maps.current != null:
		zone_outlines.refresh(game.timers.zones)

	zone_editor = G2GZoneEditor.new()
	zone_editor.name = "ZoneEditor"
	zone_editor.game = game
	zone_editor.client = self
	zone_editor.outlines = zone_outlines
	zone_editor.offline = _offline
	zone_editor.send_line = func(line: String) -> void:
		if link != null and link.has_method("send_chat"):
			link.send_chat(line, false)
	zone_editor.changed.connect(func() -> void: zone_outlines.refresh(game.timers.zones))
	add_child(zone_editor)

	if _offline:
		for _i in range(60):
			await get_tree().process_frame
			if game.maps != null and game.maps.current != null:
				break
		player = game.add_player(&"local", "Player", true)
		_watch(&"local")
	else:
		var netted := _build_netcode()
		DotLog.result("g2g.client", "netcode", netted)

	# The server browser. Built on every client, connected or not: looking for a
	# server is what you do when you are not on one, and a browser that only existed
	# while you were already playing would be a browser nobody could reach.
	servers = G2GBrowser.new()
	servers.name = "Servers"
	add_child(servers)

	var listed := servers.setup()
	DotLog.result("g2g.client", "the server browser", listed)

	_grab_mouse()
	set_process(true)


# --- The load gate ---------------------------------------------------------

## The screen stays covered, and the local body and the input stay still, until the level is
## built, the local player exists and its camera is current.
##
## [b]Without it the first frames were a half-built world.[/b] Solo the player spawned in the
## tick the first map landed and fell onto a floor that was still arriving; connected, the
## client drew from its first frame with no player, no camera and a HUD with nobody to read; a
## map change tore the level down in front of a body that kept moving, and the run timer was
## fed the whole time. The gate does not stop the simulation by itself: [member G2GGame.covered]
## freezes the tick (and with it the timers), [method G2GPlayer.simulate] skips a frozen body
## and reads no keys while it settles, and the keys and the netcode sampling check
## [method _covered].
func _build_gate() -> void:
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	# The rest of the platform stays this client's own: its presentation layer owns the
	# settings and the console, G2GMenuPages the menu, and _grab_mouse the pointer (it has a
	# click-to-play notice). What it takes over is the cover, and telling the server about it.
	platform.use_settings = false
	platform.use_console = false
	platform.capture_pointer = false
	platform.spawned_text = "Joining"
	platform.spawned_fn = func() -> bool:
		return player != null and player.camera != null and player.camera.is_inside_tree()
	# The chat box, console, menu, help and spectating have the keyboard; polled by the
	# platform each frame, so nothing needs forwarding from each of them.
	platform.busy_fn = _input_busy
	add_child(platform)
	gate = platform.gate
	gate.hold(&"map", "Loading the map")
	# The cover blocks input too, so the sampler is still while it is up.
	platform.input_blocked_changed.connect(func(_blocked: bool) -> void: _refresh_suspended())


## Releases the map hold once the first level is in, and holds again for each map change.
## Offline the first map is already up (the game loads it inside its own `_ready`); connected
## it arrives with the server's `load`.
func _wire_gate_to_maps() -> void:
	game.maps.changing.connect(
		func(_from: DotMapDef, _to: DotMapDef) -> void: gate.hold(&"map", "Loading the map")
	)
	game.maps.changed.connect(
		func(_map: DotMapDef, _loaded: Node) -> void: gate.release(&"map")
	)
	if game.maps.current != null:
		gate.release(&"map")


## True while the load gate covers the screen: no key, no mouse turn, no run.
func _covered() -> bool:
	return gate != null and not gate.is_open()


# --- The end of a deathmatch: final killcam, winner reveal, board ------------------

## How long the board stays up after the reveal, with nobody holding Tab.
const SUMMARY_BOARD_SEC := 8.0

## The final killcam: records every frame, replays the last kill before the winner reveal.
var killcam: G2GKillcam = null
var winner_reveal: DotWinnerReveal = null

var _end_rows: Array = []
var _end_active: bool = false
var _reveal_hid: Dictionary = {}
var _summary_board_open: bool = false
var _killcam_sec: float = 0.0


func _build_killcam() -> void:
	killcam = G2GKillcam.new()
	killcam.name = "FinalKillcam"
	killcam.players_fn = func() -> Array: return game.players.values() if game != null else []
	killcam.player_for_fn = func(id: StringName) -> Variant: return game.players.get(id) if game != null else null
	killcam.seconds_fn = func() -> float: return _killcam_sec
	killcam.weapon_name_fn = func(id: String) -> String:
		var def: DotWeaponDef = G2GArsenal.weapon_catalogue().get_def(StringName(id)) if id != "" else null
		return def.display_name if def != null and def.display_name != "" else id.capitalize()
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_winner())
	add_child(killcam)
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = G2GKillcam.SKIP_ACTIONS
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)
	game.map_ready.connect(func(_map: DotMapDef) -> void: _leave_match_end())


## The deathmatch ended: the final killcam if there is a kill to show, then the winner.
func _match_over(killcam_sec: float, rows: Array) -> void:
	if killcam == null:
		return
	_end_rows = rows
	_end_active = true
	_killcam_sec = killcam_sec
	if killcam.match_ended():
		DotLog.debug("g2g.client", "the winner waits for the final killcam")


## The top three on a podium, after the killcam and before the board.
func _reveal_winner() -> void:
	if not _end_active:
		return
	var entries: Array = []
	for row: Dictionary in _end_rows:
		var kills := int(row.get("kills", 0))
		var deaths := int(row.get("deaths", 0))
		entries.append({"name": str(row.get("name", "")), "score": "%d %s  %d %s" % [
			kills, "kill" if kills == 1 else "kills", deaths, "death" if deaths == 1 else "deaths"]})
	winner_reveal.reduced_motion = presentation != null and presentation.settings != null \
		and presentation.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "WINNER", "hint": "Jump to skip"})
	if not shown.ok:
		_end_active = false
		_open_summary_board()
		return
	if hud != null:
		_reveal_hid[hud] = hud.visible
		hud.visible = false


func _on_reveal_finished(_skipped: bool) -> void:
	for n: Variant in _reveal_hid:
		if is_instance_valid(n):
			(n as CanvasItem).visible = _reveal_hid[n]
	_reveal_hid.clear()
	if _end_active:
		_end_active = false
		_open_summary_board()


func _open_summary_board() -> void:
	if menu == null or menu.any_open():
		return
	menu.scoreboard.open()
	_summary_board_open = true
	await get_tree().create_timer(SUMMARY_BOARD_SEC).timeout
	if _summary_board_open and menu != null:
		_summary_board_open = false
		menu.scoreboard.close()


## A new match or map began: whatever of the end is still up goes.
func _leave_match_end() -> void:
	if not _end_active and not _summary_board_open:
		return
	_end_active = false
	if killcam != null:
		killcam.skip()
	if winner_reveal != null:
		winner_reveal.skip()
	if _summary_board_open and menu != null:
		_summary_board_open = false
		menu.scoreboard.close()


# --- Dead bodies -------------------------------------------------------------

## The yard the dead lie in, the presentation's sound, and the solo game's own deaths. Built
## once; emptied on a map change (a body on the old map's floor would hang in the new one's
## air). Connected, the deaths arrive as DEATH and ALIVE through the bridge instead.
func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = func(id: StringName, at: Vector3, volume: float) -> void:
		if presentation != null:
			var _played := presentation.on_body(id, at, volume)
	add_child(ragdolls)

	game.map_ready.connect(func(_map: DotMapDef) -> void:
		ragdolls.clear()
		for id: StringName in game.players:
			rise(id)
	)

	# Solo, the world is this process's and there is no DEATH message: the death the combat
	# layer decided is on the player.
	if game.combat != null:
		game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
			var id := game.combat.player_id_for(entry.victim_key.to_int())
			var who: G2GPlayer = game.players.get(id)
			var _fell := fall(id, who.death if who != null else null)
		)
		game.combat.player_respawned.connect(rise)
		game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
			var killer := game.combat.player_id_for(entry.killer_key.to_int()) if entry.killer_key != "" else &""
			if killcam != null:
				killcam.note_kill(killer, game.combat.player_id_for(entry.victim_key.to_int()), entry.cause, entry.headshot)
		)
		if game.combat.match_node != null:
			# Deferred: the last kill ends the match from inside its own report, before the kill
			# reaches the killcam.
			game.combat.match_node.match_ended.connect(func(_winner: int, _outcome: int) -> void:
				_match_over.call_deferred(game.config.killcam_seconds, game.combat.podium_rows())
			)


## [param id]'s body falls the way the server picked ([param death]; null is a plain drop),
## copied from the rig this client draws, which stays hidden until [method rise]. Null when
## the server's style hides bodies, or nobody here draws that body: a player the client is
## hiding, or this client's own in first person (the camera is inside its head).
func fall(id: StringName, death: DotPlayerDeath) -> DotPlayerRagdoll:
	if killcam != null:
		killcam.set_alive(id, false)
	var who: G2GPlayer = game.players.get(id) if game != null else null
	if who == null or ragdolls == null or who.rig == null or not who.rig.is_inside_tree():
		return null
	if not who.visible or (who == player and not who.rig.visible_to_owner):
		return null
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	return ragdolls.spawn(who.rig, death if death != null else DotPlayerDeath.new(), velocity)


## [param id] is alive again: the rig a fall hid is drawn again where they now stand.
func rise(id: StringName) -> void:
	if killcam != null:
		killcam.set_alive(id, true)
	_leave_match_end()
	var who: G2GPlayer = game.players.get(id) if game != null else null
	if who != null and who.rig != null:
		who.rig.visible = true


## Lists what the browser found, on the HUD. What `!servers` and F3 both call.
##
## [b]A chat command rather than a screen, and game-arena has a screen.[/b] That game
## has a [DotScreenStack]; this client has a HUD and a keyboard, and the genre's answer
## to "show me the servers" is a chat trigger, because that is what a bhop player's
## fingers already do. The list model, the sources, the filters and the favourites are
## the same addon doing the same work either way.
func show_servers() -> void:
	if servers == null or hud == null:
		return

	hud.notice("Looking for servers…")

	var found: DotResult = await servers.refresh()

	if not found.ok:
		hud.notice(found.error.message)
		return

	for line in servers.lines():
		hud.notice(line)


## Hides and captures the cursor, or arranges for a click to do it.
##
## [b]A browser will not hide the cursor because a scene asked it to.[/b] Pointer lock
## needs transient user activation — a real click — and `_ready()` is the one moment in
## a client's life that is guaranteed not to have one. The request is refused, and it is
## refused SILENTLY: `Input.mouse_mode` reads back as CAPTURED, the cursor stays on
## screen, and the view still turns, so nothing anywhere reports a problem. What the
## player gets is a mouse that leaves the window mid-run.
##
## This is the family's own rule about deployment shapes, on a capability nothing had
## needed yet: game-hungario is the only other browser client and it is 2D — it reads
## the cursor's position and never locks it — so g2gfast is the first thing here that
## has ever asked a browser for pointer lock.
##
## Desktop has no such rule and captures immediately, because a player who launched a
## first-person game should not have to click their own window first.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true
	_say_click_to_play()


## Tells the player the one thing they have to do, once there is a HUD to say it on.
##
## `_ready()` builds the HUD only on the offline path; a networked client gets one when
## the server says who it is, which is several hundred milliseconds later. Saying it in
## both places rather than once is why this is a function.
func _say_click_to_play() -> void:
	if _awaiting_click and hud != null:
		hud.notice("Click to play")


## Follows a player: the camera, the HUD, and everything the keys act on.
##
## [b]The id arrives one message before the player does.[/b] `HELLO` says who you are and
## `JOIN` is what creates you — `G2GNetBridge._apply_join` calls `game.add_player` — so a
## networked client that resolved [member player] here and never again held null for the
## whole session. Nothing errored: the HUD binds by id and worked, movement is polled
## from the [InputMap] by `DotFpsSampler.sample` and worked, and the camera follows the
## entity rather than this reference. What did not work was every line below the
## `player == null` guard in [method _unhandled_input] — which is mouse look, F5, Tab, R,
## C, V and M. **The whole keyboard and the whole mouse, on a client that otherwise
## looked fine.**
##
## `headless_net` never instantiates this class — it drives two bridges directly — so
## nothing in the suite had ever been through this path.
func _watch(id: StringName) -> void:
	_watch_id = id
	_adopt(game.players.get(id))

	if hud == null:
		hud = G2GHud.new()
		hud.name = "Hud"
		add_child(hud)
		_follow_hud()
	hud.bind(game, id)
	# The server's time left, which may well have arrived before there was a HUD: HELLO
	# and the admit's CLOCK come together, and JOIN is what makes the player watched.
	if bridge != null:
		hud.clock_view = bridge.clock_view
	# Likewise the standing: kept from whenever it came, so a HUD made after it still
	# shows the best and the record.
	if not _standing.is_empty():
		hud.apply_standing(_standing)
	if not _stage_reference.is_empty():
		hud.apply_stage_reference(_stage_reference)
	apply_client_settings()
	_say_click_to_play()

	# By id, like the HUD, and for the same reason: HELLO names us before JOIN makes us.
	if presentation != null:
		presentation.follow_runs(game.timers, id)


## The player we are waiting for has been created. Fires for every player; ours is one.
func _on_player_added(added: G2GPlayer) -> void:
	_hear_beacon(added)

	if player == null and added != null and added.player_id == _watch_id:
		_adopt(added)


## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## Every player reaches this, because every player on a client — offline, the local one
## and a ghost; online, everybody the server sends — is made by `G2GGame.add_player`,
## which emits `player_added` after this client has connected to it. Guarded anyway,
## because a second connection would be every ping played twice.
##
## Bound to the body, so a ping can be left unplayed for a player [method _hidden] is
## hiding — a beacon you cannot see should not be one you can hear either. The guard is a
## dictionary rather than `is_connected`, because a bound callable is a new [Callable] and
## would never compare equal to the one already connected.
func _hear_beacon(body: G2GPlayer) -> void:
	if body == null or _beacons_heard.has(body.get_instance_id()):
		return

	_beacons_heard[body.get_instance_id()] = true
	body.beacon_pulsed.connect(_on_beacon_pulsed.bind(body))


func _on_beacon_pulsed(at: Vector3, body: G2GPlayer) -> void:
	if presentation != null and not _hidden(body):
		var _voice := presentation.on_beacon(at)


func _adopt(candidate: G2GPlayer) -> void:
	if candidate == null:
		return

	player = candidate
	gate.freeze(player)

	# The sampler turns the view at the rate this player's style says, and until there
	# is a player to ask it is on the game's own tunables. Done here rather than in
	# `_on_hello` for the same reason as everything else in this function: at hello
	# there is nobody to ask.
	if _sampler != null:
		_sampler.tunables = player.controller.tunables

	# The settings that live on the PLAYER rather than on the presentation layer, and
	# for the same reason the sampler is here: `apply_all()` ran during `setup()`, when
	# there was nobody to apply them to. A networked client reaches this function a
	# JOIN after that, and again every time the server hands it a new player.
	if presentation != null:
		presentation.apply_own_body()

	apply_client_settings()
	_apply_rules_to_player()
	_restore_style()
	# A new player has a new sampler (offline), and it has to start the way the old one
	# was left: a chat box open across a respawn or a map change is still open.
	_refresh_suspended()


func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = 32
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
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
	# Every death on the server, a hunter's swipe included, and every return to a start.
	bridge.death_received.connect(func(id: StringName, death: DotPlayerDeath) -> void:
		var _fell := fall(id, death)
	)
	bridge.alive_received.connect(rise)
	bridge.kill_received.connect(func(killer: StringName, victim: StringName, weapon: String, head: bool) -> void:
		if killcam != null:
			killcam.note_kill(killer, victim, weapon, head)
	)
	bridge.match_end_received.connect(_match_over)
	# The server's sv_ragdoll* set: this end draws the bodies. An older shell's link cannot
	# say, and the rules keep their defaults.
	if link != null:
		var _bodies := game.ragdoll_rules.follow_cvars(link)
		# The server's mp_forceview: this end places its own camera (G2GGame keeps every
		# camera under it).
		var _view := game.view_rules.follow_cvars(link)
		# mp_forcecamera, mp_freeroam and mp_freeroam_speed: whether the free camera is
		# offered, and how fast it flies.
		if game.spectate != null and game.spectate.manager != null:
			var _roam := game.spectate.manager.rules.follow_cvars(link)
			game.spectate.manager.rules.rules_changed.connect(_refresh_spectator_hud)
	# The map's time left, from the server's vote. The bridge holds it; the HUD draws it.
	bridge.clock_received.connect(func(_state: Dictionary) -> void:
		if hud != null:
			hud.clock_view = bridge.clock_view
	)
	# The map vote's cue and countdown. The ballot itself arrives as chat; this is what
	# chat cannot carry.
	bridge.vote_received.connect(func(info: Dictionary) -> void:
		var seconds_left := int(info.get("seconds_left", 0))
		if seconds_left > 0 and hud != null:
			hud.notice("%s in %d…" % [
				"Runoff" if bool(info.get("runoff", false)) else "Map vote", seconds_left
			])
		if presentation != null:
			presentation.on_vote_cue(StringName(str(info.get("cue", ""))))
	)

	_sampler = DotFpsSampler.new(game.tunables)
	DotFpsSampler.register_default_actions(_sampler)

	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", bridge.ask_ready, CONNECT_ONE_SHOT)

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


# --- Chat ------------------------------------------------------------------

## Joins the chat box to the two things it needs: a way out, and a way to stop the runner.
##
## [b]The sampler is the half that is easy to forget, and on a timer server it is the
## expensive one.[/b] `swallows_input` keeps typed keys out of `_unhandled_input`, but
## movement here is POLLED — `DotFpsSampler.sample` reads the device every physics frame
## and does not care what consumed an event. Without `suspended`, typing during a run
## strafes the player off a ramp and ends it.
func _wire_chat_window() -> void:
	var window: DotChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)

	window.opened.connect(func(_channel: StringName) -> void: _refresh_suspended())
	window.closed.connect(func() -> void: _refresh_suspended())


## What a player typed, on its way to the server.
##
## Nothing is filtered here: the server decides what a line may contain and its answer is
## the only one that counts.
func _on_chat_submitted(text: String, channel: StringName) -> void:
	if _offline:
		# Offline there is no server to decide anything, so the line goes straight to the
		# log. Saying nothing would read as a chat box that does not work.
		if presentation != null and presentation.chat_window != null:
			presentation.chat_window.add_said("You", text, Color(0.62, 0.78, 1.0))
		return

	if link != null and link.has_method("send_chat"):
		link.send_chat(text, channel == &"team")


## A line somebody said, in the chat box, with the name drawn apart from the text.
func _on_said(speaker: String, text: String, kind: String) -> void:
	# The server's own lines (a vote, a record, a map change) go on the HUD's centre notice
	# only when there is no box to read them in. Every line used to, which put whatever
	# anybody typed over the timer; then every system line did, so a vote was written three
	# times (notice, box, and the drawn ballot). The box draws even when a relay hides its
	# entry field, so it is always the place. hungario 5bfb319 and playground 532b7ca agree.
	if kind == "system" and hud != null and (presentation == null or presentation.chat_window == null):
		hud.notice(text)

	if presentation == null or presentation.chat_window == null:
		return

	var speaker_colour := Color(0.55, 0.85, 0.60) if kind == "team" else Color(0.62, 0.78, 1.0)

	if speaker == "":
		presentation.chat_window.add_text(text, Color(0.80, 0.82, 0.86))
		return

	presentation.chat_window.add_said(speaker, text, speaker_colour)


func _on_hello(player_id: int) -> void:
	_watch(StringName("u%d" % player_id))
	# The server dressed us from dot-platform's admission if it could; a launcher
	# that resolved one locally through DotAvatarManager sets [member avatar] and it
	# goes up now, to be conformed against the server's schema like any other.
	if avatar != null and bridge != null:
		bridge.publish_avatar(avatar)


## The server moved to a map this client will not or cannot load.
##
## [b]Leaves, rather than staying.[/b] The server keeps simulating this player on the map
## it announced, so staying is a player whose every tick is corrected into geometry their
## screen does not have — and the server cannot know to do anything about it, because
## dot-map keeps a refusal silent on purpose. The client is the one end that knows, so it
## is the one that acts, with the reason on the way out rather than a connection that
## simply goes strange.
func _on_map_refused(map_id: StringName, reason: String) -> void:
	var text := "Cannot follow the server to %s: %s" % [String(map_id), reason]
	if hud != null:
		hud.notice(text)
	if link != null and link.has_method("disconnect_from_server"):
		link.call("disconnect_from_server", text)


func _physics_process(delta: float) -> void:
	if _offline or net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)
	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if net.clock.is_synced():
			# The clock above has advanced; only the sampling waits, so the mouse does not pile
			# up a turn behind the cover and the server sees an idle body until it lifts.
			var command: DotFpsCommand = DotFpsCommand.new() if _covered() else _sampler.sample(delta)
			bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), command)


func _process(delta: float) -> void:
	if net != null and not _offline:
		net.interpolate_frame()

	# A cover rather than a grey world, while the server is somewhere this client is not.
	if hud != null and bridge != null:
		hud.show_loading(bridge.transit_text())

	_fold_look()
	_fold_correction()
	_fold_clock()

	for id in (game.players if game != null else {}):
		(game.players[id] as G2GPlayer).present(delta)

	if game != null:
		_present_others()
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
		presentation.present(delta, eye, forward)

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
			# Zero by default on this game, which is the whole point: a shaken camera on
			# a surf ramp is a lost run. Applied here rather than written by the shake so
			# there is one thing that moves a camera.
			camera.position = presentation.camera_shake()

	# [b]Last, after everything that writes the camera.[/b] It sat above the shake, which
	# sets the active camera's local position every frame — so a spectator's camera was
	# turned to face the watched player's view and put straight back at their own eyes,
	# and spectating showed nothing but a slightly wrong angle. Every check passed,
	# because they asked the spectator manager where the camera should be, not where the
	# camera was. `headless_client` asks the camera.
	_drive_spectator_camera()
	if killcam != null:
		killcam.hide_while_playing = [hud]
		killcam.frame()


## Hands the local player this frame's view, the mouse motion of THIS frame folded in,
## so a frame on which no tick ran still turns. See [member G2GPlayer.view_now].
##
## By name, with the state's angles as the fallback: a pack runs on whatever
## dot-player-controller the client shell carries, and a shell older than `look_now`
## draws exactly what it drew before.
func _fold_look() -> void:
	if player == null:
		return
	var sampler := _active_sampler()
	if sampler == null or not sampler.has_method(&"look_now") or is_spectating():
		player.view_now = null
		return
	player.view_now = sampler.call(&"look_now")


## Hands the local player what is left of its prediction corrections, so the eye eases
## across one rather than jumping with it. See [member G2GPlayer.drawn_offset].
func _fold_correction() -> void:
	if player == null:
		return
	player.drawn_offset = Vector3.ZERO
	if _offline or net == null or net.predictor == null or bridge == null:
		return
	var mine := bridge.behaviour_for(bridge.local_player_id)
	if mine != null and mine.identity != null and mine.player == player:
		player.drawn_offset = net.predictor.visual_offset(mine.identity.net_id)


## Hands the local player's controller the clock its ticks are counted on, so its
## `render_state` draws at `DotNetClock.render_alpha` (dot-net) rather than the engine's
## physics fraction: the clock stretches and shrinks its ticks while it settles on the
## server, a physics frame now and then runs no tick or two, and drawn at the engine's
## fraction the eye stood still on one frame and moved double on the next.
## `headless_feel`'s *a clock slip* section measures it beside its control.
##
## By name both ways: `set` on a shell's older `DotFpsController` is a no-op, and the
## controller asks the clock for `render_alpha` by name, so a shell older than either draws
## exactly as before. Null offline, where every physics frame is one tick.
func _fold_clock() -> void:
	if player == null or player.controller == null:
		return
	var connected := not _offline and net != null and net.is_running() and net.clock != null
	player.controller.set(&"render_clock", net.clock if connected else null)


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


## Mouse motion while roaming, as radians for [DotSpectatorFreeCam.look]: x turns the view
## left for positive (so mouse right is negative), y up for positive (mouse down is negative).
func _roam_mouse(motion: InputEventMouseMotion) -> void:
	var sampler := _active_sampler()
	var degrees := sampler.tunables.mouse_sensitivity if sampler != null and sampler.tunables != null else 0.12
	var invert := -1.0 if sampler != null and sampler.tunables != null and sampler.tunables.invert_look_y else 1.0
	_roam_look += Vector2(-motion.relative.x, -motion.relative.y * invert) * deg_to_rad(degrees)


## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
##
## [b]Only while the cursor is actually captured.[/b] KEY_ESCAPE releases it, and on the
## web [member _awaiting_click] leaves it released before the first click too — in both
## of those states the pointer is a pointer, so spending its motion on the view turns
## the player away from the "click to play" notice they are being asked to click.
## `game-arena` guarded this from the start; this file and `game-playground` did not.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested here.[/b] The dummy display server pins the
## mode to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so a suite
## can neither put a client into the state a player plays in nor out of it — which is
## why arena's identical guard has never been exercised by anything.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
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

	# [b]Before the `player == null` guard, deliberately.[/b] A browser player clicks
	# while the world is still loading more often than not, and a click swallowed
	# because no player exists yet is a click that never captures the cursor — after
	# which the only affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
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

	# The zone editor takes its own keys and the left button while it is open; mouse look
	# and movement carry on, because aiming IS how a corner is placed.
	if zone_editor != null and zone_editor.is_open():
		if event is InputEventKey and zone_editor.handle_key(event as InputEventKey):
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and zone_editor.handle_click(event as InputEventMouseButton):
			get_viewport().set_input_as_handled()
			return

	# Spectating: the two buttons cycle whom. Pressed only — a release is not a second
	# click — and only once the pointer is the view's, so the click that captures it in a
	# browser is not also a change of target.
	if is_spectating() and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button := (event as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_LEFT or button == MOUSE_BUTTON_RIGHT:
			cycle_spectate(button == MOUSE_BUTTON_RIGHT)
			get_viewport().set_input_as_handled()
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

	# Push to talk, handled BEFORE the "is this a press" filter below, because a talk
	# key needs its release as much as its press: a key whose release nobody reads is
	# a microphone that never closes.
	#
	# [b]K, not V, by default.[/b] V is this game's second checkpoint key and has been since
	# the client was written; the genre's own voice key is unbound here because the genre
	# binds it per player. K is what is left that nothing else claims.
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

	# Actions rather than keycodes, so every one of these is the player's own key. A mouse
	# button bound to one arrives here as well as a key does.
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


## R. Once: back to the start of the stage you are in (or of the track, when you are in
## none). Twice inside [constant DOUBLE_TAP_MSEC]: back to the main start zone, from a bonus
## too. See [method G2GGame.restart] for what each means.
##
## [b]The first press acts at once rather than waiting to see whether a second comes.[/b]
## Waiting would put a third of a second of nothing between every R and the restart, on the
## key a runner presses more than any other; and the second press only ever widens what the
## first did, so having acted early costs nothing.
func _restart_key(now_msec: int = -1) -> int:
	var now := now_msec if now_msec >= 0 else Time.get_ticks_msec()
	var mode := G2GEvents.RESTART_MAIN if now - _last_restart_msec <= DOUBLE_TAP_MSEC \
		else G2GEvents.RESTART_STAGE
	# A double tap is spent: a third press starts counting again rather than being a
	# second double tap.
	_last_restart_msec = now if mode == G2GEvents.RESTART_STAGE else -100000

	if _offline:
		var _restarted := game.restart(&"local", mode)
		if hud != null:
			hud.refresh_stage_reference()
	elif bridge != null:
		bridge.ask_restart(mode)
	return mode


# --- Themes and the HUD's layout -------------------------------------------------------

## The theme the menu just changed to, onto the HUD and the zone editor. The menus restyle
## themselves (dot-menu rebuilds them rather than recolouring, for the reason its CLAUDE.md
## gives); this is the half that is this game's.
## dot-ui's pieces on the HUD (the hit marker, the damage numbers) in the menu's theme too,
## live: the menu sets the theme on the HUD's root (dot-menu's `follow_hud`, by name for a
## shell older than it). Not scaled by the HUD size setting: this HUD is laid out by the
## player's own zone editor (`hud_positions`), in the frame's pixels. Whichever of the HUD and
## the menu comes second calls it.
func _follow_hud() -> void:
	if hud != null and menu != null and menu.has_method(&"follow_hud"):
		menu.call(&"follow_hud", hud, null, false)


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


# --- Menus ---------------------------------------------------------------------

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
	board.title_text = "g2gfast"
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
	return {"server": {"name": "g2gfast", "game": "offline" if _offline else "", "map": map_name}, "players": rows}


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


func open_menu(page: StringName = &"") -> void:
	if menu == null:
		return
	_refresh_menu_words()
	menu.open(page)


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


# --- Spectating -------------------------------------------------------------------

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


# --- Flashlight and the others ----------------------------------------------------

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
##
## Everybody but the local player, the ghost included — and never the one being spectated,
## because hiding the player you chose to watch would be a camera pointed at nothing.
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


# --- Settings that land on the client ------------------------------------------------

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


# --- What the menu asks the client (see G2GMenu.host) --------------------------------

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
