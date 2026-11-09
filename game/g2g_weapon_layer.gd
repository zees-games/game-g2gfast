extends Node

## Deagles lying in the world: dot-weapon's drop layer under the `sv_weapon_drop*` rules, built on the
## server (simulates, hands weapons to an empty slot) and on a client (draws what it is told).

const G2GArsenal := preload("g2g_arsenal.gd")
const G2GGame := preload("g2g_game.gd")
const G2GPlayer := preload("g2g_player.gd")

## The server owner's cvars; they outlive a map change, so the game owns them, not the layer.
var rules: DotWeaponDropRules = DotWeaponDropRules.new()
var drops: DotWeaponDrops = null
var game: G2GGame = null
## Server: whether each player's use key is down (set by the ask), and one [DotWeaponUseKey] per player.
var use_down: Dictionary = {}
var _keys: Dictionary = {}
## Client: the key over the weapon looked at, and the panel.
var _client_key: DotWeaponUseKey = DotWeaponUseKey.new()
var _view: DotWeaponPickupView = null


## Names itself and joins [param owner_game], on either side.
func setup(owner_game: G2GGame) -> void:
	game = owner_game
	name = "WeaponLayer"
	game.add_child(self)
	drops = DotWeaponDrops.new()
	drops.name = "WeaponDrops"
	rules.auto_pickup = true
	drops.rules = rules
	drops.is_authority = game.authoritative
	drops.draws = DisplayServer.get_name() != "headless"
	drops.collision_mask = game.ragdoll_rules.collision_mask
	# The knife is the fallback weapon and stays in hand.
	drops.keep_slots = [G2GArsenal.knife().slot]
	drops.look_of = _look
	add_child(drops)


## The drop key: throws the weapon in hand along the aim. Server side.
func throw_for(player_id: StringName) -> int:
	var player: G2GPlayer = game.players.get(player_id)
	var arsenal := _arsenal(player_id)
	if drops == null or player == null or arsenal == null or not game.combat.health_of(player_id).alive:
		return 0
	return drops.throw(arsenal, player.eye_position(), player.aim_direction(),
		game.combat.entity_for(player_id), null, player.controller.state.velocity)


## An armed player standing at a dropped weapon takes it when the slot is empty. Server side.
func tick(_delta: float) -> void:
	if drops == null or not drops.is_authority or game.combat == null or drops.count() == 0:
		return
	for player_id: StringName in game.players:
		var arsenal := _arsenal(player_id)
		var player: G2GPlayer = game.players[player_id]
		if arsenal != null and not arsenal.disabled and game.combat.health_of(player_id).alive:
			if use_step(player_id, arsenal, player, bool(use_down.get(player_id, false)), _delta):
				continue
			var _taken := drops.take_for(arsenal, player.controller.state.position + Vector3.UP * 0.5,
				game.combat.entity_for(player_id))


## The use key over a dropped weapon, the shared rules of [DotWeaponUseKey]. Server side; true while the key is busy with a drop.
func use_step(player_id: StringName, arsenal: DotWeaponArsenal, player: G2GPlayer, pressed: bool, delta: float) -> bool:
	var key: DotWeaponUseKey = _keys.get(player_id)
	if key == null:
		key = DotWeaponUseKey.new()
		_keys[player_id] = key
	return key.step(drops, arsenal, player.eye_position(), player.aim_direction(), game.combat.entity_for(player_id),
		pressed, delta, null, 0)


## The ask: the use key went down or up. Server side.
func set_use(player_id: StringName, down: bool) -> void:
	use_down[player_id] = down


## Client, every frame: the panel over the weapon looked at; returns the crosshair ring fill, 0..1.
func update_prompt(player: G2GPlayer, arsenal: Object, pressed: bool, delta: float, key_text: String = "E") -> float:
	if drops == null or player == null:
		return 0.0
	if _view == null:
		_view = DotWeaponPickupView.new()
		_view.name = "PickupView"
		_view.visible = false
		game.add_child(_view)
	var info := {}
	if drops.count() > 0:
		info = drops.prompt_for(arsenal, player.eye_position(), player.aim_direction())
	var fill := _client_key.client_progress(info, pressed, delta, rules.hold_time)
	_view.key_text = key_text
	# One ring: the crosshair's; the panel's own world circle stays off.
	_view.show_prompt(info, 0.0)
	return fill


## Called as a player dies, before the combat layer disables the arsenal (a dead one gives up nothing).
func drop_dead(player_id: StringName) -> void:
	var player: G2GPlayer = game.players.get(player_id)
	var arsenal := _arsenal(player_id)
	if drops == null or player == null or arsenal == null:
		return
	var state := player.controller.state
	var _gun := drops.drop_dead(arsenal, state.position + Vector3.UP, state.velocity * 0.5 + Vector3.UP * 2.0 + player.aim_direction(),
		game.combat.entity_for(player_id))


func clear() -> void:
	if drops != null:
		drops.clear()


func describe() -> Dictionary:
	return {"drops": drops.count() if drops != null else 0, "authority": drops != null and drops.is_authority}


func _arsenal(player_id: StringName) -> DotWeaponArsenal:
	return game.combat.arsenal_of(player_id) if game.combat != null else null


func _look(_weapon_id: StringName) -> Node3D:
	var body := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.08, 0.14, 0.32)
	body.mesh = mesh
	return body
