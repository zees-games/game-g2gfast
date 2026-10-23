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

## Joins a [G2GGame] to a [DotNetManager]. The netcode seam, and the only file in
## this project that names both.
##
## [b]The ordering is the whole file.[/b] dot-net drives simulation per entity, and
## this game's tick is a whole-game property: everybody moves, then every timer is fed
## the position its move produced. [method ensure_game_ticked] reconciles the two —
## the first behaviour through on a tick runs the whole game, the rest find it done.
##
## [codeblock]
## # server
## bridge.attach(game, net, server)      # `server` is the node the link mirrors
## bridge.add_player(peer_id, session_id, "Ada", avatar)
## bridge.server_tick(tick)              # instead of the game's own loop
##
## # client
## bridge.attach(game, net, client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command)
## [/codeblock]
##
## Modelled on dot-2d-hungry's bridge, the one in this family proven over a real
## socket, with two things it does not need — chunked field state and per-piece
## entities — left out, and one it lacks: the movement configuration travels, so a
## client derives bit-identical tunables and prediction converges.

const CHANNEL := "g2g.net"
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet
## costs the server no tick unless the next four are lost too. Over WebSocket nothing is
## ever lost; over ENet (the desktop client, since servers went dual-stack) one command a
## packet was a tick the server ran on the previous command for every packet dropped.
## game-arena measured it first: 80% of ticks with the right command at 20% loss with one
## copy, 99-100% with three, and five closed the rest (2026-10-09).
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
## This client cannot follow the server to the map it announced: refused by dot-map's
## trust rules, not fetchable, or not loadable. Client side. [G2GClient] leaves the server
## on it, because a client on a world the server is not simulating is a player being
## corrected into the air every tick.
signal map_refused(map_id: StringName, reason: String)
## The map-change protocol put this client on a map. Client side.
signal map_loaded(map: DotMapDef)

var game: G2GGame = null
var net: DotNetManager = null
var link: G2GNetLink = null

## [code]func(bytes: PackedByteArray) -> void[/code]. Where a received voice frame goes
## on a client. The client points it at `DotVoiceManager.receive`.
##
## A callable rather than a typed reference, because this file must not name dot-voice:
## a build with no voice addon installed would otherwise fail to parse, and the whole
## point of a bridge is that it is the only file naming two things at once.
var voice_in_fn: Callable = Callable()

## [code]func(speaker_peer: int, bytes: PackedByteArray) -> void[/code]. Where a
## client's captured audio goes on a server. [G2GServices] points it at
## `DotVoiceRouter.relay`.
var voice_relay_fn: Callable = Callable()

## [code]func(player_id: StringName) -> void[/code]. What a client's RTV request does on
## the server. Empty falls back to [method G2GGame.rock_the_vote], which is the map
## session's own time limit — right on a server with no vote and wrong on one with a
## ballot, where the module points this at the vote so a request off the wire and a
## `!rtv` typed in chat are one vote rather than two.
var rtv_fn: Callable = Callable()

## [code]func() -> Dictionary[/code], in [method DotVoteClockView.state_of]'s shape. What a
## joining peer is told about the map's time left. Server side; empty sends nothing, and
## the client then shows its own map session's clock — which on a server with no vote is
## the one that ends the map.
var clock_fn: Callable = Callable()

## [code]func() -> Array[/code] of [code][name, help][/code]: the commands a player may type
## in chat on this server. Server side, pointed at the console by the module, because the
## bridge never names dot-server's console; empty sends no list and the client's help
## screen says it has none rather than inventing one.
var commands_fn: Callable = Callable()

## `(session_id: int) -> bool`: whether that player may change the map. Set by the module
## from the session's changemap flag; unset, nobody may (a bridge with no module has no
## admins to ask about).
var may_change_map_fn: Callable = Callable()

## The server's map list arrived, for the M screen.
signal maps_received(rows: Array)

## The server said whom this client is watching: a player key and their name, or an
## empty key for nobody. Client side; the mirror is already updated when it fires.
signal spectate_received(target: StringName, target_name: String)

## The server said who is watching [param target]. Client side.
signal spectators_received(target: StringName, names: PackedStringArray)

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

## Where the clock learns how long the link is, in milliseconds. dot-net never
## touches a transport and cannot measure it; dot-server's heartbeat already does
## (`DotClientLink.ping_ms()`), and a client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has
## already simulated. Read on every snapshot.
var rtt_source: Callable = Callable()


var _entities: Node = null
var _behaviours: Dictionary = {}
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]). A client sends READY
## when its link says PLAYING, which the link decides itself after sending `loaded` on another
## channel; over ENet with loss the READY can overtake `loaded`, and a READY dropped here left
## that client waiting for a world for ever. Admitted when seated.
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


# --- Wiring ----------------------------------------------------------------

