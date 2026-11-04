extends "headless_net_wires.gd"

## The loopback harness and the map-change sections of headless_net.gd, split out for size.

func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1




func _make_game(server: bool, scope: StringName, parent: Node) -> G2GGame:
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.authoritative = server

	var game := G2GGame.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager



func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return
	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()
	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])
	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## A request and its answer: the answer is queued during the first flush and
## delivered by the second.
func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	_client_net.clock.advance(1.0 / float(_client_game.tick_rate))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		_step(command)


func _forward() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	return c


func _server_player() -> G2GPlayer:
	return _server_game.players.get(&"u%d" % SESSION)


func _client_player() -> G2GPlayer:
	return _client_game.players.get(&"u%d" % SESSION)


# --- Tests -----------------------------------------------------------------


# --- Map changes, through dot-map's protocol --------------------------------

## A content client that takes its time over the first fetch, in front of a real one.
##
## [b]What is mounted is a real signed pack[/b], published by this suite into `user://` and
## mounted by a real [DotCloudClient] at `res://dot_cloud/<id>/<version>/` — so what the
## client loads when its download lands is a world built from a manifest out of a pack, as
## a delivered map is. The delay is the suite's, so the server's timeout can pass while the
## client is still downloading: a straggler, on demand. Registered as `dot_cloud_client`,
## which is where dot-map's loader looks on both ends — one process has one registry and
## one set of mounts, which is also why the server's own map definition below is built by
## hand rather than fetched: a server that had mounted the pack would have mounted it for
## the client too, and there would be nothing left to download.
class SlowCloud:
	extends Node

	signal progress_changed(progress: Dictionary)

	var real: DotCloudClient = null
	var delay_first: float = 0.0
	## "id@version" of every fetch asked for, in order.
	var asked: Array[String] = []
	var _delayed := false

	func ensure(
		content_id: StringName, version: String = "",
		groups: PackedStringArray = PackedStringArray(), manifest_url: String = ""
	) -> DotResult:
		asked.append("%s@%s" % [content_id, version])
		if delay_first > 0.0 and not _delayed:
			_delayed = true
			await get_tree().create_timer(delay_first).timeout
		return await real.ensure(content_id, version, groups, manifest_url)

	func is_mounted(content_id: StringName, version: String = "") -> bool:
		return real.is_mounted(content_id, version)


const SYNC_FIXTURE := &"g2g_sync_fixture"
const DELIVERED_FIXTURE := &"g2g_delivered_fixture"
const OWNED_FIXTURE := &"g2g_owned_fixture"
const REPUB_FIXTURE := &"g2g_repub_fixture"

## The signing key the delivered-map section made, which the content client trusts.
var _fixture_keys: Dictionary = {}
const SYNC_FIXTURE_ROOT := "user://g2g_headless_net_sync"
const SYNC_TIMEOUT := 1.0
## Must outlast the server's swap (timeout plus the map load, over 2 s on a slow box), or the client has caught up.
const SLOW_FETCH := 5.0

var _cloud: SlowCloud = null
var _real_cloud: DotCloudClient = null


