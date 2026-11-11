extends RefCounted

const G2GUnits := preload("g2g_units.gd")

## How far the movement carries a player, asked of the tunables a player actually runs
## with — and every jump a hand-written map asks for, measured against it.
##
## [b]Two reaches, because this genre has two and a gap is sized for one of them.[/b]
##
## [b]RUN[/b] is a jump taken at the lip from the ground at run speed. Ground
## acceleration puts a player back at [code]max_speed[/code] in about thirty units, so a
## player who lands anywhere on a block can always run to its edge and take this jump,
## however badly the last one went. It is what a player who cannot chain has, and what
## `headless_run`'s needle bot does. Under the shipped cvars it clears 189 units flat.
##
## [b]CHAIN[/b] is a hop inside a run of auto-hops at course speed, and it is a different
## quantity rather than a longer one. A chained hop takes off wherever the last one
## LANDED, not at the lip — with the key held there is no grounded tick to walk to the
## edge on — so across a line of blocks the hops have to average one whole block period
## (the gap plus the block), and a hop that falls short of the period spends the run-out
## the last landing left. Carrying speed is what makes a period possible, and strafing is
## the only thing that makes speed; so whether a chain is inside reach is a question
## about how much a player can gain in the air, which [method hop] answers from the
## tunables' own air cap.
##
## [b]A CHAIN verdict is an upper bound, deliberately.[/b] [method hop] assumes a PERFECT
## strafe every tick, which no person manages, so a chain it refuses is one nobody can
## run, and a chain it accepts is only possible. How much of a perfect strafe a chain
## needs ([method strafe_needed]) is the number that says how HARD it is, and it is
## printed rather than asserted: the suite fails on impossible, and a person reads the
## rest.
##
## [b]No hull credit anywhere.[/b] The capsule can stand with its centre a little past a
## lip, and on this game's 45.57° slope limit that is about eleven units a side. None of
## that is spent here — every distance is the player's centre from lip to lip — so it is
## the margin, rather than a factor somebody picked.
##
## Everything here is in genre units, read out of [DotFpsTunables] through [G2GUnits]:
## the jump, the gravity, the run speed, the air cap and the landing cap are the server's
## own, so `sv_gravity 600` or `sv_enablebunnyhopping 0` changes every answer below with
## no second copy of any number to update. That is the difference from the two games
## that asked this before (`[reach-1]`), which carry their three constants beside the
## maps with a check that they agree.
##
## [b]The arithmetic is [DotFpsTunables]' own[/b] (`[reach-3]`): the apex, the climb
## limit, the airtime and the reach of a jump landing higher or lower than it left are
## [method DotFpsTunables.jump_apex], [method DotFpsTunables.climb_limit],
## [method DotFpsTunables.jump_airtime] and [method DotFpsTunables.jump_reach], asked in
## metres and converted at the edge by [G2GUnits]. What stays here is the genre's: the
## CHAIN — [method hop] and everything built on it — which the addon has no notion of.

enum Kind { RUN, CHAIN }

## How much of the apex a climb may use: `DotFpsTunables.CLIMB_MARGIN`, which says why
## nine tenths. None of this game's rises comes near it.
const CLIMB_MARGIN := DotFpsTunables.CLIMB_MARGIN


## The apex of a standing jump, in units. The number every bhop player knows as 57.
static func apex(t: DotFpsTunables) -> float:
	return G2GUnits.to_units(t.jump_apex())


## The highest rise a jump is asked to make. Above this a block is a wall.
static func climb_limit(t: DotFpsTunables) -> float:
	return G2GUnits.to_units(t.climb_limit())


## A rise at or under this is walked, not jumped.
static func step(t: DotFpsTunables) -> float:
	return G2GUnits.to_units(t.step_height)


## Seconds from take-off to landing [param rise] units higher, or -1.0 if no jump
## reaches that high at all.
##
## [b]The landing height is the point.[/b] The airtime everybody writes down is the time
## to come back to the height you left, and it is the wrong number for a climb or a drop:
## 0.755 s flat, 0.665 s onto a 24-unit step, 0.889 s down 48.
static func airtime(rise: float, t: DotFpsTunables) -> float:
	return t.jump_airtime(G2GUnits.to_metres(rise))


## Run speed, in u/s.
static func run_speed(t: DotFpsTunables) -> float:
	return G2GUnits.to_units(t.max_speed)


