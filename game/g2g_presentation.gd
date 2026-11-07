extends "g2g_presentation_schema.gd"

const G2GWeaponIcons := preload("g2g_weapon_icons.gd")
const G2GUnits := preload("g2g_units.gd")
const G2GAmbience := preload("g2g_ambience.gd")

## Settings, audio, effects and a console, on a client whose whole output is a number.
##
## [b]Every decision in this file is downstream of one sentence: a player who came to run
## must not be stopped by anything added for a player who came to do something else.[/b]
## That is this game's own rule and it settles what would otherwise be arguments:
##
## - **Camera shake defaults to zero here, and to one everywhere else.** A surf ramp is a
##   precision input at 20 m/s; shaking the camera for a landing is not atmosphere, it is
##   taking the run away. It is still a setting, because a player doing deathmatch on the
##   same server may want it.
## - **The flash is off by default** for the same reason and with the same switch.
## - **Nothing on the fx budget is allowed to matter.** An effect never changes the
##   simulation, so a frame budget dropping one cannot change a time — which is the
##   property that makes the whole addon safe on a timer server.
##
## The one thing audio genuinely adds here is **the landing**: a bunny-hop is a rhythm,
## and a rhythm you can only see is one you have to watch your feet for.

const CHANNEL := "g2g.presentation"


var settings: DotSettingsManager = null

## Every key the client reads. See [G2GBindings].
var bindings: DotMenuBindings = G2GBindings.make()

## What pushes the stock settings at the engine, the audio and the effects. See
## [method _build_settings].
var applier: DotMenuApplier = null
var audio: DotAudioManager = null

## Footsteps by surface and a bed per map: dot-audio's stock (Kenney's footsteps and generated
## beds, CC0; the addon's stock/CREDITS.md). Under the landing and the timer, never over them.
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null
## The mood layer over the bed: a mood per map, indoors under a roof, the server's `g2g_ambient*` times the player's sliders.
var ambient: DotAmbienceDirector = null
var fx: DotFxManager = null
## The player's console, built by [method build_console] once the client has a menu.
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

var client: Node = null

var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false
var _was_grounded := true

## Where the local player's feet were on the last frame, for the gate effects.
var _last_at := Vector3.ZERO

## The timers [method follow_runs] is listening to, and whose runs it plays.
var _followed_timers: DotTimerManager = null
var _followed_id: StringName = &""


func setup() -> DotResult:
	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	_build_chat()
	applier.bind_audio(audio)
	applier.bind_fx(fx)
	var _applied := applier.setup()
	return DotResult.success(null)


func apply_all() -> void:
	if applier != null:
		applier.apply_all()


# --- Settings ---------------------------------------------------------------

## Pushes `show_own_body` onto the local player, whenever there is one.
##
## [b]Public, because the player is not here when the setting first is.[/b] `setup()`
## runs `apply_all()` before anything has joined — offline the player is three lines
## later, and on a networked client it is a JOIN event away — so this has to no-op
## quietly and be called again by whoever adopts a player. [method G2GClient._adopt]
## is that caller, and it is also what covers a reconnect, a map change and a player
## replaced under a new session id.
func apply_own_body() -> void:
	if client == null or settings == null:
		return

	var player: Object = client.get("player")
	if player == null:
		return

	player.set("show_own_body", bool(settings.get_value(&"show_own_body")))


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new("user://g2g_settings")
	settings.app_namespace = &"game_g2gfast"
	settings.migrations = migrations()
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("g2gfast's settings")

	# dot-menu's applier pushes the stock settings and the keys; what is this game's —
	# the body, the chat box and its two keys — is the handler below, on the same signal.
	applier = DotMenuApplier.new()
	applier.name = "Applier"
	applier.settings = settings
	applier.bindings = bindings
	add_child(applier)
	applier.on_any(_on_setting_changed)
	return DotResult.success(null)


## This game's own settings. The stock ones — volumes, window, frame rate, shake, flashes,
## effects quality, and every key — are [DotMenuApplier]'s, which calls this for every key.
func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"show_own_body":
			apply_own_body()
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_team_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))


# --- Audio ------------------------------------------------------------------

