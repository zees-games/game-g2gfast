extends Node3D

const G2GAvatars := preload("g2g_avatars.gd")
const G2GBspMap := preload("g2g_bsp_map.gd")
const G2GCamera := preload("g2g_camera.gd")
const G2GCombat := preload("g2g_combat.gd")
const G2GConfig := preload("g2g_config.gd")
const G2GEffects := preload("g2g_effects.gd")
const G2GEvents := preload("net/g2g_events.gd")
const G2GHunters := preload("g2g_hunters.gd")
const G2GMap := preload("g2g_map.gd")
const G2GMapCatalogue := preload("g2g_map_catalogue.gd")
const G2GMapMechanics := preload("g2g_map_mechanics.gd")
const G2GMovement := preload("g2g_movement.gd")
const G2GPaths := preload("g2g_paths.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GPlayerStack := preload("g2g_player_stack.gd")
const G2GProgress := preload("g2g_progress.gd")
const G2GProps := preload("g2g_props.gd")
const G2GReplays := preload("g2g_replays.gd")
const G2GSpectate := preload("g2g_spectate.gd")
const G2GUnits := preload("g2g_units.gd")

## g2gfast: the simulation. Maps, timers, styles, records, and every player.
##
## [b]A bunny-hop and surf server in the competitive-shooter shape[/b]: the genre's
## movement cvars in the genre's units, a timer with zones an admin draws from the console, styles,
## a records table, and a rotation. Runs headless as a dedicated server and is what a
## client draws.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## [b]What is this game's own, versus the addons'.[/b] Every rule about movement lives
## in dot-player-controller, every rule about timing in dot-timer, maps in dot-map,
## records in dot-leaderboard. What this file adds is the joins — the tick order, the
## unit boundary, the moment a cvar change reaches thirty players — and the joins are
## where every bug in this family has been.

const CHANNEL := "g2g"

## The registry name a dot-server module finds this under.
const SERVICE := &"g2g_game"

## The ghost's player id. Session ids are dot-server userids, which never get
## this large; the bridge treats it as a session like any other.
const GHOST_ID := &"u900000001"
const GHOST_SESSION := 900000001

signal map_ready(map: DotMapDef)

## The map catalogue was re-read from the disk. Carries `added`, `removed`, `total`.
signal maps_rescanned(change: Dictionary)
signal run_filed(player_id: StringName, run: DotTimerRun, rank: int, reason: String)

## Where a player stands on the board they are on: [code]{pb, wr, rank, total}[/code],
## seconds and places, 0 for "none". The HUD's standing line, and what the net bridge
## sends to that player's client — a client has no store to ask.
signal standing_changed(player_id: StringName, standing: Dictionary)

## The last standing worked out per player. See [method board_fields].
var _standings: Dictionary = {}

## What a staged map's splits panel compares a player against changed: their personal best
## and the record as cumulative splits, and their best time per section. The shape is
## [method stage_reference]'s. Emitted after a spawn, a style change and a filed run or
## section, never per tick; the net bridge sends it to that player alone, because a client
## has no store to ask.
signal stage_reference_changed(player_id: StringName, reference: Dictionary)

## Something worth saying about a finish. [param everyone] for a new record, which the
## whole server hears; otherwise only [param player_id].
signal announced(player_id: StringName, text: String, everyone: bool)

## The movement changed under everybody — a cvar, or a config reload.
signal movement_changed(config: G2GConfig)

## A player the game created itself — a ghost — or one a caller added. A netcode
## bridge adopts the former as a bot.
signal player_added(player: G2GPlayer)
signal player_removed(player_id: StringName)

@export var config: G2GConfig = null

## A JSON file layered over [member config]'s defaults, or empty.
@export var config_file: String = ""

## Fallback tick rate when nothing has told the engine. A dot-server always has.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process — the
## shape every headless netcode test in this family takes.
@export var service_scope: StringName = &""

## The dot-cloud client to fetch a missing map through, by registry name.
##
## [b]Looked up rather than exported as a node, and optional.[/b] A map is content and
## the browser build no longer carries any: `maps/imported/` is excluded from the web
## export, because shipping sixty-six megabytes of maps to every player so that most of
## them can play one is the opposite of a delivery network. A build that DOES carry its
## maps -- a dedicated server run from source, every headless suite -- finds them in
## [constant G2GMapCatalogue.IMPORTED_ROOTS] and never reaches this.
##
## Empty, or a registry with nothing under it, is not an error. It means this build can
## only play maps it already has, which is exactly what a server run from source is.
@export var map_content_service: StringName = &"dot_cloud_client"

## The dot-server game manager to read a loading game's descriptor from, by registry name.
## See [method _adopt_descriptor_owner]. Nothing under it is normal: a suite, a client.
@export var game_manager_service: StringName = DotGameManager.SERVICE

## Content ids already fetched and registered, so a rotation that comes back round does
## not ask dot-cloud again. dot-cloud is itself idempotent; this saves the await.
var _map_content_seen: Dictionary = {}

## Maps the game's descriptor names in `maps:`, pinned by the server's installer:
## map id -> [content id, version]. See [method _adopt_descriptor_maps].
var _pinned_maps: Dictionary = {}

## Map ids offered on M although this build has not fetched them: choosing one downloads it
## (see [method ensure_map_content]). A solo game in the browser sets it ([G2GSoloMaps]);
## empty everywhere else, so desktop and servers list what they hold.
var offered_maps: PackedStringArray = PackedStringArray()

## Whether [method fetch_content_maps] is already sweeping the configured set.
var _fetching_content_maps: bool = false

var authoritative: bool = true

## What the loaded map's brush entities do to a player (water, pushes, sinking blocks...).
## Built from the manifest on every map change, on both ends: the client predicts with it.
var mechanics: G2GMapMechanics = null

## The server's maps.yml, or null when there is none. See [method load_rotation].
var rotation_file: DotMapRotationFile = null

## Where [member rotation_file] was read from, or "" when there was no file.
var rotation_source: String = ""

var maps: DotMapSession = null

## The map-change protocol's host half, when this game has clients to take with it.
##
## Set by [code]G2GNetBridge[/code] on a server, and null everywhere else — offline, on a
## client, in every suite that runs a game without a network. [method change_map] goes
## through it when it is set, so a map change is ANNOUNCED, waited on and then made,
## rather than made here and reported afterwards. Every way a map changes on a server —
## `map`, `g2g_map`, the vote, the rotation's clock — already calls [method change_map],
## which is why this is the one line that needed to know.
var map_sync: DotMapSyncHost = null

## Whether the map session's own clock running out changes to the rotation's next map.
##
## On for a server with no vote, where that clock is the only thing that ever ends a map.
## Off once [code]G2GModule[/code] has a ballot: the vote's clock is then the one that
## ends a map, and both acting was a map the players voted to extend being ended on the
## old clock, by a rotation nobody asked.
var rotation_ends_maps: bool = true

## The clock that ends a map, as [method DotVoteClockView.state_of] describes it. Set by
## [code]G2GModule[/code] to its vote's [code]clock_state[/code]; unset on a server with
## no vote, where the map session's own clock is the one that ends a map.
##
## [b]A Callable rather than the vote, because the game does not know the vote exists[/b]
## — the module builds it, over this game, and a game holding the thing built on top of it
## is the dependency pointing the wrong way. It is read by [method time_left_text], which
## is what `g2g_status` says: that line read the map session's clock after the vote had
## taken the map's end over, so an operator was shown a limit an extend had already moved,
## and under `trigger: rtv_only` a limit the server did not have at all.
var clock_fn: Callable = Callable()
var timers: DotTimerManager = null
var boards: DotLeaderboardManager = null
var world: Node3D = null

## The tunables every player is on, before their style. Rebuilt on a cvar change.
var tunables: DotFpsTunables = null

## Movement halves of the styles, by id. The ranking halves are on the timer manager.
var movement_styles: Dictionary = {}

## The avatar schema and catalogue every rig is dressed from.
var avatar_schema: DotAvatarSchema = null
var avatar_catalogue: DotAvatarCatalogue = null

var players: Dictionary = {}

## The best replay per map, track and style. What the ghost plays.
var replays: G2GReplays = G2GReplays.new()

## The deathmatch half. Null unless `sv_deathmatch` built it.
##
## [b]A layer, not a mode switch on the game.[/b] While it exists the timer still runs
## and a player who never presses fire plays exactly the game they played before —
## which is the only shape a deathmatch on a records server can honestly take.
## Every world object the server has an id for. See [DotEntityTable].
##
## [b]Here rather than on [code]combat[/code], which is where the ids are minted.[/b]
## The table outlives the deathmatch layer -- `sv_deathmatch` is a cvar an operator
## turns off mid-map -- and the hunters and the effects layer both ask it questions
## without going through combat at all. A handle whose lifetime is shorter than its
## holders' is the shape that leaks.
var entities := DotEntityTable.new()

var combat: G2GCombat = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. On the game, not on [member combat]: a client
## has no combat layer and still draws every fall.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## Hunters on the course. Null unless `sv_hunters` built them.
var hunters: G2GHunters = null

## How good the hunters are, server-wide: `npc_skill`, `npc_reaction_scale`,
## `npc_reaction_min`. On the game rather than on [member hunters], which is null until
## `sv_hunters` builds it and is rebuilt on a map change; the module binds the cvars and
## the hunters attach this to each spawner they make.
var npc_skill: DotNpcAiSkill = DotNpcAiSkill.new()

## Props an admin can place. Null unless `sv_props` built them.
var props: G2GProps = null

## The server's bots (`g2g_bots.gd`): built on every authoritative game, idle until something
## adds one (`G2GModule` from `bot_quota`). Untyped and loaded by path, never preloaded: it
## brings dot-bot's surf classes with it, and a client never needs them.
var bots: Node = null

## Watching somebody run, which on a timer server is the point rather than a
## consolation for being dead. Built in every configuration.
var spectate: G2GSpectate = null

## Status effects, with the one rule that makes them safe here: a movement effect is a
## style, and a style you did not choose is a record you did not set. See [G2GEffects].
var effects: G2GEffects = null

## Statistics and achievements. Null on a client, and on a server that keeps none.
##
## [b]Authority only.[/b] A mirroring client sees every finish replicated to it, and
## counting them there would file everybody's runs a second time in a place the server
## never reads — and let a modified client award itself achievements. The numbers
## belong to whoever decides whether a run counted.
var progress: G2GProgress = null

## Who is in the session, which side, what class, where they start, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: the timers
## still time, the boards still rank. What it does is keep one set of records in step,
## so a scoreboard, a spectator seat and a start selector read the same thing rather
## than three dictionaries that agree until somebody reconnects. See [G2GPlayerStack].
var player_stack: G2GPlayerStack = null

var _samples: Dictionary = {}
var _tick: int = 0
var _accumulator: float = 0.0

## Whether something else drives the tick — a net bridge, whose tick has to happen
## between dot-net applying inputs and building the snapshot. See [G2GNetBridge].
var external_tick: bool = false

## Asked once a tick: true while the client's load gate holds the world still. See [method is_covered].
var covered: Callable = Callable()


## dot-player-controller's `mp_forceview`: whether a player may switch to third person
## (0), or is held in first (1) or third (2). `sv_allow_thirdperson`, this game's own older
## switch, writes it (0 is first only); bound REPLICATED by the module and followed by a
## client through its link, on top of RULES' `thirdperson` for an older server.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()


## Every camera under the view rules now, and the config's switch kept in step.
func _on_view_rules_changed() -> void:
	config.allow_thirdperson = view_rules.allows_third()
	for id in players:
		var p: G2GPlayer = players[id]
		if p.camera != null:
			p.camera.follow_view_rules(view_rules)


func _ready() -> void:
	if config == null:
		config = G2GConfig.new()
	if not view_rules.changed.is_connected(_on_view_rules_changed):
		view_rules.changed.connect(_on_view_rules_changed)

	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.error(CHANNEL, "the g2gfast configuration is not usable", {
			"why": loaded.error.message
		})

	authoritative = config.authoritative
	tick_rate = _resolve_tick_rate()
	# Snapped to float32 before anything derives from it: that is the precision
	# the wire carries, and a server has to move its players with the values its
	# clients were sent. See [method G2GConfig.snap_movement].
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	DotRegistry.register(DotRegistry.scoped_name(SERVICE, service_scope), self)

	DotLog.info(CHANNEL, "g2gfast starting", {
		"config": config.describe_summary(),
		"tick_rate": tick_rate,
		"authoritative": authoritative,
	})

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	avatar_schema = G2GAvatars.schema()
	avatar_catalogue = G2GAvatars.catalogue()

	_build_styles()
	_build_boards()
	_build_timers()
	_build_progress()
	_build_layers()
	_build_maps()
	_build_player_stack()

	if authoritative:
		await _open_records_store()
		await retire_legacy_records()

	set_physics_process(true)

	if config.initial_map != &"":
		_adopt_descriptor_owner()
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)


