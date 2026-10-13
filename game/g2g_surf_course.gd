extends RefCounted

## One stage of a map as a surf bot sees it: where it starts, what counts as arriving,
## what counts as falling, and how far along a position is.
##
## [b]Read from the timer's zones, never written per map.[/b] The start is the stage
## zone's own destination and yaw (what `!s<n>` does to a player); the goal is the next
## stage's zone, the finish, and every door whose destination lies in one of them (on a
## staged surf map the way out of a stage is a teleport, and the player is sent into the
## next stage's zone by it); a pit is every RESPAWN and SLAY zone and every other door.
## A door that does not lead on is a pit for the bot even when it is a shortcut, because
## nothing here can tell a shortcut from a way back.
##
## [b]Progress is distance along the line from the start to the goal, plus energy.[/b]
## On the ramp the bot cannot see the goal's direction in its options -- every action
## goes roughly the same way -- and what separates a good state from a doomed one is how
## much height and speed it still has. Energy is height plus v²/2g, in metres: a ride
## converts one into the other without changing it, a scrub or a clip loses it, and an
## air strafe adds it. A stage whose line bends far from the straight one (a 180-degree
## turn) needs a guide polyline here; the straight line is enough for every stage
## measured so far, which is one.

const G2GSurfSim := preload("g2g_surf_sim.gd")
const G2GUnits := preload("g2g_units.gd")

## How much one metre of energy is worth against one metre of progress.
const ENERGY_WEIGHT := 0.5
## How far under the lowest goal or pit floor a player is past saving (units).
const BELOW_MARGIN_UNITS := 1024.0

var map_id: StringName = &""
var stage := 1
var start := Vector3.ZERO
var start_yaw := 0.0
var goal_centre := Vector3.ZERO
var goals: Array[DotTimerZone] = []
var pits: Array[DotTimerZone] = []
var floor_y := -INF
var gravity := 15.24
var _dir := Vector3.FORWARD


## The course for stage [param number] of the main track of the map [param game] has
## loaded (0 is the whole run, from the spawn to the finish). Null, with the reason in
## [param why], when the map has no such stage.
static func for_stage(game: Node, number: int, why: Array = []) -> RefCounted:
	var zones: DotTimerZoneSet = game.timers.zones
	var track := DotTimerTrack.MAIN
	var total := zones.stage_count(track)
	var course: RefCounted = (load("res://game/g2g_surf_course.gd") as GDScript).new()
	course.map_id = game.maps.current.id
	course.stage = number
	var map: Node = game.current_map_node()
	if number == 0:
		course.start = map.spawn_for(track)
		course.start_yaw = map.spawn_yaw_for(track)
	else:
		var from := zones.stage_zone(track, number)
		if from == null:
			why.append("no stage %d on main (it has %d)" % [number, total])
			return null
		course.start = from.destination
		course.start_yaw = from.destination_yaw
	if number > 0 and number < total:
		course.goals.append(zones.stage_zone(track, number + 1))
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.END, track):
		course.goals.append(zone)
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.TELEPORT):
		var leads_on := false
		for goal: DotTimerZone in course.goals.duplicate():
			if goal.contains(zone.destination):
				leads_on = true
		if leads_on:
			course.goals.append(zone)
		else:
			course.pits.append(zone)
	for kind: DotTimerZone.Kind in [DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY]:
		for zone: DotTimerZone in zones.of_kind(kind):
			course.pits.append(zone)
	if course.goals.is_empty():
		why.append("stage %d has nowhere to arrive" % number)
		return null
	course._settle()
	return course


func _settle() -> void:
	# The door (or line) nearest the start is the one the straight line aims at: a stage's
	# own exit, not the finish at the far end of the map.
	var best := INF
	var lowest := INF
	for goal: DotTimerZone in goals:
		var d := goal.centre().distance_to(start)
		if d < best:
			best = d
			goal_centre = goal.centre()
		lowest = minf(lowest, minf(goal.from.y, goal.to.y))
	for pit: DotTimerZone in pits:
		if pit.kind != DotTimerZone.Kind.TELEPORT:
			lowest = minf(lowest, minf(pit.from.y, pit.to.y))
	floor_y = lowest - G2GUnits.to_metres(BELOW_MARGIN_UNITS)
	var flat := Vector3(goal_centre.x - start.x, 0.0, goal_centre.z - start.z)
	_dir = flat.normalized() if flat.length() > 0.01 else DotFpsMotor.forward_for(start_yaw)


## What [param position] is: in a goal, in a pit, below the course, or none of those.
func event_at(position: Vector3) -> G2GSurfSim.Event:
	if position.y < floor_y:
		return G2GSurfSim.Event.BELOW
	for goal: DotTimerZone in goals:
		if goal.contains(position):
			return G2GSurfSim.Event.GOAL
	for pit: DotTimerZone in pits:
		if pit.contains(position):
			return G2GSurfSim.Event.PIT
	return G2GSurfSim.Event.NONE


## How far along [param state] is, in metres of progress plus weighted energy.
func score(state: DotFpsState) -> float:
	var along := (state.position - start).dot(_dir)
	var energy := state.position.y + state.velocity.length_squared() / (2.0 * gravity)
	return along + ENERGY_WEIGHT * energy


## The yaw from the start toward the goal: what "forward" is before there is a velocity.
func reference_yaw() -> float:
	return rad_to_deg(atan2(-_dir.x, -_dir.z))


## The path a course's cache is saved at.
static func cache_path(id: StringName) -> String:
	return "res://maps/routes/%s.surf.json" % id