func attach(p_game: G2GGame, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	for style in game.timers.styles_in_order():
		_style_ids.append(style.id)

	net.send_fn = _send

	var event := net.messages.register(
		G2GEvent.NAME, G2GEvent, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		G2GRequest.NAME, G2GRequest, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(G2GEvent.NAME, _on_event)
	net.messages.on(G2GRequest.NAME, _on_request)

	link = G2GNetLink.attached_to(link_parent, self, net.is_server)
	# Not a bare add_child: the link must sit under the server node (RPCs route by path) yet die
	# with this bridge. Without that a module reload left a second link, Godot renamed the live
	# one `@Node@n`, and every RPC to a real client was lost without an error. DotGameLink frees
	# it with the bridge, and without remove_child, which errors when the whole tree is torn down.
	DotGameLink.attach(link, link_parent, self, G2GNetLink.NODE_NAME)

	_build_map_sync()

	# Both ends: the server's tick is server_tick, and the client's is client_tick,
	# which simulates what it predicts and leaves the rest to interpolation. A
	# client game still running its own loop would simulate the local player twice
	# a tick and dead-reckon every remote one from stale state.
	game.external_tick = true

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.timers.player_started.connect(_on_run_started)
		game.timers.player_stopped.connect(_on_run_stopped)
		game.timers.player_staged.connect(_on_staged)
		game.run_filed.connect(_on_run_filed)
		game.standing_changed.connect(_on_standing_changed)
		game.stage_reference_changed.connect(_on_stage_reference_changed)
		game.announced.connect(_on_announced)
		game.movement_changed.connect(_on_movement_changed)
		game.map_ready.connect(_on_map_ready)
		# Built in the game's `_ready`, before any bridge, or never (no deathmatch and no
		# hunters), so connecting once here sees every combat layer this game will have.
		if game.combat != null:
			game.combat.hit_landed.connect(_on_hit_landed)
			# Every death, a hunter's included, and every return: before this nothing
			# connected player_killed, and a dead runner stood upright on every screen.
			game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
				broadcast_death(game.combat.player_id_for(entry.victim_key.to_int()))
				broadcast_kill(entry))
			if game.combat.match_node != null:
				# Deferred: the last kill ends the match from inside its own report, before the
				# kill is broadcast, and the killcam needs the kill first.
				game.combat.match_node.match_ended.connect(
					func(_winner: int, _outcome: int) -> void: broadcast_match_end.call_deferred())
			game.combat.player_respawned.connect(broadcast_alive)

	return DotResult.success(self)


## To the one who fired: their marker and number are drawn from this, never predicted.
func _on_hit_landed(by: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> void:
	var peer_id := peer_for_player(session_of(by))
	if peer_id > 0:
		_tell(peer_id, G2GEvents.Kind.HIT, G2GEvents.write_hit(victim, amount, point, killed, headshot))


## To everybody: [param id] died, and how the body falls ([member G2GPlayer.death], the
## server's pick). Server side; from [signal G2GCombat.player_killed].
func broadcast_death(id: StringName) -> void:
	var victim: G2GPlayer = game.players.get(id)
	if victim != null:
		_broadcast(G2GEvents.Kind.DEATH, G2GEvents.write_death(session_of(id), victim.death))


## To everybody: a kill, for the final killcam. Server side.
func broadcast_kill(entry: DotKillFeed.Entry) -> void:
	var killer := game.combat.player_id_for(entry.killer_key.to_int()) if entry.killer_key != "" else &""
	_broadcast(G2GEvents.Kind.KILL, G2GEvents.write_kill(
		session_of(killer) if killer != &"" else 0,
		session_of(game.combat.player_id_for(entry.victim_key.to_int())),
		String(entry.cause), entry.headshot))


## To everybody: the deathmatch is over. Server side; from [signal DotMatch.match_ended].
func broadcast_match_end() -> void:
	_broadcast(G2GEvents.Kind.MATCH_END, G2GEvents.write_match_end(
		game.config.killcam_seconds, game.combat.podium_rows()))


## To everybody: [param id] is alive again. Server side; from [signal G2GCombat.player_respawned].
func broadcast_alive(id: StringName) -> void:
	_broadcast(G2GEvents.Kind.ALIVE, G2GEvents.write_player(session_of(id)))


func _style_index(id: StringName) -> int:
	return maxi(_style_ids.find(id), 0)


func _style_id(index: int) -> StringName:
	return _style_ids[index] if index >= 0 and index < _style_ids.size() else &"normal"


# --- Transport -------------------------------------------------------------

func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return
	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## Peer by peer, never the broadcast address: a broadcast reaches peers that have
## not built their scene yet, and every one of those is a lost event.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server:
		return
	for peer_id in _ready_peers.keys():
		net.send(G2GEvent.new(kind, body), int(peer_id))


## The map vote's cue or countdown second, to every ready peer. Server side.
func broadcast_vote(cue: StringName, seconds_left: int, runoff: bool) -> void:
	_broadcast(G2GEvents.Kind.VOTE, G2GEvents.write_vote(String(cue), seconds_left, runoff))


## The vote's clock, to every ready peer. Server side.
func broadcast_clock(state: Dictionary) -> void:
	_broadcast(G2GEvents.Kind.CLOCK, G2GEvents.write_clock(state))


func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net != null and net.is_server and peer_id > 0:
		net.send(G2GEvent.new(kind, body), peer_id)


# --- Membership (server) ---------------------------------------------------

## Adds a player and makes them a replicated entity. [param session_id] is the id
## everything is keyed by; a peer id is reassigned on reconnect.
func add_player(
	peer_id: int, session_id: int, display_name: String, avatar: DotAvatar = null,
	record_key: StringName = &""
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var id := _player_key(session_id)
	_adding = true
	var player := game.add_player(id, display_name, false, avatar, false, record_key)
	_adding = false

	if player == null:
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	var identity := _build_entity(player, peer_id)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		game.remove_player(id)
		return registered

	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)
	_map_forget(peer_id)

	# Released BEFORE the game is told, and the ordering is load-bearing:
	# game.remove_player emits player_removed, which _on_player_removed answers by
	# releasing the entity and broadcasting LEAVE. Releasing first empties
	# _behaviours, so that handler finds nothing and this function stays the one
	# place a leaving player is announced.
	_release_entity(session_id)
	# The world can be gone already: a server changing to another game frees this game's
	# scene before it unloads the module, and the module's unload is what calls this. A
	# call on the freed G2GGame took the whole server down (signal 11).
	if game != null and is_instance_valid(game):
		game.remove_player(_player_key(session_id))
	# Whoever was watching them has been moved on by now (the spectate layer answers
	# player_removed), and whoever they were watching has one spectator fewer.
	_send_spectator_lists()

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)
		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(G2GEvents.Kind.LEAVE, G2GEvents.write_player(session_id))
	roster_changed.emit(session_id)


## A player the game made itself — its ghost — becomes a bot: an entity with no
## peer, replicated to everybody, as a bot on any server is.
func _on_player_added(player: G2GPlayer) -> void:
	if _adding or player == null or net == null or not net.is_server:
		return
	var session_id := session_of(player.player_id)
	if _behaviours.has(session_id):
		return
	var identity := _build_entity(player, 0)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a game-made player", {"error": str(registered.error)})
		return
	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)
	if _behaviours.has(session_id):
		# The game removed it itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(G2GEvents.Kind.LEAVE, G2GEvents.write_player(session_id))
		roster_changed.emit(session_id)


