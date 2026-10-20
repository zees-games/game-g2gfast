extends Node

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

signal vote_opened(options: Array, seconds: float)
signal vote_closed(result: DotVoteResult)
signal rocked(voter: StringName, votes: int, needed: int)
signal change_due(id: StringName, choice: DotVoteChoice)

## Something for every client to hear or count: a [code]cue_*[/code] id, or a second of
## the countdown before a ballot. One of the two is empty or zero. The module puts it on
## the wire as [constant G2GEvents.Kind].VOTE.
signal cue_due(cue: StringName, seconds_left: int, runoff: bool)

## The map's time left changed in a way a client counting it down would not have guessed:
## an extend, a new map, a clock stopped for a ballot or started again. [param state] is
## [method DotVoteClockView.state_of]'s. The module puts it on the wire as
## [constant G2GEvents.Kind].CLOCK.
signal clock_due(state: Dictionary)

@export_group("Wiring")

## Whether this instance applies a result.
##
## Off on a client, which mirrors a vote so it can draw the ballot and must never
## change its own map.
@export var authoritative: bool = true

## The file a server owner configures this game's map vote in. Empty skips it.
##
## [b]The rules in [method _rules] are this game's DEFAULTS, not its configuration.[/b]
## They layer the way every [DotConfig] in the family does, so an owner changes a
## number without touching code:
##
## [codeblock]
## _rules()  <  game.yml metadata: map_vote:  <  this file  <  DOT_VOTE_*  <  --vote-*
## [/codeblock]
##
## The file is JSON, keyed exactly as [DotVoteRules] is, enums by name. The end-of-map
## vote and its extend option, which is what an owner usually wants to change:
##
## [codeblock]
## {
##     "end_vote": true,          "vote_lead_sec": 120,
##     "include_extend": true,    "extend_seconds": 600,    "max_extends": 3
## }
## [/codeblock]
##
## [code]DOT_VOTE_EXTEND_SECONDS=900[/code] or [code]--vote-include-extend=false[/code]
## do the same for one run. [code]duration_sec[/code] set here wins over
## [code]map_seconds[/code], which is only the default's source. A result that does not
## validate is refused whole and the defaults stand, with the reason in the log.
@export var config_path: String = "user://cfg/g2gfast_vote.json"

var game: G2GGame = null

var director: DotVoteDirector = null
var source: DotVoteMapSource = null
var commands: DotVoteCommands = null

## `() -> Dictionary`: maps.yml's `commands:` block, so an operator renames the vote commands
## without this game naming any. The module points it at the rotation file.
var commands_spec_fn: Callable = Callable()

var announce_fn: Callable = Callable()
var is_admin_fn: Callable = Callable()

## [code]func(state: Dictionary)[/code]: the ballot as a client draws it, sent whenever it
## changes. The host points it at the client shell (a dot-server notice), which draws a
## menu a player picks from with a number key or a click. Unset sends nothing.
var ballot_fn: Callable = Callable()

## [code]func(voter: StringName) -> Dictionary[/code]: a voter's name and avatar URL.
var people_fn: Callable = Callable()

## What [member ballot_fn] is fed from. Polled once per [method advance].
var feed: DotVoteBallotFeed = null

## What every client was last told about the clock, counted down the way they count it.
## See [method advance].
var clock_view: DotVoteClockView = DotVoteClockView.new()

## Simulated seconds, for [member clock_view]. Never compared with a client's clock.
var _clock_time: float = 0.0


