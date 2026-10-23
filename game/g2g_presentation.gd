extends Node

const G2GBindings := preload("g2g_bindings.gd")
const G2GPaths := preload("g2g_paths.gd")
const G2GVote := preload("g2g_vote.gd")
const G2GUnits := preload("g2g_units.gd")

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

## 2: `field_of_view` is applied now, and every document written before carries the old
## default of 110 that nothing ever read. 3: Tab is the scoreboard, and "next style" moved
## off it. See [method migrations].
const SCHEMA_VERSION := 3
const SOUND_DIR := "res://audio"

## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"

## The flashlight's switch. See [method sound_catalogue].
const FLASHLIGHT_SOUND := &"flashlight"
static var FX_DIR := G2GPaths.rebase("res://scenes/fx")

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

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	# [b]The audio, the window, the frame rate, the sensitivity and the theme are dot-menu's
	# stock settings[/b] (2026-10-09), declared at the end with the keys and scopes they were
	# stored under here, so nobody's choice moved. What is declared first below wins, which is
	# how this game keeps its own defaults where the genre wants different ones: no camera
	# shake, no flashes, and the field of view as fov_desired.
	#
	# `raw_input` is gone: it was declared here and applied by nothing, and the engine has no
	# portable switch for it to apply. A stored value is kept in the document's unknown half.


	# The style is remembered per person, not per machine. Somebody who runs sideways
	# runs sideways everywhere.
	s.add(DotSettingsDef.text(&"preferred_style", "normal", &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Which style to ask for on joining. The server decides."))

	s.add(DotSettingsDef.boolean(&"show_speed", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"show_splits", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"show_stage_splits", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("The stage-by-stage panel on a map that has stages."))
	s.add(DotSettingsDef.boolean(&"show_keys", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"show_crosshair", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# [b]The timer's layout, as the player's own.[/b] Timer plugins in this genre let a
	# server pick one of a few layouts; here every line of the clock's block is a switch,
	# the block goes where the player drags it, and all of it is ACCOUNT scope, because a
	# runner who arranged their screen once arranged it for every server. Each line is one
	# of `DotTimerHud`'s own fields, so turning one off removes it from the block rather
	# than leaving a gap. See G2GHud.apply_layout.
	s.add(DotSettingsDef.boolean(&"timer_show_time", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The running time itself."))
	s.add(DotSettingsDef.boolean(&"timer_show_track", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The style and the track, beside the clock."))
	s.add(DotSettingsDef.boolean(&"timer_show_stage", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Stage 2 / 5, on a map that has stages."))
	s.add(DotSettingsDef.boolean(&"timer_show_stats", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Jumps, strafes and sync."))
	s.add(DotSettingsDef.boolean(&"timer_show_standing", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The record, your best and your place."))
	s.add(DotSettingsDef.choice(&"timer_comparison", &"pb", [&"pb", &"wr", &"none"] as Array[StringName], &"hud")
		.with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("What the split is against: your best, the record, or nothing."))
	s.add(DotSettingsDef.boolean(&"timer_compact", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Style, track, stage and statistics on one line rather than four."))
	s.add(DotSettingsDef.integer(&"timer_size", 30, 18, 56, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The clock's size; the rest of the block scales with it."))
	s.add(DotSettingsDef.choice(&"timer_position", &"bottom_centre", [
		&"bottom_centre", &"bottom_left", &"bottom_right", &"top_left", &"top_centre", &"top_right",
	] as Array[StringName], &"hud")
		.with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Where the clock's block sits, unless it has been dragged."))
	s.add(DotSettingsDef.boolean(&"show_status", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The map, time left and rules along the top."))
	s.add(DotSettingsDef.boolean(&"show_spectators", true, &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Who is spectating you, when the server shares it (sv_spec_list)."))
	# Where each dragged piece of the HUD sits, as `{"timer": [x, y], ...}`: the CENTRE of
	# each, as a fraction of the window, so a layout arranged on a laptop lands in the same
	# place on a 4K screen. Empty is every piece in its default place. Text rather than one
	# setting per piece, because the pieces are the HUD's to name and the schema should not
	# need a migration to add one.
	s.add(DotSettingsDef.text(&"hud_positions", "", &"hud").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("Where each dragged HUD element sits. Empty is the default layout."))

	# Every start, stage and finish drawn as a glowing box. On by default: a line a runner
	# cannot see is a line they find by failing. See G2GZoneOutlines.
	s.add(DotSettingsDef.boolean(&"show_zones", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Draw the start, stage and finish zones as glowing boxes."))

	# [b]Everybody else, the ghost, and what they carry.[/b] The genre's `!hide`, which every
	# timer server has because a runner learning a section does not want somebody else's
	# body on the block they are about to land on. Drawing only: the others are still
	# simulated and still replicated, so turning it off shows them where they really are.
	# ACCOUNT, because somebody who hides others hides them on every server.
	s.add(DotSettingsDef.boolean(&"hide_others", false, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Hide every other player and the record's ghost, with their beacons."))

	# Chat. ACCOUNT scope for all three, for the reason the sensitivity above has it: a
	# runner who found their key once should never have to find it again.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server already carrying chat somewhere the player can "
		+ "see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_team_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# [b]The genre's `fov_desired`: horizontal at 4:3, so 90 is what a player expects.[/b] It
	# was declared as 110 over 70..130 and read by nothing, so the number never meant either
	# thing; G2GCamera converts it through G2GUnits like the cvar it stands for.
	s.add(DotSettingsDef.integer(&"field_of_view", 90, 75, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	).with_description("Horizontal field of view at 4:3, as fov_desired."))

	# [b]Off, which is both this genre's convention and the only default that costs a
	# runner nothing.[/b] A body drawn at the eye is 40 cm of avatar between the player
	# and the block they are about to land on, and the one visual cue a first-person
	# runner has for their own height is the SHADOW on the floor ahead — which is cast
	# either way, because the rig hides by render layer rather than by `visible`.
	#
	# ACCOUNT scope for the reason `sensitivity` and `preferred_style` have it: somebody
	# who turned their body on once should not have to find the switch again on the next
	# server. What it reaches is `G2GPlayer.show_own_body`; the head and the hat stay
	# culled whatever this says, because those mounts are at the eye and drawing them
	# fills the view with the inside of a cube.
	s.add(DotSettingsDef.boolean(&"show_own_body", false, &"video").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description(
		"Draw your own character's body in first person. Off by default; the head is "
		+ "never drawn, because the camera is inside it."
	))

	# [b]Zero by default, which is the opposite of every other game here.[/b] A surf ramp
	# is a precision input at speed; shaking the camera for a landing is taking the run
	# away. It is still a setting because the same server runs a deathmatch layer.
	s.add(DotSettingsDef.number(&"shake_scale", 0.0, 0.0, 2.0, &"accessibility")
		.with_description(
			"Zero by default on a timer server: a shaken camera is a lost run."
		))
	s.add(DotSettingsDef.boolean(&"allow_flashes", false, &"accessibility")
		.with_description("Off by default here, for the same reason as the shake."))
	s.add(DotSettingsDef.boolean(&"reduce_motion", false, &"accessibility").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The end-of-match announcement appears at once, with nothing sliding, rising or bursting."))

	# One binding per key the client reads, DEVICE scope, after the chat block above so the
	# two chat keys keep the ACCOUNT declarations they had first. See G2GBindings.
	G2GBindings.make().add_to_schema(s)

	# [b]Effects at 0.6, not the stock 1.0 (fgr-g2g-audio-1).[/b] The landing on every hop and
	# the footsteps sat on top of the bed and the timer's cues at full level, which a runner
	# hears hundreds of times a minute. Declared before the stock set so it is the one kept;
	# a player who wants the old level still has the slider.
	s.add(DotSettingsDef.number(&"sfx_volume", 0.6, 0.0, 1.0, &"audio"))
	# The wind is the speedometer's second half: the bed's level runs from `snd_wind_min` at
	# a standstill to `snd_wind_max` at `snd_wind_full_speed` genre units a second, linearly,
	# so a slow walk is a breeze and a surf at 3000 is a roar. Settings, so each one is a cvar.
	s.add(DotSettingsDef.number(&"snd_wind_min", 0.3, 0.0, 2.0, &"audio").with_description(
		"Bed level when standing still."))
	s.add(DotSettingsDef.number(&"snd_wind_max", 1.1, 0.0, 2.0, &"audio").with_description(
		"Bed level at snd_wind_full_speed."))
	s.add(DotSettingsDef.number(&"snd_wind_full_speed", 1500.0, 100.0, 5000.0, &"audio").with_description(
		"Horizontal speed in units per second at which the bed reaches snd_wind_max."))

	# Everything else a game has: volumes, the window, the frame rate, the mouse, the theme.
	return DotMenuStock.declare(s)


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


## One step per schema version, keyed by the version migrated FROM.
##
## [b]1 → 2 drops a `field_of_view` of exactly 110.[/b] A document stores every value,
## defaults included, so every player who ever ran this client has `"field_of_view": 110`
## on disk — the old default, read by nothing. Now that the camera reads it, keeping it
## would widen everybody's view from the genre's 90 to 110 overnight. Nobody can have
## CHOSEN 110 and seen it, because it was never applied, so dropping it loses no choice.
##
## [b]2 → 3 drops a `bind_style_next` of exactly "Tab".[/b] Tab is the scoreboard now, held,
## and "next style" moved to N; a document stores defaults too, so every player who never
## chose a key has "Tab" written down for it, and keeping that would put two actions on one
## key. A player who chose another key keeps it.
static func migrations() -> Dictionary:
	return {
		1: func(doc: Dictionary) -> Dictionary:
			var out := doc.duplicate(true)
			if out.has("field_of_view") and int(out["field_of_view"]) == 110:
				out.erase("field_of_view")
			return out,
		2: func(doc: Dictionary) -> Dictionary:
			var out := doc.duplicate(true)
			if str(out.get("bind_style_next", "")) == "Tab":
				out.erase("bind_style_next")
			return out,
	}


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

## What a timer server makes a noise about.
##
## Short, and every entry earns its place by telling a runner something they cannot see:
##
## - **the landing**, which is the rhythm of a bunny-hop and the one thing here that is
##   genuinely feedback rather than decoration;
## - **the start, the split and the finish**, which are the run;
## - **a personal best**, which is the only reason anybody is here.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()
	DotAudioStock.add_to(c)

	var land := DotAudioDef.new()
	land.id = &"land"
	land.path = "%s/land.ogg" % SOUND_DIR
	land.bus = &"SFX"
	# Short, because a hop is a hundred and fifty milliseconds and a landing sound that
	# outlasts the next jump is a blur rather than a beat.
	land.cooldown_ms = 60
	land.max_concurrent = 2
	land.priority = 70
	# Pitched by nothing here: the caller passes the speed, because how fast you were
	# going when you landed is the information.
	c.add(land)

	var jump := DotAudioDef.new()
	jump.id = &"jump"
	jump.path = "%s/jump.ogg" % SOUND_DIR
	jump.bus = &"SFX"
	jump.cooldown_ms = 60
	jump.max_concurrent = 2
	jump.priority = 50
	c.add(jump)

	for id in [&"timer_start", &"timer_split", &"timer_finish", &"personal_best"]:
		var d := DotAudioDef.new()
		d.id = id
		d.path = "%s/%s.ogg" % [SOUND_DIR, id]
		d.bus = &"UI"
		# Never refused for a cheaper sound. These four ARE the game.
		d.priority = 100
		d.max_concurrent = 1
		c.add(d)

	# The map vote's cues. Flat, on the interface bus: a ballot is about the server, not
	# about a place on the course. The ids are G2GVote's, which is also what its rules
	# name — one copy.
	for vote_id in [G2GVote.CUE_START, G2GVote.CUE_END, G2GVote.CUE_WARNING, G2GVote.CUE_COUNT]:
		var cue := DotAudioDef.new()
		cue.id = vote_id
		cue.path = "%s/%s.ogg" % [SOUND_DIR, String(vote_id)]
		cue.bus = &"UI"
		cue.max_concurrent = 1
		# Under the timer's four. A vote opening must never cost somebody the sound of
		# their own split.
		cue.priority = 60
		c.add(cue)

	var teleport := DotAudioDef.new()
	teleport.id = &"teleport"
	teleport.path = "%s/teleport.ogg" % SOUND_DIR
	teleport.bus = &"UI"
	teleport.priority = 80
	c.add(teleport)

	# An administrator's beacon: a ping once a second from the beaconed runner, heard by
	# everybody. Positional, because the beacon's whole job is to say WHERE somebody is and
	# a flat ping would say only that somebody somewhere is beaconed; far-reaching, because
	# surf maps are long and a beacon that went quiet at the far end of one would fail in
	# the place it is used. SFX rather than UI, so it is never mistaken for the timer's.
	#
	# Below the timer's four, the landing and the jump in priority. A ping arriving once a second
	# for as long as an admin leaves it on must never take a voice from the rhythm a runner
	# keeps time by — dropping a ping costs a second's reminder, dropping a landing costs
	# a hop.
	var ping := DotAudioDef.new()
	ping.id = BEACON_SOUND
	ping.path = "%s/beacon.ogg" % SOUND_DIR
	ping.kind = DotAudioDef.Kind.POSITIONAL_3D
	ping.bus = &"SFX"
	ping.unit_size = 20.0
	ping.max_distance = 200.0
	ping.max_concurrent = 4
	ping.priority = 40
	# An octave under `timer_start`, which is the same BLIP voice: the one tonal voice in
	# the bank, and a ping has to be a tone to be heard as a place. Half the pitch and from
	# somewhere else is the difference a runner hears; see `sound_recipes`.
	ping.pitch_min = 0.5
	ping.pitch_max = 0.5
	c.add(ping)

	# The flashlight's click, on and off. The quietest and least important thing in the
	# bank — a light switched mid-run must never take a voice from the landing — and pitched
	# well above the split's CLICK, which is the same voice, so the two are never mistaken.
	var light := DotAudioDef.new()
	light.id = FLASHLIGHT_SOUND
	light.path = "%s/flashlight.ogg" % SOUND_DIR
	light.bus = &"SFX"
	light.gain_db = -6.0
	light.pitch_min = 1.6
	light.pitch_max = 1.6
	light.max_concurrent = 1
	light.cooldown_ms = 80
	light.priority = 20
	c.add(light)

	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), shipped in the addon.
	# Under the landing and the timer: a body somewhere on the map must never take a voice
	# from the rhythm a runner keeps time by.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := DotAudioDef.new()
		fall.id = row["id"]
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.kind = DotAudioDef.Kind.POSITIONAL_3D
		fall.bus = &"SFX"
		fall.unit_size = 8.0
		fall.max_distance = 45.0
		fall.max_concurrent = 3
		fall.priority = 35
		fall.gain_db = float(row["gain_db"])
		fall.pitch_min = float(row["pitch_min"])
		fall.pitch_max = float(row["pitch_max"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		c.add(fall)

	return c


## Which synthesised voice stands in for each id until real audio is dropped into
## [constant SOUND_DIR].
##
## [b]A timer game is the one here where sound is part of the input loop rather than
## decoration.[/b] A bunny hop is a rhythm, and the jump and the landing are how a runner
## hears whether they kept it — which is why those two are the shortest and the most
## different-sounding things in this table. Everything else is the clock reporting.
##
## The same restraint as the camera shake this game turns off by default: a long tail on a
## landing would smear the rhythm it is there to mark, so `land` is an impact and not a
## thud with a body.
static func sound_recipes() -> Dictionary:
	return {
		&"land": DotAudioSynth.Voice.IMPACT,
		&"jump": DotAudioSynth.Voice.STEP,
		&"timer_start": DotAudioSynth.Voice.BLIP,
		&"timer_split": DotAudioSynth.Voice.CLICK,
		&"timer_finish": DotAudioSynth.Voice.PICKUP,
		&"personal_best": DotAudioSynth.Voice.SPAWN,
		&"teleport": DotAudioSynth.Voice.DENY,
		# The one exception to "only voices the run does not use", and it is deliberate:
		# BLIP is the only pure tone in the bank, and a beacon is a thing you locate by
		# ear. It shares the voice with `timer_start` an octave down, positional and on the
		# SFX bus, where the start is flat on UI — so it comes from somewhere and the start
		# comes from nowhere, which is the difference that matters mid-run.
		BEACON_SOUND: DotAudioSynth.Voice.BLIP,
		# The split's CLICK at 1.6x and 6 dB down: a switch, which is what a click is. The
		# pitch is what keeps it from reading as a split.
		FLASHLIGHT_SOUND: DotAudioSynth.Voice.CLICK,
		# Only voices the run does not already use. Every one above is part of the input
		# loop, and a ballot opening that sounded like a split — or a countdown tick that
		# sounded like a jump — would be the vote talking over the rhythm this table exists
		# to keep clear.
		G2GVote.CUE_START: DotAudioSynth.Voice.SHOT_TIGHT,
		G2GVote.CUE_END: DotAudioSynth.Voice.DIE,
		G2GVote.CUE_WARNING: DotAudioSynth.Voice.BOOM,
		G2GVote.CUE_COUNT: DotAudioSynth.Voice.SHOT,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}


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
	# (ambience.level) so a timer game's quiet is a breeze, not a wall of wind.
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
	ambience.level = 0.7
	add_child(ambience)
	ambience.set_map_bed(bed_for(&""))

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


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var start := DotFxDef.new()
	start.id = &"start_gate"
	start.scene_path = "%s/start_gate.tscn" % FX_DIR
	start.lifetime_ms = 600
	start.cost = 2
	start.priority = 80
	start.max_distance = 0.0
	c.add(start)

	var finish := DotFxDef.new()
	finish.id = &"finish_gate"
	finish.scene_path = "%s/finish_gate.tscn" % FX_DIR
	finish.lifetime_ms = 1200
	finish.cost = 4
	finish.priority = 90
	finish.max_distance = 0.0
	c.add(finish)

	# A tint on a personal best, off by default with everything else. Somebody who wants
	# a celebration can have one; nobody gets it in the middle of a run they did not ask
	# for it in.
	var best := DotFxDef.new()
	best.id = &"personal_best"
	best.kind = DotFxDef.Kind.SCREEN
	best.flash_peak = 0.18
	best.flash_colour = Color(0.45, 1.0, 0.55)
	best.flash_decay_ms = 500
	c.add(best)

	var land := DotFxDef.new()
	land.id = &"land_shake"
	land.kind = DotFxDef.Kind.SHAKE
	land.shake_trauma = 0.18
	c.add(land)

	return c


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
		ambience.level = wind_level(
			speed * G2GUnits.UNITS_PER_METRE,
			settings.get_float(&"snd_wind_min", 0.3),
			settings.get_float(&"snd_wind_max", 1.1),
			settings.get_float(&"snd_wind_full_speed", 1500.0))


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
