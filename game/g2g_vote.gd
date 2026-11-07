extends DotVoteTimedGame

const G2GGame := preload("g2g_game.gd")
const G2GVoteMapSource := preload("g2g_vote_map_source.gd")

## What plays next, decided by the players, with the genre's own rules.
##
## [b]This game already had a rock-the-vote and it was not one.[/b]
## `G2GGame.rock_the_vote` forwards to [DotMapTimeLimit], which counts rtv votes
## against a fraction and expires the map — a countdown and a tally and nothing else.
## What a records community actually runs is a ballot: nominations with caps,
## seconding, an instant runoff so a six-option vote is not won by a fifth of the
## server, a cooldown so `bhop_g2g_intro` does not come round twice in three maps, and
## an extend option so a map nobody has finished yet is not cut off.
##
## dot-vote is fifty-five settings' worth of exactly that, and none of it is restated
## here. What this file is, is the four callables that say who the players are, plus
## one rule about who calls [method DotVoteDirector.begin].
##
## [b]`begin_on_apply` is off, and getting it wrong halves every cooldown.[/b] The
## director can announce a change it just made, and so can the host through the map
## session's own `changed` — which is the one that has to be connected, because it also
## fires for an admin typing `g2g_map`. Both firing means two entries in the play
## history for one play, and a "not in the last five maps" cooldown that is quietly two
## or three. dot-vote found that by running inside a real host, which is the only place
## it is visible.
##
## [codeblock]
## var vote := G2GVote.new()
## vote.game = game
## add_child(vote)
## vote.setup()
## vote.announce_fn = func(line: String) -> void: services.announce(line)
## [/codeblock]

const CHANNEL := "g2g.vote"

## The key in the running game's descriptor metadata an operator's overrides are read
## from — [code]metadata: map_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "map_vote"

## The vote's sound cues, as ids in [code]G2GPresentation.sound_catalogue()[/code]. One
## copy: the rules name them and the catalogue defines them, both from here.
const CUE_START := &"vote_start"
const CUE_END := &"vote_end"
const CUE_WARNING := &"vote_warning"
const CUE_COUNT := &"vote_count"

## What dot-vote's commands are called here. `vote` rather than dot-vote's `votefor`,
## because `!vote 2` is what this game's chat has always answered.
const COMMAND_NAMES := {"vote": "vote"}


## Wiring: whether this process decides (applies a winner and registers the vote service) or only keeps a clock for a client.
@export var authoritative: bool = true

var game: G2GGame = null


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "map"
	config_path = "user://cfg/g2gfast_vote.json"
	# The ids are `u<n>`, a session's own spelling: dot-vote's default for a voter.
	bare_voter_ids = false


func setup() -> DotResult:
	if game == null or game.maps == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The vote needs a game with a map session."
		)

	auto_apply = authoritative
	register_service = authoritative

	var built := super.setup()

	if not built.ok:
		return built

	# Whatever the server booted on, so the clock starts and the history has an entry.
	game.maps.changed.connect(_on_map_changed)

	if game.maps.current != null:
		director.begin(game.maps.current.id)

	return built


## The session is the GAME's, not game.maps: change_map goes through the map-sync host, which tells the clients;
## DotMapSession.change_to swaps this process's world alone. Our subclass of dot-vote's source adds the pack's title to a Workshop map's choice.
func _make_source() -> DotVoteSource:
	var maps_source := G2GVoteMapSource.new()
	maps_source.catalogue = game.maps.catalogue
	maps_source.session = GameMaps.new(game)
	return maps_source if maps_source.is_usable() else null


func _configure_director(d: DotVoteDirector) -> void:
	# The ghost is a player in every sense that matters to the rest of this game — it
	# has an id, a rig and a timer — and in no sense that matters to a vote. Counting
	# it would let a one-player server pass a quorum of two, and let it rock the vote
	# on its own.
	d.is_spectator_fn = func(voter: StringName) -> bool:
		return voter == G2GGame.GHOST_ID