static func _player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func _build_entity(player: G2GPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: DotNetIdentity collects behaviours
	# in _ready by walking the subtree, and one added afterwards would never be found.
	var behaviour := G2GPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's
	# own movement a round trip behind their keys.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)

	_behaviours[session_of(player.player_id)] = behaviour
	return identity


func _release_entity(session_id: int) -> void:
	# Untyped first: assigning a freed node to a typed variable is a script error, and the
	# behaviour is freed with the world when a game change gets here before the module unloads.
	var held: Variant = _behaviours.get(session_id)
	_behaviours.erase(session_id)
	if held == null or not is_instance_valid(held):
		return
	var behaviour := held as G2GPlayerNet
	if behaviour != null and behaviour.identity != null and is_instance_valid(behaviour.identity) and net != null:
		net.registry.unregister(behaviour.identity.net_id)


## Redresses a player from the server side — dot-platform's wardrobe change — and
## tells everybody. The same path a client's own AVATAR request takes.
func dress(session_id: int, avatar: DotAvatar) -> bool:
	var player: G2GPlayer = game.players.get(_player_key(session_id)) if game != null else null
	if player == null or avatar == null:
		return false
	if not player.rig.dress(avatar, game.avatar_schema, game.avatar_catalogue).ok:
		return false
	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	return true


func behaviour_for(session_id: int) -> G2GPlayerNet:
	return _behaviours.get(session_id)


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func local_player() -> G2GPlayer:
	return game.players.get(_player_key(local_player_id)) if game != null else null


# --- The authoritative tick ------------------------------------------------

## One server tick, replacing the game's own loop.
## Hunters this server replicates: instance id -> their [G2GNpcNet]. Server side.
var _hunter_nets: Dictionary = {}

## Hunters this client draws: net id -> their [G2GNpcNet]. Client side.
var _hunter_mirrors: Dictionary = {}

## The spawner whose signals this is connected to. `sv_hunters` builds and a map change
## rebuilds the hunters, so it is checked every tick rather than connected once.
var _watched_spawner: DotNpcSpawner = null

var _hunter_world: Node3D = null


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	_watch_hunters()
	_watch_spectate()
	if net != null:
		net.server_tick(tick)
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return
	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: G2GPlayerNet = _behaviours[session_id]
		# Only what a peer sent. A bot has no peer and is driven by something else
		# — a replay, a test, an AI — and an empty command applied over the top of
		# that would stand it still.
		if behaviour.player != null and behaviour.identity != null and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	game.tick_once(tick)


# --- The client tick -------------------------------------------------------

## Whether the local player is holding the trigger this tick.
##
## Set by the client each frame and read once, when the input packet is built. A field
## rather than a parameter on [method client_tick] because `client_tick` is called from
## the clock's "how many ticks is this frame worth" loop and may run two or three times
## for one frame's worth of input — so the trigger belongs beside the sampler's state
## rather than in the loop's arguments.
var attack_wanted: bool = false


## Tells the combat layer a player pulled the trigger on a tick.
##
## [b]Called from `_net_apply_input`, which runs on a replay as well as on a fresh
## tick.[/b] The predictor re-applies every unacknowledged command when it reconciles,
## so a trigger read anywhere else would be a shot the replay could not reproduce — and
## on the server it is the one place the input for a given tick is known to have been
## applied to that tick.
func note_attack(player: G2GPlayer, attack: bool) -> void:
	if game == null or game.combat == null or player == null:
		return

	var command := DotWeaponCommand.new()
	command.set_button(DotWeaponCommand.BUTTON_ATTACK, attack)
	game.combat.set_fire_command(player.player_id, command)


## Client: whether the server is simulating this player on a map this client does not have
## loaded yet.
##
## [b]Two cases, and they are the same bug.[/b] A joiner is admitted — HELLO, JOIN, its
## player spawned on the server's map — before it has been announced that map, so on a
## cold cache it spends the whole download and build with no world at all. A straggler is
## told to `load` while its download is still running, and spends the rest of it on the
## old map while the server has moved it to the new one. Either way, a client that
## predicted here was simulating its player against geometry the server did not have:
## falling through nothing from the origin, corrected back into the air by every
## snapshot, while the server applied the keys it was sent to a player on the real map.
## That was the first connect to a server whose map was not cached — a grey screen that
## jittered for as long as the download took, and a player somewhere else when it landed
## — and why reconnecting, with the pack now cached, "fixed" it.
##
## [b]From the `load`, not from the announce.[/b] An ordinary change announces the next
## map while the server is still playing the current one, waiting for every client to say
## it has the new one; gating on the announce would freeze every player for the length of
## everybody's download at the end of every map. The server swaps when it sends `load`,
## and not before.
func in_transit() -> bool:
	if net == null or net.is_server or game == null or game.maps == null:
		return false

	var current := game.maps.current

	if current == null:
		return true

	return _server_map != &"" and current.id != _server_map


## Client: what the loading cover says, or empty when there is nothing to cover.
func transit_text() -> String:
	if not in_transit():
		return ""

	var id := _server_map

	if id == &"" and map_client != null and map_client.announced != null:
		id = map_client.announced.id

	if id == &"":
		return "Joining…"

	var name := String(id)
	var def := game.maps.catalogue.get_map(id) if game.maps.catalogue != null else null
	if def == null and map_client != null and map_client.announced != null \
			and map_client.announced.id == id:
		def = map_client.announced
	if def != null:
		name = def.label()

	if map_fetch_fraction > 0.0 and map_fetch_fraction < 1.0:
		return "Loading %s… %d%%" % [name, int(map_fetch_fraction * 100.0)]

	return "Loading %s…" % name


func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	# [b]Still sent while in transit, and neutral.[/b] Not silence: the server applies the
	# last command it heard to every tick it hears nothing for, so a key held when the
	# world went away would be held for the whole download. Nor the real one: the player
	# cannot see where they are going. The view is kept so it does not snap when the
	# world arrives, and the packet carries the snapshot ack either way.
	var transit := in_transit()
	var move := command if command != null else DotFpsCommand.new()

	if transit:
		move = move.duplicate_command()
		move.move = Vector2.ZERO
		move.buttons = 0

	var packet := G2GNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = move
	packet.attack = attack_wanted and not transit

	# [b]Neither recorded nor predicted while in transit.[/b] There is nothing to predict
	# against, so the server's own state is shown as it arrives; and a command kept in
	# the history would be replayed by the first reconciliation on the new map, against
	# the position it was never simulated from.
	if not transit:
		# Into the local history BEFORE predicting: reconciliation replays it.
		net.local_inputs().push(packet)

		# The behaviour simulates from last_move, on a fresh tick and on a replayed one
		# alike — the predictor's replay sets it through _net_apply_input, and this is
		# the fresh tick's equivalent.
		var mine: G2GPlayerNet = _behaviours.get(local_player_id)
		if mine != null:
			mine.last_move = packet.move
			mine.last_attack = packet.attack

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# The whole client game ticks once: predicted players simulate through their
	# behaviours, and every timer — including remote players' — is fed afterwards.
	if _client_ticked_for != tick:
		_client_ticked_for = tick
		if not transit:
			for identity in net.registry.predicted():
				for behaviour in identity.behaviours:
					behaviour._net_simulate(tick, net.clock.tick_duration())
		game.tick_timers_only(tick)


# --- Receiving -------------------------------------------------------------

func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))
	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")
	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")
	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return G2GNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, peer_id)


## A relayed voice frame arrived. Client side.
##
## [b]Deliberately NOT routed through [DotNetManager].[/b] dot-net's `receive` decodes
## a bit-packed message against a sealed schema and applies the payload cap and the
## rate limit that go with it; a voice frame is an opaque blob from a codec and has
## nothing to do with the replication wire. Putting it through would mean either a
## message type per codec or a schema that changes when the codec does — and the
## schema hash is what both ends check to agree they are speaking the same game.
func receive_voice(payload: PackedByteArray) -> DotResult:
	if not voice_in_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "Nothing here plays voice.")

	voice_in_fn.call(payload)
	return DotResult.success(payload.size())


## A client's captured audio arrived. Server side.
##
## The speaker is [param peer_id], which the transport reported. It is never read out
## of the payload: a client that could name its own speaker id could put words in
## anybody's mouth.
func receive_voice_frame(peer_id: int, payload: PackedByteArray) -> DotResult:
	if not voice_relay_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "This end does not relay voice.")

	voice_relay_fn.call(peer_id, payload)
	return DotResult.success(payload.size())
# --- Server: what a joining peer is told ------------------------------------

func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true
	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, G2GEvents.Kind.HELLO, G2GEvents.write_hello(
		game.tick_rate, session_id, peer_id, net.clock.tick, game.config
	))

	for other in _behaviours.keys():
		_tell(peer_id, G2GEvents.Kind.JOIN, _join_body(int(other)))

	for other in _behaviours.keys():
		_send_timer(int(other), peer_id)

	# The time left now, rather than at the clock's next change — which on a quiet map is
	# never, and a joiner would count down nothing until it came.
	if clock_fn.is_valid():
		_tell(peer_id, G2GEvents.Kind.CLOCK, G2GEvents.write_clock(clock_fn.call()))

	_tell(peer_id, G2GEvents.Kind.RULES, G2GEvents.write_rules(rules_body()))

	# The joiner's own standing, again. The join's spawn already worked it out, but inside
	# `game.add_player` — before this peer was mapped to its player, and before it was
	# ready — so a store that answers from its cache emitted it to nobody, and a returning
	# player's timer showed no best and no record until their next finish (while the Tab
	# board, which reads the same standing on the server, showed both).
	var standing := game.standing_of(_player_key(session_id))
	if not standing.is_empty():
		_tell(peer_id, G2GEvents.Kind.STANDING, G2GEvents.write_standing(session_id, standing))
	var reference := game.stage_reference(_player_key(session_id))
	if not reference.is_empty():
		_tell(peer_id, G2GEvents.Kind.STAGE_REF, G2GEvents.write_stage_ref(session_id, reference))

	# Every hunter already out on the course. A runner joining a server whose hunters were
	# released an hour ago would otherwise be hit by things it was never told about.
	for instance_id in _hunter_nets.keys():
		var hunter: G2GNpcNet = _hunter_nets[instance_id]
		if hunter.identity != null and hunter.npc != null and hunter.npc.is_alive():
			_tell(peer_id, G2GEvents.Kind.NPC, G2GEvents.write_npc(
				hunter.identity.net_id, hunter.npc.def.id, hunter.npc.position()
			))

	# Last, so everything above describes the world the announce is about to put it in.
	_map_admit(peer_id)


# --- Spectating -----------------------------------------------------------------
#
# The server's spectator manager decides who watches whom; this half tells the two people
# each decision is about. Until it existed `!spec` changed the server's view and nothing
# else: the server said "Watching ada." and the client's camera stayed where it was,
# because the client's manager is a mirror and nobody told it anything.

var _watched_spectate: DotSpectatorManager = null

## What each player was last told about who is watching them: target key -> names.
var _sent_spectators: Dictionary = {}


## Follows the game's spectator manager. Server side, every tick, for the hunters' reason:
## the game builds it, and may build it again.
func _watch_spectate() -> void:
	if net == null or not net.is_server or game == null:
		return
	var manager: DotSpectatorManager = game.spectate.manager if game.spectate != null else null
	if manager == _watched_spectate:
		return
	if _watched_spectate != null and is_instance_valid(_watched_spectate):
		if _watched_spectate.view_changed.is_connected(_on_view_changed):
			_watched_spectate.view_changed.disconnect(_on_view_changed)
		if _watched_spectate.retargeted.is_connected(_on_retargeted):
			_watched_spectate.retargeted.disconnect(_on_retargeted)
	_watched_spectate = manager
	_sent_spectators.clear()
	if manager != null:
		manager.view_changed.connect(_on_view_changed)
		manager.retargeted.connect(_on_retargeted)