func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	# Small. There is one player making noises and the rest is a timer.
	audio.voices = 12
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md): a 40 s stand-in run on
	# the intro read -26.9 LUFS with the bed and the steps in, -21.6 at +8. The bed is held back a little
	# (the speed-driven wind level below) so a timer game's quiet is a breeze.
	audio.loudness_trim_db = 12.0
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("g2gfast's audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = audio
	# The landing is this game's own sound (the rhythm of a hop, pitched by speed); a stock
	# landing step on top would smear it.
	steps.landing_air_time = 1.0e9
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = audio
	add_child(ambience)
	ambience.set_map_bed(bed_for(&""))
	ambient = DotAmbienceDirector.new()
	ambient.name = "Ambient"
	ambient.manager = audio
	ambient.default_mood = G2GAmbience.DEFAULT_MOOD
	ambient.prefix_moods = G2GAmbience.PREFIX_MOODS
	ambient.rules = G2GAmbience.make_rules()
	ambient.beds = ambience
	add_child(ambient)
	var _moods := ambient.setup()
	ambient.follow_settings(settings)

	# Only on a real sink, and only after setup: the manager decides whether there is a
	# device, and on a headless server there is nothing to bake for. Building the bank
	# anyway would be arithmetic per dedicated-server startup for streams no process on
	# that machine can play.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())
		DotLog.info(
			CHANNEL,
			"no audio files; synthesised stand-ins are in use",
			{"ids": sound_recipes().size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 0.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", false)
	fx.config.max_decals = 0
	# Deliberately small. Nothing here is allowed to cost a frame on a server where a
	# frame is a tick and a tick is 7.8 ms of somebody's time.
	fx.config.frame_budget = 24
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("g2gfast's effects")

	# [b]Said out loud, because a missing scene is otherwise a DEBUG line.[/b] Until
	# 2026-09-27 neither gate scene existed, and every start and finish was refused for it
	# with no suite noticing. `headless_presentation` asserts the list is empty; this is
	# for a build that lost one anyway.
	var missing := fx.catalogue.missing_scenes()
	if not missing.is_empty():
		DotLog.warn(CHANNEL, "effect scenes missing; those effects will not draw", {
			"paths": ", ".join(missing),
		})
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

## dot-console's kit, with this game's two differences, and registered with [param menu].
##
## Called by [G2GClient] after its [DotMenu] exists, not from [method setup]: the menu is
## built from this layer's settings, and the kit makes the console one of the menu's
## overlays, which is what stops the runner. A console that is not an overlay walks the
## player while they type: the sampler polls the keys, and a focused line edit does not
## stop `Input.is_action_pressed`.
##
## [b]The server's console behind the word `server`, which is this game's own decision.[/b]
## The kit bridges an in-process server's console unprefixed, catching whatever the client
## did not claim. Here the two consoles share names that mean opposite things -- `!s3` on a
## client is a local navigation and on a server is a teleport that ends a run -- and an
## unprefixed server console is how somebody types something meant for their own client
## and loses the run they were three stages into. So the kit's bridge is taken out and
## [ServerPrefixed] put in: `server <line>`.
func build_console(menu: Object = null) -> void:
	console = DotConsoleKit.build(self, settings, menu)
	var kit_sources: Array = console.sources()
	if not kit_sources.is_empty() and kit_sources[0] is DotConsoleLocal:
		var _icons_bound := G2GWeaponIcons.shared.bind_console(kit_sources[0])

	var bridged: DotConsoleBridge = null
	for s in console.sources().slice(1):
		console.remove_source(s)
		if s is DotConsoleBridge:
			bridged = s
	console.add_source(_local_commands())
	if bridged != null:
		console.add_source(ServerPrefixed.new(bridged))

	console_panel = get_node_or_null(^"ConsoleLayer/ConsolePanel") as DotConsolePanel


## This game's own command; the kit has `help`, `clear`, `settings` and every setting.
func _local_commands() -> DotConsoleLocal:
	var local := DotConsoleLocal.new()
	local.add_command(&"quit", "Leave", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	return local


## An in-process server's console, reached only as `server <line>`. See [method build_console].
class ServerPrefixed extends DotConsoleSource:
	const PREFIX := "server"

	var _bridge: DotConsoleBridge = null

	func _init(bridge: DotConsoleBridge) -> void:
		_bridge = bridge

	func claims(name: String) -> bool:
		return name.to_lower() == PREFIX and _bridge != null and _bridge.valid()

	func execute(line: String) -> DotResult:
		var parts := DotConsoleLine.split_line(line)
		if parts.size() < 2:
			return DotResult.fail(DotError.CODE_INVALID, "usage: %s <command>" % PREFIX)
		return _bridge.execute(line.substr(line.find(parts[1], parts[0].length())))

	func names() -> PackedStringArray:
		return PackedStringArray([PREFIX])

	func help_for(name: String) -> String:
		return "Run a line on this process's server: server <command>" if name == PREFIX else ""

	func source_name() -> String:
		return "server"


# --- Chat -------------------------------------------------------------------

## The box a runner types in, and the three settings that decide it.
##
## [b]This game could receive a chat line and could not send one.[/b] `DotChatClient` held
## the history, the HUD drew the notice, and there was no key anywhere that opened
## anything to type in — so a player could be talked to and could not talk back.
##
## Bottom left, at the default inset: this HUD keeps its clock and its key display along
## the bottom CENTRE and its status line along the top, so the corner is free.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"g2g_chat"
	chat_window.team_action = &"g2g_chat_team"
	# [b]An outline, because the floors are pale.[/b] Light-blue names and white text over
	# light grey tiles were a log the players asked, in that log, to be able to read. dot-ui
	# outlines rather than panels on purpose (see `DotFeedView`): a backing box is a grey
	# rectangle in the corner of the view even when nobody is talking.
	chat_window.outline_size = 5
	chat_window.width = CHAT_WIDTH
	chat_window.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	_chat_layer.add_child(chat_window)


## The box's width when nothing is beside it, the narrowest it is squeezed to, and the gap
## it keeps from the timer's plate.
const CHAT_WIDTH := 460.0
const CHAT_MIN_WIDTH := 240.0
const CHAT_GAP := 12.0


## Narrows the box so a full log stays left of the timer's plate.
##
## [b]Bottom left is not free at every width.[/b] The plate is bottom CENTRE, 428 wide at
## 1280, so its left edge is at 426 and a 460-wide box from 16 drew its wrapped lines over
## "0 u/s" (seen in a game-ballot frame). Called every frame with [method G2GHud.timer_rect]:
## the plate moves with the player's placement setting and the interface scale.
func fit_chat_beside(plate: Rect2) -> void:
	if chat_window == null or not chat_window.is_inside_tree():
		return

	var w := chat_width_beside(plate, chat_window, chat_window.get_viewport_rect().size.y)

	if not is_equal_approx(w, chat_window.width):
		chat_window.width = w
		chat_window.offset_right = chat_window.margin_left + w


## The width a box may have beside [param plate] on a screen [param screen_height] tall.
## Snapped to 16 pixels, so a plate that grows a digit does not re-wrap the log every frame.
static func chat_width_beside(plate: Rect2, window: DotChatWindow, screen_height: float) -> float:
	if plate.size.x <= 0.0:
		return CHAT_WIDTH

	var log_top := screen_height - (
		window.margin_bottom + window.entry_height
		+ float(window.max_lines) * (window.line_height + window.line_gap)
	)

	if plate.end.y <= log_top or plate.position.x <= window.margin_left:
		return CHAT_WIDTH

	var room := floorf((plate.position.x - window.margin_left - CHAT_GAP) / 16.0) * 16.0
	return clampf(room, CHAT_MIN_WIDTH, CHAT_WIDTH)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## `on` is both halves at once — a relayed server AND a box in front of the game. `off` is
## a player who chats somewhere else. `auto` draws it unless this server is already putting
## these lines somewhere this player can see them. In every case the log keeps drawing what
## other people said: off means "you type somewhere else", never "you are out of it".
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


# --- What the game asks for -------------------------------------------------

func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)
	_advance_tails(delta)


func camera_shake() -> Vector3:
	return fx.shake.offset()


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does[/b], and on a timer server
## it is worse than elsewhere: a client that keeps reading movement while somebody types
## does not merely walk them into a wall, it ends a run they have been building for
## minutes. Nobody may lose a personal best by saying "gg".
func swallows_input() -> bool:
	if console != null and console.is_open():
		return true
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


## Called once a tick with the local player's movement state.
##
## [b]Watched rather than listened for, and it is the same argument this family made about
## eating in a 2D arena:[/b] a landing fires on the authority, which on a netted client is
## somewhere else — so a client that hooked a signal would be silent online and perfectly
## noisy offline, which is the kind of difference nothing catches. What a player perceives
## is their own feet touching the ground, and that arrives either way.
func watch_movement(grounded: bool, speed: float, at: Vector3) -> void:
	if grounded and not _was_grounded:
		# The pitch is the speed. A runner cannot see their own velocity while looking at
		# a ramp, and a landing that sounds different at 400 units and at 1200 is the
		# cheapest speedometer there is.
		audio.play_at(&"land", at, 1.0, clampf(0.75 + speed / 2000.0, 0.6, 1.6))
		fx.spawn(&"land_shake", Transform3D.IDENTITY)
	elif _was_grounded and not grounded:
		audio.play(&"jump")
	_was_grounded = grounded
	_last_at = at
	if ambience != null and settings != null:
		ambience.drive = wind_level(
			speed * G2GUnits.UNITS_PER_METRE,
			settings.get_float(&"snd_wind_min", 0.3),
			settings.get_float(&"snd_wind_max", 1.1),
			settings.get_float(&"snd_wind_full_speed", 1500.0)) / DotAudioAmbience.DEFAULT_LEVEL


## The stock weapon sound each of this game's two weapons plays (dot-audio's weapon stock,
## in the catalogue through DotAudioStock.add_to).
const WEAPON_SOUNDS := {&"deagle": &"weapon_magnum_fire", &"knife": &"weapon_swing"}

## Beyond this, a deagle is heard as its distant recording.
const FAR_METRES := 60.0


## Whether the listener stands under a roof, stepped by the client each frame: roofed, a deagle shot is followed by its room tail.
var shot_roof := DotAmbienceRoof.new()

## Tails waiting out [constant DotWeaponSound.TAIL_DELAY]: `{id, at, left}`.
var _tails: Array[Dictionary] = []


## The listener's roof, once a frame.
func follow_roof(delta: float, eye: Vector3, space: PhysicsDirectSpaceState3D, world_mask: int) -> void:
	shot_roof.mask = world_mask
	var _changed := shot_roof.step(delta, eye, space)
	if ambient != null and ambient.has_moods():
		ambient.follow_roof(delta, eye, space, world_mask)


func _advance_tails(delta: float) -> void:
	for tail in _tails.duplicate():
		tail.left -= delta
		if tail.left <= 0.0:
			_tails.erase(tail)
			var _voice := audio.play_at(tail.id, tail.at, db_to_linear(DotWeaponSound.TAIL_GAIN_DB))


## A weapon went off at [param at]. Positional, so a shot across a course has a direction.
func on_weapon_used(weapon: StringName, at: Vector3, listener: Vector3) -> void:
	var id: StringName = WEAPON_SOUNDS.get(weapon, &"")
	if id == &"" or audio == null:
		return
	if weapon == &"deagle" and listener.distance_to(at) > FAR_METRES:
		id = &"weapon_magnum_far"
	var _voice := audio.play_at(id, at)
	if weapon == &"deagle" and shot_roof.roofed and DotWeaponSound.pick_tail(&"magnum", true) != null:
		_tails.append({"id": &"weapon_magnum_far", "at": at, "left": DotWeaponSound.TAIL_DELAY})


## The trigger fell on nothing.
func on_weapon_dry(at: Vector3) -> void:
	if audio != null:
		var _voice := audio.play_at(&"weapon_dry", at)


## A weapon came up.
func on_weapon_equipped(at: Vector3) -> void:
	if audio != null:
		var _voice := audio.play_at(&"weapon_equip", at)


## The bed's level for a horizontal speed in genre units a second. Static so the curve can be
## checked without an audio device, which a headless run does not have.
static func wind_level(units_per_second: float, level_min: float, level_max: float, full_speed: float) -> float:
	return lerpf(level_min, level_max, clampf(units_per_second / maxf(full_speed, 1.0), 0.0, 1.0))


## Plays the timer's start, splits and finish for one player.
##
## [b]The four sounds that ARE the game were reachable from the suite and from nothing
## else.[/b] `on_run_started`, `on_split` and `on_run_finished` were written, tested with
## a null sink, and never called by the client — so a run started, split and finished in
## silence on every build. Listened for on the client's OWN [DotTimerManager], which is
## fed on a netted client too (`G2GGame.tick_timers_only`), so the start is heard on the
## tick the local prediction crosses the line rather than a round trip later.
##
## A personal best is [signal DotTimerManager.record_accepted], which only fires where
## records are filed — offline, here. A netted client is told a rank, not whether it beat
## its own time, and plays the finish without the fanfare rather than guessing.
##
## Called again whenever the followed player changes; connects once per manager.
func follow_runs(timers: DotTimerManager, player_id: StringName) -> void:
	_followed_id = player_id

	if timers == _followed_timers:
		return

	if _followed_timers != null and is_instance_valid(_followed_timers):
		_followed_timers.player_started.disconnect(_on_followed_started)
		_followed_timers.player_staged.disconnect(_on_followed_staged)
		_followed_timers.player_finished.disconnect(_on_followed_finished)
		_followed_timers.record_accepted.disconnect(_on_followed_record)

	_followed_timers = timers

	if timers == null:
		return

	timers.player_started.connect(_on_followed_started)
	timers.player_staged.connect(_on_followed_staged)
	timers.player_finished.connect(_on_followed_finished)
	timers.record_accepted.connect(_on_followed_record)


func _on_followed_started(id: StringName, _run: DotTimerRun) -> void:
	if id == _followed_id:
		on_run_started(_last_at)


func _on_followed_staged(id: StringName, _number: int, _split: float) -> void:
	if id == _followed_id:
		on_split()


func _on_followed_finished(id: StringName, _run: DotTimerRun) -> void:
	if id == _followed_id:
		on_run_finished(_last_at, false)


func _on_followed_record(record: DotTimerRecord, previous: DotTimerRecord, _rank: int) -> void:
	if record == null or record.player_id != _followed_id:
		return

	if previous == null or record.beats(previous):
		on_personal_best()


func on_run_started(at: Vector3) -> void:
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play(&"timer_start")
	fx.spawn(&"start_gate", t)


func on_split() -> void:
	audio.play(&"timer_split")


func on_run_finished(at: Vector3, personal_best: bool) -> void:
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play(&"timer_finish")
	fx.spawn(&"finish_gate", t)
	if personal_best:
		on_personal_best()


## Separate from the finish because it is known later: the record is filed after the run
## ends, so the finish sounds on the tick and the fanfare when the store says so.
func on_personal_best() -> void:
	audio.play(&"personal_best")
	# Refused unless the player asked for flashes, which they have not by default.
	fx.flash(&"personal_best")


func on_teleported() -> void:
	audio.play(&"teleport")
	# Everything drawn about where you were is about somewhere you are not.
	fx.clear()


## A map-vote cue from the server. Empty is silence, and an id this catalogue does not
## have is dot-audio's silent refusal: a server with a sound set this client was not built
## with should cost a noise, not a log line per second.
func on_vote_cue(id: StringName) -> int:
	if id == &"" or audio == null:
		return 0

	return audio.play(id)


## A beacon's ripple went out from [param at]. `G2GPlayer.beacon_pulsed`, on every
## client, for every beaconed player — the beaconed one included, who hears their own.
func on_beacon(at: Vector3) -> int:
	if audio == null:
		return 0

	return audio.play_at(BEACON_SOUND, at)


## A dead body's sound (dot-player-char's ragdolls), where it landed.
func on_body(id: StringName, at: Vector3, volume: float) -> int:
	if audio == null:
		return 0

	return audio.play_at(id, at, clampf(volume, 0.3, 1.0))


## The flashlight went on or off.
func on_flashlight(_on: bool) -> int:
	if audio == null:
		return 0

	return audio.play(FLASHLIGHT_SOUND)


func on_map_changed(map_id: StringName = &"") -> void:
	fx.clear()
	_was_grounded = true
	if ambient != null and ambient.has_moods():
		ambient.on_map(map_id)
	if ambience != null:
		ambience.set_map_bed(bed_for(map_id))


## A map's bed, from its name: the built-in stages are sky platforms (wind); a surf map is
## ramps in the air (wind), a climb map is rock (a cave's rumble and drips), anything else a
## breeze and birds. By prefix, because imported maps arrive by the hundred and nobody will
## list them.
static func bed_for(map_id: StringName) -> StringName:
	var id := String(map_id).to_lower()
	if id.begins_with("surf_") or id == "bhop_g2g_stages":
		return &"amb_wind"
	if id.begins_with("kz_") or id.begins_with("climb_") or id.begins_with("xc_"):
		return &"amb_cave"
	return &"amb_outdoor"


## Everybody on the map steps, once a frame. A rider is a Node3D moved by its controller, so
## the ground is the controller's own answer, not a ray.
func keep_walkers(players: Array) -> void:
	if steps == null:
		return
	var live: Array = []
	for p: Variant in players:
		if not (p is Node3D) or not is_instance_valid(p):
			continue
		var rider: Node3D = p
		live.append(rider)
		if not steps.is_tracking(rider):
			# By property, not by type: a player script is referenced by path (a delivered
			# pack's class_name is not registered in the host).
			steps.track(rider, {"grounded": func() -> bool:
				if not is_instance_valid(rider):
					return false
				var c: Variant = rider.get("controller")
				return c != null and (c as Object).get("state") != null and bool(c.state.is_grounded())})
	steps.keep(live)


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("g2gfast's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))

	return out
