extends RefCounted

## A bot that follows a route written down as data, and air-strafes to keep up with it.
##
## [b]Why a route and not a heading (`g2g-maps-1`).[/b] `stage_ride` heading straight for
## the finish finished none of eight imported maps: a bhop corridor turns, and a bot
## aimed through a wall stops at the wall. The line a map is run along is not in the BSP
## anywhere -- it is in the mapper's head and in every player's -- so it is written here,
## per map, in `maps/routes/<id>.json`: a list of points in the manifest's units and axes
## (Godot axes in genre units: x, up, z -- what every tool here prints), which the bot
## passes in order before it heads for the finish.
##
## [b]It strafes.[/b] The hand-built routes' bots hold forward and never gain, because a
## route that asked for a gain could not be driven (docs/routes.md, "How the bots drive"). An imported
## bhop map asks for one on every section, so this one strafes: in the air it looks along
## its own velocity and holds strafe toward the side its next point is on. With this
## game's `sv_airaccelerate` the whole of `sv_maxairwishspeed` is added every tick, and
## at right angles to the velocity that is the most any wish direction adds -- so the
## same input both gains and turns, which is what a player's mouse-and-strafe-key does.
## Pointed straight at its target it alternates sides each tick and gains without turning.
##
## On a face too steep to stand on it surfs the way `stage_ride` does -- along the face,
## strafing into it -- choosing the direction along the face that its next point is in.
##
## A point is `[x, up, z]` or `{"at": [x, up, z], ...}` with any of:
##   `"radius"`  units within which (flat) the point counts as passed (default 96)
##   `"max"`     a speed (u/s) above which the bot stops strafing until under it
##   `"walk"`    true: no jumping toward this point (a narrow ledge, a drop to walk off)
##   `"hop"`     true: jump on every landing toward this point (keep speed) instead of
##               only at a lip or a step too tall to walk, which is the default
##   `"land"`    false: the point is passed in the air too. By default a point counts
##               only once the bot is on the ground near or past it -- landed on it --
##               because a block flown over is not a block reached. A surf route sets
##               it false for the whole route at the top level.
##   `"door"`    true: a door (a TELEPORT zone) to walk into; passed when it teleports
##   `"note"`    why the point is there; ignored
## A point also counts as passed once the bot is beyond it along the leg it is on, so a
## point the bot flies past at speed is not chased back.

const G2GUnits := preload("g2g_units.gd")

const DEFAULT_RADIUS := 96.0
## A route without its own `max`: fast enough for any jump on these maps, slow enough
## that the next point is still turnable-to. 0 for no cap.
const DEFAULT_MAX := 0.0
## Flat speed (u/s) from which a jump is taken from the ground. A jump from a standstill
## creeps at the air cap for ever (headless_run's `_prestrafe`).
const JUMP_FROM := 230.0
## Inside this angle of the target the bot alternates strafe sides rather than turning.
const STRAIGHT_DEGREES := 2.0
const TRACE_UNITS := 160.0
## Wanting this much more speed (u/s) than it has, the bot strafes to gain rather than aims.
const GAIN_MARGIN := 20.0
## No landing is aimed faster than this (u/s); further than that, it is a long flight.
const MAX_AIM_SPEED := 3500.0
## The lip test: the ground looked for this far ahead (units, plus LEDGE_TICKS of travel)
## and up to LEDGE_DROP under the feet.
const LEDGE_LEAD := 6.0
const LEDGE_TICKS := 3.0
const LEDGE_DROP := 24.0
## The wall test: a ray at a step's height plus a little, this far ahead.
const STEP_PLUS := 22.0
const WALL_LOOK := 40.0
## No progress: the bot stayed within STUCK_RADIUS metres for STUCK_SECONDS (wedged on a wall the
## route does not know about), so it hops off the aimed line for UNSTICK_SECONDS, a new side each time.
const STUCK_SECONDS := 2.0
const STUCK_RADIUS := 1.0
const UNSTICK_SECONDS := 1.0
const UNSTICK_TURNS := [90.0, -90.0, 180.0, 45.0, -45.0, 135.0, -135.0]

