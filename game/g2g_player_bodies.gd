extends RefCounted

## Players solid to each other: the physics half of `mp_solidplayers`.
##
## [b]Both halves, or nothing changes.[/b] Each player gets a static hull on the layout's `player`
## layer that rides its node (feet at the origin), and each controller sweeps against that
## layer. [member DotPlayerBodyRules.pair_fn] (dot-team's block rules: `mp_teamblock`,
## `mp_enemyblock`, `!block`, `!noblock`) then decides pair by pair, by leaving the other's hull
## out of this player's sweep. The same call runs on both ends, so a client predicts against the
## pairs the server decided. A hull is where its player's node is drawn, so a client meets a
## remote where it is interpolated, not where the server has it; that is the cost of the
## physics hull, and a pair that passes costs nothing.

const HULL_BODY := &"SolidHullBody"

## The ghost is a recording, not a runner: nobody stops at it.
const GHOST_ID := &"u900000001"


## Brings every player in line with [param game]'s `body_rules`: mask, pass-out layers, hull and
## exclusions. Safe to repeat; called when the rules change and when a player joins or leaves.
static func apply(game: Object) -> void:
	var rules: DotPlayerBodyRules = game.body_rules
	var stack: Object = game.get("player_stack")
	var layers := player_layers(stack)
	var base: int = stack.player_collision_mask() if stack != null else 1
	var bodies: Dictionary = {}
	for id: StringName in game.players:
		var player: Node = game.players[id]
		if player == null or not is_instance_valid(player) or id == GHOST_ID:
			continue
		var ctl: Object = player.get("controller")
		if ctl == null or ctl.get("tunables") == null:
			continue
		var hull := _hull_body(player, layers)
		rules.apply_hull(hull, ctl.tunables.stand_height, ctl.tunables.radius)
		var mask := rules.mask(base, layers)
		player.use_collision_mask(mask)
		ctl.set_collision_mask(mask)
		ctl.set_pass_out_layers(layers if rules.solid else 0)
		bodies[id] = {"body": hull, "controller": ctl}
	var any := false
	for id: StringName in bodies:
		var ctl: Object = (bodies[id] as Dictionary)["controller"]
		var rids: Array[RID] = [((bodies[id] as Dictionary)["body"] as CollisionObject3D).get_rid()]
		for other: StringName in bodies:
			if other == id:
				continue
			if rules.blocks(String(id), String(other)):
				any = true
			else:
				rids.append(((bodies[other] as Dictionary)["body"] as CollisionObject3D).get_rid())
		ctl.set_extra_excludes(rids)
	game.hulls_live = any


static func player_layers(stack: Object) -> int:
	if stack == null or stack.get("physics") == null or stack.physics.layout == null:
		return 0
	return stack.physics.layout.layer_mask(&"player")


## A player's hull body, made on first use; nothing else touches it.
static func _hull_body(player: Node, layers: int) -> StaticBody3D:
	var body := player.get_node_or_null(NodePath(String(HULL_BODY))) as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = HULL_BODY
		body.collision_mask = 0
		player.add_child(body)
	body.collision_layer = layers
	return body
