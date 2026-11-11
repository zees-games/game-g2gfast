extends RefCounted

## The solids, state and plane geometry of G2GMapSurvey.

const G2GUnits := preload("g2g_units.gd")
const G2GReach := preload("g2g_reach.gd")

## A slot and reach sweep over a hand-built map's boxes (`[gate-sweep-1]`,
## `[gate-sweep-2]`): where two solids leave a crack narrower than a player, what a player
## can stand on, what they can get to from a spawn or a `!s<n>`, and what they cannot get
## back out of.
##
## [b]Why a map needs this when its routes are already driven and measured.[/b]
## `headless_run` asks about the bodies a course NAMES. Nothing asked about the ones it
## does not: the top of a back wall, the floor a player who misses a ramp lands on, a
## crack between a ramp and a pad. Every one of those is found by a player on a live
## server, reported as "stuck", and fixed with a `!r`. This asks the geometry instead.
##
## [b]Everything is in genre units[/b], read off the same [DotFpsTunables] the server
## applies: the hull is [code]2 × radius[/code] (32 u, the genre's hull), the headroom a
## crouched player (54 u), the step [code]sv_stepsize[/code] (18 u), the slope limit
## [code]max_slope[/code] (45.57°), and a jump [G2GReach]'s RUN reach and climb limit.
##
## [b]How it works[/b] (game-playlot's `PlaygroundMapSurvey`, reimplemented here — a copy
## per project is the family's rule). The boxes are read off the built map and rasterised
## into columns on a [constant CELL] grid: each column is the list of solid spans a
## vertical line through it passes. The top of a span is somewhere to stand if the face it
## leaves through is no steeper than the slope limit, there is a crouched player's headroom
## above it, and nothing in the neighbouring columns intrudes into the hull. Standable
## cells are joined into REGIONS by walking (a step of at most the step height), and
## regions into a directed graph by: dropping off an edge; sliding down the fall line of a
## face nobody can stand on; a RUN jump (from the lip at run speed) inside
## [method G2GReach.run_reach]; and the consecutive bodies of every CHAIN course the map
## declares (`G2GMap.add_course`), provided [method G2GReach.chain] says a perfect strafe
## runs it — the chain is `headless_run`'s question and its answer is reused, not redone.
##
## - [b]Unreached[/b]: a region no spawn and no stage destination leads to, and that the
##   caller has not declared.
## - [b]Trapped[/b]: a region a spawn leads to that leads to none of: a spawn, a finish
##   zone, a respawn zone, or a fall into one. A player there can only type `!r`.
## - [b]Slots[/b]: two solids with air between them narrower than the hull, side by side
##   over more than a step. A passage that looks open and is not, or a crack that holds a
##   body.
##
## [b]What reach means on a surf map, and why it stops short there on purpose.[/b] A surf
## ramp is steeper than anybody can stand on, so it has no cells: it is a surface a player
## slides on, not a floor. What a player on one reaches is decided by their SPEED, and on
## a ramp speed is the rider's — an air-strafe adds up to [code]sv_maxairwishspeed[/code]
## a tick, to [code]sv_maxvelocity[/code] — so any bound on it is either "everywhere" or a
## guess at a player's skill, and a flood fill over either answers nothing. The survey
## floods only what needs no skill: walking, a step, a drop, a RUN jump, and a slide down a
## face's FALL LINE (straight down it, off its low edge, onto whatever is below). A surf
## route whose next surface is reached by a carried flight — off the end of a bank, over a
## gap to the next one — reads as unreached, which errs toward reporting, and the caller
## declares it with the check that rides it. The standable parts (pads, floors, platforms,
## finishes) are surveyed fully: slots, headroom, trapped and spawns all mean on a surf map
## exactly what they mean on a bhop map.
##
## [b]What it does not do, on purpose.[/b] A jump is judged edge to edge from above, not
## swept through the air. A tilted box's slot distance is sampled along its edges every
## [constant EDGE_SAMPLE] units rather than solved exactly. Each is a place to extend it
## the day a map needs it.

## Grid spacing, units. Half the hull, so a cell's eight neighbours are the hull.
const CELL := 16.0

## Units between the points sampled along a tilted solid's edges for the slot distance.
const EDGE_SAMPLE := 8.0

## Most slide steps followed down one face before the survey gives up on it.
const SLIDE_LIMIT := 4000

## Units. How far above the highest span a slide or a fall may still count a top as
## "at or below": the tilt of one cell of a steep face.
const _TOL := 2.0


## One solid box, in units.
class Solid:
	extends RefCounted
	var xform: Transform3D
	var inverse: Transform3D
	var size: Vector3
	var bounds: AABB
	var upright: bool
	## The body it came from, so a course can name it; null for a fixture.
	var body: Node3D = null


## One zone, in units. The timer's zones are in metres; the survey converts at the edge.
class Box:
	extends RefCounted
	var kind: int
	var from: Vector3
	var to: Vector3

	func has(at: Vector3) -> bool:
		return at.x >= from.x and at.x <= to.x and at.y >= from.y and at.y <= to.y \
			and at.z >= from.z and at.z <= to.z


var solids: Array[Solid] = []

# From the tunables, in units.
var hull := 32.0
var headroom := 54.0
var step := 18.0
var climb := 51.3
var cos_limit := 0.7
var _tunables: DotFpsTunables = null
var _tick_rate := 128

