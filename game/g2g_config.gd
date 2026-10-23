extends DotConfig

const G2GUnits := preload("g2g_units.gd")

## Everything a g2gfast server is configured with, in genre units, layered like every
## [DotConfig]: exported defaults, then a JSON file, then [code]G2G_*[/code]
## environment variables, then [code]--g2g-*[/code] arguments.
##
## [b]Every movement field here is one of the genre's cvars by another name[/b], in
## its own units and with its own defaults for a bunny-hop server. An operator who has
## run one of those servers sets [member air_accelerate] to 1000 for bhop and 150 for
## surf without reading anything, which is the point. The conversion to the metres
## the simulation runs in is [G2GMovement]'s, and happens nowhere else.
##
## [b]The tick rate is deliberately not here.[/b] It is dot-server's
## [code]sv_tickrate[/code], and the timer takes it from the engine — see
## [DotTimerConfig]. A second copy of that number is a second number that can
## disagree with the first, and the failure is a leaderboard wrong by their ratio with
## no error anywhere.

@export_group("Bunny-hopping")

## Hold jump to hop. The familiar [code]sv_autobunnyhopping[/code].
##
## [b]The setting this game exists to expose.[/b] Off, a hop has to be timed to the
## tick the player lands on — a keyboard-hardware contest. On, the skill is aiming the
## strafes, which is the actual game. Every modern bhop and surf server runs it on;
## it is on here by default for that reason, and a competition server turns it off.
@export var auto_bhop: bool = true

## Whether hopping may keep and build speed. [code]sv_enablebunnyhopping[/code].
##
## Off applies the landing cap (1.1 × max speed) those games added to [i]stop[/i]
## bunny-hopping. On a bhop server it is on.
@export var enable_bunnyhopping: bool = true

## Seconds before touchdown a jump press is still honoured. 0 is "on the tick".
##
## Only read when [member auto_bhop] is off. The community timers' easy-bhop window.
@export_range(0.0, 0.2, 0.005) var jump_buffer: float = 0.0

@export_group("Movement (genre units)")

## [code]sv_gravity[/code], in units per second squared.
@export_range(1.0, 4000.0, 1.0) var gravity: float = 800.0

## [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 5.0

## [code]sv_airaccelerate[/code]. 1000 for bhop, 150 for surf, 10 for a stock shooter.
@export_range(0.0, 10000.0, 1.0) var air_accelerate: float = 1000.0

## [code]sv_friction[/code].
@export_range(0.0, 50.0, 0.1) var friction: float = 4.0

## [code]sv_stopspeed[/code], in units per second.
@export_range(0.0, 500.0, 1.0) var stop_speed: float = 75.0

## Run speed, in units per second. The genre's knife speed.
@export_range(10.0, 2000.0, 1.0) var max_speed: float = 250.0

## [code]sv_maxvelocity[/code], in units per second. A backstop, not a gameplay number.
@export_range(100.0, 100000.0, 10.0) var max_velocity: float = 3500.0

## Airborne wish-speed cap, in units per second. Hard-coded at 30 in those games.
@export_range(0.0, 1000.0, 1.0) var air_wish_cap: float = G2GUnits.AIR_WISH_CAP

## Vertical velocity on a jump, in units per second.
@export_range(10.0, 2000.0, 0.1) var jump_velocity: float = G2GUnits.JUMP_VELOCITY

## [code]sv_stepsize[/code], in units.
@export_range(0.0, 64.0, 1.0) var step_size: float = 18.0

## Steepest floor a player can stand on, in degrees. A 0.7 floor normal is 45.57°.
@export_range(1.0, 89.0, 0.1) var max_slope: float = 45.57

## [code]sv_edgefriction[/code]. 1 disables it; those games ship 2.
@export_range(1.0, 10.0, 0.1) var edge_friction: float = 1.0

## `sv_crestlaunch`: speed, as a multiple of `sv_maxspeed`, above which the top of a walkable
## ramp throws a player instead of holding them to the floor past it. 0 never throws
## (dot-player-controller's `crest_launch_speed_scale`; a hop taken over a ramp's crest at
## speed leaves it, a run up it does not).
@export_range(0.0, 10.0, 0.01) var crest_launch: float = 1.25

@export_group("View")

## [code]fov_desired[/code]: horizontal field of view at 4:3, as those games define it.
##
## The one number a player carries between games. See
## [method G2GUnits.horizontal_fov_to_vertical] for why it is not handed to the camera
## directly.
@export_range(30.0, 150.0, 1.0) var fov_desired: float = 90.0

