extends "g2g_game_content.gd"

const G2GAvatars := preload("g2g_avatars.gd")
const G2GBspMap := preload("g2g_bsp_map.gd")
const G2GCamera := preload("g2g_camera.gd")
const G2GCombat := preload("g2g_combat.gd")
const G2GEffects := preload("g2g_effects.gd")
const G2GEvents := preload("net/g2g_events.gd")
const G2GHunters := preload("g2g_hunters.gd")
const G2GMap := preload("g2g_map.gd")
const G2GMapMechanics := preload("g2g_map_mechanics.gd")
const G2GMovement := preload("g2g_movement.gd")
const G2GPaths := preload("g2g_paths.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GPlayerBodies := preload("g2g_player_bodies.gd")
const G2GPlayerStack := preload("g2g_player_stack.gd")
const G2GProgress := preload("g2g_progress.gd")
const G2GProps := preload("g2g_props.gd")
const G2GReplays := preload("g2g_replays.gd")
const G2GSpectate := preload("g2g_spectate.gd")
const G2GUnits := preload("g2g_units.gd")
const G2GWeaponLayer := preload("g2g_weapon_layer.gd")


## The registry name a dot-server module finds this under.
const CONFIG_GAME_ID := "game-g2gfast"
const SERVICE := &"g2g_game"

## The ghost's player id. Session ids are dot-server userids, which never get
## this large; the bridge treats it as a session like any other.
const GHOST_ID := &"u900000001"
const GHOST_SESSION := 900000001

signal map_ready(map: DotMapDef)

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


## A JSON file layered over [member config]'s defaults, or empty.
@export var config_file: String = ""

## The config as an operator surface (cvars, cfg/ profile, workbench, yml diff). Built in
## [method _ready] over [member config].
var config_binder: DotGameConfigBinder = null

## Whether players are solid to each other (`mp_solidplayers`, 1). Every player has a hull
## (`g2g_player_bodies.gd`) and dot-team's block rules, on `pair_fn`, say which pairs stop:
## runners pass through each other (the genre) until `mp_teamblock`, `mp_enemyblock` or `!block`
## say otherwise. With no block rules (no dot-team in the build) nobody blocks.
var body_rules: DotPlayerBodyRules = _make_body_rules()

## dot-team's `DotTeamBlockRules` (`mp_teamblock`, `!block`, `!noblock`), set by the module or
## the client's `add_noblock`; null while dot-team is not in the build.
var block_rules: Object = null:
	set(value):
		block_rules = value
		if value != null and value.has_signal(&"changed") and not value.is_connected(&"changed", body_rules.refresh):
			value.connect(&"changed", body_rules.refresh)
		body_rules.refresh()


## Whether some pair of players currently stops at each other (set by `G2GPlayerBodies.apply`).
var hulls_live: bool = false

## Whether nothing a player's body queries moves between ticks: no placed props (rigid bodies)
## and no player hulls. Lets the motor reuse a ground probe across ticks.
func world_is_static() -> bool:
	return props == null and not hulls_live


## Snapshots a second sent at [param rate] ticks: the nearest to 32 that is whole ticks apart
## (60 gives 30). dot-net divides with integers, so 32 at 60 Hz sent every tick.
static func snapshot_rate_for(rate: int) -> int:
	return rate / maxi(1, roundi(float(rate) / 32.0))


static func _make_body_rules() -> DotPlayerBodyRules:
	var rules := DotPlayerBodyRules.new()
	rules.pair_fn = func(_a: Variant, _b: Variant) -> bool: return false
	return rules


## The side a player stands on for the block rules: the one team of a free-for-all, "" without one.
func block_side(id: Variant) -> Variant:
	if player_stack == null or player_stack.teams == null:
		return ""
	var team := String(player_stack.teams.team_of(str(id)))
	return team

## Fallback tick rate when nothing has told the engine. A dot-server always has.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process — the
## shape every headless netcode test in this family takes.
@export var service_scope: StringName = &""


## The dot-server game manager to read a loading game's descriptor from, by registry name.
## See [method _adopt_descriptor_owner]. Nothing under it is normal: a suite, a client.
@export var game_manager_service: StringName = DotGameManager.SERVICE


var authoritative: bool = true

## What the loaded map's brush entities do to a player (water, pushes, sinking blocks...).
## Built from the manifest on every map change, on both ends: the client predicts with it.
var mechanics: G2GMapMechanics = null

## The server's maps.yml, or null when there is none. See [method load_rotation].
var rotation_file: DotMapRotationFile = null

## Where [member rotation_file] was read from, or "" when there was no file.
var rotation_source: String = ""


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
## Where the boards live; null builds one layered from [constant BOARDS_CONFIG_PATH].
var boards_config: DotBoardsConfig = null

const BOARDS_CONFIG_PATH := "user://g2g_boards.json"

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

## Weapons lying in the world (both sides build it; the server simulates).
var weapon_layer: G2GWeaponLayer = null

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


## dot-player-controller's `mp_forceview`: third person allowed (0), held first (1) or third (2).
## `sv_allow_thirdperson` writes it; bound REPLICATED by the module, followed by a client.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()

## dot-mobile's `sv_mobile_*`, `sv_aim_assist*` and `sv_autofire*`: what a phone player may use. Bound REPLICATED by
## the module, followed by a client. Aim assist and auto-fire need targets this game does not hand in, so stay inert.
var mobile_rules: DotMobileRules = DotMobileRules.new()

## dot-replay's `mp_killview*`: the killer's replayed eye, off until the server turns it on.
var killview_rules: DotKillViewRules = DotKillViewRules.new()

## Hulls, masks and exclusions to match `body_rules` ([G2GPlayerBodies.apply]): when the rules
## change, and when a player joins or leaves.
func _apply_bodies() -> void:
	G2GPlayerBodies.apply(self)


## Every camera under the view rules now, and the config's switch kept in step.
func _on_view_rules_changed() -> void:
	config.allow_thirdperson = view_rules.allows_third()
	for id in players:
		var p: G2GPlayer = players[id]
		if p.camera != null:
			p.camera.follow_view_rules(view_rules)


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


## The engine's rate when a server has set it, else the export. See game-playlot.
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
	if boards_config == null:
		boards_config = DotBoardsConfig.for_game("g2g")
		var layered := boards_config.load_layered(BOARDS_CONFIG_PATH)
		if not layered.ok:
			DotLog.warn(CHANNEL, "the boards configuration is not usable, using memory", {
				"why": str(layered.error),
			})
			boards_config = DotBoardsConfig.for_game("g2g")
	boards.backend = boards_config.backend
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)
	_bind_board_reporter()

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