## Each `{"at": Vector3 metres, "radius": metres, "max": u/s, "walk": bool}`.
var points: Array[Dictionary] = []
## The finish's centre in metres, aimed at once every point is passed.
var finish := Vector3.INF
var index := 0
var surfed := 0
var _side := 1.0
var _leg_from := Vector3.INF
var unstuck := 0
var _anchor := Vector3.INF
var _held := 0.0
var _unstick_left := 0.0
var _unstick_turn := 0.0


## The route file for [param id], or an empty array (no file, or unreadable -- said why
## in [param why]).
static func load_points(id: StringName, why: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := "res://maps/routes/%s.json" % id
	if not FileAccess.file_exists(path):
		why.append("no %s" % path)
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("points")) != TYPE_ARRAY:
		why.append("%s has no \"points\" list" % path)
		return out
	for raw: Variant in parsed["points"]:
		var p: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {"at": raw}
		var at: Array = p.get("at", [])
		if at.size() != 3:
			why.append("%s: a point without three coordinates" % path)
			return [] as Array[Dictionary]
		out.append({
			"at": G2GUnits.vector_to_metres(Vector3(float(at[0]), float(at[1]), float(at[2]))),
			"radius": G2GUnits.to_metres(float(p.get("radius", DEFAULT_RADIUS))),
			"max": float(p.get("max", parsed.get("max", DEFAULT_MAX))),
			"walk": bool(p.get("walk", false)),
			"hop": bool(p.get("hop", parsed.get("hop", false))),
			"land": bool(p.get("land", parsed.get("land", true))),
			"door": bool(p.get("door", false)),
		})
	return out


func _init(route: Array[Dictionary] = [], finish_centre: Vector3 = Vector3.INF) -> void:
	points = route
	finish = finish_centre


## Start over from the first point (after a pit put the player back at the start).
func restart() -> void:
	index = 0
	_leg_from = Vector3.INF
	_anchor = Vector3.INF
	_unstick_left = 0.0


## A door moved the player: the door point it was walking into is passed.
func teleported() -> void:
	if index < points.size() and bool(points[index]["door"]):
		index += 1
	_leg_from = Vector3.INF


## The point aimed at now, in metres.
func target() -> Vector3:
	return points[index]["at"] if index < points.size() else finish


## This tick's command for a player in [param state], in [param space].
func command(state: DotFpsState, space: PhysicsDirectSpaceState3D, tunables: DotFpsTunables, delta: float) -> DotFpsCommand:
	var max_slope := tunables.max_slope_angle
	var at := state.position
	if _leg_from == Vector3.INF:
		_leg_from = at
	_advance(at, state.is_grounded())
	var goal := target()
	if _watch_progress(at, delta):
		return _unstick(state, goal)
	var point: Dictionary = points[index] if index < points.size() else {}
	var to := Vector3(goal.x - at.x, 0.0, goal.z - at.z)
	var goal_yaw := rad_to_deg(atan2(-to.x, -to.z))
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := G2GUnits.to_units(flat.length())
	var cap: float = point.get("max", DEFAULT_MAX)
	var hop: bool = point.get("hop", false)

	var c := DotFpsCommand.new()
	var ramp := ramp_under(space, at, flat, max_slope)
	if ramp != Vector3.ZERO:
		var inward := Vector3(-ramp.x, 0.0, -ramp.z).normalized()
		var along := Vector3(inward.z, 0.0, -inward.x)
		var going := to if to.length() > 0.01 else flat
		if along.dot(going) < 0.0:
			along = -along
		c.yaw = rad_to_deg(atan2(-along.x, -along.z))
		var right := Vector3(cos(deg_to_rad(c.yaw)), 0.0, -sin(deg_to_rad(c.yaw)))
		c.move = Vector2(signf(right.dot(inward)), 0.0)
		surfed += 1
	elif state.is_grounded():
		c.yaw = goal_yaw
		c.move = Vector2(0.0, 1.0)
		var jump := false
		if not bool(point.get("walk", false)):
			var dir := flat.normalized() if speed > 30.0 else to.normalized()
			jump = (hop and speed > JUMP_FROM) or ledge_ahead(space, at, dir, speed) or wall_ahead(space, at, dir)
		c.set_button(DotFpsCommand.BUTTON_JUMP, jump)
	else:
		c = _air(state, goal, flat, cap, tunables, delta)
	return c