func _on_view_changed(key: String, mode: int, target: String) -> void:
	# Nobody left to watch is not a camera worth keeping: a spectator parked on an empty
	# fixed view has a frozen screen and no idea why. They are put back in their own view.
	# A free camera has no target by design, so it is the one exception.
	if target == "" and mode != DotSpectatorView.Mode.NONE \
			and mode != DotSpectatorView.Mode.ROAMING and _watched_spectate != null:
		_watched_spectate.stop(key)
		return
	var peer := peer_for_player(session_of(StringName(key)))
	if peer > 0 and _ready_peers.has(peer):
		_tell(peer, G2GEvents.Kind.SPECTATE, G2GEvents.write_spectate(target, mode, _name_of(target)))
	_send_spectator_lists()


func _on_retargeted(key: String, _from: String, to: String, _reason: StringName) -> void:
	var v := _watched_spectate.view(key) if _watched_spectate != null else null
	_on_view_changed(key, int(v.mode) if v != null else DotSpectatorView.Mode.NONE, to)


func _name_of(key: String) -> String:
	if key == "" or game == null:
		return ""
	var player: G2GPlayer = game.players.get(StringName(key))
	return player.display_name if player != null else key


## The names of everybody watching [param target], sorted, so two calls compare equal.
func spectators_of(target: String) -> PackedStringArray:
	var out := PackedStringArray()
	if _watched_spectate == null or target == "":
		return out
	for viewer in _watched_spectate.viewers():
		if _watched_spectate.view(viewer).target == target:
			out.append(_name_of(viewer))
	out.sort()
	return out


## Tells every player whose list of spectators changed, and everybody watching them. With
## [param force], tells everybody listed whatever it was — `sv_spec_list` changing.
##
## [b]Gated on the server, not only hidden on the client.[/b] `sv_spec_list 0` is an
## operator saying spectating is anonymous here, and a list the client merely chose not to
## draw would still be on the wire for anybody who wanted to read it.
func _send_spectator_lists(force: bool = false) -> void:
	if net == null or not net.is_server or game == null or _watched_spectate == null:
		return
	var now := {}
	if game.config.spectator_list:
		for viewer in _watched_spectate.viewers():
			var target := _watched_spectate.view(viewer).target
			if target != "" and not now.has(target):
				now[target] = spectators_of(target)

	var targets := {}
	for t: Variant in now:
		targets[t] = true
	for t: Variant in _sent_spectators:
		targets[t] = true

	for t: Variant in targets:
		var names: PackedStringArray = now.get(t, PackedStringArray())
		if not force and _sent_spectators.has(t) and _sent_spectators[t] == names:
			continue
		var body := G2GEvents.write_spectators(str(t), names)
		var told := {}
		var own := peer_for_player(session_of(StringName(str(t))))
		if own > 0 and _ready_peers.has(own):
			_tell(own, G2GEvents.Kind.SPECTATORS, body)
			told[own] = true
		for viewer in _watched_spectate.viewers():
			if _watched_spectate.view(viewer).target != str(t):
				continue
			var peer := peer_for_player(session_of(StringName(viewer)))
			if peer > 0 and _ready_peers.has(peer) and not told.has(peer):
				_tell(peer, G2GEvents.Kind.SPECTATORS, body)
				told[peer] = true

	_sent_spectators = now


## `sv_spec_list` changed: everybody's list again, empty if it went off.
func broadcast_spectators() -> void:
	_send_spectator_lists(true)


# --- Hunters -------------------------------------------------------------------

## Follows whichever hunters the game has. Server side. Every tick, because `sv_hunters`
## and a map change both build or drop them.
func _watch_hunters() -> void:
	if net == null or not net.is_server or game == null:
		return

	var spawner: DotNpcSpawner = game.hunters.spawner if game.hunters != null else null

	if spawner == _watched_spawner:
		return

	if _watched_spawner != null and is_instance_valid(_watched_spawner):
		if _watched_spawner.spawned.is_connected(_on_hunter_spawned):
			_watched_spawner.spawned.disconnect(_on_hunter_spawned)
		if _watched_spawner.removed.is_connected(_on_hunter_removed):
			_watched_spawner.removed.disconnect(_on_hunter_removed)

	for instance_id in _hunter_nets.keys():
		_forget_hunter(int(instance_id))

	_watched_spawner = spawner

	if spawner == null:
		return

	spawner.spawned.connect(_on_hunter_spawned)
	spawner.removed.connect(_on_hunter_removed)

	for npc in spawner.all_npcs():
		_on_hunter_spawned(npc)


func _on_hunter_spawned(npc: DotNpcInstance) -> void:
	var body := npc.node as Node3D

	if body == null or net == null or _hunter_nets.has(npc.instance_id):
		return

	var behaviour := G2GNpcNet.new()
	behaviour.name = "Net"
	behaviour.npc = npc
	behaviour.body = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	# Relevant to everybody: a hunter is a threat a runner must see coming, and an interest
	# radius would announce one and then never move it — arena's first version did exactly
	# that, a monster drawn frozen where it spawned.
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a hunter", {"error": str(registered.error)})
		return

	_hunter_nets[npc.instance_id] = behaviour
	behaviour.pull()
	_broadcast(G2GEvents.Kind.NPC, G2GEvents.write_npc(identity.net_id, npc.def.id, body.global_position))


func _on_hunter_removed(npc: DotNpcInstance, _reason: StringName) -> void:
	_forget_hunter(npc.instance_id)


func _forget_hunter(instance_id: int) -> void:
	var behaviour: G2GNpcNet = _hunter_nets.get(instance_id)
	_hunter_nets.erase(instance_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)
	_broadcast(G2GEvents.Kind.NPC_GONE, G2GEvents.write_npc_gone(net_id))


## A client's copy of a hunter: its scene, no brain, moved by its net behaviour.
func _mirror_hunter(info: Dictionary) -> void:
	var net_id := int(info["net_id"])

	if _hunter_mirrors.has(net_id) or net == null:
		return

	var def := G2GHunters.catalogue().get_npc(info["kind_id"])

	if def == null:
		DotLog.debug(CHANNEL, "a hunter this build does not have", {"id": str(info["kind_id"])})
		return

	var scene: Variant = load(def.scene_path) if ResourceLoader.exists(def.scene_path) else null

	if not (scene is PackedScene):
		DotLog.warn(CHANNEL, "a hunter's scene would not load", {"path": def.scene_path})
		return

	var body := (scene as PackedScene).instantiate() as Node3D

	if body == null:
		return

	# A mirror must not simulate: a CharacterBody3D left alone sits still, a RigidBody3D
	# would fall under the client's own physics between snapshots.
	if body is RigidBody3D:
		(body as RigidBody3D).freeze = true

	if _hunter_world == null or not is_instance_valid(_hunter_world):
		_hunter_world = Node3D.new()
		_hunter_world.name = "HunterMirrors"
		game.add_child(_hunter_world)

	_hunter_world.add_child(body)
	body.global_position = info["position"]

	var behaviour := G2GNpcNet.new()
	behaviour.name = "Net"
	behaviour.body = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a hunter", {"error": str(registered.error)})
		body.queue_free()
		return

	_hunter_mirrors[net_id] = behaviour


func _drop_hunter_mirror(net_id: int) -> void:
	var behaviour: G2GNpcNet = _hunter_mirrors.get(net_id)
	_hunter_mirrors.erase(net_id)

	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.body != null and is_instance_valid(behaviour.body):
		behaviour.body.queue_free()


