extends Node

const G2GConfig := preload("../g2g_config.gd")
const G2GEvent := preload("g2g_event.gd")
const G2GEvents := preload("g2g_events.gd")
const G2GGame := preload("../g2g_game.gd")
const G2GMapCatalogue := preload("../g2g_map_catalogue.gd")
const G2GNetCommand := preload("g2g_net_command.gd")
const G2GNetLink := preload("g2g_net_link.gd")
const G2GPlayer := preload("../g2g_player.gd")
const G2GPlayerNet := preload("g2g_player_net.gd")
const G2GNpcNet := preload("g2g_npc_net.gd")
const G2GHunters := preload("../g2g_hunters.gd")
const G2GRequest := preload("g2g_request.gd")

## Joins a [G2GGame] to a [DotNetManager]: the only file in this project that names both.
## dot-net simulates per entity but this game ticks as a whole, so [method ensure_game_ticked]
## lets the first behaviour through run the game and the rest find it done.

const CHANNEL := "g2g.net"
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so one lost packet costs
## no tick. One copy ran 80% of ticks on the right command at 20% loss over ENet; three gave
## 99-100%, five closed the rest.
const INPUT_COPIES := 5

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)
signal roster_changed(player_id: int)
## A finish announced by the authority. [param rank] 0 means it was not filed.
signal finish_received(player_id: int, time: float, rank: int)
signal notice_received(player_id: int, text: String)
## The map vote's cue and countdown second, from [method G2GEvents.read_vote]. Client side.
signal vote_received(info: Dictionary)
## The vote's clock changed: [member clock_view] has just adopted [param state]. Client
## side.
signal clock_received(state: Dictionary)

## The local player's standing, from the server: [code]{pb, wr, rank, total}[/code].
signal standing_received(player_id: int, standing: Dictionary)

## The local player's splits comparison, from the server: [method G2GGame.stage_reference]'s
## shape. The client has no store, so this is the only way its panel learns a best.
signal stage_reference_received(player_id: int, reference: Dictionary)

## What the server allows on this client's own screen, and the chat commands it answers:
## [code]{flashlight, thirdperson, commands}[/code]. Client side. See [method rules_body].
signal rules_received(rules: Dictionary)
## This client cannot follow the server to the map it announced: refused by dot-map's trust
## rules, not fetchable, or not loadable. Client side. [G2GClient] leaves the server on it,
## because a client on a world the server is not simulating is corrected into the air every tick.
signal map_refused(map_id: StringName, reason: String)
## The map-change protocol put this client on a map. Client side.
signal map_loaded(map: DotMapDef)

var game: G2GGame = null
var net: DotNetManager = null
var link: G2GNetLink = null

## [code]func(bytes: PackedByteArray) -> void[/code]. Where a received voice frame goes on a client.
## A callable, not a typed reference: this file must not name dot-voice, or a build without
## the addon fails to parse.
var voice_in_fn: Callable = Callable()

## [code]func(speaker_peer: int, bytes: PackedByteArray) -> void[/code]. Where a
## client's captured audio goes on a server. [G2GServices] points it at
## `DotVoiceRouter.relay`.
var voice_relay_fn: Callable = Callable()

## [code]func(player_id: StringName) -> void[/code]. What a client's RTV request does on the server.
## Empty falls back to [method G2GGame.rock_the_vote], wrong on a server with a ballot: the
## module points this at the vote so `!rtv` and the wire request are one vote.
var rtv_fn: Callable = Callable()

## [code]func() -> Dictionary[/code], in [method DotVoteClockView.state_of]'s shape: the map's time
## left, told to a joining peer. Server side; empty sends nothing and the client shows its own
## session's clock.
var clock_fn: Callable = Callable()

## [code]func() -> Array[/code] of [code][name, help][/code]: the commands a player may type in chat.
## Server side, pointed at the console by the module (the bridge never names it); empty
## sends no list.
var commands_fn: Callable = Callable()

## `(session_id: int) -> bool`: whether that player may change the map. Set by the module
## from the session's changemap flag; unset, nobody may (a bridge with no module has no
## admins to ask about).
var may_change_map_fn: Callable = Callable()

## `(peer: int) -> void`: a peer was admitted (it said READY and was seated). Set by the module to send the workbench's rows.
var peer_ready_fn: Callable = Callable()

## The server's map list arrived, for the M screen.
signal maps_received(rows: Array)

## The server said whom this client is watching: a player key and their name, or an
## empty key for nobody. Client side; the mirror is already updated when it fires.
signal spectate_received(target: StringName, target_name: String)

## The server said who is watching [param target]. Client side.
signal spectators_received(target: StringName, names: PackedStringArray)

## Somebody's weapon went off (any player, the local one included); the server's word.
signal shot_received(player: StringName, weapon: StringName, at: Vector3)

## A hit of this client's player that the server applied (see [signal G2GCombat.hit_landed]).
signal hit_received(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool)

## A player died: their key, and how the body falls (null from a server that did not say).
signal death_received(player_id: StringName, death: DotPlayerDeath)

## A dead player is alive again: their key.
signal alive_received(player_id: StringName)

## A kill on the server: player keys (empty for the world), the weapon id and whether it was the head.
signal kill_received(killer: StringName, victim: StringName, weapon: String, headshot: bool)

## The deathmatch ended: the killcam's seconds and the top of the board.
signal match_end_received(killcam_sec: float, rows: Array)

## The map's time left as the server last described it. Client side; what the HUD draws.
## Never adopted means never told, which the HUD answers with the local clock.
var clock_view: DotVoteClockView = DotVoteClockView.new()

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## The host half of dot-map's map-change protocol. Server side; built by [method attach]
## and handed to the game as [member G2GGame.map_sync]. See "Map changes" below.
var map_host: DotMapSyncHost = null

## The peer half. Client side; built by [method attach].
var map_client: DotMapSyncClient = null

## Where the clock learns the link's length in milliseconds (`DotClientLink.ping_ms()`); dot-net
## cannot measure it. Unfed, the clock assumes an instant link and stamps commands for ticks
## already simulated. Read on every snapshot.
var rtt_source: Callable = Callable()


var _entities: Node = null
var _behaviours: Dictionary = {}
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]); over ENet with loss
## READY can overtake `loaded`, and a READY dropped here left the client waiting for a world
## for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

## Client: the longest frame whose every tick the engine still simulates. See
## [method _keep_up_through_slow_frames].
const SLOW_FRAME_SECONDS := 0.25
var _tick: int = 0
var _adding: bool = false
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1

## Client: the map id of the announce being handled, for [signal map_refused]. dot-map
## reports a refused announce with no map, because it refused to make one.
var _map_handling: StringName = &""

## Client: the map the server is simulating, as its last `load` said. See [method in_transit].
var _server_map: StringName = &""

## Client: how far the announced map's download has got, 0..1. For the loading cover.
var map_fetch_fraction: float = 0.0

## A style index -> id table both ends build identically. See [DotTimerNet].
var _style_ids: Array[StringName] = []
