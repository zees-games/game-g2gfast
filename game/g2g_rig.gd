extends Node3D

const G2GAvatars := preload("g2g_avatars.gd")
const G2GMovement := preload("g2g_movement.gd")
const G2GUnits := preload("g2g_units.gd")

## The visible character: attachment nodes for the avatar slots, sized to the genre
## hull, and the switch between "I am looking out of it" and "I am looking at it".
##
## [b]The rig is a Node3D under the player body, not the body itself.[/b] The body is
## what the movement drives and what the view rotates for yaw; the rig is what a
## camera looks at. Keeping them apart is what lets first person hide the rig without
## hiding the collider, and third person spin the camera round something that still
## faces where the player is aiming.
##
## Attachment nodes are named for the schema's slots, which is how
## [DotAvatarBuilder.apply] finds them — a slot whose node is missing is a warning
## and an invisible part, never a crash.

## The render layer the local player's own rig is on, so a first-person camera can
## cull it without hiding anybody else's.
const LAYER_LOCAL_BODY := 2

var body_mount: Node3D = null
var head_mount: Node3D = null
var hat_mount: Node3D = null

## Whether the rig is drawn at all. Off in first person for the local player.
var visible_to_owner: bool = true:
	set(value):
		visible_to_owner = value
		_apply_visibility()

## Whether the head and the hat are part of what the owner sees.
##
## [b]Only meaningful while [member visible_to_owner] is on, and it exists because the
## two halves of the rig are in different places relative to the camera.[/b] The head
## and hat mounts sit AT the eye — that is what they are for — so a first-person camera
## that draws them is inside a 40 cm cube and the view is a flat rectangle of one
## colour with a straight edge across it, which is the artefact the layer split in
## [method _set_layers_recursive] exists to prevent. The body mount is 40 cm below the
## eye and draws as a torso, arms and legs, which is a body a player can see.
##
## So "show me my own body in first person" is this off and [member visible_to_owner]
## on; third person is both on, because there the camera is behind the head rather
## than inside it.
var owner_sees_head: bool = true:
	set(value):
		owner_sees_head = value
		_apply_visibility()

## The avatar currently applied, for a HUD or a debug dump.
var avatar: DotAvatar = null

## The person drawn, or null before [method dress].
var person: DotHumanoidFigure = null

var _crouch: float = 0.0


func _ready() -> void:
	var height := G2GMovement.player_height()
	var eye := height * G2GMovement.eye_fraction()

	body_mount = _mount(G2GAvatars.SLOT_BODY, Vector3(0.0, height * 0.42, 0.0))
	head_mount = _mount(G2GAvatars.SLOT_HEAD, Vector3(0.0, eye, 0.0))
	hat_mount = _mount(G2GAvatars.SLOT_HAT, Vector3(0.0, eye + 0.02, 0.0))


func _mount(slot: StringName, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = String(slot)
	node.position = at
	add_child(node)
	return node


## Puts an avatar on the rig: as one of the family's people (dot-player-char's
## `DotHumanoidFigure`), coloured from the document by `G2GAvatars.look_of`, wearing the
## document's hat. The parts are still built onto the mounts (conformed first, so a part from a
## newer client is dropped rather than refused, and the result counts the slots drawn), then
## the body and head parts are let go: the person is the body and the head. The hat stays, on
## the top of the person's head.
func dress(
	p_avatar: DotAvatar,
	schema: DotAvatarSchema,
	catalogue: DotAvatarCatalogue
) -> DotResult:
	avatar = p_avatar

	for mount in [body_mount, head_mount, hat_mount]:
		for child in mount.get_children():
			mount.remove_child(child)
			child.queue_free()

	var built := G2GAvatars.apply(p_avatar, self, schema, catalogue)
	if not built.ok:
		return built

	for mount in [body_mount, head_mount]:
		for child in mount.get_children():
			mount.remove_child(child)
			child.queue_free()

	if person != null:
		remove_child(person)
		person.queue_free()
	person = DotHumanoidFigure.new()
	person.name = "Person"
	add_child(person)
	var height := G2GMovement.player_height()
	person.build(G2GAvatars.look_of(p_avatar, StringName(str(get_meta(&"player_key", "")))), height)
	# The people's heads are big: the crown is a few centimetres under the full height.
	hat_mount.position = Vector3(0.0, height - HAT_DROP, 0.0)

	_apply_visibility()

	return built


## How far under the person's full height a hat sits (the hair is the top).
const HAT_DROP := 0.3


## Tells the person how the player moves and advances its clip, once a frame: the drawn
## state's ground speed, vertical speed and floor. The crouch is [method set_crouch]'s.
func move(state: DotFpsState, delta: float) -> void:
	if person == null:
		return
	var v := state.velocity
	person.set_motion({
		"on_floor": state.is_grounded(),
		"vertical": v.y,
		"crouched": _crouch > 0.5,
		# The view's pitch: the upper body and the head follow it, so anybody watching reads
		# where this player is looking.
		"aim": deg_to_rad(state.pitch),
	})
	person.animate(Vector2(v.x, v.z).length(), delta)
	# The hat rides the person's crown (a mount on the head bone), so it goes down with a
	# crouch and nods with the head; it stood still at standing height before, over a
	# crouched player's head.
	var crown := person.attachment(&"hat")
	if crown != null and crown.is_inside_tree() and hat_mount != null:
		hat_mount.global_transform = crown.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, -HAT_DROP, 0.0))