## Takes [member G2GConfig.map_content_owner] from the descriptor of the game dot-server is
## loading this scene for, before the first map is fetched.
##
## [b]The first fetch happens before the cvar that names the owner exists.[/b] dot-server
## instantiates this scene, and this `_ready` starts on the first map, before it applies the
## descriptor's `cvars:`; `sv_map_content_owner` belongs to this game's module, which a host
## loads after the scene is up, so it is only applied on the host's second pass. Without
## this the boot map was fetched from the unowned path (`surf_mesa` instead of
## `gamemann/surf_mesa`) and only worked while an origin still carried the legacy pack.
## The descriptor is already known while the scene is being built (it is the manager's
## pending game), so the one value the boot fetch depends on is read from there. The
## module's pass later sets the same value, so nothing disagrees afterwards.
func _adopt_descriptor_owner() -> void:
	if not authoritative:
		return

	var manager: Object = DotRegistry.get_service(game_manager_service)

	if manager == null:
		return

	var descriptor: Object = _descriptor_for_this_scene(manager)

	if descriptor == null:
		return

	_adopt_descriptor_maps(descriptor)

	var cvars: Dictionary = descriptor.get("cvars")

	if not cvars.has(G2GConfig.MAP_CONTENT_OWNER_CVAR):
		return

	config.map_content_owner = str(cvars[G2GConfig.MAP_CONTENT_OWNER_CVAR]).strip_edges()
	DotLog.info(CHANNEL, "the map owner comes from the game's descriptor", {
		"owner": config.map_content_owner,
	})


## Takes the map set from the descriptor's `maps:` list, when the server has one.
##
## [b]The list used to be this game's own cvars[/b] -- `sv_content_maps` and an owner --
## fetched at whatever version each pack's origin called latest, on whichever day a box
## happened to boot. dot-server now carries a game's delivered maps as pinned
## `<owner>/<map id>@<version>` keys (DotGameDescriptor.maps), written by the installer
## that checked each one exists, so every server running one release of this game offers
## the same bytes. A server whose dot-server predates the field has no `maps` property;
## `get` answers null and the cvars still work as they always did.
func _adopt_descriptor_maps(descriptor: Object) -> void:
	var keys: Variant = descriptor.get("maps")

	if not (keys is PackedStringArray) or (keys as PackedStringArray).is_empty():
		return

	var ids := PackedStringArray()

	for key in (keys as PackedStringArray):
		var map := DotMapDef.from_content_key(key)

		if map == null:
			DotLog.warn(CHANNEL, "a maps: entry is not <owner>/<map>@<version>", {"entry": key})
			continue

		_pinned_maps[map.id] = [String(map.content_id), map.content_version]
		ids.append(String(map.id))

	config.content_maps = ids
	DotLog.info(CHANNEL, "the map set comes from the game's descriptor", {"maps": ids.size()})


## The descriptor this scene is being built for: the manager's pending game, or, when
## dot-server is putting the [i]previous[/i] game back because the pending one's scene was
## missing, its current one. In that restore the pending descriptor is the game that
## failed, so reading it would boot the restored game with another game's owner (or none).
## A descriptor is this scene's when its scene path is ours; a path either side cannot
## compare (a uid, a scene built with no file) is taken as ours.
func _descriptor_for_this_scene(manager: Object) -> Object:
	for method in [&"pending", &"current"]:
		if not manager.has_method(method):
			continue

		var descriptor: Variant = manager.call(method)

		if not (descriptor is Object) or not (descriptor.get("cvars") is Dictionary):
			continue

		var theirs := ""
		if descriptor.has_method("resolve_scene_path"):
			theirs = str(descriptor.call("resolve_scene_path"))

		if theirs.begins_with("res://") and scene_file_path.begins_with("res://") \
				and theirs != scene_file_path:
			continue

		return descriptor

	return null


## Stands up the player-facing addons and binds them to this game.
##
## After the layers and the maps, because it reads the spectator manager the layers
## built and the start points the map session will load — and a stack built before any
## of that binds to nothing and reports success.
func _build_player_stack() -> void:
	player_stack = G2GPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors the server's rate; re-applying a profile there would have it
	# simulate at a rate the server does not, which on a timer server is the difference
	# between a run that validates and one that does not.
	player_stack.apply_physics = authoritative
	add_child(player_stack)

	var res := player_stack.setup(self)

	if not res.ok:
		DotLog.warn(CHANNEL, "the player stack is off", {"why": res.error.message})
		remove_child(player_stack)
		player_stack.queue_free()
		player_stack = null


## The engine's rate when a server has set it, else the export. See game-playground.
func _resolve_tick_rate() -> int:
	return Engine.physics_ticks_per_second if Engine.physics_ticks_per_second > 0 else tick_rate


## Counts at [param rate] ticks a second from now on. Returns whether it changed.
##
## [b]A client's rate is the SERVER's, and it does not come from the engine.[/b]
## `_resolve_tick_rate` reads `Engine.physics_ticks_per_second`, which on a server is
## `sv_tickrate` and on a client is whatever the host project exported — 128 here, 60
## in a project that never set it. So a client left on its own number simulates at a
## rate the server does not, and since `1.0 / tick_rate` is the step prediction
## replays with and the divisor every replicated run time is reconstituted through, a
## client on 60 against a server on 128 shows times wrong by that ratio while
## everything else looks healthy. [G2GNetBridge] calls this from HELLO, which has
## carried the server's rate since it was written.
##
## Every run in progress is abandoned, by [method DotTimerManager.set_tick_rate]'s own
## rule: a run half at one rate and half at another is a run at neither. That costs
## nothing here, because this is called before a client has a player.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	timers.set_tick_rate(rate)
	# Read back rather than assigned: the timer manager clamps, and two copies of
	# this number that disagree is the failure the whole method exists to prevent.
	tick_rate = timers.tick_rate

	for id in players:
		(players[id] as G2GPlayer).tick_rate = tick_rate

	DotLog.info(CHANNEL, "tick rate adopted", {"tick_rate": tick_rate})
	return true


# --- Building --------------------------------------------------------------

func _build_styles() -> void:
	for style in DotFpsStyle.defaults():
		# Prespeed limits are in genre units here, like everything a style says to
		# an operator. 290 u/s is the number every timer in this genre ships.
		style.prespeed_limit = 290.0

		# [b]The SERVER decides auto-hop, not the style.[/b] The shipped styles force
		# it on, which is right for a game with no cvar and wrong here: with the
		# style overriding the base, `sv_autobunnyhopping 0` reached every player's
		# tunables and was then undone by the style on top — silently, and the
		# integration suite caught it as a held key still hopping. Every style
		# inherits, except the one whose whole identity is "no auto-hop".
		if style.id != &"prebhop":
			style.auto_hop = DotFpsStyle.Toggle.INHERIT
			style.easy_bhop = DotFpsStyle.Toggle.INHERIT

		movement_styles[style.id] = style


func _build_boards() -> void:
	boards = DotLeaderboardManager.new()
	boards.name = "Leaderboards"
	boards.store = DotLeaderboardStoreMemory.new()
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)

	# `publish` follows the server's own switch. Both were defined with it off, the
	# reporter skips an unpublished board, and so a server with report_to_backbone on
	# sent nothing at all — the site had no records from any g2gfast server, with no
	# error anywhere, because "this board is not published" is a normal configuration.
	var fastest := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	fastest.display_name = "Fastest time"
	fastest.publish = config.report_to_backbone
	boards.define(fastest)

	var points := DotLeaderboardDef.make(&"points", DotLeaderboardDef.Kind.POINTS)
	points.display_name = "Ranking points"
	points.decimals = 1
	points.publish = config.report_to_backbone
	# A ranking total goes DOWN when somebody else's record moves the scale; a board
	# that kept each player's best would freeze them at their highest-ever total.
	points.running_total = true
	boards.define(points)


