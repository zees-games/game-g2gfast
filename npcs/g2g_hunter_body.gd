extends CharacterBody3D

## A hunter's body: a capsule that walks and falls, drawn as a person on the zombie gait.
##
## [b]A [CharacterBody3D] here, where game-arena's monsters are plain [Node3D]s, and
## the difference is the two games' collision.[/b] Arena is analytic — its map is a
## list of boxes and there is no physics space on its server — so a monster there moves
## by writing a position. This game's players collide against Godot's physics, and a
## hunter that walked through the map its quarry cannot is not a hunter.
## [method DotNpcBrain.steer_toward] handles both and applies gravity to this one,
## which a [CharacterBody3D] does not have of its own.
##
## Extended by nothing and referenced by PATH. A `class_name` would reserve a global
## identifier in every consuming project for a capsule, and a script inside a mounted
## dot-cloud pack cannot resolve one anyway.

@export var body_radius: float = 0.4

@export var body_height: float = 1.7

@export var tint: Color = Color(0.75, 0.25, 0.30)

@export var visible_body: bool = true

## The drawn person, or null when the body is not drawn. Public for the suite.
var person: DotHumanoidFigure = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# The same layer players and geometry are on. A hunter on a layer of its own is a
	# hunter that walks through walls, and the symptom looks like broken navigation
	# rather than like a mask.
	collision_layer = 1
	collision_mask = 1
	floor_max_angle = deg_to_rad(50.0)

	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var capsule := CapsuleShape3D.new()
	capsule.radius = body_radius
	capsule.height = maxf(body_height, body_radius * 2.0 + 0.05)
	shape.shape = capsule
	shape.position = Vector3(0.0, body_height * 0.5, 0.0)
	add_child(shape)

	if not visible_body:
		return

	# A person on the zombie gait, in the hunter's tint: the walk shuffles, the run is a real
	# sprint, and it stands in the capsule the body collides as. It faces -Z, as the snout did.
	var look := DotHumanoidLook.make(&"sam", Color("8a9a6a"), Color("2a2420"), tint, tint.darkened(0.55))
	person = DotHumanoidFigure.new()
	person.name = "Person"
	person.zombie_gait = true
	person.auto_animate = true
	person.auto_smooth_time = 0.15
	add_child(person)
	person.build(look, body_height)