## Whether the bot is off the line to hop free right now; counts how long it has gone nowhere.
func _watch_progress(at: Vector3, delta: float) -> bool:
	if _unstick_left > 0.0:
		_unstick_left -= delta
		_anchor = at
		_held = 0.0
		return _unstick_left > 0.0
	if _anchor == Vector3.INF or Vector2(at.x - _anchor.x, at.z - _anchor.z).length() > STUCK_RADIUS \
			or absf(at.y - _anchor.y) > 2.0 * STUCK_RADIUS:
		_anchor = at
		_held = 0.0
		return false
	_held += delta
	if _held < STUCK_SECONDS:
		return false
	_held = 0.0
	_unstick_left = UNSTICK_SECONDS
	_unstick_turn = UNSTICK_TURNS[unstuck % UNSTICK_TURNS.size()]
	unstuck += 1
	return true


## Forward and jumping, turned [member _unstick_turn] degrees off the goal.
func _unstick(state: DotFpsState, goal: Vector3) -> DotFpsCommand:
	var at := state.position
	var c := DotFpsCommand.new()
	c.yaw = rad_to_deg(atan2(-(goal.x - at.x), -(goal.z - at.z))) + _unstick_turn
	c.move = Vector2(0.0, 1.0)
	if not state.is_grounded() and (unstuck / 2) % 2 == 0:
		# Forward alone gains nothing in the air: every other pair of attempts strafes to build speed off the spot.
		_side = -_side
		c.move = Vector2(_side, 1.0)
	c.set_button(DotFpsCommand.BUTTON_JUMP, state.is_grounded())
	return c


## In the air, aim the landing: the horizontal velocity that brings the player down
## onto [param goal]'s height over [param goal] is what to have, and the wish is spent
## turning the velocity into it. Under this game's `sv_airaccelerate` a wish can change
## the velocity by almost anything in a tick -- so the bot can brake in the air as well
## as gain, which is what makes a 64-unit block reachable at speed. Too slow for the
## landing it wants, it strafes at right angles to its velocity (the most any wish adds)
## toward the target's side, which gains and turns at once.
func _air(state: DotFpsState, goal: Vector3, flat: Vector3, cap: float,
		tunables: DotFpsTunables, delta: float) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	var at := state.position
	var to := Vector3(goal.x - at.x, 0.0, goal.z - at.z)
	var g := tunables.gravity
	var vy := state.velocity.y
	var drop := goal.y - at.y
	var disc := vy * vy - 2.0 * g * drop
	# Time until the feet are back at the goal's height; past the apex already and still
	# under it, there is no landing on it this flight, so go as fast as allowed.
	var t := (vy + sqrt(disc)) / g if disc >= 0.0 else 0.0
	var want_speed := to.length() / t if t > delta else INF
	if cap > 0.0:
		want_speed = minf(want_speed, G2GUnits.to_metres(cap))
	var speed := flat.length()
	var goal_yaw := rad_to_deg(atan2(-to.x, -to.z))
	var heading := rad_to_deg(atan2(-flat.x, -flat.z)) if speed > 0.5 else goal_yaw
	var off := wrapf(goal_yaw - heading, -180.0, 180.0)

	if want_speed > speed + G2GUnits.to_metres(GAIN_MARGIN) and absf(off) < 90.0:
		c.yaw = heading
		if absf(off) < STRAIGHT_DEGREES:
			_side = -_side
		else:
			_side = -1.0 if off > 0.0 else 1.0  # +yaw is a left turn; strafe left is -1
		c.move = Vector2(_side, 0.0)
		return c

	# The velocity wanted, and the wish that turns this one into it in one tick where
	# the air cap allows: the step is `air_accelerate * wish * delta` and the target is
	# the cap, so the move's magnitude chooses whichever of the two binds.
	var want := to.normalized() * minf(want_speed, G2GUnits.to_metres(MAX_AIM_SPEED)) if to.length() > 0.01 else Vector3.ZERO
	var change := want - flat
	var need := change.length()
	if need < 0.01:
		return c
	var w := change / need
	var run := tunables.max_speed
	var along := flat.dot(w)
	var per_unit := tunables.air_accelerate * run * delta
	var m := 1.0
	if need + along <= tunables.max_air_wish_speed:
		m = clampf(maxf(need / per_unit, (need + along) / run), 0.0, 1.0)
	c.yaw = rad_to_deg(atan2(-w.x, -w.z))
	c.move = Vector2(0.0, m)
	return c