func _build_timers() -> void:
	timers = DotTimerManager.new()
	timers.name = "Timers"

	var timer_config := DotTimerConfig.new()
	timer_config.tick_rate = 0
	timer_config.default_tick_rate = tick_rate
	timer_config.authoritative = authoritative
	timer_config.record_runs = true
	timer_config.records_directory = config.records_directory
	timer_config.record_replays = config.record_replays
	timer_config.fastest_expected_speed = G2GUnits.to_metres(config.max_velocity)
	timer_config.points_formula = config.points_formula
	timer_config.points_weighting = config.points_weighting
	timer_config.enforce_stages = config.enforce_stages
	timer_config.resume_seconds = config.resume_seconds
	timers.config = timer_config

	# Assigned before the manager is in the tree, so its configuration keeps it rather
	# than building the file store. Opened in `_open_records_store`, before the first map.
	if authoritative and config.records_database.strip_edges() != "":
		timers.store = _records_store_from_config()

	add_child(timers)
	tick_rate = timers.tick_rate

	var timer_styles := DotTimerStyle.defaults()
	for style in timer_styles:
		# The community timers' `startinair`, on: a bunny-hopper leaves the start pad mid-hop far
		# more often than not, and a run that only begins from a grounded exit is
		# one most players never start. The prespeed clamp is what stops the "build
		# speed outside and dive through" trick this switch was for.
		style.allow_air_start = true
	timers.set_styles(timer_styles)

	var replays_ready := replays.setup(config.records_directory if config.record_replays else "")
	if not replays_ready.ok:
		DotLog.warn(CHANNEL, "replays will not persist", {"why": replays_ready.error.message})
	timers.record_accepted.connect(_on_record_accepted)
	timers.record_refused.connect(_on_record_refused)
	timers.run_filed.connect(_on_timer_filed)
	# A section filed on its own moves the player's best for it; the panel's gold and its
	# sum of best read that. Refreshed here and not in the HUD, because online the HUD has no
	# store and the server tells it.
	# Only a section that improved: a slower crossing changes none of the bests, and each
	# refresh awaits n + 1 store reads and sends a message.
	timers.section_filed.connect(
		func(result: Dictionary) -> void:
			if bool(result.get("improved", true)):
				refresh_stage_reference(match_id(result["player"]))
	)
	timers.practice_finished.connect(_on_practice_finished)
	timers.start_refused.connect(
		func(id: StringName, reason: String) -> void: announced.emit(match_id(id), reason, false)
	)
	# Restarts only: `!end` asks for the end zone and the command puts the player there
	# itself. Spawning first would spend a start site's cooldown on a player leaving it.
	timers.teleport_requested.connect(
		func(id: StringName, _zone: DotTimerZone, why: StringName) -> void:
			if why != &"end":
				spawn_player(match_id(id))
	)
	timers.points_changed.connect(_on_points_changed)
	timers.effect_requested.connect(_on_effect_requested)
	timers.stage_requested.connect(_on_stage_requested)
	timers.player_finished.connect(_on_player_finished)


## The SQL records store [member G2GConfig.records_database] names, not yet open. Null
## when dot-sql is not installed or the settings are wrong — said at ERROR, and the
## manager then builds the file store as it always did.
##
## [b]dot-sql is reached by path, never by name.[/b] This game is delivered as a pack, and
## a pack's scripts parse against whatever addons the host build carries; naming
## `DotSql` would make every one of them fail to parse on a host without it. Loading the
## script by path is a missing feature on such a host, not a broken game.
func _records_store_from_config() -> DotTimerStoreSql:
	var path := "res://addons/dot_sql/core/dot_sql.gd"
	if not ResourceLoader.exists(path):
		DotLog.error(CHANNEL, "records_database is set but dot-sql is not installed; records stay in files", {
			"records_database": config.records_database,
		})
		return null
	var sql_script: Script = load(path)
	var kind := config.records_database.strip_edges().to_lower()
	var made: DotResult = sql_script.call("from_config", {
		"driver": kind if kind == "sqlite" else "gateway",
		"dialect": kind if kind != "sqlite" else "sqlite",
		"path": config.records_database_path,
		"url": config.records_database_url,
		"token": config.records_database_token,
	}, self)
	if not made.ok or made.value == null:
		DotLog.error(CHANNEL, "the records database settings are not usable; records stay in files", {
			"why": made.error.message if not made.ok else "no driver", "detail": made.error.detail if not made.ok else "",
		})
		return null
	var store := DotTimerStoreSql.new(made.value)
	store.prefix = config.records_table_prefix
	store.cache_seconds = config.records_cache_seconds
	return store


## Opens the SQL store, or falls back to files if it will not open.
func _open_records_store() -> void:
	var sql := timers.store as DotTimerStoreSql
	if sql == null:
		return
	var opened: DotResult = await sql.open()
	if opened.ok:
		DotLog.info(CHANNEL, "records are kept in a database", {"database": config.records_database, "prefix": sql.prefix})
		return
	DotLog.error(CHANNEL, "the records database would not open; records stay in files this session", {
		"why": opened.error.message, "detail": opened.error.detail,
	})
	# Files only where the configuration said there is a directory; with none it means
	# "memory", and a file store pointed at "" writes to the filesystem root and fails
	# every flush for the rest of the session.
	timers.store = (
		DotTimerStoreFile.at(config.records_directory) if config.records_directory.strip_edges() != ""
		else DotTimerStoreMemory.new()
	)


## Moves aside every record filed under a [method is_legacy_key] player.
##
## Before records were keyed by account they were keyed by the session's `u<userid>`, a
## server-local counter. Such a row cannot be mapped back to an account (the number was
## reused after every restart, so even "the same u12" is not one person), and left in
## place it ranks a stranger's time as a runner who can never be reached again and lets a
## new seat that draws the same number inherit it. So the rows are written to
## `legacy_records.jsonl` (in [member G2GConfig.records_directory], else `user://`) and
## then removed with [method DotTimerManager.wipe_player], which re-scores every board
## and total they touched. Nothing is lost silently and nothing is deleted before it is
## written; the store needs no migration of its own, because the test is the key's shape
## and a store of any kind answers [code]records_on_map[/code].
##
## Idempotent: a second run finds nothing. Returns how many rows were moved.
func retire_legacy_records() -> int:
	if not authoritative or timers == null or timers.store == null:
		return 0
	var store := timers.store
	var listed: DotResult = await store.maps()
	if not listed.ok:
		return 0
	var legacy := {}
	for row in (listed.value as Array):
		var on_map: DotResult = await store.records_on_map(StringName(str((row as Dictionary).get("map", ""))))
		if not on_map.ok:
			continue
		for record in (on_map.value as Array):
			if is_legacy_key((record as DotTimerRecord).player_id):
				legacy[(record as DotTimerRecord).player_id] = true
	if legacy.is_empty():
		return 0

	var base := config.records_directory.strip_edges()
	var path := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var out := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if out == null:
		DotLog.error(CHANNEL, "legacy records could not be archived; they stay where they are", {
			"path": path, "why": error_string(FileAccess.get_open_error()),
		})
		return 0
	out.seek_end()

	var moved := 0
	for key in legacy:
		var theirs: DotResult = await store.records_of(key, {"stage": -1})
		if not theirs.ok:
			continue
		for record in (theirs.value as Array):
			out.store_line(JSON.stringify((record as DotTimerRecord).to_dictionary()))
		out.flush()
		var wiped: DotResult = await timers.wipe_player(key)
		if wiped.ok:
			moved += int(wiped.value)
	out.close()
	DotLog.info(CHANNEL, "records keyed by a session number were moved aside", {
		"players": legacy.size(), "records": moved, "archive": path,
	})
	return moved