## Runs a change on the server while pumping the link, and says how it ended.
##
## [b]A bare statement, and not an await[/b] — the fan-out trap in the form dot-map's
## own suite records: the change waits on a client that only answers when this pump
## runs, so awaiting it here deadlocks. The outcome comes back through the host's signals.
## [param during] runs right after the change starts, while the host is waiting on peers.
func _change_and_pump(id: StringName, seconds: float, during: Callable = Callable()) -> Dictionary:
	var host := _server_bridge.map_host
	var outcome := {"done": false, "ok": false, "reason": "", "ms": 0, "client_then": ""}
	var started := Time.get_ticks_msec()

	var on_finished := func(_map: DotMapDef) -> void:
		outcome["done"] = true
		outcome["ok"] = true
		outcome["ms"] = Time.get_ticks_msec() - started
		# Where the client is at the moment the server swaps: the straggler's proof.
		outcome["client_then"] = String(_client_game.maps.current.id) if _client_game.maps.current != null else ""
	var on_failed := func(_map: DotMapDef, reason: String) -> void:
		outcome["done"] = true
		outcome["reason"] = reason
		outcome["ms"] = Time.get_ticks_msec() - started

	host.change_finished.connect(on_finished)
	host.change_failed.connect(on_failed)

	_server_game.change_map(id)
	if during.is_valid():
		during.call()

	var deadline := started + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline and not bool(outcome["done"]):
		_flush()
		await get_tree().process_frame

	# The `load` the host sent on its way out, and the client's own load after it.
	for _i in range(4):
		_flush()
		await get_tree().process_frame

	host.change_finished.disconnect(on_finished)
	host.change_failed.disconnect(on_failed)
	return outcome


## Pumps until the client is on [param id], or [param seconds] pass.
func _until_client_on(id: StringName, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _client_game.maps.current != null and _client_game.maps.current.id == id:
			return true
		_flush()
		await get_tree().process_frame
	return _client_game.maps.current != null and _client_game.maps.current.id == id


## A map as a signed pack: a manifest and a mesh, published into `user://`. Empty of
## geometry on purpose — this suite is about who has it, not what is in it.
##
## [param version] empty publishes as [method G2GMapCatalogue.pack_version] does, from the
## files; [param extra] is merged into the manifest, so a republish can change them.
func _publish_map_fixture(
	id: StringName, version: String, keys: Dictionary, owner := "", extra := {}
) -> DotResult:
	var source := SYNC_FIXTURE_ROOT.path_join("src").path_join(String(id))
	DirAccess.make_dir_recursive_absolute(source)
	var manifest := {
		"id": String(id), "tier": 1, "display_name": String(id).replace("_", " "),
		"spawn": {"origin": [0, 64, 0]}, "surfaces": [], "zones": [],
	}
	manifest.merge(extra, true)
	var json := FileAccess.open(source.path_join("%s.json" % id), FileAccess.WRITE)
	json.store_string(JSON.stringify(manifest))
	json.close()
	var bin := FileAccess.open(source.path_join("%s.bin" % id), FileAccess.WRITE)
	bin.store_8(0)
	bin.close()

	var content := String(id) if owner.is_empty() else "%s/%s" % [owner, id]
	var publisher := DotCloudPublisher.new()
	publisher.content_id = content
	publisher.version = version if not version.is_empty() else G2GMapCatalogue.pack_version(source)
	publisher.signing_key_pem = str(keys["private"])
	publisher.signing_key_id = "headless_net"
	# Published at `<base>/<id>/`, the layout a server's version-less `ensure(id)` finds —
	# `G2GGame.ensure_map_content` asks for whatever version the origin has, and a client
	# asks for the version its announce named; both reach the same manifest.
	return publisher.publish(source, "%s/dist/%s" % [SYNC_FIXTURE_ROOT, content])


## One content client for both ends, behind [SlowCloud], trusting only this suite's key.
func _start_content(keys: Dictionary) -> void:
	var config := DotCloudConfig.new()
	config.side = "both"
	config.cache_dir = SYNC_FIXTURE_ROOT.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"headless_net": str(keys["public"])}

	_real_cloud = DotCloudClient.new()
	_real_cloud.name = "RealCloud"
	_real_cloud.config = config
	_real_cloud.config_file = ""
	_real_cloud.local_search_dirs = PackedStringArray([SYNC_FIXTURE_ROOT.path_join("dist")])
	_real_cloud.manifest_url_template = "{base}/{id}/manifest.json"
	_real_cloud.register_service = false
	add_child(_real_cloud)

	_cloud = SlowCloud.new()
	_cloud.name = "SlowCloud"
	_cloud.real = _real_cloud
	add_child(_cloud)
	DotRegistry.register(&"dot_cloud_client", _cloud)


