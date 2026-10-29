extends Node

## The static half of G2GCombat: the weapon table, the default kit, the hitbox layout and the id parse.
## No class_name; scripts keep using G2GCombat.

const G2GArsenal := preload("g2g_arsenal.gd")


## The two weapons everybody starts with.
static func _give_default(arsenal: DotWeaponArsenal) -> void:
	arsenal.clear()
	arsenal.give(G2GArsenal.ITEM_KNIFE)
	arsenal.give(G2GArsenal.ITEM_DEAGLE)
	hold(arsenal, 2)


## Holds [param slot] at once. `select` refuses while the arsenal is disabled, which would leave a
## player (a bot presses no slot key) on the first weapon given, the knife.
static func hold(arsenal: DotWeaponArsenal, slot: int, tick: int = 0) -> void:
	if arsenal.has_method("equip") and arsenal.equip(slot):
		return
	var _selected := arsenal.select(slot, tick)


## The shared weapon table, built and validated once for the whole process.
static var _shared_catalogue: DotWeaponCatalogue = null


static func catalogue() -> DotWeaponCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = G2GArsenal.weapon_catalogue()
		var res := _shared_catalogue.validate()
		if not res.ok:
			push_error(res.error.message)
	return _shared_catalogue


static func _add_hitboxes(set_node: DotHitboxSet) -> void:
	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.15
	head.position = Vector3(0.0, 1.62, 0.0)
	# Higher than the chest's, so the surface the two share resolves to the head every
	# time rather than about half the time.
	head.precedence = 10
	set_node.add_child(head)

	var chest := DotHitbox.new()
	chest.name = "Chest"
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.30
	chest.height = 1.05
	chest.position = Vector3(0.0, 0.98, 0.0)
	set_node.add_child(chest)

	var legs := DotHitbox.new()
	legs.name = "Legs"
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.24
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	set_node.add_child(legs)


## The account number inside a player id. `u123` becomes 123.
## Not an entity id: a loadout's filename and the session lookup want this number.
static func userid_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else text.to_int()