func setup() -> DotResult:
	if game == null or game.maps == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The vote needs a game with a map session."
		)

	# dot-vote's own map source, rather than a subclass. It duck-types the catalogue
	# and the session as [Object]s — which is why dot-vote installs in a project that
	# has never heard of dot-map — and `apply` calls `session.change_to(id)`.
	#
	# [b]The session it is given is the GAME's, not `game.maps`.[/b] It was `game.maps`,
	# and `DotMapSession.change_to` swaps this process's world and tells nobody: a vote
	# moved the server to bhop_fur while every client stayed on surf_mesa, and the
	# respawn that follows a change put each of them at bhop_fur's start — in the sky
	# over a map they were still drawing. `G2GGame.change_map` is what an admin's
	# `g2g_map` and the time limit call: it goes through the map-sync host, which tells
	# the clients, waits for them, and only then swaps.
	# Our subclass of it, which adds the pack's title to a Workshop map's choice.
	source = G2GVoteMapSource.new()
	source.catalogue = game.maps.catalogue
	source.session = GameMaps.new(game)

	if not source.is_usable():
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to vote for.")

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = configured_rules()
	director.source = source
	director.auto_apply = authoritative
	director.begin_on_apply = false
	# The game's tick drives this, not the frame clock: a server that stalls should
	# not lose that time off its map, and a test must be able to run an hour of one in
	# a millisecond.
	director.self_advance = false
	director.register_service = authoritative

	director.player_count_fn = _player_count

	director.voters_fn = func() -> Array:
		var out: Array = []

		for id in _voter_ids():
			out.append(id)

		return out

	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))

	# The ghost is a player in every sense that matters to the rest of this game — it
	# has an id, a rig and a timer — and in no sense that matters to a vote. Counting
	# it would let a one-player server pass a quorum of two, and let it rock the vote
	# on its own.
	director.is_spectator_fn = func(voter: StringName) -> bool:
		return voter == G2GGame.GHOST_ID

	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	director.vote_opened.connect(
		func(options: Array, seconds: float) -> void:
			vote_opened.emit(options, seconds)
	)
	director.vote_closed.connect(
		func(result: DotVoteResult) -> void: vote_closed.emit(result)
	)
	director.rocked.connect(
		func(voter: StringName, votes: int, needed: int) -> void:
			rocked.emit(voter, votes, needed)
	)
	director.change_due.connect(
		func(id: StringName, choice: DotVoteChoice) -> void:
			change_due.emit(id, choice)
	)

	# Two signals, two messages: dot-vote emits a countdown second and that second's cue
	# separately, and merging them here would be this file deciding which cue belongs to
	# which second.
	director.cue.connect(
		func(id: StringName) -> void: cue_due.emit(id, 0, false)
	)
	director.countdown_tick.connect(
		func(seconds_left: int, runoff: bool) -> void:
			cue_due.emit(&"", seconds_left, runoff)
	)

	feed = DotVoteBallotFeed.of(director, func(state: Dictionary) -> void:
		if ballot_fn.is_valid():
			ballot_fn.call(state)
	)
	feed.title = "Vote for the next map"
	feed.people_fn = func(voter: StringName) -> Dictionary:
		return people_fn.call(voter) if people_fn.is_valid() else {}

	# Whatever the server booted on, so the clock starts and the history has an entry.
	game.maps.changed.connect(_on_map_changed)

	if game.maps.current != null:
		director.begin(game.maps.current.id)

	return DotResult.success(self)


## [method _rules], with the server owner's layers over it. See [member config_path].
func configured_rules() -> DotVoteRules:
	var rules := _rules()
	var layered := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)

	if not layered.ok:
		# Loud and not fatal: a server that refused to start over its vote file would be
		# one an operator cannot get back. This one runs on its tested defaults.
		DotLog.error(CHANNEL, "the map vote configuration is not usable; using the defaults", {
			"path": config_path,
			"why": layered.error.message,
			"detail": layered.error.detail,
		})

	# Nothing in this game reports a round end or a leading score to the vote, so a
	# `trigger: round_end` or a score limit in an operator's file would validate and then
	# wait for ever — and with the map's own clock handed to the vote, the map never ends.
	var unfed := rules.drop_unfed(false, false)
	if not unfed.is_empty():
		DotLog.error(CHANNEL, "the map vote configuration asks for what this game cannot drive; ignored", {
			"path": config_path, "ignored": ", ".join(unfed),
		})

	return rules


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
func _player_count() -> int:
	return _voter_ids().size()


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


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)

	if feed != null:
		feed.poll()

	_clock_time += delta

	# [b]Sent when a client's own count would be wrong, not every second.[/b] Both ends
	# count with `DotVoteClockView`, so the server knows exactly what every client is
	# showing and only an extend, a new map or a stopped clock is worth a message.
	if clock_view.is_stale(director, _clock_time):
		clock_view.adopt(clock_state(), _clock_time)
		clock_due.emit(clock_view.to_state())


## The map's time left as a client should show it: the VOTE's clock, which is the one that
## ends a map here, and no clock at all when the vote has none.
func clock_state() -> Dictionary:
	return DotVoteClockView.state_of(director)


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


func is_voting() -> bool:
	return director != null and director.is_voting()


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


func timeleft_line() -> String:
	return director.clock.timeleft_line() if director != null else "-"


func next_map() -> String:
	if director == null:
		return "-"

	var pending := director.pending_id()
	return String(pending) if pending != &"" else String(director.next_in_rotation())


## dot-vote's commands, on [param host] — the module, so they go when it does.
##
## [b]The only vote commands here, and that is the point.[/b] This game registered its
## own `rtv`, `nominate`, `nextmap` and `timeleft`, answered `!rtv` and `!vote` again in
## the chat handler, and had none of dot-vote's operator commands — `setnextmap`,
## `nominate_addmap`, `forcertv`, `votereload`. Worse, its console `rtv` went to the map
## session's own time limit, not to this director at all, so `rtv` typed at the console
## and `!rtv` typed in chat were two different votes. Voters are `u<userid>`, which is
## dot-vote's default and this game's player id.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES.duplicate()
	commands.spec_fn = commands_spec_fn

	var bound := commands.bind(host)

	if feed != null:
		feed.command = commands.command_name("vote")

	return bound


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"voters": _player_count(),
		"director": director.describe() if director != null else {},
	}


## What [DotVoteMapSource] reads a session for — the current map, and a way to change it —
## answered by the game, so that a vote changes the map the way everything else does.
## See [method setup].
class GameMaps extends RefCounted:
	var game: Node = null

	var current: Variant:
		get:
			return game.maps.current if game != null and game.maps != null else null

	func _init(p_game: Node) -> void:
		game = p_game

	func change_to(id: StringName) -> DotResult:
		return await game.change_map(id)