## The clear air a RUN jump crosses, landing [param rise] units higher. 0 if unreachable.
static func run_reach(rise: float, t: DotFpsTunables) -> float:
	return G2GUnits.to_units(t.jump_reach(G2GUnits.to_metres(rise)))


## The most speed one airborne tick can add, in u/s: [code]sv_maxairwishspeed[/code],
## unless the air acceleration is too low to deliver even that in one tick.
##
## [b]Why the cap and not the acceleration.[/b] Air acceleration adds along the wish
## direction up to the CAP measured against the current velocity's projection on it —
## so the most a tick adds to the speed is a cap's worth at right angles, and speed
## grows as [code]v² + cap²[/code] per tick. That is the whole of air-strafing, and the
## number is `DotFpsMotor.accelerate`'s, not a guess at a player's skill.
static func strafe_gain(t: DotFpsTunables, tick_rate: int) -> float:
	var cap := G2GUnits.to_units(t.max_air_wish_speed)
	var step_per_tick := t.air_accelerate * run_speed(t) / float(maxi(tick_rate, 1))
	return minf(cap, step_per_tick)


## One hop from [param speed]: how far it goes and how fast the player lands, as
## [code]Vector2(distance, landing speed)[/code].
##
## [param strafe] is the fraction of a perfect strafe spent: 1.0 is the ceiling, 0.0 is
## a held key with no strafe at all, which is exactly what a scripted bot does.
##
## [code]sv_enablebunnyhopping 0[/code] is honoured, because it is the cvar that decides
## whether a chain exists: the landing cap trims the take-off speed to
## [code]bhop_speed_cap_scale × max_speed[/code] before every hop, and the air can only
## add back what one hop's worth of strafing adds.
static func hop(
	speed: float, rise: float, t: DotFpsTunables, tick_rate: int, strafe: float = 1.0
) -> Vector2:
	var time := airtime(rise, t)

	if time <= 0.0:
		return Vector2(0.0, speed)

	var v := speed

	if t.bhop_speed_cap_scale > 0.0:
		v = minf(v, run_speed(t) * t.bhop_speed_cap_scale)

	var ticks := maxi(int(ceil(time * float(tick_rate))), 1)
	var dt := time / float(ticks)
	var gain := strafe_gain(t, tick_rate) * clampf(strafe, 0.0, 1.0)
	var ceiling := G2GUnits.to_units(t.max_velocity)
	var distance := 0.0

	for _i in range(ticks):
		v = minf(sqrt(v * v + gain * gain), ceiling)
		distance += v * dt

	return Vector2(distance, v)


# --- Measuring a map --------------------------------------------------------

## One jump a map declares, measured off the two bodies it is between.
##
## [b]Read off the geometry, never written down.[/b] The map says only WHICH two bodies
## are a route — see `G2GMap.add_course` — and the rise, the gap and the landing depth
## come from their transforms and their box shapes. A table of expected numbers is a
## fourth description of the geometry, and it is stale the first time somebody moves a
## block; this cannot disagree with the map because it IS the map.
class Route:
	extends RefCounted

	var name: String = ""
	## Top face to top face, units. Negative is a drop.
	var rise: float = 0.0
	## The least clear air between the two footprints, units. Zero when they touch.
	##
	## The Euclidean distance between the footprints rather than the larger axis gap
	## game-fatal-contact uses: that is right for boxes that overlap on one axis, and short for
	## ones that do not — `bhop_g2g_stages`' zigzag is 80 units across AND the gap along,
	## and the player flies the diagonal.
	var gap: float = 0.0
	## How deep the landing body is along the direction of travel, units: the room a
	## chained hop has to land in and take off again from.
	var depth: float = 0.0
	## The landing body, so a stage restart can be matched to the route it starts from.
	var to_body: Node3D = null


## A body's top face and footprint, in units, or an empty dictionary if it is not a
## level box. A ramp is not a route and the question is refused rather than answered
## about the wrong face.
static func footprint(body: Node3D) -> Dictionary:
	var shape: BoxShape3D = null

	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			shape = (child as CollisionShape3D).shape
			break

	if shape == null:
		return {}

	var basis := body.transform.basis

	if not basis.y.normalized().is_equal_approx(Vector3.UP):
		return {}

	var half := shape.size * 0.5
	var centre := G2GUnits.vector_to_units(body.transform.origin)
	var corners := PackedVector2Array()

	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var local := basis * Vector3(half.x * corner.x, 0.0, half.z * corner.y)
		var at := G2GUnits.vector_to_units(local)
		corners.append(Vector2(centre.x + at.x, centre.z + at.z))

	return {
		"top": centre.y + G2GUnits.to_units(half.y),
		"corners": corners,
		"centre": Vector2(centre.x, centre.z),
	}