var _origin := Vector2.ZERO
var _nx := 0
var _nz := 0

# Per column (ix + iz * _nx), the merged spans: [bottom, top, standable, nx, nz] * n.
var _spans: Dictionary = {}
var _top_max := PackedFloat32Array()
var _bottom_min := PackedFloat32Array()

# Standable cells: their column, their height, and their region.
var _node_col := PackedInt32Array()
var _node_y := PackedFloat32Array()
var _node_region := PackedInt32Array()
var _col_first := PackedInt32Array()
var _col_count := PackedInt32Array()

var _parent := PackedInt32Array()

var _region_low: Array[Vector3] = []
var _region_high: Array[Vector3] = []
var _region_count := PackedInt32Array()
var _region_edge: Array[PackedInt32Array] = []

var _out: Array[Dictionary] = []
var _escapes: Dictionary = {}
var _void_falls := 0
var _course_links := 0
var _course_problems: Array[String] = []


static func _corners(s: Solid) -> PackedVector3Array:
	var half := s.size * 0.5
	var out := PackedVector3Array()
	for i in range(8):
		out.append(s.xform * Vector3(
			half.x * (1.0 if i & 1 else -1.0),
			half.y * (1.0 if i & 2 else -1.0),
			half.z * (1.0 if i & 4 else -1.0)
		))
	return out


## The least distance from any point along [param a]'s edges to [param b].
static func _edge_distance(a: Solid, b: Solid) -> float:
	var corners := _corners(a)
	var best := INF
	# The 12 edges of a box: pairs of corner indices differing in one bit.
	for i in range(8):
		for bit in [1, 2, 4]:
			var j: int = i | bit
			if j == i:
				continue
			var p := corners[i]
			var q := corners[j]
			var n := maxi(1, int(ceil(p.distance_to(q) / EDGE_SAMPLE)))
			for k in range(n + 1):
				best = minf(best, _point_box(p.lerp(q, float(k) / float(n)), b))
	return best


## Distance from [param p] to solid [param s], 0 inside it.
static func _point_box(p: Vector3, s: Solid) -> float:
	var local := s.inverse * p
	var half := s.size * 0.5
	var d := Vector3(
		maxf(absf(local.x) - half.x, 0.0),
		maxf(absf(local.y) - half.y, 0.0),
		maxf(absf(local.z) - half.z, 0.0)
	)
	return d.length()


## Whether two boxes intersect or touch, by the separating axis test.
static func _boxes_overlap(a: Solid, b: Solid) -> bool:
	var axes: Array[Vector3] = []
	for s in [a, b]:
		for k in range(3):
			axes.append((s as Solid).xform.basis[k].normalized())
	for i in range(3):
		for j in range(3):
			var cross := a.xform.basis[i].normalized().cross(b.xform.basis[j].normalized())
			if cross.length() > 1e-6:
				axes.append(cross.normalized())

	var ca := _corners(a)
	var cb := _corners(b)

	for axis in axes:
		var a_lo := INF
		var a_hi := -INF
		var b_lo := INF
		var b_hi := -INF
		for v in ca:
			a_lo = minf(a_lo, v.dot(axis))
			a_hi = maxf(a_hi, v.dot(axis))
		for v in cb:
			b_lo = minf(b_lo, v.dot(axis))
			b_hi = maxf(b_hi, v.dot(axis))
		if a_hi < b_lo - 0.01 or b_hi < a_lo - 0.01:
			return false
	return true


static func _footprint(s: Solid) -> PackedVector2Array:
	var x := s.xform.basis.x * s.size.x * 0.5
	var z := s.xform.basis.z * s.size.z * 0.5
	var c := s.xform.origin
	var out := PackedVector2Array()
	for corner in [c - x - z, c + x - z, c + x + z, c - x + z]:
		out.append(Vector2((corner as Vector3).x, (corner as Vector3).z))
	return out


static func _polygons_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for poly in [a, b]:
		var p := poly as PackedVector2Array
		for k in range(p.size()):
			var edge := p[(k + 1) % p.size()] - p[k]
			var axis := Vector2(-edge.y, edge.x)
			var a_lo := INF
			var a_hi := -INF
			var b_lo := INF
			var b_hi := -INF
			for v in a:
				a_lo = minf(a_lo, v.dot(axis))
				a_hi = maxf(a_hi, v.dot(axis))
			for v in b:
				b_lo = minf(b_lo, v.dot(axis))
				b_hi = maxf(b_hi, v.dot(axis))
			if a_hi < b_lo - 1e-4 or b_hi < a_lo - 1e-4:
				return false
	return true


static func _point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- Columns -----------------------------------------------------------------

static func _push_span(out: PackedFloat32Array, span: Array) -> void:
	out.append(float(span[0]))
	out.append(float(span[1]))
	out.append(1.0 if bool(span[2]) else 0.0)
	out.append(float(span[3]))
	out.append(float(span[4]))


const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

const SIDES: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


static func _flood(starts: Array, edges: Array[Dictionary]) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array = starts.duplicate()

	for s: int in starts:
		seen[s] = true

	while not queue.is_empty():
		var r: int = queue.pop_back()
		for next: int in edges[r]:
			if not seen.has(next):
				seen[next] = true
				queue.append(next)

	return seen
