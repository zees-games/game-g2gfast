extends "g2g_net_bridge_state.gd"

# --- Wiring ----------------------------------------------------------------

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


## To everybody: [param id]'s weapon went off at [param at]. Server side.
func broadcast_shot(id: StringName, weapon: StringName, at: Vector3) -> void:
	_broadcast(G2GEvents.Kind.SHOT, G2GEvents.write_shot(session_of(id), String(weapon), at))


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
	if killview != null:
		killview.forget(id)
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
	weapon_net.watch(game.weapon_layer)
	if net != null:
		net.server_tick(tick)
	ensure_game_ticked(tick)
	if killview != null and game.combat != null:
		for clip: Dictionary in killview.tick(tick):
			_tell(peer_for_player(session_of(clip["player"])), G2GEvents.Kind.KILLVIEW, clip["body"])


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
## Set by the client each frame and read once, when the input packet is built: `client_tick`
## may run two or three times for one frame, so the trigger is not a parameter.
var attack_wanted: bool = false


## Tells the combat layer a player pulled the trigger on a tick.
##
## [b]Called from `_net_apply_input`, which also runs on a replay.[/b] A trigger read anywhere
## else would be a shot the replay could not reproduce.
func note_attack(player: G2GPlayer, attack: bool) -> void:
	if game == null or game.combat == null or player == null:
		return

	var command := DotWeaponCommand.new()
	command.set_button(DotWeaponCommand.BUTTON_ATTACK, attack)
	game.combat.set_fire_command(player.player_id, command)


## Client: whether the server is simulating this player on a map this client does not have
## loaded yet.
##
## A joiner or a straggler is simulated by the server on a map this client lacks: predicting
## there falls through nothing and is corrected by every snapshot (the grey screen on a cold
## cache). Gated from the `load`, not the announce, or every map end freezes for the downloads.
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
			# Through the predictor, which remembers each tick: a snapshot can only skip its replay when the
			# tick it describes was remembered.
			_fresh_tick = tick
			net.predict_tick(tick, packet)
		feed_client_timers(tick)


## The predicted player's fresh move times the tick from inside the prediction, so a pit zone's teleport is
## in the tick the predictor remembers. After it, every snapshot of a pit was a 5 m correction (nightly 1546).
func timers_after_predicted_move(tick: int) -> void:
	if tick == _fresh_tick:
		feed_client_timers(tick)


## Once a tick: a replay reaching a tick again must not re-enter its zones.
func feed_client_timers(tick: int) -> void:
	if _timers_fed_for == tick or game == null:
		return
	_timers_fed_for = tick
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
## [b]Deliberately NOT routed through [DotNetManager].[/b] Its schema hash and payload cap fit
## the replication wire; a voice frame is an opaque codec blob, and a message type per codec
## would change the hash both ends compare.
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