## Hands the boards' reporter the backbone client the host (or the identity layer) registered.
##
## **Without this the reporter has no client, so nothing is ever sent**: `publish` was on and
## `report_to_backbone` was on, every record was queued, and the site had no board for any
## g2gfast server (found on the dev end-to-end run, 2026-11-08). The stats and achievement
## trackers find the client by themselves; the boards' reporter only has what it is given.
## Safe to call again: it binds once, and a client that registers later is picked up by the
## next call (a record being filed).
func _bind_board_reporter() -> void:
	if boards == null or not config.report_to_backbone or boards.reporter.client != null:
		return

	var client: Object = DotRegistry.get_service(&"dot_backbone_client")

	if client != null:
		boards.reporter.client = client


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
## Before `_build_maps`: they connect to `map_ready`, which `_ready` can fire for an initial
## map. Each is built even when disabled, because `enabled` is a cvar flipped mid-map.
func _build_layers() -> void:
	weapon_layer = G2GWeaponLayer.new()
	weapon_layer.setup(self)

	if not authoritative:
		# Spectating is the one layer a client needs: its camera is drawn from this client's poses.
		_build_spectate()
		return

	# Loaded (g2g_bots.gd preloads this file) and rebased: a bare res:// path misses in a pack.
	bots = (load(G2GPaths.rebase("res://game/g2g_bots.gd")) as GDScript).new()
	bots.name = "Bots"
	bots.set("game", self)
	add_child(bots)

	if config.deathmatch or config.hunters:
		# The hunters need combat to put damage somewhere, so it is built for either.
		combat = G2GCombat.new()
		combat.name = "Combat"
		combat.game = self
		combat.enabled = config.deathmatch
		combat.score_limit = config.score_limit
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

	# Built whatever else is on: a plain timer server still lets a player watch a runner.
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


## Marks every catalogue map in or out of rotation from the file; no file keeps `arena`-kind maps out.
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