## Statistics and achievements, if this instance keeps any.
##
## [b]After the timers and before the maps, and both halves of that matter.[/b]
## [method G2GProgress.attach] connects to the timer manager's own signals, which do
## not exist until `_build_timers` has run; and it connects to `map_ready`, which
## `_build_maps` can fire during `_ready` when an initial map is configured — so a
## progress node built afterwards would miss the first map of the session.
func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = G2GProgress.new()
	progress.name = "Progress"
	progress.report_to_backbone = config.report_to_backbone
	progress.progress_dir = config.records_directory
	add_child(progress)

	var attached := progress.attach(self)

	if not attached.ok:
		# A server with no statistics is a server. One that refuses to boot because an
		# achievement catalogue was rejected is not.
		DotLog.warn(CHANNEL, "progression is off", {"why": attached.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null


## Who is watching whom. On a server it decides; on a client it is a mirror the bridge
## tells (`DotSpectatorManager.authoritative` follows the game's), and only its camera is
## used. After combat on a server, because its rules read whether the deathmatch is on.
func _build_spectate() -> void:
	spectate = G2GSpectate.new()
	spectate.name = "Spectate"
	spectate.game = self
	add_child(spectate)

	var watching := spectate.setup()

	if not watching.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": watching.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


## The deathmatch, the hunters and the props, if this server runs any.
##
## [b]Before `_build_maps`, and that is load-bearing.[/b] All three connect to
## `map_ready`, and `_build_maps` can fire it during `_ready` when an initial map is
## configured — so a layer built afterwards misses the first map of the session, which
## for the hunters means no route and for the props means nothing cleared.
##
## [b]Each one is built whether or not it is enabled.[/b] `enabled` is a live cvar an
## operator flips mid-map, and a layer that only existed when it was on would have to
## be constructed under live players — which is where the interesting failures are.
## Built and off costs a node and three signal connections.
func _build_layers() -> void:
	if not authoritative:
		# Spectating is the one layer a client needs a copy of: the camera is drawn
		# here, from the poses this client has. Until 2026-10-08 this return came first
		# and a client had no spectator manager at all, so `_drive_spectator_camera`
		# returned on its first line every frame and `!spec` moved no client's camera.
		_build_spectate()
		return

	# Loaded, not preloaded (g2g_bots.gd preloads this file), and rebased: a bare res:// path
	# names the host project's root in a delivered pack, so a delivered server had no bots and
	# stopped building its layers here.
	bots = (load(G2GPaths.rebase("res://game/g2g_bots.gd")) as GDScript).new()
	bots.name = "Bots"
	bots.set("game", self)
	add_child(bots)

	if config.deathmatch or config.hunters:
		# The hunters need somewhere to put damage, so combat is built for either.
		# A hunter that could hurt a player the server is not tracking would be doing
		# damage nothing could heal, display or respawn away.
		combat = G2GCombat.new()
		combat.name = "Combat"
		combat.game = self
		combat.enabled = config.deathmatch
		add_child(combat)

		var armed := combat.setup()

		if not armed.ok:
			DotLog.warn(CHANNEL, "deathmatch is off", {"why": armed.error.message})
			remove_child(combat)
			combat.queue_free()
			combat = null

	if config.hunters:
		hunters = G2GHunters.new()
		hunters.name = "Hunters"
		hunters.game = self
		hunters.enabled = true
		add_child(hunters)

		var hunting := hunters.setup()

		if not hunting.ok:
			DotLog.warn(CHANNEL, "the hunt is off", {"why": hunting.error.message})
			remove_child(hunters)
			hunters.queue_free()
			hunters = null

	# Built whatever else is on. A player watching a runner needs no combat, no hunters
	# and no props, and refusing them the camera because the server is a plain timer
	# server would be refusing it on every server this game was written for.
	_build_spectate()

	if config.deathmatch or config.hunters:
		effects = G2GEffects.new()
		effects.name = "Effects"
		effects.game = self
		add_child(effects)

		var applied := effects.setup()

		if not applied.ok:
			DotLog.warn(CHANNEL, "effects are off", {"why": applied.error.message})
			remove_child(effects)
			effects.queue_free()
			effects = null

	if config.placeable_props:
		props = G2GProps.new()
		props.name = "Props"
		props.game = self
		add_child(props)

		var placed := props.setup()

		if not placed.ok:
			DotLog.warn(CHANNEL, "props are off", {"why": placed.error.message})
			remove_child(props)
			props.queue_free()
			props = null


func _build_maps() -> void:
	maps = DotMapSession.new()
	maps.name = "Maps"
	maps.world_ref = DotNodeRef.of_path(^"../World")
	add_child(maps)

	maps.catalogue = _map_catalogue()

	if config.catalogue_path != "":
		DotLog.result(CHANNEL, "loading the map catalogue",
			maps.load_catalogue(config.catalogue_path))

	maps.rotation = DotMapRotation.of(maps.catalogue)
	maps.rotation.cooldown = 1
	maps.time_limit.duration = config.map_seconds
	load_rotation()
	# A map that arrives later (a rescan, a fetched pack) is judged against the same file.
	maps_rescanned.connect(func(_change: Dictionary) -> void: apply_rotation())

	maps.changing.connect(_on_map_changing)
	maps.changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)


## Reads maps.yml and applies it. Called at boot and by [method rescan_maps], so an operator
## who edits the file runs `g2g_maps_reload`.
##
## Two layers, weakest first: the game's own shipped `res://maps.yml` and the server's
## [member G2GConfig.map_rotation_file]. The merge, the wildcards and the rules for what a
## rotation does are dot-map's [DotMapRotationFile]; this game only supplies the paths.
##
## A file that is present and unreadable is an ERROR and changes nothing: rotating every
## map is a better failure than rotating none.
func load_rotation() -> DotResult:
	var paths := PackedStringArray()
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)
	if found == "" and stem != "" and (dir != "" or stem != G2GConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates",
			{"file": stem, "config_dir": dir})
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate):
			paths.append(candidate)
	var read := DotMapRotationFile.load_files(paths, "game-g2gfast")
	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates",
			{"why": read.error.message})
		rotation_file = null
		rotation_source = ""
		apply_rotation()
		return read
	rotation_file = read.value
	rotation_source = ", ".join(rotation_file.sources)
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {"paths": rotation_source, "active": rotation_file.active_name()})
	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation from the file ([DotMapRotationFile.apply]).
##
## Out of rotation is [member DotMapDef.in_rotation] off, which is what the rotation's pool,
## the vote's ballot and a nomination already read -- so a map can be left installed and
## loadable by name without being played. With no file an `arena`-kind map (a combat surf
## map, which is game-arena's) is out; a file that lists it brings it in.
func apply_rotation() -> void:
	if maps == null or maps.catalogue == null or maps.rotation == null:
		return
	if rotation_file != null and rotation_file.has_rotations():
		# An empty rotation plays "every installed map", but not the ones this game keeps out
		# when there is no file: the fallback is the no-file behaviour, not a wider one.
		rotation_file.fallback_in = func(map: DotMapDef) -> bool: return map.kind != DotMapDef.KIND_ARENA
		rotation_file.apply(maps.rotation)
		return
	maps.rotation.order = []
	for map: DotMapDef in maps.catalogue.maps:
		map.in_rotation = map.kind != DotMapDef.KIND_ARENA


## Whether [param id] is in rotation. A map the catalogue does not hold is not.
func in_rotation(id: StringName) -> bool:
	var map: DotMapDef = maps.catalogue.get_map(id) if maps != null and maps.catalogue != null else null
	return map != null and map.in_rotation and map.enabled


## Where zones drawn in-game for map [param id] are saved and read from.
static func user_zones_path(id: StringName) -> String:
	return "user://zones/%s.json" % String(id)


## [method map_rows] as dot-menu's map menu draws them: the kind as the mode, the tier under
## it, "combat" for a map for the deathmatch layer, and "not in rotation" in the warning colour
## (every map, not the rotation: an operator keeps maps installed the rotation does not play).
static func menu_rows(rows: Array) -> Array:
	var out: Array = []
	for m: Dictionary in rows:
		var tags: Array = []
		if str(m.get("kind", "")) == "arena":
			tags.append("combat")
		if bool(m.get("workshop", false)):
			tags.append("Workshop")
		if bool(m.get("download", false)):
			tags.append("downloads when chosen")
		var rotating := bool(m.get("rotation", true))
		if not rotating:
			tags.append("not in rotation")
		out.append({"id": str(m.get("id", "")), "name": str(m.get("name", m.get("id", "?"))),
			"mode": str(m.get("kind", "")).capitalize(), "detail": "tier %d" % int(m["tier"]) if int(m.get("tier", 0)) > 0 else "",
			"tags": tags, "current": bool(m.get("current", false)), "warn": not rotating})
	return out


## Every map in the catalogue as the M screen shows it, by id: `{id, name, tier, kind,
## rotation, current}`. The offline client reads it directly; a server sends it.
func map_rows() -> Array:
	var out: Array = []
	if maps == null or maps.catalogue == null:
		return out
	var current: StringName = maps.current.id if maps.current != null else &""
	var list: Array[DotMapDef] = maps.catalogue.maps.duplicate()
	list.sort_custom(func(a: DotMapDef, b: DotMapDef) -> bool: return String(a.id) < String(b.id))
	for map in list:
		out.append({
			"id": String(map.id), "name": map.label(), "tier": map.tier,
			"kind": String(map.kind), "rotation": map.in_rotation and map.enabled,
			"current": map.id == current, "workshop": G2GMapCatalogue.is_workshop(map),
		})
	for raw in offered_maps:
		if maps.catalogue.has(StringName(raw)):
			continue
		out.append({
			"id": raw, "name": raw, "tier": 0, "kind": "", "rotation": true,
			"current": false, "download": true,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return out


## Every map on disk. See [G2GMapCatalogue] — there is no list here on purpose.
func _map_catalogue() -> DotMapCatalogue:
	return G2GMapCatalogue.discover(_map_roots())


## Extra places to look for imported maps, from the configuration.
func _map_roots() -> PackedStringArray:
	var out := PackedStringArray()
	if config != null and not config.maps_directory.is_empty():
		out.append(config.maps_directory)
	return out


## Pick up maps added to or removed from the disk since this server booted.
##
## [b]Why a server needs this at all:[/b] the point of an imported map is that an
## operator drops one in, and a game that only reads the disk once makes them restart
## to play it — which on a live server means kicking everybody to add a map.
##
## The map being played is deliberately NOT unloaded when it disappears from the disk.
## Its scene is already resident, the players on it are mid-run, and taking the world
## out from under them to enforce a directory listing is a worse outcome than letting
## the current map finish and never being chosen again.
func rescan_maps() -> Dictionary:
	if maps == null or maps.catalogue == null:
		return {"added": [], "removed": [], "total": 0}

	var playing: StringName = maps.current.id if maps.current != null else &""
	var change := G2GMapCatalogue.rescan(maps.catalogue, _map_roots())
	var _rotation := load_rotation()

	if playing != &"" and not maps.catalogue.has(playing):
		DotLog.warn(CHANNEL, "the map being played is no longer on disk",
			{"map": String(playing)})

	DotLog.info(CHANNEL, "map catalogue rescanned", {
		"added": change["added"].size(),
		"removed": change["removed"].size(),
		"total": change["total"],
	})
	maps_rescanned.emit(change)
	return change


# --- Movement cvars --------------------------------------------------------

## Rebuilds the movement from [member config] and hands it to every player.
##
## [b]What `sv_autobunnyhopping 1` does, and every run in progress is abandoned by
## it.[/b] The tunables are an input to the simulation, so a run that was half on one
## set and half on another is not comparable with anything — the same reason a tick
## rate change abandons runs. It costs everybody one attempt, and a server changing
## its movement is a server whose operator is asking for exactly that.
func apply_movement() -> void:
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	for id in players:
		var player: G2GPlayer = players[id]

		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)

		var applied := player.set_movement(tunables)

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not take the new movement", {
				"player": String(id), "why": applied.error.message
			})

	DotLog.info(CHANNEL, "movement applied", {
		"autobhop": config.auto_bhop,
		"airaccel": config.air_accelerate,
		"gravity": config.gravity,
		"fingerprint": tunables.fingerprint(),
	})

	movement_changed.emit(config)


# --- Players ---------------------------------------------------------------

## match id -> record key, for the players who have one. See [method record_key].
var _record_keys: Dictionary = {}
## record key -> match id, the other way, for what the timer manager reports back.
var _match_ids: Dictionary = {}


