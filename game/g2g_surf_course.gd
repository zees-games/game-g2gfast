extends DotBotSurfCourse

## One stage of a map as a surf bot sees it, read from the timer's zones: the adapter between
## this game and dot-bot's surf planner and pilot ([DotBotSurfPlanner], [DotBotSurfPilot]).
##
## [b]Read from the timer's zones, never written per map.[/b] The start is the stage zone's own
## destination and yaw (what `!s<n>` does to a player); the goal is the next stage's zone, the
## finish, and every door whose destination lies in one of them (on a staged surf map the way out
## of a stage is a teleport, and the player is sent into the next stage's zone by it); a pit is
## every RESPAWN and SLAY zone and every other door. A door that does not lead on is a pit for the
## bot even when it is a shortcut, because nothing here can tell a shortcut from a way back.
##
## Progress and energy are dot-bot's ([method DotBotSurfCourse.score]). The simulator is
## dot-player-controller's ([DotFpsSimulator]); what this game runs beside the motor (the map's
## pushes, gravity volumes and lethal hurt, [G2GMapMechanics]) is its [code]mechanics[/code]
## hook, on a rider of the simulation's own ([method simulator_for]). The volume modes (water,
## ladders) come with the motor's registered modes. The rider memory of pushes and sinking
## blocks is not branched with the state; nothing on a planned stage uses it.

const G2GMapMechanics := preload("g2g_map_mechanics.gd")
const G2GPaths := preload("g2g_paths.gd")
const G2GUnits := preload("g2g_units.gd")

var map_id: StringName = &""
var stage := 1
var goal_zones: Array[DotTimerZone] = []
var pit_zones: Array[DotTimerZone] = []


## The course for stage [param number] of the main track of the map [param game] has loaded (0 is
## the whole run, from the spawn to the finish). Null, with the reason in [param why], when the
## map has no such stage.
static func for_stage(game: Node, number: int, why: Array = []) -> DotBotSurfCourse:
	var zones: DotTimerZoneSet = game.timers.zones
	var track := DotTimerTrack.MAIN
	var total := zones.stage_count(track)
	var course: DotBotSurfCourse = (load(G2GPaths.rebase("res://game/g2g_surf_course.gd")) as GDScript).new()
	course.map_id = game.maps.current.id
	course.stage = number
	course.gravity = G2GUnits.to_metres(800.0)
	course.below_margin = G2GUnits.to_metres(1024.0)
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
	var goals: Array[DotTimerZone] = []
	var pits: Array[DotTimerZone] = []
	if number > 0 and number < total:
		goals.append(zones.stage_zone(track, number + 1))
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.END, track):
		goals.append(zone)
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.TELEPORT):
		var leads_on := false
		for goal: DotTimerZone in goals.duplicate():
			if goal.contains(zone.destination):
				leads_on = true
		if leads_on:
			goals.append(zone)
		else:
			pits.append(zone)
	for kind: DotTimerZone.Kind in [DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY]:
		for zone: DotTimerZone in zones.of_kind(kind):
			pits.append(zone)
	if goals.is_empty():
		why.append("stage %d has nowhere to arrive" % number)
		return null
	course.goal_zones = goals
	course.pit_zones = pits
	course.settle_zones()
	return course


## The door (or line) nearest the start is the one the straight line aims at: a stage's own exit,
## not the finish at the far end of the map. The floor is under the lowest goal and every pit but
## a door.
func settle_zones() -> void:
	var best := INF
	var lowest := INF
	for goal: DotTimerZone in goal_zones:
		var d := goal.centre().distance_to(start)
		if d < best:
			best = d
			goal_centre = goal.centre()
		lowest = minf(lowest, minf(goal.from.y, goal.to.y))
	for pit: DotTimerZone in pit_zones:
		if pit.kind != DotTimerZone.Kind.TELEPORT:
			lowest = minf(lowest, minf(pit.from.y, pit.to.y))
	floor_y = lowest - below_margin
	var _settled := settle()


## What [param state] is in: in a goal zone, in a pit, below the course, or none of those.
func event_at(state: Variant) -> int:
	var position: Vector3 = state.position
	if position.y < floor_y:
		return EVENT_BELOW
	for goal: DotTimerZone in goal_zones:
		if goal.contains(position):
			return EVENT_GOAL
	for pit: DotTimerZone in pit_zones:
		if pit.contains(position):
			return EVENT_PIT
	return EVENT_NONE


## The simulator the planner and the pilot ride this course on: the player's own motor copied,
## the map's mechanics run after each tick on a rider of its own (a lethal hurt is a pit), and
## this course as the oracle.
func simulator_for(controller: DotFpsController, mechanics: G2GMapMechanics) -> DotFpsSimulator:
	var sim := controller.simulator()
	if sim == null:
		return null
	if mechanics != null:
		var rider := G2GMapMechanics.Rider.new()
		sim.mechanics = func(state: DotFpsState, motor: DotFpsMotor, delta: float, _start: Vector3) -> int:
			return EVENT_PIT if mechanics.simulate(rider, motor, state, delta) == G2GMapMechanics.Event.HURT else EVENT_NONE
	sim.oracle = event_at
	return sim


## The path a course's cache is saved at.
static func cache_path(id: StringName) -> String:
	return "res://maps/routes/%s.surf.json" % id
