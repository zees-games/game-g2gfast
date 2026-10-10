extends Node3D

const G2GUnits := preload("g2g_units.gd")

## Base class for the maps this build ships.
##
## A map builds its geometry and its zones from the same constants, so a start line
## cannot drift from the block it sits on; the written-out JSON copy in `maps/` is what
## a DELIVERED map would ship, and the headless suite checks the two agree. See
## game-playground's docs/maps.md for the reasoning; it is the same here.
##
## Positions and sizes are in genre units throughout. Zone volumes are converted to
## metres where they are built, because the timer works in whatever the movement
## works in — and the movement works in metres.

## Where players appear if the map has no spawn zone, in units.
@export var fallback_spawn_units: Vector3 = Vector3(0.0, 8.0, 0.0)

## Tier, 1..10, for the ranking points.
@export_range(1, 10, 1) var tier: int = 1


## A line of bodies a player is meant to jump along, in order, and which reach it is
## meant to be jumped with. See [G2GReach] for the two, and [method add_course].
class Course:
	extends RefCounted

	var name: String = ""
	var track: int = 0
	var kind: int = 0
	var bodies: Array = []


## Every course this map asks a player to jump, as [method _build] declared them.
##
## [b]Always appended through [method add_course], never written by hand.[/b] Filled by
## [method _build], so it describes the geometry that was actually built.
var courses: Array[Course] = []


## Declares that [param bodies] are jumped in order on [param track], with the reach
## [param kind] ([code]G2GReach.Kind.RUN[/code] or [code].CHAIN[/code]).
##
## [b]The only hand-written part is which bodies are a route and which reach it is
## sized for.[/b] The rise, the gap and the landing room are read off the bodies'
## transforms and shapes by [G2GReach], so moving a block moves the route and
## `headless_run` re-decides it — game-arena's `climbs` pattern, for a genre with two
## reaches rather than one. A map is content and content does not assert; the question
## is asked in the suite, where failing is useful.
func add_course(of_name: String, track: int, kind: int, bodies: Array) -> Course:
	var course := Course.new()
	course.name = of_name
	course.track = track
	course.kind = kind
	course.bodies = bodies.duplicate()
	courses.append(course)
	return course


func _ready() -> void:
	_build()


func _build() -> void:
	pass


func timer_zones() -> DotTimerZoneSet:
	return null


func spawn_for(track: int) -> Vector3:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
		if spawn != null:
			return spawn.destination

	return G2GUnits.vector_to_metres(fallback_spawn_units)


func spawn_yaw_for(track: int) -> float:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
		if spawn != null:
			return spawn.destination_yaw

	return 0.0


## A zone box from two corners in genre units.
static func zone_box(
	kind: DotTimerZone.Kind, track: int, a: Vector3, b: Vector3
) -> DotTimerZone:
	return DotTimerZone.make(kind, track).set_box(
		G2GUnits.vector_to_metres(a), G2GUnits.vector_to_metres(b)
	)


## A stage line, numbered from 1, with the spot a `!s<n>` puts a player.
##
## [b]The destination is not optional on a staged map.[/b] `DotTimerManager.request_stage`
## resolves "go to stage 3" to a stage zone and hands the host that zone's
## [member DotTimerZone.destination]; a stage zone drawn with none resolves to
## [code]Vector3.ZERO[/code], which on any of these maps is a point in the sky above the
## start. Nothing errors — the request succeeds and the player is dropped out of the
## world — so the zone that has one and the zone that does not look identical
## everywhere except in play.
static func zone_stage(
	track: int, number: int, a: Vector3, b: Vector3, at: Vector3, yaw: float = 0.0
) -> DotTimerZone:
	var zone := zone_box(DotTimerZone.Kind.STAGE, track, a, b)
	zone.number = float(number)
	zone.destination = G2GUnits.vector_to_metres(at)
	zone.destination_yaw = yaw
	return zone


## A spawn point from a position in genre units.
static func zone_spawn(track: int, at: Vector3, yaw: float) -> DotTimerZone:
	var zone := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	zone.destination = G2GUnits.vector_to_metres(at)
	zone.destination_yaw = yaw
	return zone