## [code]sensitivity[/code], with the meaning it has everywhere else: degrees per count is this × 0.022.
@export_range(0.01, 50.0, 0.01) var sensitivity: float = 2.5

## Whether players may use the third-person camera at all.
##
## Server-side, because a competition server may want everybody on the same view —
## third person sees over ledges first person cannot.
@export var allow_thirdperson: bool = true

## Which view a player starts in.
@export var default_thirdperson: bool = false

## [code]sv_flashlight[/code]: whether a player may switch on their own flashlight.
##
## Allowed by default, because the maps this server imports were built for a game whose
## every player carried one, and some of them have corners that are dark on purpose. The
## light is drawn on the player's own screen only — nobody else sees it, so nobody can be
## blinded by somebody else's — and this is the operator's way to say no.
@export var flashlight: bool = true

## [code]sv_stagger_snapshots[/code]: spread the snapshot work over the ticks between
## snapshots, a share of the peers on each tick, instead of every peer on one tick.
##
## On by default since 2026-10-09. It changes WHEN a given peer hears about a tick, not
## what it hears: each peer still gets one snapshot per period, at a fixed tick of its own
## within it rather than all on one. What it buys is the worst tick on a full server -- 32
## players measured 46.6 ms p99 against 22.7 staggered in tools/load_probe
## (LOAD_STAGGER=1) -- and the worst tick is the one that holds everybody's input up. Off
## for an operator who wants every peer on the same tick (the cvar is live).
@export var stagger_snapshots: bool = true

## [code]sv_spec_list[/code]: whether a player is told who is spectating them (and the
## people watching the same runner are told too).
##
## On by default, because on a records server being watched is the point: somebody going
## for a record wants to know the server is watching. Off is an operator saying spectating
## is anonymous here — and then the names are not sent at all, rather than sent and hidden,
## so a modified client cannot draw them anyway. A player who does not want the list on
## their screen turns `show_spectators` off on their own side.
@export var spectator_list: bool = true

@export_group("Content")

## The map a server loads when it boots.
##
## [b]An imported map, and not one of the three built in code.[/b] `bhop_g2g_intro` is
## sixteen blocks in a straight line: it proves the movement and it is what a suite
## should run, which is why every example here still sets it explicitly. It is not what
## a player arriving at a public server should be met by. `surf_mesa` is a real
## imported map — one long descent with a start, a finish, a pit and a push volume —
## and it is the default for the same reason a server ships with a map rather than with
## a test fixture.
##
## It also makes the imported half the DEFAULT path rather than the one nothing reaches
## unless somebody types a map name, which is this family's own rule about deployment
## shapes: the built-in maps are a scene and a script and can never fail to be there,
## and an imported map is data at a path that has to be found, parsed and built.
@export var initial_map: StringName = &"surf_mesa"

## An extra directory to find imported maps in, outside the build.
##
## [b]This is how a shipped server is given a map.[/b] `res://` is a read-only PCK in
## an exported build, so a map baked in at export time is the only one a server can
## ever play unless it can look somewhere else. `user://maps` is always searched;
## this names one more, wherever an operator keeps them.
@export_dir var maps_directory: String = ""

## A map catalogue JSON file. Empty uses the maps this build ships.
@export var catalogue_path: String = ""

## Map ids to fetch from the content origin at boot, beyond the one being loaded.
##
## [b]This is the map list a delivered server has instead of a directory.[/b]
## [G2GMapCatalogue] finds maps by looking, and that is still how a server run from
## source gets all eight of them — they are on its disk. A server that mounts the game
## as a pack has no `maps/imported/` at all: the directory is excluded from the pack
## on purpose, because it is 66 MB of geometry and a player should download the map
## being played rather than every map that could be. So the catalogue on a delivered
## server holds the built-in scenes and whatever has been FETCHED, and nothing has been
## fetched until somebody asks for it by name.
##
## What that costs is not the `map` command — [member DotMapCommands.may_fetch_unknown]
## lets a typed id through to the fetch — it is everything that reads the catalogue as
## a SET: `maps` lists three scenes on a surf server, the rotation can only ever choose
## between those three, and `rtv` offers them. A rotation that silently excludes every
## real map is the failure worth naming, because the server keeps working and just
## never plays anything anybody came for.
##
## Fetched in the background after boot, one at a time, and already-cached ones cost
## nothing. Set it from `sv_content_maps`, space- or comma-separated.
@export var content_maps: PackedStringArray = PackedStringArray()