## How many hunters this end replicates or draws.
func hunter_count() -> int:
	return _hunter_nets.size() if net != null and net.is_server else _hunter_mirrors.size()


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: G2GPlayerNet = _behaviours.get(session_id)
	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	var player := behaviour.player
	return G2GEvents.write_join(
		session_id, peer_for_player(session_id), behaviour.identity.net_id,
		player.display_name, player.rig.avatar,
		_style_index(player.timer_style.id if player.timer_style != null else &"normal"),
		player.timer.track if player.timer != null else 0
	)


func _send_timer(session_id: int, to_peer: int = 0) -> void:
	var player: G2GPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	var state := DotTimerNet.state_of(
		player.timer.run, _tick,
		_style_index(player.timer.style.id if player.timer.style != null else &"normal")
	)
	var body := G2GEvents.write_timer(session_id, state)

	if to_peer > 0:
		_tell(to_peer, G2GEvents.Kind.TIMER, body)
	else:
		_broadcast(G2GEvents.Kind.TIMER, body)


func _on_run_started(id: StringName, _run: DotTimerRun) -> void:
	_send_timer(session_of(game.match_id(id)))


func _on_run_stopped(id: StringName, _run: DotTimerRun, _reason: StringName) -> void:
	_send_timer(session_of(game.match_id(id)))


func _on_staged(id: StringName, number: int, split: float) -> void:
	var session_id := session_of(game.match_id(id))
	_tell(peer_for_player(session_id), G2GEvents.Kind.NOTICE, G2GEvents.write_text(
		session_id, "Stage %d — %s" % [number, DotTimerRun.format_time(split)]
	))


func _on_stage_reference_changed(id: StringName, reference: Dictionary) -> void:
	var session_id := session_of(id)
	_tell(peer_for_player(session_id), G2GEvents.Kind.STAGE_REF, G2GEvents.write_stage_ref(session_id, reference))


func _on_standing_changed(id: StringName, standing: Dictionary) -> void:
	var session_id := session_of(id)
	_tell(peer_for_player(session_id), G2GEvents.Kind.STANDING, G2GEvents.write_standing(session_id, standing))


## A record is everybody's news; anything else is the finisher's.
func _on_announced(id: StringName, text: String, everyone: bool) -> void:
	var session_id := session_of(id)
	if everyone:
		_broadcast(G2GEvents.Kind.RECORD, G2GEvents.write_text(session_id, text))
	else:
		_tell(peer_for_player(session_id), G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id, text))


func _on_run_filed(id: StringName, run: DotTimerRun, rank: int, reason: String) -> void:
	var session_id := session_of(id)
	var player: G2GPlayer = game.players.get(id)
	if player == null or run == null:
		return

	var finish := DotTimerNet.finish_of(run, _style_index(run.style_id), rank)
	_broadcast(G2GEvents.Kind.FINISH, G2GEvents.write_finish(session_id, finish))

	# What a finish MEANT is `G2GGame.announced` (`_on_announced`): a new record to
	# everybody, anything else to the finisher. This used to broadcast "set a server
	# record" whenever the rank was 1 — and the rank here is the player's standing after
	# the finish, which is 1 for every finish by the record holder, so their slower runs
	# were announced as records too, and a real one was announced twice.
	if reason != "" and (game.timers == null or game.timers.store == null):
		_tell(peer_for_player(session_id), G2GEvents.Kind.NOTICE,
			G2GEvents.write_text(session_id, "Not recorded: %s" % reason))


## What every client is told about its own screen. Server side.
##
## [b]The flashlight is the server's to allow and the client's to draw.[/b] It is a
## light on one machine's camera that nobody else sees, so nothing about it is simulated
## or replicated — but an operator running a dark map as a challenge, or a competition
## that wants everybody seeing the same thing, has to be able to say no, and a client
## cannot be trusted to have read the cvar from anywhere else.
func rules_body() -> Dictionary:
	return {
		"flashlight": game.config.flashlight if game != null else true,
		"thirdperson": game.config.allow_thirdperson if game != null else true,
		"commands": commands_fn.call() if commands_fn.is_valid() else [],
	}


## Tells every ready peer the rules again, after a cvar changed them.
func broadcast_rules() -> void:
	if net == null or not net.is_server:
		return

	_broadcast(G2GEvents.Kind.RULES, G2GEvents.write_rules(rules_body()))


func _on_movement_changed(config: G2GConfig) -> void:
	_broadcast(G2GEvents.Kind.MOVEMENT, G2GEvents.write_movement(config))


## The new map is live on the server. Every player's style and track again, because a
## map change resets both on the server.
##
## [b]The map itself is NOT announced here any more[/b], and that line was the ad-hoc
## protocol: a map id broadcast from `map_ready`, which fires AFTER the server has already
## swapped, to clients that were never asked whether they had it. The change is now
## announced before it happens and loaded after everybody is ready; see "Map changes".
func _on_map_ready(_map: DotMapDef) -> void:
	for session_id in _behaviours.keys():
		_broadcast(G2GEvents.Kind.JOIN, _join_body(int(session_id)))


# --- Map changes -------------------------------------------------------------
#
# dot-map's protocol, carried over dot-net: announce -> (fetch) -> ready -> load, with
# the straggler timeout and the trust refusals as dot-map wrote them. The host sends a
# MAP event per peer; a peer answers with an Ask.MAP request. dot-map is transport-
# agnostic on purpose and names no dot-net class, so this is where the two meet.
#
# [b]What it replaced[/b] was a map id broadcast from `map_ready`: sent AFTER the server
# had already swapped, to clients that had never been asked whether they had the map,
# which resolved it against their own build and fetched nothing. A client that could not
# load it stayed on the old world while the server simulated it on the new one, and
# nothing on either end knew.
#
# [b]Nothing here works around dot-map any more.[/b] Running this for the first time
# found five things wrong in the addon, and this section carried a workaround for four of
# them: it answered a joiner's ready with a `load` itself, held a joiner mid-change back
# until the change settled, thinned progress to four a second, and fetched a delivered
# map by its own convention before dot-map saw the announce — then queued every map
# message behind that fetch, because a straggler's `load` overtook it. All of that is
# dot-map's now (see its docs/history.md, "What the first transport found"), and what is left
# is the one decision that IS this game's:
#
# - [b]The imported-map scene is a trusted template.[/b] Every imported map is ONE scene
#   in the build pointed at a manifest (see G2GMapCatalogue) — the mount constraint
#   forbids putting it in the pack — so the client lists that scene in
#   `trusted_template_scenes`, and dot-map then requires the manifest, not the scene, to
#   be inside `res://dot_cloud/<content>/<version>/`. A server marks a map it fetched
#   into a mount as that content (`G2GGame._mark_delivered`); the client fetches it from
#   ITS OWN content client and origin, verified against ITS keys. The host still says
#   only WHICH map; this client decides what it is made of.

## The game outlives this bridge — a module unloads and the game it drove stays in the
## scene — so the host half is taken back from it here, and the next `change_map` is this
## process's own again. A FREED host already reads as null on 4.7.2 (`dedicated`'s unload
## section was armed against this and did not fire); this is for a bridge removed from the
## tree without being freed, whose host would otherwise still be announcing changes to
## peers it can no longer hear.
func _exit_tree() -> void:
	if game != null and is_instance_valid(game) and game.map_sync == map_host:
		game.map_sync = null


## Server and client: the half of the protocol this end needs.
func _build_map_sync() -> void:
	if net.is_server:
		map_host = DotMapSyncHost.new()
		map_host.name = "MapSync"
		map_host.session = game.maps
		map_host.sync_timeout_sec = game.config.map_sync_seconds
		map_host.send_fn = _send_map
		map_host.on_timeout_fn = _on_map_straggler
		add_child(map_host)
		game.map_sync = map_host
	else:
		map_client = DotMapSyncClient.new()
		map_client.name = "MapSync"
		map_client.session = game.maps
		map_client.send_fn = _send_map_reply
		# The one scene an imported map is. Its manifest is what has to be delivered.
		map_client.trusted_template_scenes = PackedStringArray([G2GMapCatalogue.IMPORTED_SCENE])
		map_client.template_path_keys = PackedStringArray(["manifest"])
		map_client.fetch_failed.connect(_on_map_fetch_failed)
		map_client.fetching.connect(func(_map: DotMapDef) -> void: map_fetch_fraction = 0.0)
		map_client.fetch_progress.connect(func(fraction: float) -> void:
			map_fetch_fraction = fraction
		)
		map_client.changed.connect(func(map: DotMapDef) -> void: map_loaded.emit(map))
		add_child(map_client)


