extends Node

## The sound recipes and effects catalogue of G2GPresentation, with the ids they name.
## No class_name; scripts keep using G2GPresentation.

const G2GPaths := preload("g2g_paths.gd")
const G2GVote := preload("g2g_vote.gd")

## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"

## The flashlight's switch. See [method sound_catalogue].
const FLASHLIGHT_SOUND := &"flashlight"

static var FX_DIR := G2GPaths.rebase("res://scenes/fx")


## Which synthesised voice stands in for each id until real audio is dropped into SOUND_DIR.
## Sound is part of this game's input loop, so the jump and landing are the shortest voices,
## and `land` is an impact, not a thud with a tail that would smear the rhythm.
static func sound_recipes() -> Dictionary:
	return {
		&"land": DotAudioSynth.Voice.IMPACT,
		&"jump": DotAudioSynth.Voice.STEP,
		&"timer_start": DotAudioSynth.Voice.BLIP,
		&"timer_split": DotAudioSynth.Voice.CLICK,
		&"timer_finish": DotAudioSynth.Voice.PICKUP,
		&"personal_best": DotAudioSynth.Voice.SPAWN,
		&"teleport": DotAudioSynth.Voice.DENY,
		# The one voice the run also uses: BLIP is the only pure tone, and a beacon is located by ear.
		# Positional on the SFX bus, where the start is flat on UI.
		BEACON_SOUND: DotAudioSynth.Voice.BLIP,
		# A switch, which is what a click is; the pitch keeps it from reading as a split.
		FLASHLIGHT_SOUND: DotAudioSynth.Voice.CLICK,
		# Only voices the run does not use, so a ballot never sounds like a split or a jump.
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

	# A tint on a personal best, off by default like everything else.
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
