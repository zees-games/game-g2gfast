extends "g2g_presentation_catalogue.gd"

## The settings schema, its migrations and the sound catalogue of G2GPresentation.

const G2GBindings := preload("g2g_bindings.gd")

## 2: `field_of_view` is applied now, and every document written before carries the old
## default of 110 that nothing ever read. 3: Tab is the scoreboard, and "next style" moved
## off it. See [method migrations].
const SCHEMA_VERSION := 3
const SOUND_DIR := "res://audio"



static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	# The audio, window, frame rate, sensitivity and theme are dot-menu's stock settings, declared
	# at the end; what is declared first wins, which keeps this game's defaults (no shake, no flash).
	# `raw_input` is gone (nothing applied it); a stored value stays in the document's unknown half.

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
	_schema_hud(s)
	_schema_chat(s)
	_schema_video(s)
	_schema_accessibility(s)
	G2GBindings.make().add_to_schema(s)
	_schema_audio(s)

	# Everything else a game has: volumes, the window, the frame rate, the mouse, the theme.
	return DotMenuStock.declare(s)


## The timer layout, status and dragged-HUD settings.
static func _schema_hud(s: DotSettingsSchema) -> void:
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


## The chat keys and settings.
static func _schema_chat(s: DotSettingsSchema) -> void:
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


## Field of view and the own body.
static func _schema_video(s: DotSettingsSchema) -> void:
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


## Shake, flashes and reduced motion.
static func _schema_accessibility(s: DotSettingsSchema) -> void:
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


## Sound levels declared before the stock set so these defaults win.
static func _schema_audio(s: DotSettingsSchema) -> void:
	# [b]Effects at 0.6, not the stock 1.0 (fgr-g2g-audio-1).[/b] The landing on every hop and
	# the footsteps sat on top of the bed and the timer's cues at full level, which a runner
	# hears hundreds of times a minute. Declared before the stock set so it is the one kept;
	# a player who wants the old level still has the slider.
	s.add(DotSettingsDef.number(&"sfx_volume", 0.6, 0.0, 1.0, &"audio"))
	# The wind and birdsong bed is off until a player turns it up: a runner listens for the
	# landings and the timer. Still a slider (Audio page), and Effects scales it as well.
	s.add(DotSettingsDef.number(&"ambience_volume", 0.0, 0.0, 1.0, &"audio"))
	# The wind is the speedometer's second half: the bed's level runs from `snd_wind_min` at
	# a standstill to `snd_wind_max` at `snd_wind_full_speed` genre units a second, linearly,
	# so a slow walk is a breeze and a surf at 3000 is a roar. Settings, so each one is a cvar.
	s.add(DotSettingsDef.number(&"snd_wind_min", 0.3, 0.0, 2.0, &"audio").with_description(
		"Bed level when standing still."))
	s.add(DotSettingsDef.number(&"snd_wind_max", 1.1, 0.0, 2.0, &"audio").with_description(
		"Bed level at snd_wind_full_speed."))
	s.add(DotSettingsDef.number(&"snd_wind_full_speed", 1500.0, 100.0, 5000.0, &"audio").with_description(
		"Horizontal speed in units per second at which the bed reaches snd_wind_max."))


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