## The key the timers, the records, the boards and the statistics know a player by.
##
## [b]Not the match id.[/b] The match id (`u<userid>`) is dot-server's sequential,
## server-local counter: it names a seat for the length of one connection, and the same
## account reconnecting is a new number (and a restarted server hands the old numbers to
## strangers). A record keyed by it was a different runner at every connection, and could
## be inherited. The key is the account's [code]session.uid()[/code] (a guest's is per
## device), given to [method add_player]. A player added without one (a solo game, the
## ghost, a client's copy, a test) is known by the match id, which is then also the key.
## A display name is never a key.
func record_key(id: StringName) -> StringName:
	return _record_keys.get(id, id)


## The match id a timer-manager key belongs to; the key itself when none does.
func match_id(key: StringName) -> StringName:
	return _match_ids.get(key, key)


## True for a key that is a server-local session number (`u<digits>`): the keying records
## carried before they were keyed by account. See [method retire_legacy_records].
static func is_legacy_key(key: StringName) -> bool:
	var text := String(key)
	return text.length() > 1 and text.begins_with("u") and text.substr(1).is_valid_int() and not text.contains("-")


func _claim_record_key(id: StringName, key: StringName) -> void:
	if key == &"" or key == id:
		return
	if _match_ids.has(key) and _match_ids[key] != id:
		# The same account twice at once would share one timer, and the second seat's
		# runs would be filed under the first's. It keeps its match id as its key: a
		# legacy-shaped key, which is never ranked.
		DotLog.warn(CHANNEL, "an account is already playing; this seat has no records", {
			"player": String(id), "key": String(key),
		})
		return
	_record_keys[id] = key
	_match_ids[key] = id


func _release_record_key(id: StringName) -> void:
	var key: StringName = _record_keys.get(id, &"")
	_record_keys.erase(id)
	if key != &"":
		_match_ids.erase(key)


func add_player(
	id: StringName, display_name: String, local: bool = false, avatar: DotAvatar = null,
	bot: bool = false, p_record_key: StringName = &""
) -> G2GPlayer:
	if players.has(id):
		return players[id]

	_claim_record_key(id, p_record_key)

	var player := G2GPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.tick_rate = tick_rate
	player.samples_input = local
	player.has_camera = local

	# The layout's player mask rather than the magic 1. With placed blocks on the prop
	# layer, a mask of 1 is a player who walks through every one of them.
	if player_stack != null:
		player.collision_mask = player_stack.player_collision_mask()
	player.base_tunables = tunables
	add_child(player)

	var added := timers.add_player(record_key(id), display_name)
	if not added.ok:
		DotLog.warn(CHANNEL, "could not give a player a timer", {
			"player": String(id), "why": added.error.message
		})

	player.timer = timers.timer_for(record_key(id))
	player.set_style(movement_styles[&"normal"], timers.style_for(&"normal"))

	# A bot (`g2g_bots.gd`) runs no timer and counts towards nothing, as the ghost does: its
	# rides are the bots layer's to judge, and a board or a statistic with a bot in it is
	# one nobody trusts.
	player.is_bot = bot
	if bot:
		timers.remove_player(record_key(id))
		player.timer = null

	if player.camera != null:
		player.camera.fov_desired = config.fov_desired
		player.camera.others_fn = func() -> Array:
			var out: Array = []
			for other_id in players:
				if players[other_id] != player and is_instance_valid(players[other_id]):
					out.append(players[other_id])
			return out
		player.camera.allow_third_person = config.allow_thirdperson and view_rules.allows_third()
		player.camera.forced_third = not view_rules.allows_first()
		player.camera.set_mode(
			G2GCamera.Mode.THIRD_PERSON if config.default_thirdperson and config.allow_thirdperson
			else G2GCamera.Mode.FIRST_PERSON
		)

	# Their own avatar when they have one, a stock character when they do not. The
	# stock one is a real document over the same schema, so nothing about drawing
	# changes the day the platform hands one over.
	player.rig.set_meta(&"player_key", String(id))
	var dressed := player.rig.dress(
		avatar if avatar != null else G2GAvatars.stock_avatar(id),
		avatar_schema, avatar_catalogue
	)
	if not dressed.ok:
		DotLog.warn(CHANNEL, "a player could not be dressed", {
			"player": String(id), "why": dressed.error.message
		})

	players[id] = player
	_samples[id] = DotTimerSample.new()
	player.set_mechanics(mechanics)
	player.map_event.connect(_on_map_event.bind(id))

	if progress != null and not bot:
		# Not awaited: an achievement store may be remote and a join may not wait on
		# it. Readings that arrive during the load are still counted — see
		# `G2GProgress.begin`.
		progress.begin(id, display_name)

	spawn_player(id)
	player_added.emit(player)

	return player