func _test_map_change() -> void:
	_section("changing the map: a client that has it")

	var host := _server_bridge.map_host
	host.poll_interval_sec = 0.05
	host.sync_timeout_sec = 5.0

	var order: Array[String] = []
	var fetched: Array[String] = []
	var on_ready := func(m: DotMapDef) -> void: order.append("client ready:" + String(m.id))
	var on_swap := func(m: DotMapDef, _w: Node) -> void: order.append("server swap:" + String(m.id))
	var on_fetch := func(m: DotMapDef) -> void: fetched.append(String(m.id))
	_client_bridge.map_client.content_ready.connect(on_ready)
	_server_game.maps.changed.connect(on_swap)
	_client_bridge.map_client.fetching.connect(on_fetch)

	# A second client admitted WHILE the change is in flight. dot-map's `add_peer` said
	# such a peer "is not waited for" and its wait loop counted it anyway, so it held the
	# change to the timeout for a map it was never announced; dot-map snapshots the peers
	# a change was announced to now. Its traffic goes nowhere in this loopback, which is
	# exactly a peer that would never answer. Armed by admitting it straight into the
	# host before the fix: the change took the full five seconds.
	var late_peer := 4
	var late_session := 9
	var mid_change := func() -> void:
		_server_bridge.add_player(late_peer, late_session, "Late")
		var writer := DotNetWriter.new()
		_server_net.messages.encode(G2GRequest.new(G2GEvents.Ask.READY, PackedByteArray()), writer)
		_server_bridge.receive_request(late_peer, writer.to_bytes())

	var outcome := await _change_and_pump(&"surf_g2g_intro", 8.0, mid_change)

	_client_bridge.map_client.content_ready.disconnect(on_ready)
	_server_game.maps.changed.disconnect(on_swap)
	_client_bridge.map_client.fetching.disconnect(on_fetch)

	_check(bool(outcome["ok"]), "the server changes", str(outcome["reason"]))
	_check(_server_game.maps.current.id == &"surf_g2g_intro", "and is on it")
	_check(_client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro", "and the client follows")
	_check(order == ["client ready:surf_g2g_intro", "server swap:surf_g2g_intro"],
		"having said it had the map BEFORE the server swapped, which the old broadcast never asked",
		str(order))
	_check(int(outcome["ms"]) < int(host.sync_timeout_sec * 1000.0),
		"as soon as it was ready, not at the timeout — the joiner mid-change was not waited on",
		"%d ms" % int(outcome["ms"]))
	_check(host.peers.has(late_peer),
		"and that joiner follows the next change, having been announced the map this one settled on")

	# A built-in map is not a pack and the protocol says so: the announce names no content,
	# and the client reports ready without starting a fetch. Nothing was faked into a
	# download to make the protocol happy.
	var announced := _client_bridge.map_client.announced
	_check(announced != null and announced.is_local() and announced.content_id == &"",
		"a built-in map is announced as one — no content id, nothing to fetch")
	_check(fetched.is_empty(), "and the client fetched nothing", str(fetched))

	_server_bridge.remove_player(late_session)
	_check(not host.peers.has(late_peer), "a peer that leaves stops being followed")

	_check(_client_player() != null, "keeping its players")
	_steps(4)
	_check(_client_player().global_position.distance_to(_server_player().global_position) < 1.0, "at the new spawn",
		"%.3f m" % _client_player().global_position.distance_to(_server_player().global_position))
	_done()


## [b]A map won by vote reaches the clients.[/b]
##
## The vote's map source was handed `game.maps`, and `DotMapSession.change_to` swaps the
## server's own world and tells nobody — so on a live server a vote moved it to bhop_fur
## while both players stayed on surf_mesa, and the respawn put them at bhop_fur's start
## in the sky over a map they were still drawing. `_test_map_change` could not see it: it
## calls `G2GGame.change_map`, which was always right. This goes in through the door the
## vote uses — `source.apply`, exactly what the director calls on a winner. Armed by
## giving the source `game.maps` back: the server changed and the client did not.
func _test_map_by_vote() -> void:
	_section("changing the map by vote: the clients are told")

	var host := _server_bridge.map_host
	host.poll_interval_sec = 0.05
	host.sync_timeout_sec = 5.0

	var vote := G2GVote.new()
	vote.name = "MapVote"
	vote.game = _server_game
	vote.authoritative = false
	vote.config_path = ""
	add_child(vote)
	var built := vote.setup()
	_check(built.ok, "a vote is built on the server's game", str(built.error) if not built.ok else "")

	var announced := [0]
	var on_announce := func(_m: Variant) -> void: announced[0] += 1
	host.change_finished.connect(on_announce)

	var target := &"bhop_g2g_intro"
	var applied := [null]
	var apply := func() -> void: applied[0] = await vote.source.apply(target)
	apply.call()

	var on_client := await _until_client_on(target, 8.0)
	host.change_finished.disconnect(on_announce)

	_check(_server_game.maps.current.id == target, "the server changes to the map that won")
	_check(announced[0] == 1, "through the map-sync host, which tells the clients",
		"the vote swapped the server's world on its own")
	_check(on_client, "and the client follows it",
		"client on %s" % (String(_client_game.maps.current.id) if _client_game.maps.current != null else "nothing"))

	_steps(4)
	_check(_client_player() != null and _client_player().global_position.distance_to(_server_player().global_position) < 1.0,
		"standing where the server put it, not at the new map's start inside the old one")

	vote.queue_free()
	_done()


## [b]An imported map, delivered, through the protocol.[/b]
##
## Every imported map is ONE scene in the build, `maps/imported_map.tscn`, pointed at a
## manifest — the mount constraint forbids putting a scene that extends a build class in
## the pack. dot-map's rule for a map a client does not have used to be that its scene is
## in the pack, so it refused every one; the bridge fetched by its own convention before
## dot-map saw the announce. Now the client lists that scene as a trusted template and
## dot-map requires the MANIFEST to be in the pack instead. Armed by removing the template
## from the bridge: the client refused the map and stayed where it was.
func _test_map_delivered() -> void:
	_section("changing the map: an imported map that is delivered")

	DotPaths.remove_tree(SYNC_FIXTURE_ROOT)
	var keys := DotCloudSignature.generate_keypair()
	_check(keys.ok, "a signing key is made for this suite's content")
	if not keys.ok:
		return
	_fixture_keys = keys.value
	var published := _publish_map_fixture(DELIVERED_FIXTURE, "1.2.0", keys.value)
	var slow_one := _publish_map_fixture(SYNC_FIXTURE, "1.0.0", keys.value)
	_check(published.ok and slow_one.ok, "two imported maps publish as signed packs",
		"%s %s" % [published.error, slow_one.error])
	if not (published.ok and slow_one.ok):
		return
	_start_content(keys.value)
	await get_tree().process_frame

	# The server fetches it the way it fetches `content_maps`, and says what it is.
	var fetched: DotResult = await _server_game.ensure_map_content(DELIVERED_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(DELIVERED_FIXTURE)
	var mount := "res://dot_cloud/%s/1.2.0/" % DELIVERED_FIXTURE
	_check(fetched.ok and on_server != null, "the server fetches the map into its catalogue",
		str(fetched.error) if not fetched.ok else "")
	_check(on_server != null and on_server.content_id == DELIVERED_FIXTURE
		and on_server.content_version == "1.2.0"
		and str(on_server.meta.get("manifest", "")).begins_with(mount),
		"and marks it as that content and version, its manifest in the mount",
		str(on_server.describe()) if on_server != null else "none")
	_check(not _client_game.maps.catalogue.has(DELIVERED_FIXTURE), "the client does not have it")

	var refused: Array[String] = []
	var on_refused := func(id: StringName, why: String) -> void: refused.append("%s: %s" % [id, why])
	_client_bridge.map_refused.connect(on_refused)

	var outcome := await _change_and_pump(DELIVERED_FIXTURE, 8.0)
	_client_bridge.map_refused.disconnect(on_refused)

	_check(bool(outcome["ok"]) and refused.is_empty(), "the server changes to it and the client does not refuse",
		"%s %s" % [outcome["reason"], refused])
	var followed := await _until_client_on(DELIVERED_FIXTURE, 3.0)
	_check(followed, "the client is on it",
		String(_client_game.maps.current.id) if _client_game.maps.current != null else "none")
	var world := _client_game.maps.world
	_check(world != null and world.scene_file_path == G2GMapCatalogue.IMPORTED_SCENE
		and str(world.get("manifest_path")).begins_with(mount),
		"as the imported-map scene out of its own build, built from the manifest in the pack",
		"%s %s" % [world.scene_file_path if world != null else "-", world.get("manifest_path") if world != null else "-"])
	var kept := _client_game.maps.catalogue.get_map(DELIVERED_FIXTURE)
	_check(kept != null and kept.content_id == DELIVERED_FIXTURE,
		"and keeps it, as delivered content, for next time")
	_done()


## A map republished with different files, in one process: the server's next fetch and a
## client that had mounted the OLD pack both end on the new one.
##
## [b]Every map pack was `@0.0.0` (`[g2g-maps-version-1]`).[/b] dot-cloud keys a mount on
## `id@version` and cannot undo one, so a client that had mounted the old pack was told
## "that map, 0.0.0" by a server that had the new one, found it mounted, and played the
## old geometry. `G2GMapCatalogue.pack_version` names a pack by its files; this is the
## check that a change of files reaches a client that already holds the map.
func _test_map_republished() -> void:
	_section("changing the map: a map republished with different files")
	if _fixture_keys.is_empty():
		_check(false, "the delivered section made a signing key")
		_done()
		return

	var first := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys)
	var again := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys)
	_check(first.ok and again.ok, "a map publishes under the version of its files",
		"%s %s" % [first.error, again.error])
	var source := SYNC_FIXTURE_ROOT.path_join("src").path_join(String(REPUB_FIXTURE))
	var v1 := G2GMapCatalogue.pack_version(source)

	var fetched: DotResult = await _server_game.ensure_map_content(REPUB_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(REPUB_FIXTURE)
	var outcome := await _change_and_pump(REPUB_FIXTURE, 8.0)
	var followed := await _until_client_on(REPUB_FIXTURE, 3.0)
	_check(fetched.ok and on_server != null and on_server.content_version == v1
		and bool(outcome["ok"]) and followed and _client_world_from(REPUB_FIXTURE, v1),
		"and the server and a client are on it at that version (%s)" % v1,
		"%s %s" % [fetched.error if not fetched.ok else "", outcome["reason"]])

	var changed := _publish_map_fixture(REPUB_FIXTURE, "", _fixture_keys, "",
		{"display_name": "repub fixture, second cut"})
	var v2 := G2GMapCatalogue.pack_version(source)
	_check(changed.ok and v2 != v1 and v2.begins_with("0.0.0-"),
		"republished with different files, it is a different version (%s)" % v2)

	# What a restarted server knows: nothing about this map. Same process, same mounts,
	# and the client still holds the first pack and its catalogue entry.
	_server_game.maps.catalogue.remove(REPUB_FIXTURE)
	_server_game._map_content_seen.erase(REPUB_FIXTURE)
	var away := await _change_and_pump(DELIVERED_FIXTURE, 8.0)
	var refetched: DotResult = await _server_game.ensure_map_content(REPUB_FIXTURE)
	on_server = _server_game.maps.catalogue.get_map(REPUB_FIXTURE)
	_check(bool(away["ok"]) and refetched.ok and on_server != null
		and on_server.content_version == v2,
		"the server's next fetch mounts the new version beside the old",
		str(on_server.describe()) if on_server != null else str(refetched.error))

	outcome = await _change_and_pump(REPUB_FIXTURE, 8.0)
	followed = await _until_client_on(REPUB_FIXTURE, 3.0)
	_check(bool(outcome["ok"]) and followed and _client_world_from(REPUB_FIXTURE, v2),
		"and a client that had the old one plays the new one",
		"%s %s" % [outcome["reason"],
			_client_game.maps.world.get("manifest_path") if _client_game.maps.world != null else "-"])
	_done()


## Whether the client's world was built from [param id]'s pack at [param version].
func _client_world_from(id: StringName, version: String) -> bool:
	var world := _client_game.maps.world
	return world != null and str(world.get("manifest_path")).begins_with(
		"res://dot_cloud/%s/%s/" % [id, version])


## A map on an origin that keeps packs under an owner: the map id stays what a player
## types, the pack is `<owner>/<id>`. See [member G2GConfig.map_content_owner].
func _test_map_owned() -> void:
	_section("changing the map: a map published under an owner")

	# The key the delivered section made and the content client already trusts. A fresh
	# one here replaced it, and every fixture signed before it stopped verifying.
	var published := _publish_map_fixture(OWNED_FIXTURE, "1.0.0", _fixture_keys, "someone") \
		if not _fixture_keys.is_empty() else DotResult.fail(DotError.CODE_STATE, "no key")
	_check(published.ok, "a map publishes as someone/<id>", str(published.error))
	if not published.ok:
		_done()
		return

	_server_game.config.map_content_owner = "someone"
	var fetched: DotResult = await _server_game.ensure_map_content(OWNED_FIXTURE)
	var on_server := _server_game.maps.catalogue.get_map(OWNED_FIXTURE)
	_check(fetched.ok and on_server != null,
		"the server fetches it by the map id alone, with the owner from its config",
		str(fetched.error) if not fetched.ok else "")
	_check(on_server != null and String(on_server.content_id) == "someone/%s" % OWNED_FIXTURE
		and str(on_server.meta.get("manifest", "")).begins_with(
			"res://dot_cloud/someone/%s/1.0.0/" % OWNED_FIXTURE),
		"and files it under the map id, marked as the owned content it came from",
		str(on_server.describe()) if on_server != null else "none")

	var outcome := await _change_and_pump(OWNED_FIXTURE, 8.0)
	var followed := await _until_client_on(OWNED_FIXTURE, 3.0)
	_check(bool(outcome["ok"]) and followed,
		"and a client follows it there, fetching the owned pack the announce names",
		"%s" % outcome["reason"])
	_server_game.config.map_content_owner = ""
	_done()


func _test_map_straggler() -> void:
	_section("changing the map: a client that is still downloading")

	var host := _server_bridge.map_host
	host.sync_timeout_sec = SYNC_TIMEOUT

	# What `G2GGame.ensure_map_content` makes of a pack it fetched — built by hand, because
	# a server in this process that mounted the pack would have mounted it for the client
	# too (see [SlowCloud]). The server's own load at the swap mounts it for real.
	var on_server := DotMapDef.new()
	on_server.id = SYNC_FIXTURE
	on_server.scene_path = G2GMapCatalogue.IMPORTED_SCENE
	on_server.content_id = SYNC_FIXTURE
	on_server.content_version = "1.0.0"
	on_server.meta["manifest"] = "res://dot_cloud/%s/1.0.0/%s.json" % [SYNC_FIXTURE, SYNC_FIXTURE]
	on_server.meta["imported"] = true
	_check(_server_game.maps.catalogue.add(on_server).ok,
		"the server has a map the client does not")
	_check(not _client_game.maps.catalogue.has(SYNC_FIXTURE), "and the client does not")

	_cloud.asked.clear()
	_cloud.delay_first = SLOW_FETCH

	var timed_out: Array[int] = []
	var on_timeout := func(peer: int) -> void: timed_out.append(peer)
	host.peer_timed_out.connect(on_timeout)
	var notices: Array[String] = []
	var on_notice := func(_pid: int, text: String) -> void: notices.append(text)
	_client_bridge.notice_received.connect(on_notice)
	var progress: Array[float] = []
	var on_progress := func(_peer: int, fraction: float) -> void: progress.append(fraction)
	host.peer_progress.connect(on_progress)

	var outcome := await _change_and_pump(SYNC_FIXTURE, SYNC_TIMEOUT + 3.0)

	_check(bool(outcome["ok"]), "the change goes ahead without the client", str(outcome["reason"]))
	_check(timed_out == [CLIENT_PEER], "and the server names the one it did not wait for", str(timed_out))
	_check(outcome["client_then"] != String(SYNC_FIXTURE),
		"which was still downloading when the server swapped", str(outcome["client_then"]))
	_check(not _cloud.asked.is_empty() and _cloud.asked[0] == "%s@1.0.0" % SYNC_FIXTURE,
		"from its own content client, for exactly the content and version announced",
		str(_cloud.asked))
	_check(not progress.is_empty(), "the server heard it had started (%d reports)" % progress.size())
	_check(notices.any(func(t: String) -> bool: return t.contains("changed before your client had it")),
		"and the client was told the map changed without it", str(notices))

	# The one that matters. The `load` arrived while the fetch was still running. The bridge
	# used to queue map messages behind its own fetch for this; dot-map holds such a load
	# until the fetch lands now. Armed both times by taking the load at once: before, it
	# was dropped and the client stayed on the old world; in dot-map, it asked for the
	# pack a second time mid-download (dot-map's suite asserts that one).
	# [b]And while it waits, it does not play a world it does not have.[/b] The server is
	# simulating this player on the new map; the client still has the old one, or on a
	# joiner's first connect no world at all. Predicting there was a player falling through
	# nothing and corrected back by every snapshot, while the server applied the keys it was
	# sent to somewhere the player could not see — the grey, jittering first connect that a
	# reconnect, with the pack cached, never showed. Armed by making `in_transit` answer
	# false: the client predicts the held key and sends it, and both checks below fail.
	_check(_client_bridge.in_transit() and _client_bridge.transit_text().begins_with("Loading"),
		"the client knows the server is on a map it has not loaded, and says so",
		_client_bridge.transit_text())
	var history_before := _client_net.local_inputs().since(0).size()
	var client_before := _client_player().global_position
	_steps(8, _forward())
	_check(_client_net.local_inputs().since(0).size() <= history_before
		and _client_player().global_position.distance_to(client_before) < 0.05,
		"so it predicts nothing from the keys held meanwhile",
		"history %d -> %d, moved %.3f m" % [history_before,
			_client_net.local_inputs().since(0).size(),
			_client_player().global_position.distance_to(client_before)])
	var held: G2GPlayerNet = _server_bridge.behaviour_for(SESSION)
	_check(held != null and held.last_move.move.length() < 0.01,
		"and the server is sent a player standing still, not the key it would repeat",
		str(held.last_move.move) if held != null else "no behaviour")

	var followed := await _until_client_on(SYNC_FIXTURE, SLOW_FETCH + 2.0)
	_check(followed, "and it follows once the download finishes, because the load waited behind it",
		String(_client_game.maps.current.id) if _client_game.maps.current != null else "none")
	_check(_client_game.maps.catalogue.has(SYNC_FIXTURE), "and keeps the map for next time")
	_check(not _client_bridge.in_transit() and _client_bridge.transit_text() == "",
		"and the cover comes down once it is on the server's map")

	host.peer_timed_out.disconnect(on_timeout)
	host.peer_progress.disconnect(on_progress)
	_client_bridge.notice_received.disconnect(on_notice)
	_done()


func _test_map_refused() -> void:
	_section("changing the map: a client that refuses")
	print("  (the refusals below log on purpose: a WRN from dot-map and one from the bridge each)")

	var host := _server_bridge.map_host
	host.sync_timeout_sec = SYNC_TIMEOUT
	var refused: Array[String] = []
	var on_refused := func(id: StringName, why: String) -> void: refused.append("%s: %s" % [id, why])
	_client_bridge.map_refused.connect(on_refused)
	var timed_out: Array[int] = []
	var on_timeout := func(peer: int) -> void: timed_out.append(peer)
	host.peer_timed_out.connect(on_timeout)

	# A map the server has in ITS build and the client has nowhere, named by a host.
	# Loading it would mean loading a path of the host's choosing out of THIS build — the
	# rule dot-map exists to enforce, now enforced over a real wire.
	var stages := _server_game.maps.catalogue.get_map(&"bhop_g2g_stages")
	var server_only := DotMapDef.from_dictionary(stages.to_dictionary())
	server_only.id = &"g2g_server_only"
	_server_game.maps.catalogue.add(server_only)

	var before: StringName = _client_game.maps.current.id
	var outcome := await _change_and_pump(&"g2g_server_only", SYNC_TIMEOUT + 3.0)

	_check(bool(outcome["ok"]) and _server_game.maps.current.id == &"g2g_server_only",
		"the server changes anyway", str(outcome["reason"]))
	_check(timed_out == [CLIENT_PEER], "timing out the client, which never said ready", str(timed_out))
	_check(refused.size() == 1 and refused[0].begins_with("g2g_server_only: A host may not send a map that is not delivered content"),
		"the client refuses a map that is neither its own nor delivered", str(refused))
	_check(_client_game.maps.current.id == before,
		"and stays where it was rather than load a scene the host named out of its own build",
		String(_client_game.maps.current.id))

	# A map both have, at a version the client does not: the republished-map case, which on
	# a timer server is a record set on geometry nobody else has.
	refused.clear()
	timed_out.clear()
	var republished := DotMapDef.from_dictionary(stages.to_dictionary())
	republished.version = "2.0.0"
	_server_game.maps.catalogue.remove(&"bhop_g2g_stages")
	_server_game.maps.catalogue.add(republished)
	var second := await _change_and_pump(&"bhop_g2g_stages", SYNC_TIMEOUT + 3.0)
	_check(bool(second["ok"]) and timed_out == [CLIENT_PEER], "a map the client has at another version times it out too",
		"%s %s" % [second["reason"], timed_out])
	_check(refused.size() == 1 and refused[0].contains("different version"),
		"because it refuses to play old geometry the server has replaced", str(refused))
	_check(_client_game.maps.current.id == before, "and stays put again")

	# And a refusal wedges nothing: the next change to a map both have is an ordinary one.
	_server_game.maps.catalogue.remove(&"bhop_g2g_stages")
	_server_game.maps.catalogue.add(stages)
	_server_game.maps.catalogue.remove(&"g2g_server_only")
	host.sync_timeout_sec = 5.0
	var back := await _change_and_pump(&"surf_g2g_intro", 8.0)
	_check(bool(back["ok"]) and int(back["ms"]) < 5000
		and _client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro",
		"the next change after a refusal is an ordinary one", "%s %d ms" % [back["reason"], int(back["ms"])])

	host.peer_timed_out.disconnect(on_timeout)
	_client_bridge.map_refused.disconnect(on_refused)
	DotRegistry.unregister_instance(&"dot_cloud_client", _cloud)
	_cloud.queue_free()
	_real_cloud.queue_free()
	_server_game.maps.catalogue.remove(SYNC_FIXTURE)
	_server_game.maps.catalogue.remove(DELIVERED_FIXTURE)
	DotPaths.remove_tree(SYNC_FIXTURE_ROOT)
	_steps(4)
	_done()