## Whose namespace a map is fetched from. `sv_map_content_owner`.
##
## [b]A map id and a content id are not the same thing any more, and this is the whole
## difference.[/b] The id is what a player types (`map surf_mesa`), what every record,
## zone file and vote is filed under, and it must not move. The content id is where the
## pack lives on the origin, and a pack on a shared origin belongs to somebody:
## `gamemann/surf_mesa`, the `<owner>/<name>` shape the site gives every pack it
## publishes. So the owner is prefixed where a map is FETCHED and nowhere else. Empty
## keeps the old unowned layout (`surf_mesa`), which is what an origin that predates
## owners still serves.
@export var map_content_owner: String = ""

## The cvar that sets [member map_content_owner]. One spelling for the module that registers
## it and for [method G2GGame._adopt_descriptor_owner], which reads it out of a game
## descriptor before the module exists.
const MAP_CONTENT_OWNER_CVAR := "sv_map_content_owner"


## The content id map [param id] is fetched as. See [member map_content_owner].
func map_content_id(id: StringName) -> String:
	var name := String(id)
	if map_content_owner.strip_edges().is_empty() or name.contains("/"):
		return name
	return "%s/%s" % [map_content_owner.strip_edges(), name]

## Seconds a map runs before the next is chosen. 0 disables it.
##
## Forty-five minutes: a records map is learned over several attempts, and the people still
## running it at the limit are the ones who wanted more of it. A map's own `meta.vote`
## time limit still wins, for the three-stage intro that wants ten.
@export_range(0.0, 86400.0, 30.0) var map_seconds: float = 2700.0

## [member map_seconds] for a game played OFFLINE: by yourself, with nobody waiting for
## the next map. 0, no limit, by default -- a clock that changes the map under a player
## alone on it is a clock that interrupts practice and serves nobody. Set it (JSON, env or
## `--g2g-offline-map-seconds`) for an offline session that should still rotate.
@export_range(0.0, 86400.0, 30.0) var offline_map_seconds: float = 0.0

## The file that says which maps a server ROTATES: `cfg/maps.yml`, layered over the game's own
## shipped `res://maps.yml` (see dot-map's `DotMapRotationFile` for the format: named
## rotations, `random` or `cycle`, wildcards). Empty, or no such file, rotates every map in the
## catalogue but a combat one, which is what this game always did.
##
## A map the active rotation does not list stays INSTALLED: `map <id>` loads it and the map
## list (M) shows it, marked as not in rotation. It is only left out of the rotation, the
## vote and nominations. `sv_map_rotation_file`; `sv_map_rotation <name>` switches the list.
@export var map_rotation_file: String = "cfg/maps.yml"

## Seconds a map change waits for every connected client to say it has the new map.
## `sv_map_sync_timeout`.
##
## [b]Thirty, where dot-map's own default is three hundred[/b], and the difference is who
## is waiting. The wait holds the whole server on the old map — every runner stopped, the
## clock frozen — for the slowest client, and a timer server's players came to run. A
## client that misses it is not dropped: the change goes ahead without it
## ([member DotMapSyncHost.swap_without_stragglers] stays on), it is told so, and it
## follows the moment its download finishes, because the load it was sent is queued
## behind its own fetch rather than lost. So a short wait costs the slow client a few
## seconds on the wrong map and a long one costs everybody else the same seconds.
@export_range(1.0, 3600.0, 1.0) var map_sync_seconds: float = 30.0

@export_group("Records")

## Where records go. Empty keeps them in memory only.
@export var records_directory: String = "user://g2gfast/records"

## A database for records instead of files: [code]sqlite[/code], or [code]postgres[/code]
## / [code]mysql[/code] through dot-sql's HTTP gateway. Empty keeps files.
##
## [b]A database is what lets several servers share one leaderboard[/b], which files
## cannot: each server would keep its own. If the database cannot be opened at boot the
## server says so at ERROR and keeps files, rather than refusing to start — a timer
## server with no records is still a server people can play on.
@export var records_database: String = ""

## SQLite only: the database file.
@export var records_database_path: String = "user://g2gfast/records.db"

## Postgres or MySQL: the gateway's URL, e.g. http://10.0.0.5:8780.
@export var records_database_url: String = ""

## The gateway's bearer token. [b]From the config file only[/b] — refused from the
## environment and the command line, which every process on the box can read.
@export var records_database_token: String = ""

## Table name prefix, so several games can share one database.
@export var records_table_prefix: String = "dot_timer_"

## Seconds a cached board read is served. Another server's new record is at most this
## old on this server's HUD; this server's own are on it at once.
@export_range(0.0, 600.0, 1.0) var records_cache_seconds: float = 10.0