## Puts the record's replay on the map as a player everybody sees.
##
## A ghost is a [G2GPlayer] with [member G2GPlayer.replay] set, so it replicates
## through the same bridge as a person: the server drives it, clients interpolate
## it, and a browser client that could not decode a replay still sees the run.
func spawn_ghost(track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> G2GPlayer:
	if not authoritative or not config.show_replay_bot or maps.current == null:
		return null

	var best := replays.best(maps.current.id, track, style_id)
	if best == null:
		return null

	remove_player(GHOST_ID)

	var player := add_player(
		GHOST_ID, "WR %s · %s" % [DotTimerRun.format_time(best.time), best.player_name], false
	)
	if player == null:
		return null

	var replay_player := DotTimerReplayPlayer.new()
	var loaded := replay_player.load_replay(best)
	if not loaded.ok:
		remove_player(GHOST_ID)
		return null

	timers.remove_player(GHOST_ID)
	player.timer = null
	player.replay = replay_player
	replay_player.play()
	return player


func ghost() -> G2GPlayer:
	return players.get(GHOST_ID)


func remove_player(id: StringName) -> void:
	if effects != null:
		effects.on_player_removed(id)

	if not players.has(id):
		return

	maps.time_limit.unrock(id)
	timers.remove_player(record_key(id))
	(players[id] as G2GPlayer).queue_free()
	players.erase(id)
	_samples.erase(id)
	_standings.erase(id)
	player_removed.emit(id)
	# After the signal: the statistics layer files the player's last readings under it.
	_release_record_key(id)


func spawn_player(id: StringName) -> void:
	var player: G2GPlayer = players.get(id)
	if player == null:
		return

	# A spawn follows a join, a track or style change, a map change and a restart —
	# every moment the board a player is measured against may have changed.
	refresh_standing(id)

	var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
	var map := current_map_node()

	# [b]The director chooses among the map's own starts; the map is the fallback.[/b]
	# `G2GPlayerStack.refresh_spawns` copies every track's start into it, so this is not
	# a second set of spawns — it is the per-site cooldown, the occupancy check and, with
	# `sv_deathmatch` on, the protection window that is granted inside `choose` and
	# nowhere else. Without this call the director was fed every start on every map and
	# asked nothing for the life of the server.
	if player_stack != null:
		var chosen := player_stack.choose_start(id, track)

		if chosen.ok:
			var choice := chosen.value as DotSpawnChoice
			# Degrees out, for the same reason radians went in: `DotFpsState.yaw` is in
			# degrees and `DotFpsController` converts at exactly this boundary too.
			player.teleport(
				choice.transform.origin,
				rad_to_deg(choice.transform.basis.get_euler().y)
			)
			return

	if map != null:
		player.teleport(map.spawn_for(track), map.spawn_yaw_for(track))
	else:
		# A Workshop map is a plain scene, not a G2GMap, so its spawn is the one its zones
		# file states (`Kind.SPAWN`, falling back to the main run's) and nothing else says.
		var spawn := _zone_spawn(track)
		if spawn != null:
			player.teleport(spawn.destination, spawn.destination_yaw)
		else:
			player.teleport(Vector3(0.0, 2.0, 0.0), 0.0)


## The spawn zone of [param track] in the zones the timer holds, or of the main run, or null.
func _zone_spawn(track: int) -> DotTimerZone:
	if timers == null or timers.zones == null:
		return null
	var spawn := timers.zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	if spawn == null and track != DotTimerTrack.MAIN:
		spawn = timers.zones.first_of_kind(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	return spawn


func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: G2GPlayer = players.get(id)
	if player == null or not movement_styles.has(style_id):
		return false

	var ranking := timers.style_for(style_id)
	if ranking == null:
		return false

	var changed := player.set_style(movement_styles[style_id], ranking).ok
	refresh_standing(id)
	return changed


func current_map_node() -> G2GMap:
	return maps.world as G2GMap if maps != null else null


# --- The tick --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if external_tick:
		return

	var step := 1.0 / float(maxi(tick_rate, 1))
	_accumulator += delta
	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		_tick += 1
		_simulate_tick(step)

	if _accumulator >= step:
		_accumulator = 0.0


## True while the client's load gate covers the screen. Set only by a client; a server and
## every suite leave it empty, so nothing here ever waits for a cover that does not exist.
func is_covered() -> bool:
	return covered.is_valid() and bool(covered.call())


## The tick this game is on.
##
## Read rather than reconstructed. `_tick` is advanced by three different callers —
## the accumulator in `_physics_process`, `tick_once` from a netcode bridge, and
## `tick_timers_only` on a client — and anything deriving its own would be a fourth
## copy of a number that already exists.
func current_tick() -> int:
	return _tick


## One authoritative tick driven from outside, at a tick number the driver chose.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))

	if player_stack != null:
		player_stack.tick(tick)


## Feeds every timer from the players' current positions without moving anybody.
##
## The client's tick: prediction moved the local player through its behaviour and
## snapshots moved everybody else, so the only thing left to do per tick is what the
## server does after its moves — time them.
func tick_timers_only(tick: int) -> void:
	_tick = tick
	_feed_timers()


## Move every player, then time the tick with the position the move produced.
func _simulate_tick(step: float) -> void:
	# [b]Under the client's load cover only the local body moves[/b], and only while the gate
	# settles it onto the floor. The map clock, the bots, the hunters, combat, effects and
	# above all the timers wait: a run that started (or a start zone that fired) behind the
	# cover would be a time the player never played.
	if is_covered():
		for id in players:
			var body: G2GPlayer = players[id]
			if body.has_camera:
				body.simulate(_tick, step)
		return

	maps.advance(step)

	# The bots' keys, before anybody moves: see `g2g_bots.gd`.
	if bots != null:
		bots.call("drive", step)

	for id in players:
		(players[id] as G2GPlayer).simulate(_tick, step)

	# After the moves and before the timers, which is where every per-tick measurement
	# in this game belongs: the counters it reads are what the move just produced, and
	# the distance it measures is the distance that move covered.
	if progress != null:
		progress.sample(step)

	# The three layers, in the order their inputs are produced. Combat resolves shots
	# against the world as it ends the tick — half a tick of movement at surf speeds
	# is two metres, which at range is a different part of the map. The hunters
	# perceive where the players ended up. The props are only a rate limit.
	if combat != null:
		combat.tick(step)

	if hunters != null:
		hunters.tick(step)

	if props != null:
		props.tick(step)

	# Before the timers, and it has to be: an effect that changes how somebody moves
	# has already changed it by the time the timer measures the tick, and one applied
	# after would be a tick of movement the run was not told about.
	if effects != null:
		effects.tick(step)

	if spectate != null:
		spectate.tick(step)

	_feed_timers()


func _feed_timers() -> void:
	if is_covered():
		return

	for id in players:
		var player: G2GPlayer = players[id]
		if player.timer == null or player.replay != null:
			continue
		var sample: DotTimerSample = _samples[id]
		player.fill_sample(sample)
		timers.tick_player(
			record_key(id), sample.position, sample.velocity, sample.grounded, sample.alive,
			player.controller.state.yaw, player.controller.state.pitch, sample.buttons,
			player.replay_flags()
		)


# --- Maps ------------------------------------------------------------------

func change_map(id: StringName) -> DotResult:
	# [b]Before the change, not after it.[/b] `DotMapSession.change_to` refuses an id the
	# catalogue does not hold, and on a browser client the catalogue holds nothing until
	# the pack is mounted -- so without this line a client joining a server whose map it
	# has never seen is told "no such map" about a map that is sitting on the CDN.
	var content := await ensure_map_content(id)

	if not content.ok:
		return content

	# [b]Through the protocol on a server with clients, and only there.[/b] The session's
	# own `change_to` swaps this process's world and nothing else; it is what the ad-hoc
	# version called, and then broadcast the map id to clients that had not been asked
	# whether they could load it. A client never takes this branch: its map changes when
	# the host tells it to, through `DotMapSyncClient`, which calls the session directly.
	if map_sync != null and authoritative:
		return await map_sync.change_to(id)

	return await maps.change_to(id)


## Make sure the map [param id] is something the catalogue can load, fetching it if not.
##
## [b]The map id IS the content id.[/b] That is a convention rather than a mechanism, and
## it is the one the publisher already follows: `dist/surf_mesa/` holds `surf_mesa.json`
## and `surf_mesa.bin`, and the manifest names `surf_mesa` as its content id. Anything
## else would need a second registry mapping one to the other, maintained in a third
## place, to express a relationship that is already true.
##
## Succeeds and does nothing in three cases that are all normal: the catalogue already
## has the map (a build that ships it, or a pack fetched earlier), there is no dot-cloud
## client (a server run from source), or the map is one of the built-in scenes.
func ensure_map_content(id: StringName) -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "No map id.")

	if maps != null and maps.catalogue != null and maps.catalogue.has(id):
		return DotResult.success(null)

	if _map_content_seen.has(id):
		return DotResult.success(null)

	var cloud: Object = DotRegistry.get_service(map_content_service)

	if cloud == null or not cloud.has_method("ensure"):
		# Not an error, and deliberately not a warning either. `change_to` is about to
		# refuse the id with a message naming the map, which is the better one to read.
		return DotResult.success(null)

	DotLog.info(CHANNEL, "fetching a map this build does not have", {"map": String(id)})

	# At the version the installer pinned when the descriptor names the map; otherwise by
	# the owner cvar, at whatever the origin calls latest (a map typed at the console).
	var pinned: Array = _pinned_maps.get(id, [])
	var got: Variant

	if not pinned.is_empty():
		got = await cloud.call("ensure", StringName(pinned[0]), pinned[1])
	else:
		# Unpinned (solo, or a map typed at the console): ask the origin which version is
		# newest. `ensure` with no version means `0.0.0`, and the shell's fallback layout
		# answers that with an unversioned manifest a publish never updates -- a solo game
		# was handed a surf_mesa from weeks earlier while latest.json named today's.
		var content_id := config.map_content_id(id)
		var newest := await _latest_map_version(cloud, content_id)
		got = await cloud.call("ensure", StringName(content_id), newest)

	if not (got is DotResult):
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"The content client answered with something else."
		)

	var res: DotResult = got

	if not res.ok:
		return res.wrap("could not fetch the map %s" % id)

	# `ensure` returns the entry scene path when the manifest names one and the mount
	# prefix when it does not. A map pack names `<id>.json`, so this is normally the
	# first -- and the directory is what the catalogue wants either way.
	var where := str(res.value)
	var dir := where.get_base_dir() if where.ends_with(".json") else where
	var map := G2GMapCatalogue.at_directory(id, dir)

	if map == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s was fetched but does not look like a map." % id
		)

	_mark_delivered(map, dir)

	var added := maps.catalogue.add(map)

	if not added.ok:
		return added

	_map_content_seen[id] = true
	DotLog.info(CHANNEL, "a map was added from delivered content", {
		"map": String(id), "version": map.content_version, "dir": dir
	})
	return DotResult.success(null)


## The version the origin's `latest.json` names for [param content_id], or "" when no base
## answers (an origin without the pointer, or a client with no HTTP bases) -- "" is the
## old unversioned lookup, so a failure here costs nothing that worked before.
func _latest_map_version(cloud: Object, content_id: String) -> String:
	if not cloud.has_method("resolved_http_base_urls"):
		return ""

	var http := DotHttp.new()
	http.name = "MapLatest"
	add_child(http)

	var version := ""

	for base in cloud.call("resolved_http_base_urls"):
		var url := "%s/%s/latest.json" % [str(base).rstrip("/"), content_id]
		var res: DotResult = await http.get_json(url)

		if res.ok and res.value is Dictionary:
			version = str((res.value as Dictionary).get("version", ""))
			if version != "" and not version.contains("/") and not version.contains(".."):
				break
			version = ""

	http.queue_free()
	DotLog.debug(CHANNEL, "newest published map version", {"content": content_id, "version": version})
	return version


## Says, on a map that came out of a dot-cloud mount, which content and version it is.
##
## [b]So that a client can be sent it.[/b] Without a content id a map is, to dot-map, a map
## in this build, and a client that does not have it refuses it — correctly: a host that
## could name a local map could name anything in the client's build. With one, the client
## fetches that content from its own origin and accepts the announce because the scene is
## [constant G2GMapCatalogue.IMPORTED_SCENE], which it lists as a trusted template, and the
## manifest is inside the pack (see the bridge's "Map changes"). The mount is
## [code]res://dot_cloud/<content_id>/<version>[/code], so both come off the directory
## rather than out of a second record that could disagree with it.
func _mark_delivered(map: DotMapDef, dir: String) -> void:
	# `res://dot_cloud/<content id>/<version>`, where the content id is the map id or,
	# with an owner, `<owner>/<map id>` -- read off the path rather than rebuilt from the
	# config, so a map fetched under one owner is not re-announced under another if an
	# operator changes the cvar mid-session.
	var root := "res://dot_cloud/"
	var base := dir.rstrip("/")
	if not base.begins_with(root):
		return                            # a directory on disk, not a mount
	var rest := base.substr(root.length())
	var cut := rest.rfind("/")
	if cut <= 0:
		return
	var content := rest.substr(0, cut)
	var version := rest.substr(cut + 1)
	if version.is_empty() or (content != String(map.id) and not content.ends_with("/" + String(map.id))):
		return
	map.content_id = StringName(content)
	map.content_version = version


## Fetch every id in [member G2GConfig.content_maps] into the catalogue, in the background.
##
## [b]Deliberately not awaited by the caller, and that is the one thing to know about
## it.[/b] Calling a coroutine without `await` is normally this family's own mistake —
## it returns a [GDScriptFunctionState] and the work silently does not happen where the
## caller thought it did. Here the work DOES happen, on its own, and being made to wait
## for it is the bug: this is up to 66 MB over the network, and a server that blocked
## its boot on it would sit unreachable for a minute on a slow link with nothing in the
## log to say why. So it is started and left, and the catalogue grows under a running
## server exactly the way [method rescan_maps] already lets it.
##
## One at a time rather than eight at once. They share a link and a content client, and
## eight concurrent transfers finish no sooner while making the progress lines — the
## operator's only view of a long download — interleave into nonsense.
##
## Re-entrant calls are dropped rather than queued: the cvar that sets this is settable
## live, and an operator pasting a list twice should not start a second sweep of the
## same eight maps.
func fetch_content_maps() -> void:
	if _fetching_content_maps or config == null or config.content_maps.is_empty():
		return

	_fetching_content_maps = true

	# One frame before the first request, because a descriptor's cvars are applied in one
	# pass in FILE order: `sv_content_maps` listed above `sv_map_content_owner` would
	# start this sweep before the owner arrived and fetch every map from the unowned
	# path. Waiting a frame lets the whole pass land, whatever order it was written in.
	if is_inside_tree():
		await get_tree().process_frame

	var wanted := config.content_maps
	var added: Array[StringName] = []
	var failed := 0

	DotLog.info(CHANNEL, "fetching the configured map set", {"maps": wanted.size()})

	for raw in wanted:
		var id := StringName(raw.strip_edges())
		if id == &"":
			continue
		if maps != null and maps.catalogue != null and maps.catalogue.has(id):
			continue

		var res: DotResult = await ensure_map_content(id)

		# `ensure_map_content` succeeds and does nothing when there is no content client,
		# so "ok" is not "arrived" -- the catalogue is what says whether it arrived, and
		# a server with no content origin should say so once rather than eight times.
		if not res.ok:
			failed += 1
			DotLog.warn(CHANNEL, "a configured map could not be fetched",
				{"map": String(id), "why": res.error.message})
		elif maps != null and maps.catalogue != null and maps.catalogue.has(id):
			added.append(id)

	_fetching_content_maps = false

	var total := maps.catalogue.size() if maps != null and maps.catalogue != null else 0
	DotLog.info(CHANNEL, "the configured map set is in", {
		"added": added.size(), "failed": failed, "catalogue": total,
	})

	# The same signal a disk rescan emits, because to everything downstream -- the
	# rotation's pool, a vote's ballot, a client's map list -- this IS a rescan: the set
	# of maps this server can load just changed, and nothing cares which side of the
	# network they came from.
	var removed: Array[StringName] = []
	maps_rescanned.emit({"added": added, "removed": removed, "total": total})