## Records the crouch for the person, who crouches with its clip ([method move]).
## [param fraction] is the state's crouch fraction. It was a squash of the rig when the
## characters were rigid parts with no knees.
func set_crouch(fraction: float) -> void:
	_crouch = fraction


func _apply_visibility() -> void:
	# Layers rather than `visible`, so the rig still casts a shadow a first-person
	# player sees on the floor in front of them — which is the one cue for "how tall
	# am I" a first-person view has.
	#
	# Per mount rather than for the whole rig, because [member owner_sees_head] is the
	# difference between the two halves and the mounts are what separates them. A mount
	# this rig never built (nothing has called `_ready` yet) compares unequal to
	# `body_mount` and is hidden, which is the safe way round.
	for child in get_children():
		var sees := visible_to_owner
		if sees and not owner_sees_head and child != body_mount and child != person:
			sees = false
		_set_layers_recursive(child, sees)
	# The person is one mesh, so the head is not a separate mount to cull: its bone is shrunk
	# instead, for the owner's own body in first person.
	if person != null:
		person.hide_head = visible_to_owner and not owner_sees_head


func _set_layers_recursive(node: Node, owner_sees: bool) -> void:
	if node is VisualInstance3D:
		var visual := node as VisualInstance3D
		# Layer 1 is what every camera sees, LAYER_LOCAL_BODY is the one the local
		# first-person camera culls, and the point of two layers is to be on a
		# DIFFERENT one depending on whether the owner should see this rig.
		#
		# [b]Setting both unconditionally defeats the whole mechanism[/b], which is
		# what this did: `owner_sees` arrived, was used for nothing but a ternary
		# whose branches were identical, and every rig stayed on layer 1 — so the
		# first-person camera drew its own player's body at point-blank range, and
		# the bottom third of the screen was the inside of the player's own head.
		# The cull mask, the layer constant and the third-person path were all
		# correct; only the one line that had to differ did not.
		visual.layers = (
			(1 | (1 << (LAYER_LOCAL_BODY - 1))) if owner_sees
			else (1 << (LAYER_LOCAL_BODY - 1))
		)

		# Unconditional, and not an oversight: a first-person player is culled out of
		# their own camera and their SHADOW is then the only cue for how tall they are
		# and where they are standing. Casting it is the reason this uses layers
		# rather than `visible`.
		if node is GeometryInstance3D:
			(node as GeometryInstance3D).cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	for child in node.get_children():
		_set_layers_recursive(child, owner_sees)


func describe() -> Dictionary:
	return {
		"avatar": str(avatar) if avatar != null else "-",
		"crouch": "%.2f" % _crouch,
		"owner_sees": "%s%s" % [
			"yes" if visible_to_owner else "no",
			"" if owner_sees_head else " (body only)",
		],
		"parts": body_mount.get_child_count() + head_mount.get_child_count()
			+ hat_mount.get_child_count() + (1 if person != null else 0),
		"person": person.describe() if person != null else {},
	}