## The least distance between two convex footprints, 0 if they touch or overlap.
static func clear_air(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if not Geometry2D.intersect_polygons(a, b).is_empty():
		return 0.0

	var best := INF

	for pair in [[a, b], [b, a]]:
		var points: PackedVector2Array = pair[0]
		var edges: PackedVector2Array = pair[1]

		for p in points:
			for i in range(edges.size()):
				var q := Geometry2D.get_closest_point_to_segment(
					p, edges[i], edges[(i + 1) % edges.size()]
				)
				best = minf(best, p.distance_to(q))

	return best


## Every route between consecutive [param bodies]; a body that is not a level box is
## reported in [param refused] by index rather than measured.
static func measure(bodies: Array, refused: Array = []) -> Array[Route]:
	var out: Array[Route] = []

	for i in range(bodies.size() - 1):
		var from := footprint(bodies[i])
		var to := footprint(bodies[i + 1])

		if from.is_empty() or to.is_empty():
			refused.append(i if from.is_empty() else i + 1)
			continue

		var route := Route.new()
		route.name = "%d->%d" % [i, i + 1]
		route.rise = float(to["top"]) - float(from["top"])
		route.gap = clear_air(from["corners"], to["corners"])
		route.to_body = bodies[i + 1]

		var travel: Vector2 = (to["centre"] as Vector2) - (from["centre"] as Vector2)
		travel = travel.normalized() if travel.length() > 0.001 else Vector2(0.0, -1.0)
		var lo := INF
		var hi := -INF

		for c: Vector2 in to["corners"]:
			lo = minf(lo, c.dot(travel))
			hi = maxf(hi, c.dot(travel))

		route.depth = hi - lo
		out.append(route)

	return out


## Whether [param route] is walked rather than jumped: no gap, and a rise the step
## height takes. Those have no airborne phase to judge.
static func walked(route: Route, t: DotFpsTunables) -> bool:
	return route.gap <= 0.001 and route.rise <= step(t)


## Runs a chain of hops over [param routes] from [param from_index], starting at the lip
## at run speed, spending [param strafe] of a perfect strafe per tick.
##
## Returns [code]{"ok", "at", "short", "top"}[/code]: whether it got to the end, the
## index of the route it fell at, by how many units, and the fastest it went.
##
## [b]Greedy, and greedy is optimal here.[/b] Each landing is taken as far onto the next
## block as the hop allows, because a player with a longer hop than they need can always
## make it shorter by strafing wider, and landing further on leaves less run-out to
## spend next time. So if this falls, every other way of flying the same hops falls too.
static func chain(
	routes: Array, t: DotFpsTunables, tick_rate: int, strafe: float, from_index: int = 0
) -> Dictionary:
	var speed := run_speed(t)
	var run_out := 0.0
	var top := speed

	for i in range(from_index, routes.size()):
		var route: Route = routes[i]
		var flight := hop(speed, route.rise, t, tick_rate, strafe)
		var needed := run_out + route.gap

		if flight.x < needed:
			return {"ok": false, "at": i, "short": needed - flight.x, "top": top}

		var landed := minf(flight.x - needed, route.depth)
		run_out = route.depth - landed
		speed = flight.y
		top = maxf(top, speed)

	return {"ok": true, "at": -1, "short": 0.0, "top": top}


## The least fraction of a perfect strafe that carries a chain from [param from_index]
## to its end: 0.0 means a held key with no strafe at all does it, and a value over 1.0
## (returned as 2.0) means nobody can.
static func strafe_needed(
	routes: Array, t: DotFpsTunables, tick_rate: int, from_index: int = 0
) -> float:
	if bool(chain(routes, t, tick_rate, 0.0, from_index)["ok"]):
		return 0.0

	if not bool(chain(routes, t, tick_rate, 1.0, from_index)["ok"]):
		return 2.0

	var lo := 0.0
	var hi := 1.0

	for _i in range(16):
		var mid := (lo + hi) * 0.5

		if bool(chain(routes, t, tick_rate, mid, from_index)["ok"]):
			hi = mid
		else:
			lo = mid

	return hi