func _on_map_changing(_from: DotMapDef, _to: DotMapDef) -> void:
	remove_player(GHOST_ID)
	for id in players:
		var player: G2GPlayer = players[id]
		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)


func _on_map_changed(map: DotMapDef, loaded: Node) -> void:
	var g2g_map := loaded as G2GMap

	# An imported map is data, and this is where it learns which data. It must happen
	# before `timer_zones()` below: the zones come out of the manifest, so asking an
	# unbuilt map for them returns an empty set and the map plays with no start, no
	# finish and no pit -- with nothing erroring, because an empty zone set is a
	# legitimate thing for a map to have.
	var bsp := loaded as G2GBspMap
	if bsp != null:
		bsp.build_from(map)

	var zones: DotTimerZoneSet = g2g_map.timer_zones() if g2g_map != null else null

	# Zones somebody drew in-game (Z offline, `g2g_zone_save` on a server) win over the
	# map's own. They were saved to this path from the day the console could draw a zone
	# and read from nowhere, so a saved zone set lasted until the next map change.
	# The authority's only: a client mirrors the server's zones, and a file it drew
	# offline for the same map would put its outlines, its stage count and its HUD on a
	# set the server is not timing.
	var drawn := user_zones_path(map.id)
	if authoritative and FileAccess.file_exists(drawn):
		var loaded_zones := DotTimerZoneSet.load_json(drawn)
		if loaded_zones.ok:
			zones = loaded_zones.value
			DotLog.info(CHANNEL, "zones drawn in-game replace the map's own", {"map": String(map.id), "path": drawn})
		else:
			DotLog.warn(CHANNEL, "a saved zone file could not be read; the map's own zones are used",
				{"path": drawn, "why": loaded_zones.error.message})

	if zones == null and maps.zones_json != "":
		var parsed := DotTimerZoneSet.from_json(maps.zones_json)
		if parsed.ok:
			zones = parsed.value

	timers.set_zones(zones)

	mechanics = G2GMapMechanics.new()
	if bsp != null:
		mechanics.read(bsp.manifest)
	if not mechanics.is_empty():
		DotLog.debug(CHANNEL, "the map's brush entities", {
			"map": String(map.id), "mechanics": mechanics.describe_lines()[0]})
	for id in players:
		(players[id] as G2GPlayer).set_mechanics(mechanics)

	for id in players:
		spawn_player(id)

	map_ready.emit(map)
	spawn_ghost()


func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	if not rotation_ends_maps:
		DotLog.debug(CHANNEL, "the map clock ran out; the vote decides", {"reason": String(reason)})
		return

	var next := maps.rotation.choose(players.size())
	if next == null:
		return

	DotLog.info(CHANNEL, "changing map", {"reason": String(reason), "to": String(next.id)})

	var changed: DotResult = await change_map(next.id)
	if not changed.ok:
		maps.time_limit.extend(120.0)


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


# --- Timer events ----------------------------------------------------------

func _on_effect_requested(timer_key: StringName, zone: DotTimerZone) -> void:
	var player_id := match_id(timer_key)
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return

	match zone.kind:
		DotTimerZone.Kind.RESPAWN when zone.payload.has(G2GBspMap.SENDS_TO):
			# The map's own pit, sending the player where its trigger_teleport aims: the
			# start of the section they fell out of, the far side of a gate. The run goes
			# on, as it does in Source -- a fall costs the time it takes, not the run.
			# Until 2026-10-08 every pit put the player back at the track's spawn, which
			# on a staged map restarted the whole run from section one.
			player.teleport(zone.destination, zone.destination_yaw, true)
		DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
			spawn_player(player_id)
		DotTimerZone.Kind.TELEPORT:
			# A door, and a door keeps the run: this is how a staged map joins one
			# section to the next. It stopped the run for as long as the importer has
			# been making doors, so surf_kitsune -- the map `doorways` was written for
			# -- could not be timed past its first section, and nothing said so.
			player.teleport(zone.destination, zone.destination_yaw, true)
		_:
			pass


## A map volume finished something only the server may: a block sank under a player
## who stayed on it, or a lethal hurt volume caught one. See [G2GMapMechanics].
func _on_map_event(event: int, index: int, player_id: StringName) -> void:
	if not authoritative or mechanics == null:
		return
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return
	match event:
		G2GMapMechanics.Event.BLOCK_SANK:
			if index >= 0 and index < mechanics.blocks.size():
				var block: Dictionary = mechanics.blocks[index]
				# Where the plate under the block sends people, with the run kept -- the
				# same as falling into it, which is what standing on a block is in Source.
				player.teleport(block["destination"], float(block["yaw"]), true)
		G2GMapMechanics.Event.HURT:
			spawn_player(player_id)


## `!s <n>` and `!rs` land here: [method DotTimerManager.request_stage] has already
## stopped the run and handed over the stage zone, and moving the player is the game's
## half. [b]Nothing listened until 2026-09-28[/b], so every stage destination on every
## map -- authored, imported, and checked for standability by `headless_imported` -- was
## a spot no command ever sent anybody to.
func _on_stage_requested(timer_key: StringName, _number: int, zone: DotTimerZone) -> void:
	var player_id := match_id(timer_key)
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return
	player.teleport(zone.destination, zone.destination_yaw)


## Sends a player to stage [param number]'s spot on the track they are on. The run
## stops: a stage restart is practice, never a time.
##
## Refused, with the run untouched, for a stage that has nowhere to stand: see
## [constant G2GBspMap.NO_RESTART]. The refusal comes first because the timer's own
## `request_stage` stops the run before the game is asked to move anybody.
func request_stage(id: StringName, number: int) -> DotResult:
	var why: Variant = _no_restart_reason(id, number)
	if why != null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED,
			"Stage %d has no start to send you to: %s" % [number, why])
	return timers.request_stage(record_key(id), number)


## Sends a player back to the start of the stage they are in (stage 1 before the first
## line). Shavit's `!rs`. In a stage with no restart, the start of the nearest stage
## before it that has one -- the section that stage line splits.
func restart_stage(id: StringName) -> DotResult:
	var found := timers.player(record_key(id))
	if found == null:
		return timers.restart_stage(record_key(id))
	var number := maxi(found.timer.run.stage, 1)
	while number > 1 and _no_restart_reason(id, number) != null:
		number -= 1
	return timers.request_stage(record_key(id), number)


## R, and R twice. [param mode] is one of `G2GEvents.RESTART_*`:
##
## - TRACK: the start of the track the player is on. What R always was, and what `!r` is.
## - STAGE: one R. The start of the stage the player is in, on a map with stages and a run
##   past its first line — the genre's `!rs`, which stops the run, because a stage restart
##   is practice. Anywhere else (no run, stage 1, a map with no stages) it is TRACK, so a
##   single R in a start zone or on a linear map still means "again from the top".
## - MAIN: two Rs. The main track's start zone, from a bonus as well, which is the only
##   way back to the main route that does not need a command.
##
## [b]Spectating ends here too.[/b] A player who pressed R wants to run, and leaving them
## watching somebody else while their own body was moved is a key that looks broken.
func restart(id: StringName, mode: int) -> DotResult:
	if not players.has(id):
		return DotResult.fail(DotError.CODE_STATE, "No such player.")

	if spectate != null and spectate.is_spectating(id):
		spectate.stop(id)

	var found := timers.player(record_key(id)) if timers != null else null
	var track := found.timer.track if found != null else DotTimerTrack.MAIN

	match mode:
		G2GEvents.RESTART_STAGE:
			var run := found.timer.run if found != null else null
			var staged := timers.stage_count(track) > 1
			if staged and run != null and run.is_running() and run.stage > 1:
				return restart_stage(id)
		G2GEvents.RESTART_MAIN:
			if track != DotTimerTrack.MAIN:
				var _switched := timers.set_player_track(record_key(id), DotTimerTrack.MAIN)

	spawn_player(id)
	return DotResult.success(null)


## The reason stage [param number] on [param id]'s track cannot be restarted, or null.
func _no_restart_reason(id: StringName, number: int) -> Variant:
	var found := timers.player(record_key(id))
	if found == null or timers.zones == null:
		return null
	var zone := timers.zones.stage_zone(found.timer.track, number)
	if zone == null or not zone.payload.has(G2GBspMap.NO_RESTART):
		return null
	return str(zone.payload[G2GBspMap.NO_RESTART])


func _on_player_finished(timer_key: StringName, run: DotTimerRun) -> void:
	var player: G2GPlayer = players.get(match_id(timer_key))
	if player == null:
		return

	# Statistics in genre units, because that is what a record's viewer reads.
	var stats := player.controller.stats.to_dictionary()
	stats["max_speed"] = G2GUnits.to_units(float(stats.get("max_speed", 0.0)))
	stats["avg_speed"] = G2GUnits.to_units(float(stats.get("avg_speed", 0.0)))
	stats["max_jump_speed"] = G2GUnits.to_units(float(stats.get("max_jump_speed", 0.0)))

	timers.note_stats(timer_key, stats)
	player.controller.stats.reset()
	player.finished.emit(run)