## How records are scored: [code]curve[/code], [code]tiered[/code] or
## [code]placement[/code]. See DotTimerPoints. `timer_points_formula`.
@export var points_formula: String = "curve"

## Decay down a player's list of records when totalling them. 1 = a plain sum.
@export_range(0.5, 1.0, 0.001) var points_weighting: float = 0.975

## Whether a finish must have crossed every stage line to be filed.
@export var enforce_stages: bool = true

## Seconds a dropped player's run is kept for them to come back to. 0 = off.
@export_range(0.0, 86400.0, 10.0) var resume_seconds: float = 600.0

@export var record_replays: bool = true

## Whether the server record's replay runs the map as a ghost everybody can see —
## A replay bot, as every community timer has. Needs [member record_replays].
@export var show_replay_bot: bool = true

## Whether published boards reach the TMC backbone. Off by default: it sends player
## names and times off the server, and that is an operator's decision.
@export var report_to_backbone: bool = false

## Whether the server counts per-player statistics and awards achievements.
##
## [b]On, and it is cheap, but it is a switch rather than an assumption.[/b] A server
## that keeps lifetime numbers is one that writes a file per player, and an operator
## running a scratch instance or a LAN night should be able to say no. It is also what
## a client sets false — a mirroring client that counted its own finishes would file
## everybody's runs a second time.
@export var keep_progress: bool = true

@export_group("Modes")

## Whether players can shoot each other. `sv_deathmatch`.
##
## Off. This is a timer server. While it is on the timer still runs — a player who
## came to run must not be stopped by a player who came to shoot — so what it adds is
## hitboxes, health, an arsenal and a scoreboard, and it takes nothing away.
@export var deathmatch: bool = false

## Seconds of the final killcam when a deathmatch ends, added to the end's wait. `mp_killcam_time`; 0 is off.
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Whether hunters walk the course. `sv_hunters`.
##
## Off. A hunter cannot catch a runner who is running well — the fastest one does
## 8 m/s and a bhop player on a good line does forty — so what it punishes is
## stopping, which is what the timer already punishes.
@export var hunters: bool = false

## Whether an admin can place practice blocks. `sv_props`.
##
## Off, and while it is on a run made with anything placed is refused a record. A
## board with one time set over a placed block is a board nobody trusts.
@export var placeable_props: bool = false

@export_group("Role")

## Whether this instance times, ranks and decides. A client sets this false.
@export var authoritative: bool = true


## The database token is a secret: environment variables and argv are readable by every
## process on the box and end up in `ps` and in pasted bug reports.
func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["records_database_token"])


func env_prefix() -> String:
	return "G2G_"


func cli_prefix() -> String:
	return "--g2g-"


func validate() -> DotResult:
	if max_speed > max_velocity:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"max_velocity must not be below max_speed.",
			"%.0f vs %.0f u/s" % [max_velocity, max_speed]
		)

	# [b]Only an authoritative instance chooses a map.[/b] A client is told which map
	# it is in by the map-change protocol's announce, right behind HELLO, and clears this
	# deliberately (see [G2GClient]) — so requiring
	# one unconditionally made every networked client's own configuration invalid.
	# `load_layered` validates last and returns the failure, so every client logged
	# "the g2gfast configuration is not usable" on startup, about a config that was
	# exactly right for a client. Visible in the browser and in no headless run, because
	# the suites build their client config in code and never layer it.
	if authoritative and initial_map == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "There has to be a map to start on."
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "autobhop %s, airaccel %.0f, gravity %.0f, fov %.0f, map %s" % [
		"on" if auto_bhop else "off", air_accelerate, gravity, fov_desired,
		String(initial_map),
	]


## The fields that decide how a player moves — what travels to a client, in this
## order, so both ends derive one set of tunables.
const MOVEMENT_FIELDS: Array[String] = [
	"auto_bhop", "enable_bunnyhopping", "jump_buffer", "gravity", "accelerate",
	"air_accelerate", "friction", "stop_speed", "max_speed", "max_velocity",
	"air_wish_cap", "jump_velocity", "step_size", "max_slope", "edge_friction",
	# Appended, never inserted: a field before the end moves every later one for a reader of
	# the old order.
	"crest_launch",
]


## Rounds every movement value to what float32 can hold, in place.
##
## That is the precision the wire carries, and a server has to simulate with the
## values its clients received rather than the doubles it read from a file — or the
## two ends derive tunables that differ in the last bit and prediction never
## quite converges, with nothing to point at.
func snap_movement() -> void:
	for field in MOVEMENT_FIELDS:
		var value: Variant = get(field)
		if value is float:
			set(field, PackedFloat32Array([value])[0])