## Server: one protocol message to one peer. dot-map's `send_fn`.
func _send_map(peer_id: int, payload: Dictionary) -> void:
	var body := G2GEvents.write_map_message(payload)
	if body.is_empty():
		# An announce is a map definition and its meta; one that does not fit is a
		# catalogue entry somebody has filled with something it should not carry.
		DotLog.error(CHANNEL, "a map-change message is too large to send", {
			"peer": peer_id, "kind": String(DotMapMessage.kind_of(payload)),
			"cap": G2GEvents.MAP_MESSAGE_BYTES,
		})
		return
	_tell(peer_id, G2GEvents.Kind.MAP, body)


## Server: a peer can receive, so it follows map changes from now on — and is told the
## map it is joining onto, through the same announce a change would send.
##
## dot-map's `admit_peer` does the rest: it sends the `load` when the peer says it has the
## map, and a peer admitted during a change is announced the map that change settles on
## rather than waited on for one it was never told about.
func _map_admit(peer_id: int) -> void:
	if map_host == null or peer_id <= 0:
		return
	map_host.admit_peer(peer_id)


## Server: a peer is gone. It must not be waited on by a change in flight.
func _map_forget(peer_id: int) -> void:
	if map_host != null and peer_id > 0:
		map_host.remove_peer(peer_id)


## Server: a ready or a progress from a peer.
func _on_map_reply(peer_id: int, payload: Dictionary) -> void:
	if map_host == null or not DotMapMessage.is_map_message(payload):
		return
	map_host.handle(peer_id, payload)


## Server: a peer did not have the map in time, and the change went ahead without it.
##
## [b]Told, and not dropped.[/b] dot-map deliberately leaves this to the game, and this
## game's answer is that the server is authoritative: a straggler's inputs are simulated
## on the new map whatever its screen shows, so nothing it does there can reach a board.
## A straggler still downloading follows on its own — dot-map holds the `load` it was
## sent until the fetch lands. A client that REFUSED the map is the one that cannot follow,
## and it is the one that knows it, so it leaves (see [signal map_refused]); the server
## cannot tell the two apart, because a refusal is silent by dot-map's design.
func _on_map_straggler(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)
	var pending := String(map_host.describe().get("pending", "-")) if map_host != null else "-"
	DotLog.info(CHANNEL, "a client did not have the map in time; changing without it", {
		"peer": peer_id, "session": session_id, "map": pending,
	})
	_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(
		session_id, "The map changed before your client had it. You will follow when it arrives."
	))


## Client: one protocol message to the host. dot-map's `send_fn`.
##
## Progress arrives here already throttled (`DotMapSyncClient.progress_interval_sec`),
## because dot-net's server allows a client so many messages a second and drops the
## excess without asking which — so a burst of progress could cost the `ready` behind it.
func _send_map_reply(payload: Dictionary) -> void:
	var body := G2GEvents.write_map_message(payload, G2GEvents.MAP_REPLY_BYTES)
	if body.is_empty():
		DotLog.error(CHANNEL, "a map-change reply is too large to send", {
			"kind": String(DotMapMessage.kind_of(payload)), "cap": G2GEvents.MAP_REPLY_BYTES,
		})
		return
	_ask(G2GEvents.Ask.MAP, body)


## Client: a protocol message from the host.
##
## Handed straight to dot-map, which does not suspend the caller: an announce starts a
## fetch on its own, and a `load` that overtakes that fetch — a straggler's — is held by
## dot-map until the fetch lands.
func _on_map_message(payload: Dictionary) -> void:
	if not DotMapMessage.is_map_message(payload):
		DotLog.warn(CHANNEL, "the server sent a map message this client cannot read")
		return
	if map_client == null:
		return

	# The server sends `load` when it has swapped, so this is the map it simulates now.
	# See [method in_transit].
	if DotMapMessage.kind_of(payload) == DotMapMessage.KIND_LOAD:
		_server_map = StringName(str(payload.get("map", "")))

	# A refused announce is reported with no map, synchronously, from inside `handle`.
	var def: Variant = payload.get("map", {})
	_map_handling = (
		StringName(str((def as Dictionary).get("id", "")))
		if DotMapMessage.kind_of(payload) == DotMapMessage.KIND_ANNOUNCE and def is Dictionary
		else &""
	)
	map_client.handle(payload)
	_map_handling = &""


## Client: dot-map refused the announce, could not fetch it, or could not load it.
##
## [b]WARN, not ERROR.[/b] A refusal is dot-map's trust rule doing its job, and the client
## leaving over it is the designed outcome rather than a failure of this code; an ERROR
## here would staple a backtrace to every refusal and read like a crash in the one log
## where somebody is looking for why a player left.
func _on_map_fetch_failed(map: DotMapDef, error: DotError) -> void:
	var id := map.id if map != null else _map_handling
	var why := error.message if error != null else "unknown"
	if error != null and error.detail != "":
		why = "%s (%s)" % [why, error.detail]
	DotLog.warn(CHANNEL, "cannot follow the server to its map", {"map": String(id), "why": why})
	map_refused.emit(id, why)


# --- Client: asking ----------------------------------------------------------

func ask_ready() -> void:
	_ask(G2GEvents.Ask.READY, PackedByteArray())


func ask_style(style_id: StringName) -> void:
	_ask(G2GEvents.Ask.STYLE, G2GEvents.write_int(_style_index(style_id)))


func ask_track(track: int) -> void:
	_ask(G2GEvents.Ask.TRACK, G2GEvents.write_int(track))


func ask_restart(mode: int = G2GEvents.RESTART_TRACK) -> void:
	_ask(G2GEvents.Ask.RESTART, G2GEvents.write_int(mode))


## A spectating step: one of `G2GEvents.SPECTATE_*`.
func ask_spectate(step: int) -> void:
	_ask(G2GEvents.Ask.SPECTATE, G2GEvents.write_int(step))


## The server's word on whom this client watches, onto the client's mirror. The mirror's
## camera then follows the target from the poses this client already draws, once a frame.
func _apply_spectate(target: String, mode: int, target_name: String) -> void:
	var key := String(_player_key(local_player_id))
	var manager: DotSpectatorManager = game.spectate.manager if game != null and game.spectate != null else null
	if manager != null:
		var wanted := mode if target != "" or mode == DotSpectatorView.Mode.ROAMING \
			else DotSpectatorView.Mode.NONE
		manager.apply_wire({"k": key, "v": {"m": wanted, "t": target, "u": -1}})
	spectate_received.emit(StringName(target), target_name)


func ask_rtv() -> void:
	_ask(G2GEvents.Ask.RTV, PackedByteArray())


func ask_checkpoint(action: int) -> void:
	_ask(G2GEvents.Ask.CHECKPOINT, G2GEvents.write_int(action))


## Asks for the server's map list (empty id) or to change to [param id]. The server
## checks the changemap flag for both and says no in a NOTICE.
func ask_maps(id: String = "") -> void:
	_ask(G2GEvents.Ask.MAPS, G2GEvents.write_map_id(id))


func publish_avatar(avatar: DotAvatar) -> void:
	_ask(G2GEvents.Ask.AVATAR, G2GEvents.write_avatar(avatar))


func _ask(kind: int, body: PackedByteArray) -> void:
	if net != null and not net.is_server:
		net.send(G2GRequest.new(kind, body), 1)