## The rules a records server votes by.
##
## [b]Instant runoff, and a per-map time limit.[/b] The second is the one dot-vote
## built [member DotVoteChoice.time_limit_sec] for and it is this genre's own problem:
## forty minutes of `surf_kitsune` and ten minutes of a three-stage bhop intro are not
## the same number, and a server that gives them the same one either rushes the first
## or bores everybody through the second. A map def carries it in `meta.vote`.
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()

	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	# Two and a half minutes: a ballot, a runoff and the result all fit with room to spare.
	rules.vote_lead_sec = 150.0
	rules.duration_sec = maxf(game.config.map_seconds, 300.0)
	rules.vote_duration_sec = 30.0
	rules.method = DotVoteRules.Method.INSTANT_RUNOFF
	rules.tie_break = DotVoteRules.TieBreak.LEAST_RECENTLY_PLAYED
	rules.max_options = 6

	# Extending matters more here than anywhere else in this family: a player two
	# stages into a run they have been learning for an hour should not lose the map to
	# a clock. Three extends of ten minutes is the ceiling.
	rules.include_extend = true
	rules.extend_seconds = 600.0
	rules.max_extends = 3
	rules.extend_resets_rtv = true

	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	# Two minutes, measured from when the map started. Without it a player who does
	# not like the map can rock the vote before anybody has left the start pad.
	rules.rtv_delay_sec = 120.0

	rules.nominations_enabled = true
	rules.nomination_seconding = true
	rules.nomination_slots = 3

	# Immediately. A timer server has no rounds to end on, and "at the end of the
	# round" on a game with none is a change that never happens — which is the shape
	# of every setting this family has found that reads correctly and decides nothing.
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.apply_delay_sec = 5.0

	rules.cooldown = 5
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	# Capped against the pool, so a five-map cooldown on a three-map catalogue does
	# not leave nothing to offer. dot-vote applies it; naming it here is what makes it
	# a decision rather than a default nobody read.
	rules.cooldown_max_fraction = 0.5

	# The ids G2GPresentation's catalogue plays. dot-vote ships every cue empty and names
	# no audio class; this game has a catalogue, so it has something to name. No
	# countdown before the ballot: a runner is not in a fight, and a ballot that waits ten
	# seconds is ten seconds off a two-minute lead for nothing.
	rules.cue_vote_start = String(CUE_START)
	rules.cue_vote_end = String(CUE_END)
	rules.cue_warning = String(CUE_WARNING)
	rules.cue_runoff_warning = String(CUE_WARNING)
	rules.cue_countdown = String(CUE_COUNT)

	return rules


## How many players there are, for every threshold in the rules.
##
## [b]Not `game.players.size()`.[/b] That counts the record ghost, which is a
## [G2GPlayer] with a replay and no peer — so on an empty server the rtv fraction
## would be measured against one player who cannot vote, and a quorum of two would be
## reached by nobody.


func _voters() -> Array:
	return _voter_ids()


func _voter_ids() -> Array[StringName]:
	var out: Array[StringName] = []

	if game == null:
		return out

	for id in game.players.keys():
		if id == G2GGame.GHOST_ID:
			continue

		# Bots neither vote nor count: a bot in the count raised every threshold out of the
		# humans' reach, and one that counted the other way would let a lone player pass a
		# vote "of two". Keyed `u<n>` like a session, so the flag is the only tell.
		var player: Variant = game.players[id]
		if player is Object and is_instance_valid(player) and bool((player as Object).get("is_bot")):
			continue

		out.append(id)

	return out


## Tells the director what is running, after a change from ANY cause.
##
## The one call site. See the class note on `begin_on_apply`.


func _on_map_changed(map: DotMapDef, _world: Node) -> void:
	if director != null and map != null:
		director.begin(map.id)


func rock_the_vote(voter: StringName) -> DotResult:
	return (
		director.rock_the_vote(voter) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func nominate(voter: StringName, id: StringName) -> DotResult:
	return (
		director.nominate(voter, id) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func cast_one(voter: StringName, choice: StringName) -> DotResult:
	return (
		director.cast_one(voter, choice) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func timeleft_line() -> String:
	return director.clock.timeleft_line() if director != null else "-"


func next_map() -> String:
	if director == null:
		return "-"

	var pending := director.pending_id()
	return String(pending) if pending != &"" else String(director.next_in_rotation())


func _describe_extra() -> Dictionary:
	return {"authoritative": authoritative, "voters": _player_count()}


class GameMaps extends RefCounted:
	var game: Node = null

	var current: Variant:
		get:
			return game.maps.current if game != null and game.maps != null else null

	func _init(p_game: Node) -> void:
		game = p_game

	func change_to(id: StringName) -> DotResult:
		return await game.change_map(id)