func _advance(at: Vector3, grounded: bool) -> void:
	while index < points.size():
		var p: Vector3 = points[index]["at"]
		var flat := Vector2(at.x - p.x, at.z - p.z)
		var leg := Vector2(p.x - _leg_from.x, p.z - _leg_from.z)
		var near := flat.length() < float(points[index]["radius"])
		var beyond := leg.length() > 0.01 and flat.dot(leg) > 0.0
		if not (near or beyond):
			return
		# A block is passed by landing on it. Flying over one and aiming at the next
		# from the air commits the bot to a jump it never took off for.
		if bool(points[index]["land"]) and not grounded:
			return
		if bool(points[index]["door"]):
			return  # passed by the teleport, never by standing near it
		_leg_from = p
		index += 1


## No ground under the point the player is about to move over: a lip, so jump now.
## A chained hop takes off wherever the last one landed (docs/routes.md, "How the bots drive"), so the
## default jumps AT gaps, from the last ground before them.
static func ledge_ahead(space: PhysicsDirectSpaceState3D, position: Vector3, dir: Vector3, speed: float) -> bool:
	var ahead := G2GUnits.to_metres(LEDGE_LEAD + speed * LEDGE_TICKS / 128.0)
	var from := position + dir * ahead + Vector3.UP * G2GUnits.to_metres(8.0)
	var to := from + Vector3.DOWN * G2GUnits.to_metres(8.0 + LEDGE_DROP)
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to)).is_empty()


## Something too tall to walk up just ahead of the player's knees: jump onto it.
static func wall_ahead(space: PhysicsDirectSpaceState3D, position: Vector3, dir: Vector3) -> bool:
	var from := position + Vector3.UP * G2GUnits.to_metres(STEP_PLUS)
	var to := from + dir * G2GUnits.to_metres(WALL_LOOK)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	return not hit.is_empty() and absf((hit["normal"] as Vector3).y) < 0.7


## The normal of a surf face under or beside a player at [param feet], or ZERO.
static func ramp_under(space: PhysicsDirectSpaceState3D, position: Vector3, flat: Vector3, limit: float) -> Vector3:
	var feet := position + Vector3.UP * G2GUnits.to_metres(8.0)
	var ahead := flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
	var side := Vector3(-ahead.z, 0.0, ahead.x)
	var reach := G2GUnits.to_metres(TRACE_UNITS)
	for dir: Vector3 in [Vector3.DOWN, (Vector3.DOWN + side).normalized(), (Vector3.DOWN - side).normalized()]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(feet, feet + dir * reach))
		if hit.is_empty():
			continue
		var angle := rad_to_deg((hit["normal"] as Vector3).angle_to(Vector3.UP))
		if angle > limit and angle < 85.0:
			return hit["normal"]
	return Vector3.ZERO