# --- Server: answering ------------------------------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as G2GRequest
	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id

	# Before the seat check: a READY can come before the seat (see `_ready_unseated`), and
	# `_admit` keeps it rather than drop it.
	if ask.kind == G2GEvents.Ask.READY:
		_admit(peer_id)
		return

	var session_id := player_for_peer(peer_id)
	if session_id == 0:
		return

	var id := _player_key(session_id)
	var reader := ask.reader()

	match ask.kind:
		G2GEvents.Ask.STYLE:
			if game.set_player_style(id, _style_id(G2GEvents.read_int(reader))):
				_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
		G2GEvents.Ask.TRACK:
			var track := G2GEvents.read_int(reader)
			if DotTimerTrack.is_valid(track) and game.timers.set_player_track(game.record_key(id), track):
				game.spawn_player(id)
				_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
		G2GEvents.Ask.AVATAR:
			var avatar := G2GEvents.read_avatar(reader)
			var player: G2GPlayer = game.players.get(id)
			# Conformed by the rig's own dress path: a part this build lacks is
			# dropped, and a document that fails outright leaves the stock one.
			if avatar != null and player != null:
				dress(session_id, avatar)
		G2GEvents.Ask.RESTART:
			# The mode is the body; an older client sends none, which reads as TRACK —
			# exactly what its R meant. A double tap from a bonus changes the track, and
			# every client is told, as a track change from the menu is.
			var track_before := _track_of(id)
			var _restarted := game.restart(id, G2GEvents.read_int(reader))
			if _track_of(id) != track_before:
				_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
		G2GEvents.Ask.SPECTATE:
			_on_spectate_asked(peer_id, session_id, id, G2GEvents.read_int(reader))
		G2GEvents.Ask.RTV:
			if rtv_fn.is_valid():
				rtv_fn.call(id)
			else:
				game.rock_the_vote(id)
		G2GEvents.Ask.CHECKPOINT:
			_checkpoint(id, G2GEvents.read_int(reader))
		G2GEvents.Ask.MAP:
			_on_map_reply(peer_id, G2GEvents.read_map_message(reader, G2GEvents.MAP_REPLY_BYTES))
		G2GEvents.Ask.MAPS:
			_on_maps_asked(peer_id, session_id, G2GEvents.read_map_id(reader).strip_edges())


func _track_of(id: StringName) -> int:
	var found := game.timers.player(game.record_key(id)) if game != null and game.timers != null else null
	return found.timer.track if found != null else DotTimerTrack.MAIN


## A click while spectating, or the first one. The answer is a SPECTATE event (from the
## manager's own signal, so a chat `!spec` and a click are told the same way), or a
## NOTICE saying why not.
func _on_spectate_asked(peer_id: int, session_id: int, id: StringName, step: int) -> void:
	if game.spectate == null:
		_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id, "Spectating is not available here."))
		return
	var res: DotResult
	match step:
		G2GEvents.SPECTATE_STOP:
			game.spectate.stop(id)
			return
		G2GEvents.SPECTATE_ROAM:
			res = game.spectate.toggle_roam(id)
		G2GEvents.SPECTATE_NEXT:
			res = game.spectate.next_target(id)
		G2GEvents.SPECTATE_PREVIOUS:
			res = game.spectate.previous_target(id)
		_:
			res = game.spectate.watch_best(id)
	if not res.ok:
		_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id, res.error.message))


## The M screen's two questions. Refused unless the session may change the map, checked
## here and not on the client, because a client can send anything.
func _on_maps_asked(peer_id: int, session_id: int, id: String) -> void:
	if not (may_change_map_fn.is_valid() and bool(may_change_map_fn.call(session_id))):
		_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id,
			"Changing the map needs the changemap flag. !rtv asks for a vote."))
		return
	if id.is_empty():
		_tell(peer_id, G2GEvents.Kind.MAPS, G2GEvents.write_maps(game.map_rows()))
		return
	if game.maps.catalogue == null or not game.maps.catalogue.has(StringName(id)):
		_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id, "No map called %s." % id))
		return
	DotLog.info(CHANNEL, "a map change from the map list", {"by": session_id, "map": id})
	var changed: DotResult = await game.change_map(StringName(id))
	if not changed.ok:
		_tell(peer_id, G2GEvents.Kind.NOTICE, G2GEvents.write_text(session_id, changed.error.message))


func _checkpoint(id: StringName, action: int) -> void:
	var player: G2GPlayer = game.players.get(id)
	var checkpoints := game.timers.checkpoints_for(game.record_key(id))
	if player == null or checkpoints == null:
		return
	var s := player.controller.state
	match action:
		0:
			checkpoints.save(s.position, s.velocity, s.yaw, s.pitch, s.is_grounded(), s.is_crouched())
		1:
			var cp := checkpoints.load_current()
			if cp != null:
				player.teleport(cp.position, cp.yaw)
				player.controller.state.velocity = cp.velocity
				player.controller.state.pitch = cp.pitch
		2:
			checkpoints.clear()


# --- Client: applying ---------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as G2GEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		G2GEvents.Kind.HELLO:
			_apply_hello(reader)
		G2GEvents.Kind.JOIN:
			_apply_join(reader)
		G2GEvents.Kind.LEAVE:
			var session_id := G2GEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		G2GEvents.Kind.MOVEMENT:
			_apply_movement(reader)
		G2GEvents.Kind.MAP:
			_on_map_message(G2GEvents.read_map_message(reader))
		G2GEvents.Kind.TIMER:
			var timer := G2GEvents.read_timer(reader)
			if bool(timer["ok"]):
				_apply_timer(int(timer["player_id"]), timer["state"])
		G2GEvents.Kind.FINISH:
			var finish := G2GEvents.read_finish(reader)
			if bool(finish["ok"]):
				var f: DotTimerNet.Finish = finish["finish"]
				finish_received.emit(int(finish["player_id"]), f.time(1.0 / float(game.tick_rate)), f.rank)
		G2GEvents.Kind.RECORD, G2GEvents.Kind.NOTICE:
			var text := G2GEvents.read_text(reader)
			notice_received.emit(int(text["player_id"]), str(text["text"]))
		G2GEvents.Kind.VOTE:
			var voted := G2GEvents.read_vote(reader)
			if bool(voted["ok"]):
				vote_received.emit(voted)
		G2GEvents.Kind.CLOCK:
			var clock := G2GEvents.read_clock(reader)
			if bool(clock["ok"]):
				clock_view.adopt(clock, Time.get_ticks_msec() / 1000.0)
				clock_received.emit(clock)
		G2GEvents.Kind.NPC:
			var hunter := G2GEvents.read_npc(reader)
			if bool(hunter["ok"]):
				_mirror_hunter(hunter)
		G2GEvents.Kind.NPC_GONE:
			var gone := G2GEvents.read_npc_gone(reader)
			if bool(gone["ok"]):
				_drop_hunter_mirror(int(gone["net_id"]))
		G2GEvents.Kind.STANDING:
			var standing := G2GEvents.read_standing(reader)
			if bool(standing["ok"]):
				standing_received.emit(int(standing["player_id"]), standing)
		G2GEvents.Kind.STAGE_REF:
			var reference := G2GEvents.read_stage_ref(reader)
			if bool(reference["ok"]):
				stage_reference_received.emit(int(reference["player_id"]), reference)
		G2GEvents.Kind.MAPS:
			maps_received.emit(G2GEvents.read_maps(reader))
		G2GEvents.Kind.RULES:
			var rules := G2GEvents.read_rules(reader)
			if bool(rules["ok"]):
				rules_received.emit(rules)
		G2GEvents.Kind.SPECTATE:
			var spec := G2GEvents.read_spectate(reader)
			if bool(spec["ok"]):
				_apply_spectate(str(spec["target"]), int(spec["mode"]), str(spec["name"]))
		G2GEvents.Kind.SPECTATORS:
			var watching := G2GEvents.read_spectators(reader)
			if bool(watching["ok"]):
				spectators_received.emit(StringName(str(watching["target"])), watching["names"])
		G2GEvents.Kind.HIT:
			var hit := G2GEvents.read_hit(reader)
			if bool(hit["ok"]):
				hit_received.emit(int(hit["victim"]), float(hit["amount"]), hit["point"],
					bool(hit["killed"]), bool(hit["headshot"]))
		G2GEvents.Kind.DEATH:
			var died := G2GEvents.read_death(reader)
			if bool(died["ok"]):
				death_received.emit(_player_key(int(died["player_id"])), died.get("death"))
		G2GEvents.Kind.KILL:
			var shot := G2GEvents.read_kill(reader)
			if bool(shot["ok"]):
				var killer := _player_key(int(shot["killer"])) if int(shot["killer"]) > 0 else &""
				kill_received.emit(killer, _player_key(int(shot["victim"])), String(shot["weapon"]),
					bool(shot["headshot"]))
		G2GEvents.Kind.MATCH_END:
			var over := G2GEvents.read_match_end(reader)
			if bool(over["ok"]):
				match_end_received.emit(float(over["killcam"]), over["rows"])
		G2GEvents.Kind.ALIVE:
			var session_id := G2GEvents.read_player(reader)
			if reader.ok():
				alive_received.emit(_player_key(session_id))


