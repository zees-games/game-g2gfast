extends Node3D

## What an administrator's `beacon` looks like: a ring on the floor under a runner that
## sends out a ripple once a second, and a thin column above them that shows through walls.
##
## [b]Drawn on every client, from one replicated flag.[/b] The server decides who is
## beaconed (`G2GPlayer.beacon`, carried as `G2GPlayerNet.net_beacon`) and nothing about
## the picture travels: the ripple's phase is each client's own, because two screens a
## quarter of a second apart in a ripple is not something anybody can see, and sending a
## phase would be a message a second per beaconed runner for nothing.
##
## [b]Through walls, on purpose.[/b] A beacon exists so that everybody can find somebody —
## the runner an admin wants the server to watch, the one hiding in a corner of a surf map
## instead of running it — and a marker the map can hide is a marker that fails in exactly
## the spot it is used for. So the column is drawn with no depth test. The ring is not: it
## is on the floor, and on a bhop map whose blocks are stacked a ring showing through the
## block below would put the runner on a platform they are not on.
##
## [b]No column on your own beacon.[/b] A first-person camera stands inside it, and a
## no-depth-test cylinder seen from inside is a translucent smear over the whole screen —
## on a timer server, over a run. The beaconed runner still sees the ring at their feet and
## hears the ping, which is how they know.
##
## Top level, so it is placed where the runner is DRAWN rather than inheriting the body's
## per-tick transform: the local player's body steps at the tick rate and is drawn between
## ticks (docs/netcode.md, "The client draws between ticks"), and a ring that stepped under a smoothly moving camera would judder.
##
## Sized to this game's hull rather than copied from game-arena's: a runner here is 32
## units across, 0.61 m, and a ring as wide as the arena's would read as a mark on the
## floor beside them rather than under them.

## Seconds between ripples, and between pings.
const PERIOD_SEC := 1.0

## How far a ripple spreads before it has faded, as a multiple of the ring.
const RIPPLE_SCALE := 3.5

## Red-orange: the colour none of the prototype textures is, so it reads as a mark rather
## than as part of the course on any of the maps.
const COLOUR := Color(1.0, 0.28, 0.18)

const COLUMN_HEIGHT := 14.0

## Where the column starts: above a standing runner's head (72 units, 1.37 m), so it
## never draws across the body it is marking.
const COLUMN_BASE := 1.7

## Whether this is the beaconed player's own view. Hides the column; see above.
var local_view: bool = false:
	set(value):
		local_view = value
		if _column != null:
			_column.visible = not value

var _ring: MeshInstance3D = null
var _ripple: MeshInstance3D = null
var _column: MeshInstance3D = null
var _ripple_material: StandardMaterial3D = null
var _ring_material: StandardMaterial3D = null

## Seconds into the current period. Starts at the end of one, so the first advance pings:
## an admin who turns a beacon on should hear it start, not a second later.
var _phase: float = PERIOD_SEC


func _init() -> void:
	top_level = true

	_ring_material = _material(0.95, false)
	_ring = _torus(0.44, 0.56, _ring_material)
	_ring.name = "Ring"
	add_child(_ring)

	_ripple_material = _material(0.8, false)
	_ripple = _torus(0.47, 0.53, _ripple_material)
	_ripple.name = "Ripple"
	add_child(_ripple)

	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.06
	cylinder.bottom_radius = 0.06
	cylinder.height = COLUMN_HEIGHT
	cylinder.radial_segments = 8
	cylinder.rings = 1
	_column = MeshInstance3D.new()
	_column.name = "Column"
	_column.mesh = cylinder
	_column.material_override = _material(0.45, true)
	_column.position = Vector3(0.0, COLUMN_HEIGHT * 0.5 + COLUMN_BASE, 0.0)
	_column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_column.visible = not local_view
	add_child(_column)


## Moves the time on by [param delta] and redraws. Returns true when a new ripple starts,
## which is when the caller plays the ping.
func advance(delta: float) -> bool:
	_phase += maxf(delta, 0.0)
	var pinged := false

	if _phase >= PERIOD_SEC:
		_phase = fmod(_phase, PERIOD_SEC)
		pinged = true

	var t := _phase / PERIOD_SEC
	var spread := lerpf(1.0, RIPPLE_SCALE, t)
	_ripple.scale = Vector3(spread, 0.25, spread)
	_ripple_material.albedo_color.a = 0.8 * (1.0 - t) * (1.0 - t)

	# The ring itself breathes with the ripple rather than holding still, so a beacon seen
	# from across a surf map — a few pixels of ring — still reads as something alive.
	_ring_material.albedo_color.a = lerpf(0.95, 0.55, t)

	return pinged


## The fraction of a period the ripple is through, for a check.
func phase() -> float:
	return _phase / PERIOD_SEC


## Whether the column is drawn, for a check.
func column_shown() -> bool:
	return _column != null and _column.visible


func _torus(inner: float, outer: float, material: StandardMaterial3D) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner
	torus.outer_radius = outer
	torus.rings = 48
	torus.ring_segments = 8
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flattened to a band on the floor. A torus's tube is round, and a round tube at a
	# runner's feet reads as a lifebuoy rather than a mark.
	mesh.scale = Vector3(1.0, 0.25, 1.0)
	mesh.position = Vector3(0.0, 0.04, 0.0)
	return mesh


func _material(alpha: float, through_walls: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(COLOUR.r, COLOUR.g, COLOUR.b, alpha)
	material.no_depth_test = through_walls
	return material
