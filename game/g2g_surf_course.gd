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

## How far under the lowest goal a ride is given up on, genre units. The floor is measured from
## the goals alone, not under every pit slab as it once was: a line that fell to the water at
## the bottom of a stage and skimmed along it toward a door 450 units above scored as progress
## and filled the beam (surf_beginner stage 3). A door is only ever reached from above or level: nothing on these
## stages rises 256 units.
const BELOW_UNITS := 256.0

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
	course.below_margin = G2GUnits.to_metres(BELOW_UNITS)
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
	# The finish is a goal only of the last stage: from any other it is at the far end of the map,
	# and as a goal it dragged the floor down to its own height.
	if number == 0 or number >= total:
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
	course.guide = guide_from_cache(course.map_id, number, course.start)
	return course


## The guide polyline a stage's cache carries (genre units, Godot axes, in `"guide"`), from
## [param start] on, in metres; empty for a stage that runs straight.
##
## [b]Why it lives in the cache, not in code.[/b] Progress is distance along the start-to-goal
## line, so a stage that turns far from that line (a hairpin) scores its own correct ride as
## going backwards and the beam drops it. The points are a property of the ride the planner
## was given, so they are saved with its rides, and the pilot's veto, which scores futures with
## the same course, reads them back from the same place.
static func guide_from_cache(id: StringName, number: int, start: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var path := ProjectSettings.globalize_path(cache_path(id))
	if not FileAccess.file_exists(path):
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	var data: Dictionary = (parsed as Dictionary).get("stages", {}).get(str(number), {})
	var points: Array = data.get("guide", [])
	if points.size() < 1:
		return out
	out.append(start)
	for p: Array in points:
		out.append(G2GUnits.vector_to_metres(Vector3(float(p[0]), float(p[1]), float(p[2]))))
	return out


## Metres along the guide, measured on the floor plan only. The base class takes the nearest
## point of the polyline in three dimensions, which on a stage that doubles back lets a line
## that falls off the first ramp land nearer the last segment in height than the ramp it left in
## plan, and score as if it had ridden the whole stage (surf_beginner stage 3, 2.6 s: 80 against
## 21 for the line that stayed on the ramp). Drops are not progress, so height is left to the
## energy term.
func progress(p: Vector3) -> float:
	if guide.size() < 2:
		return super.progress(p)
	var flat := Vector3(p.x, 0.0, p.z)
	var best_d := INF
	var best := 0.0
	var along := 0.0
	for i in range(guide.size() - 1):
		var a := Vector3(guide[i].x, 0.0, guide[i].z)
		var b := Vector3(guide[i + 1].x, 0.0, guide[i + 1].z)
		var seg := b - a
		var length := seg.length()
		var t := clampf((flat - a).dot(seg) / maxf(length * length, 0.0001), 0.0, 1.0)
		var d := flat.distance_squared_to(a + seg * t)
		if d < best_d:
			best_d = d
			best = along + t * length
		along += length
	return best


## The door nearest the start is what the straight line aims at: a stage's own exit, not the
## finish at the far end of the map. The next stage's zone is only the room a door lands in, so
## it is aimed at only when no door leads on (the last stage's finish): on surf_beginner stage 2
## the room is 230 units above the start and 2,200 away, the door that sends you there is 1,000
## units below it and 1,700 away in another direction. The floor is [constant BELOW_UNITS] under
## the lowest goal.
func settle_zones() -> void:
	var best := INF
	# The start counts too: a stage that climbs to its goal starts below the goals, and a floor
	# measured from them alone sits above the start and puts the bot back every tick.
	var lowest := start.y
	var has_door := goal_zones.any(func(z: DotTimerZone) -> bool: return z.kind == DotTimerZone.Kind.TELEPORT)
	for goal: DotTimerZone in goal_zones:
		var d := goal.centre().distance_to(start)
		if d < best and (goal.kind == DotTimerZone.Kind.TELEPORT or not has_door):
			best = d
			goal_centre = goal.centre()
		lowest = minf(lowest, minf(goal.from.y, goal.to.y))
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
