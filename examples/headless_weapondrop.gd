extends DotGameCheckSuite

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GArsenal := preload("../game/g2g_arsenal.gd")
const G2GEvent := preload("../game/net/g2g_event.gd")
const G2GEvents := preload("../game/net/g2g_events.gd")
const G2GRequest := preload("../game/net/g2g_request.gd")
const G2GWeaponNet := preload("../game/net/g2g_weapon_net.gd")

## Dropped weapons: the drop key throws the weapon in hand, an empty slot in reach takes it back,
## the despawn and cap cvars bite, a kill leaves the dead player's weapon lying, and a client
## (and a joiner's snapshot) sees the same drops through the weapon events.
##
## [codeblock]
## godot --headless --path . res://examples/headless_weapondrop.tscn
## [/codeblock]

const SECTIONS := 4
const CHECKS := 22

var _entered := 0
var _completed := 0
var _server: G2GGame = null
var _client: G2GGame = null
var _wire: Array = []
var _client_net := G2GWeaponNet.new()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: weapon drops")
	_server = await _make_game(true, &"drops_server")
	_client = await _make_game(false, &"drops_client")
	_test_wire()
	_test_throw_and_pickup()
	_test_cvars()
	_test_replication()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _make_game(server: bool, scope: StringName) -> G2GGame:
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.authoritative = server
	config.deathmatch = server
	var game := G2GGame.new()
	game.name = "Server" if server else "Client"
	game.config = config
	game.service_scope = scope
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	return game


func _test_wire() -> void:
	_entered += 1
	print("The events fit their wire")
	_check(G2GEvent.fits(), "every event kind fits its field")
	_check(G2GRequest.fits(), "every ask fits its field")
	_check(_server.weapon_layer != null and _server.weapon_layer.drops.is_authority,
		"the server game builds an authoritative layer")
	_check(_client.weapon_layer != null and not _client.weapon_layer.drops.is_authority,
		"the client game builds a mirror")
	_completed += 1


func _test_throw_and_pickup() -> void:
	_entered += 1
	print("Drop, pickup and death")
	var layer := _server.weapon_layer
	var rules := layer.rules
	var ada := _server.add_player(&"u1", "Ada")
	var _bea := _server.add_player(&"u2", "Bea")
	var arsenal := _server.combat.arsenal_of(&"u1")
	var deagle: int = G2GArsenal.deagle().slot
	if not _check(arsenal != null and arsenal.has_slot(deagle), "an armed player carries the deagle"):
		return

	rules.key_enabled = false
	_check(layer.throw_for(&"u1") == 0 and layer.drops.count() == 0, "sv_weapon_drop_key 0 throws nothing")
	rules.key_enabled = true

	_check(layer.throw_for(&"u1") > 0 and layer.drops.count() == 1, "the key throws the weapon in hand")
	_check(not arsenal.has_slot(deagle), "and it has left the player's hands")

	var where: Vector3 = (layer.drops.snapshot()[0]["at"] as Transform3D).origin
	ada.controller.state.position = where - Vector3.UP * 0.5
	layer.tick(0.0)
	_check(layer.drops.count() == 1, "it cannot be picked up again until the delay is over")
	layer.drops.tick(1.0)
	layer.tick(0.0)
	_check(layer.drops.count() == 0 and arsenal.has_slot(deagle), "then an empty slot in reach takes it back")

	var before := layer.drops.count()
	var victim := _server.combat.entity_for(&"u2")
	_server.combat.health_of(&"u2").spawn_protection_ticks = 0
	_server.combat.manager.apply_damage(DotDamage.make(0, victim, 5000.0, G2GArsenal.world()))
	_check(layer.drops.count() == before + 1, "a kill leaves the dead player's weapon lying")

	layer.clear()
	_check(layer.drops.count() == 0, "a new round clears the floor")
	_completed += 1


func _test_cvars() -> void:
	_entered += 1
	print("The cvars")
	var layer := _server.weapon_layer
	var rules := layer.rules
	var arsenal := _server.combat.arsenal_of(&"u1")
	rules.pickup_radius = 0.0

	rules.lifetime = 2.0
	_hold_deagle(arsenal)
	var _gone := layer.throw_for(&"u1")
	layer.drops.tick(3.0)
	_check(layer.drops.count() == 0, "sv_weapon_drop_time makes a drop vanish once it has lain that long")

	rules.lifetime = 60.0
	rules.max_count = 1
	_hold_deagle(arsenal)
	var first := layer.throw_for(&"u1")
	_hold_deagle(arsenal)
	var second := layer.throw_for(&"u1")
	_check(layer.drops.count() == 1 and second > 0 and not layer.drops.has_drop(first),
		"sv_weapon_drop_max 1 keeps the newest and cleans the oldest", str(layer.drops.count()))

	rules.on_death = false
	_hold_deagle(arsenal)
	var drops_before := layer.drops.count()
	layer.drop_dead(&"u1")
	_check(layer.drops.count() == drops_before, "sv_weapon_drop_death 0 leaves nothing when a player dies")

	rules.enabled = false
	_check(layer.throw_for(&"u1") == 0, "sv_weapon_drop 0 turns the whole layer off")
	rules.enabled = true
	rules.on_death = true
	rules.max_count = 32
	rules.pickup_radius = 1.4
	layer.clear()
	_completed += 1


func _test_replication() -> void:
	_entered += 1
	print("Replicated to clients")
	var layer := _server.weapon_layer
	var net := G2GWeaponNet.new(_to_wire)
	net.watch(layer)
	_hold_deagle(_server.combat.arsenal_of(&"u1"))
	var id := layer.throw_for(&"u1")
	_check(id > 0 and _wire.size() == 1, "a throw sends one event to every peer")
	_pump()
	var mirror := _client.weapon_layer.drops
	_check(mirror.count() == 1 and mirror.has_drop(id), "the client draws the same drop under the same id")

	layer.drops.tick(5.0)
	var rest: Array = layer.drops.snapshot()
	var _settled := rest.size()
	_pump()

	var joiner := G2GGame.new()
	joiner.name = "Joiner"
	joiner.config = _client.config
	joiner.service_scope = &"drops_joiner"
	add_child(joiner)
	var joined: Array = []
	net.sink = func(_peer: int, kind: int, body: PackedByteArray) -> void: joined.append([kind, body])
	net.send_snapshot(7, layer)
	net.sink = _to_wire
	_check(joined.size() == layer.drops.count(), "a joiner is sent every weapon lying", str(joined.size()))
	for entry in joined:
		var _ok := _client_net.apply(entry[0], DotNetReader.new(entry[1]), joiner.weapon_layer)
	_check(joiner.weapon_layer.drops.count() == layer.drops.count() and joiner.weapon_layer.drops.has_drop(id),
		"and builds the same floor from it")
	joiner.queue_free()

	layer.clear()
	_pump()
	_check(mirror.count() == 0, "a round reset reaches the client")
	_check(not _client_net.apply(G2GEvents.Kind.SHOT, DotNetReader.new(PackedByteArray()), _client.weapon_layer),
		"an event that is not a weapon's is left to the bridge")
	_completed += 1


func _to_wire(peer_id: int, kind: int, body: PackedByteArray) -> void:
	_wire.append([peer_id, kind, body])


func _pump() -> void:
	for item in _wire:
		var _ok := _client_net.apply(item[1], DotNetReader.new(item[2]), _client.weapon_layer)
	_wire.clear()


func _hold_deagle(arsenal: DotWeaponArsenal) -> void:
	var _given := arsenal.give(G2GArsenal.ITEM_DEAGLE)
	var _held := arsenal.equip(G2GArsenal.deagle().slot)