func _apply_hello(reader: DotNetReader) -> void:
	var hello := G2GEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# [b]The server's tick rate, before anything is derived from it.[/b] HELLO has
	# carried it since it was written and `read_hello` has always decoded it; nothing
	# read it back out, so a client counted at its own project's
	# `physics_ticks_per_second` — 128 in this repository, 60 in a host project that
	# never set one — against a server counting at `sv_tickrate`. Produced correctly
	# and consumed by nothing, which is this family's most repeated bug and is
	# invisible to `headless_net` for the usual reason: one process has one engine
	# rate, so both ends agreed no matter what the wire said.
	#
	# Before `sync_from_server`, because the clock converts its error and its lead
	# through `tick_rate` and would otherwise do that arithmetic at the old rate.
	_adopt_tick_rate(int(hello["tick_rate"]))
	_keep_up_through_slow_frames()

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	_apply_movement(DotNetReader.new(hello["movement"]))

	# No map here. The map this client joins onto arrives as the protocol's announce,
	# right behind HELLO — see `_map_admit`.
	hello_received.emit(local_player_id)


## Puts the whole client — game, timers, netcode clock — on the server's tick rate.
##
## Three places hold this number and all three have to move together. `game.tick_rate`
## is the step the simulation and every reconstituted run time use; `net.config.tick_rate`
## is what `DotNetInput.sanitise` and the interpolator's extrapolation budget read; and
## `net.clock.tick_rate` is the live one, built from the config back at `setup()` and
## therefore NOT updated by writing the config alone.
##
## A server never calls this: its rate is `sv_tickrate` and adopting a peer's would be
## a client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	net.clock.tick_rate = game.tick_rate

	# [b]And the engine's, which is the half that decides whether it looks smooth.[/b]
	# `G2GClient._physics_process` asks the clock how many ticks a frame is worth, so
	# the simulation was already correct with the engine left at 60 — it just ran them
	# in bursts of two and three. Nothing renders between ticks, so the camera moved
	# 74 mm on six frames out of seven and 112 mm on the seventh: a 47% change in
	# apparent speed, eight times a second, for as long as a browser client has
	# existed. That is the "very jittery in the browser" report.
	#
	# Interpolating fixes it and cannot be done without this line.
	# `DotFpsController.render_state` and `DotNetManager.interpolate_frame` both draw
	# at `Engine.get_physics_interpolation_fraction()`, which is a fraction through a
	# PHYSICS frame — only a fraction through a tick while the two rates are the same.
	# Measured at 60-against-128 the interpolation changes nothing at all; measured
	# with both on 128 the drawn step is uniform to within 0.3 mm. See
	# `examples/jitter_probe.tscn`, which runs all four combinations.
	#
	# A server is already excluded above: its rate is `sv_tickrate` and dot-server
	# writes this itself.
	Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## Client: lets the engine run every tick of a slow frame instead of dropping the rest.
##
## [b]The engine runs at most `max_physics_steps_per_frame` physics steps a frame, 8 by
## default, and silently drops the time past that.[/b] 8 steps are 133 ms at 60 Hz but 62.5 ms
## at this game's 128, so any client below 16 frames a second (a browser's first visit:
## packs mounting, every material's shader compiling) runs fewer ticks than the server.
##
## [b]Not what kept players on the spawn pad, though it was first taken for it.[/b] That was
## dot-net's clock, which was handed only the steps and never saw the dropped time, so every
## command was stamped for a tick the server had already simulated (dot-net API 5 credits it
## from the wall clock; docs/history.md has both). What the cap still buys is a command of the
## client's own for every tick: at 128 with 150 ms frames and a cap of 8, 57% of the server's
## ticks had none and repeated the one before, which drops a jump or a strafe shorter than a
## frame.
##
## Raised to cover [constant SLOW_FRAME_SECONDS] at the server's rate, never lowered: a
## frame that slow costs more physics steps, which is far cheaper than inputs the server
## never hears.
func _keep_up_through_slow_frames() -> void:
	if net == null or net.is_server or game == null or game.tick_rate <= 0:
		return
	var steps := ceili(SLOW_FRAME_SECONDS * float(game.tick_rate))
	if Engine.max_physics_steps_per_frame < steps:
		DotLog.info(CHANNEL, "the engine keeps up with slow frames", {
			"steps_per_frame": steps, "was": Engine.max_physics_steps_per_frame,
			"tick_rate": game.tick_rate,
		})
		Engine.max_physics_steps_per_frame = steps


func _apply_movement(reader: DotNetReader) -> void:
	var fingerprint := G2GEvents.read_movement(reader, game.config)
	game.apply_movement()

	# The whole reason the config travels rather than the tunables: both ends derive
	# through the same code, and a mismatch is one log line rather than a week of
	# "the netcode feels bad".
	if game.tunables.fingerprint() != fingerprint:
		DotLog.warn(CHANNEL, "movement fingerprint disagrees with the server", {
			"ours": game.tunables.fingerprint(), "theirs": fingerprint
		})


func _apply_join(reader: DotNetReader) -> void:
	var join := G2GEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var peer_id := int(join["peer_id"])
	var id := _player_key(session_id)
	var is_me := session_id == local_player_id

	var player: G2GPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), is_me, join["avatar"])
		if player == null:
			return
		# A client never samples: the client loop hands it commands. It keeps the
		# camera and the HUD's attention if it is the local one.
		player.sampler = null

		# The ghost has no timer anywhere: the server never feeds one, so no TIMER
		# event will ever correct what a mirror started on its own by watching the
		# ghost leave the start pad.
		if session_id == G2GGame.GHOST_SESSION:
			game.timers.remove_player(game.record_key(id))
			player.timer = null

		var identity := _build_entity(player, peer_id)
		var registered := net.registry.register(identity, int(join["net_id"]), net.clock.tick, net.config)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])
		if join["avatar"] != null:
			player.rig.dress(join["avatar"], game.avatar_schema, game.avatar_catalogue)

	game.set_player_style(id, _style_id(int(join["style_index"])))
	game.timers.set_player_track(game.record_key(id), int(join["track"]))

	roster_changed.emit(session_id)


func _apply_timer(session_id: int, state: DotTimerNet.RunState) -> void:
	var player: G2GPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	# Against the ESTIMATED server tick, not the local one: the local tick runs a
	# lead ahead so commands arrive in time, and a HUD counting from it would show
	# every run a flight time longer than the server will file it.
	player.timer.run = DotTimerNet.run_from_state(
		state, net.clock.server_tick(), 1.0 / float(game.tick_rate), _style_id(state.style_index)
	)


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"local": local_player_id,
		"tick": _tick,
		"link": link.describe() if link != null else {},
		"map_sync": (
			map_host.describe() if map_host != null
			else map_client.describe() if map_client != null else {}
		),
	}