func _on_record_accepted(record: DotTimerRecord, _previous: DotTimerRecord, rank: int) -> void:
	var scope := {
		"map": String(record.map_id), "track": str(record.track), "style": String(record.style_id),
	}

	# A seat with no account (no identity, or the account already playing) keeps its session
	# number as its key, and a session number is nobody: its time stands for this process
	# only and is moved aside at the next start, so the boards never get a row for it (the run itself is still announced).
	var ranked := not is_legacy_key(record.player_id)

	if ranked:
		await boards.submit(&"fastest", scope, record.player_id, record.player_name, record.time)

	# Completions are a counter. Points are NOT: they used to be added here too, record
	# by record, so every improvement added the run's whole worth on top of what the
	# previous best had already added — a total that grew with every retry of the same
	# map. The real total is the timer store's (re-scored when a record moves, weighted
	# down a player's list) and is filed in `_on_timer_filed`.
	var totals := DotStatSet.new()
	totals.add(&"completions", 1.0)
	if ranked:
		await boards.add_stats(record.player_id, totals)

	var who := timers.player(record.player_id)
	if who != null:
		run_filed.emit(match_id(record.player_id), who.last_finished, rank, "")
		# The ghost chases the server record: a new one replaces it on the spot.
		if rank == 1 and who.last_replay != null and replays.offer(who.last_replay, record):
			if maps.current != null and record.map_id == maps.current.id:
				spawn_ghost(record.track, record.style_id)


func _on_record_refused(timer_key: StringName, run: DotTimerRun, reason: String) -> void:
	run_filed.emit(match_id(timer_key), run, 0, reason)


## Says what a finish meant, and moves the player's standing and points.
func _on_timer_filed(result: Dictionary) -> void:
	var id := match_id(result["player"])
	var record: DotTimerRecord = result["record"]
	var previous: DotTimerRecord = result["previous"]
	var leader: DotTimerRecord = result["previous_record"]
	var where := "%s%s" % [
		DotTimerTrack.name_of(record.track),
		"" if record.style_id == &"normal" else " · " + String(record.style_id),
	]

	if bool(result["world_record"]):
		var beat := ""
		if leader != null and leader.player_id != record.player_id:
			beat = ", beating %s by %s" % [leader.player_name, DotTimerRun.format_time(leader.time - record.time)]
		elif leader != null:
			beat = ", improving it by %s" % DotTimerRun.format_time(leader.time - record.time)
		announced.emit(id, "NEW RECORD: %s %s on %s (%s)%s" % [
			record.player_name, record.formatted_time(), String(record.map_id), where, beat,
		], true)
	elif bool(result["improved"]):
		var gain := " (-%s)" % DotTimerRun.format_time(previous.time - record.time) if previous != null else ""
		announced.emit(id, "Personal best %s%s — rank %d / %d" % [
			record.formatted_time(), gain, int(result["rank"]), int(result["total"]),
		], false)
	else:
		announced.emit(id, "%s, %s behind your best — rank %d / %d" % [
			record.formatted_time(),
			DotTimerRun.format_time(record.time - previous.time) if previous != null else "",
			int(result["rank"]), int(result["total"]),
		], false)

	refresh_standing(id)


## Re-files the points board for everybody whose total moved. Everybody, not only the
## finisher: a new record re-scores every row on its board, and a removal or wipe moves
## the totals of people who did nothing. Replaced, not "kept if better" — see
## `running_total` on the board.
func _on_points_changed(player_ids: Array) -> void:
	if boards == null or timers.store == null:
		return
	for raw in player_ids:
		var id := StringName(str(raw))
		var standing: DotResult = await timers.store.player_rank(id)
		var info: DotResult = await timers.store.player_info(id)
		if not standing.ok:
			continue
		var name := str((info.value as Dictionary).get("name", raw)) if info.ok and info.value is Dictionary else str(raw)
		await boards.replace_async(&"points", {}, id, name, float(standing.value["points"]))


func _on_practice_finished(timer_key: StringName, run: DotTimerRun, would: int, total: int, reason: String) -> void:
	var id := match_id(timer_key)
	if would > 0:
		announced.emit(id, "%s — not recorded (%s). It would have placed %d / %d." % [
			run.formatted_time(), reason.trim_suffix("."), would, total + 1,
		], false)


## Recomputes [signal standing_changed] for a player, from the store (cached reads).
func refresh_standing(id: StringName) -> void:
	if not authoritative or timers == null or timers.store == null or maps == null or maps.current == null:
		return
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return
	var map_id := maps.current.id
	var track: int = player.timer.track
	var style: StringName = player.timer.run.style_id
	var store := timers.store
	var key := record_key(id)
	var best: DotResult = await store.best_for(map_id, track, style, key)
	var top: DotResult = await store.top(map_id, track, style, 1)
	var rank: DotResult = await store.rank_of(map_id, track, style, key)
	var total: DotResult = await store.count_on(map_id, track, style)
	if not players.has(id):
		return
	var standing := {
		"pb": (best.value as DotTimerRecord).time if best.ok and best.value is DotTimerRecord else 0.0,
		"wr": (top.value[0] as DotTimerRecord).time if top.ok and not (top.value as Array).is_empty() else 0.0,
		"rank": int(rank.value) if rank.ok else 0,
		"total": int(total.value) if total.ok else 0,
	}
	_standings[id] = standing
	standing_changed.emit(id, standing)
	await refresh_stage_reference(id)


## Recomputes [signal stage_reference_changed] for a player. A map with no stages says
## nothing: there is no panel to feed.
##
## Awaits the per-section bests before peeking them, because a database-backed store
## answers [code]peek_best[/code] from a cache that only a fetch fills; the first read after a
## map change would otherwise find nothing and the panel would show dashes until the next
## finish.
func refresh_stage_reference(id: StringName) -> void:
	if not authoritative or timers == null or timers.store == null or maps == null or maps.current == null:
		return
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return
	var track: int = player.timer.track
	var sections := timers.stage_count(track) + 1
	if sections <= 1:
		return
	var key := record_key(id)
	var style: StringName = player.timer.run.style_id
	for section in range(1, sections + 1):
		await timers.store.best_for(maps.current.id, track, style, key, section)
	if not players.has(id):
		return
	var reference := stage_reference(id)
	if not reference.is_empty():
		stage_reference_changed.emit(id, reference)


## What the splits panel compares [param id] against, from the store's cache (peeks, never
## waits), or empty with no store, no player or no stages:
## [code]{map, track, style, stages, pb: {splits, total}, wr: {splits, total}, bests}[/code].
## [code]splits[/code] are cumulative times by stage number (as
## [member DotTimerRecord.splits]), [code]total[/code] the same record's finish time and
## [code]bests[/code] the player's best time by section number, 1..stages + 1.
func stage_reference(id: StringName) -> Dictionary:
	if timers == null or timers.store == null or maps == null or maps.current == null:
		return {}
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return {}
	var track: int = player.timer.track
	var stages := timers.stage_count(track)
	if stages <= 0:
		return {}
	var map_id := maps.current.id
	var style: StringName = player.timer.run.style_id
	var key := record_key(id)
	var store := timers.store

	var top: Variant = store.peek_top(map_id, track, style, 1)
	if top is Array:
		top = (top as Array)[0] if not (top as Array).is_empty() else null
	var bests := {}
	for section in range(1, stages + 2):
		var found: Variant = store.peek_best(map_id, track, style, key, section)
		if found is DotTimerRecord and (found as DotTimerRecord).time > 0.0:
			bests[section] = (found as DotTimerRecord).time
	return {
		"map": map_id, "track": track, "style": style, "stages": stages,
		"pb": _reference_of(store.peek_best(map_id, track, style, key)),
		"wr": _reference_of(top),
		"bests": bests,
	}


## A record's splits and total as the panel takes them; empty ones for no record. Copied:
## a record's splits are a Dictionary, and handing out the stored reference is the aliasing
## bug this family has had before.
static func _reference_of(record: Variant) -> Dictionary:
	if not (record is DotTimerRecord):
		return {"splits": {}, "total": 0.0}
	return {"splits": (record as DotTimerRecord).splits.duplicate(true), "total": (record as DotTimerRecord).time}


## The standing [method refresh_standing] last worked out for [param id], or empty.
func standing_of(id: StringName) -> Dictionary:
	return _standings.get(id, {})


## What the Tab board says about [param id]: their style, their best on this map and
## track, and where it places them. From the standing [method refresh_standing] last worked
## out — which runs on every spawn, style change and filing — so a board held open twice a
## second costs no store reads at all.
func board_fields(id: StringName) -> Dictionary:
	var player: G2GPlayer = players.get(id)
	var standing: Dictionary = _standings.get(id, {})
	var style := ""
	if player != null and player.timer_style != null:
		style = player.timer_style.display_name
	return {
		"style": style,
		"best": float(standing.get("pb", 0.0)) if float(standing.get("pb", 0.0)) > 0.0 else -1.0,
		"rank": int(standing.get("rank", 0)),
		"of": int(standing.get("total", 0)),
		"ghost": player != null and player.replay != null,
	}


# --- Diagnostics -----------------------------------------------------------

func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("map          %s" % (String(maps.current.id) if maps != null and maps.current != null else "-"))
	out.append("players      %d" % players.size())
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if timers.tick_rate_matches_engine() else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("autobhop     %s" % ("on" if config.auto_bhop else "off"))
	out.append("movement     airaccel %.0f  accel %.1f  gravity %.0f  friction %.1f  maxvel %.0f" % [
		config.air_accelerate, config.accelerate, config.gravity, config.friction, config.max_velocity,
	])
	out.append("time left    %s" % time_left_text())

	if progress != null:
		out.append_array(progress.describe_lines())

	if combat != null:
		out.append_array(combat.describe_lines())

	if hunters != null:
		out.append_array(hunters.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	if bots != null:
		out.append_array(bots.call("describe_lines"))

	for id in players:
		out.append("  %s" % str((players[id] as G2GPlayer).describe()))
	return out


## The map's time left as an operator should read it: the vote's clock when there is a
## vote — "no limit" when that vote has none, "stopped" while a ballot holds it or it has
## run out — and
## the map session's otherwise.
##
## "no limit" here where the HUD shows nothing: a status line is read when somebody asks,
## and an absent row reads as a diagnostic that forgot to say, not as a clock that is off.
func time_left_text() -> String:
	if clock_fn.is_valid():
		var state: Dictionary = clock_fn.call()

		if not bool(state.get("has_clock", false)):
			return "no limit"

		var total := int(state.get("seconds_left", 0))
		return "%d:%02d%s" % [
			total / 60, total % 60, "" if bool(state.get("running", false)) else " (stopped)"
		]

	return maps.time_limit.formatted_remaining() if maps != null else "-"


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)
