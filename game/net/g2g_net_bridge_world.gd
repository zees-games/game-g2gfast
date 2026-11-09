extends "g2g_net_bridge_wire.gd"

func _connect_server() -> void:
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
	killview = G2GKillView.new(game)
	# Built in the game's `_ready`, before any bridge, or never (no deathmatch and no
	# hunters), so connecting once here sees every combat layer this game will have.
	if game.combat != null:
		game.combat.hit_landed.connect(_on_hit_landed)
		game.combat.weapon_used.connect(broadcast_shot)
		# Every death, a hunter's included, and every return: before this nothing
		# connected player_killed, and a dead runner stood upright on every screen.
		game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
			broadcast_death(game.combat.player_id_for(entry.victim_key.to_int()))
			killview.note_kill(entry)
			broadcast_kill(entry))
		if game.combat.match_node != null:
			# Deferred: the last kill ends the match from inside its own report, before the
			# kill is broadcast, and the killcam needs the kill first.
			game.combat.match_node.match_ended.connect(
				func(_winner: int, _outcome: int) -> void: broadcast_match_end.call_deferred())
		game.combat.player_respawned.connect(broadcast_alive)


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

	# The time left now: a quiet map's clock never changes, so a joiner would count nothing.
	if clock_fn.is_valid():
		_tell(peer_id, G2GEvents.Kind.CLOCK, G2GEvents.write_clock(clock_fn.call()))

	_tell(peer_id, G2GEvents.Kind.RULES, G2GEvents.write_rules(rules_body()))

	# The joiner's own standing, again: the join's spawn emitted it before this peer was
	# mapped or ready, so a cached store told nobody.
	var standing := game.standing_of(_player_key(session_id))
	if not standing.is_empty():
		_tell(peer_id, G2GEvents.Kind.STANDING, G2GEvents.write_standing(session_id, standing))
	var reference := game.stage_reference(_player_key(session_id))
	if not reference.is_empty():
		_tell(peer_id, G2GEvents.Kind.STAGE_REF, G2GEvents.write_stage_ref(session_id, reference))

	# Every hunter already out, or the joiner is hit by things it was never told about.
	for instance_id in _hunter_nets.keys():
		var hunter: G2GNpcNet = _hunter_nets[instance_id]
		if hunter.identity != null and hunter.npc != null and hunter.npc.is_alive():
			_tell(peer_id, G2GEvents.Kind.NPC, G2GEvents.write_npc(
				hunter.identity.net_id, hunter.npc.def.id, hunter.npc.position()
			))

	weapon_net.send_snapshot(peer_id, game.weapon_layer)
	# Last, so everything above describes the world the announce is about to put it in.
	_map_admit(peer_id)
	if peer_ready_fn.is_valid():
		peer_ready_fn.call(peer_id)


# --- Spectating -----------------------------------------------------------------
#
# The server's spectator manager decides who watches whom; this half tells the two people
# each decision is about. Until it existed `!spec` changed the server's view and nothing
# else: the server said "Watching ada." and the client's camera stayed where it was,
# because the client's manager is a mirror and nobody told it anything.

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


func ask_drop_weapon() -> void:
	_ask(G2GEvents.Ask.DROP_WEAPON, PackedByteArray())


## The use key changed: down or up, for the pickup rules.
func ask_use_key(down: bool) -> void:
	_ask(G2GEvents.Ask.USE_KEY, G2GEvents.write_int(1 if down else 0))


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

## The player asks to leave the kill view and respawn now.
func ask_respawn() -> void:
	_ask(G2GEvents.Ask.RESPAWN, PackedByteArray())


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
		G2GEvents.Ask.DROP_WEAPON:
			var _thrown := game.weapon_layer.throw_for(id)
		G2GEvents.Ask.USE_KEY:
			game.weapon_layer.set_use(id, G2GEvents.read_int(reader) != 0)
		G2GEvents.Ask.SPECTATE:
			_on_spectate_asked(peer_id, session_id, id, G2GEvents.read_int(reader))
		G2GEvents.Ask.RESPAWN:
			if killview != null:
				killview.skip(id)
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

## The spectate, hit, death, kill, shot and match-end events, split off to keep _on_event short.
func _on_watch_event(kind: int, reader: DotNetReader) -> void:
	match kind:
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
		G2GEvents.Kind.SHOT:
			var fired := G2GEvents.read_shot(reader)
			if bool(fired["ok"]):
				shot_received.emit(_player_key(int(fired["shooter"])), StringName(str(fired["weapon"])), fired["at"])
		G2GEvents.Kind.MATCH_END:
			var over := G2GEvents.read_match_end(reader)
			if bool(over["ok"]):
				match_end_received.emit(float(over["killcam"]), over["rows"])
		G2GEvents.Kind.ALIVE:
			var session_id := G2GEvents.read_player(reader)
			if reader.ok():
				alive_received.emit(_player_key(session_id))
