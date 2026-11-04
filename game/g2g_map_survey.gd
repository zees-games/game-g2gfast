extends "g2g_map_survey_grid.gd"
## Surveys a built map (its [method G2GMap._build] has run; it need not be in the tree).
##
## [param starts] are the points players are put at, in units: spawns and stage
## destinations. [param declared] is `[{box: AABB (units), why: String}]` for areas the
## caller knows no start reaches. Returns
## `{cells, reached_cells, regions, slots, unreached, trapped, startless,
## stale_declarations, void_falls, course_links, course_problems, standable_tilted}`;
## every list is of human-readable lines.
static func survey(
	map: Node3D, zones: DotTimerZoneSet, starts: Array[Vector3], declared: Array,
	t: DotFpsTunables, tick_rate: int
) -> Dictionary:
	var s := new()
	s._configure(t, tick_rate)
	s._collect(map)
	var courses: Array = map.get("courses") if map.get("courses") != null else []
	return s._run(zones, starts, declared, courses)


## Surveys a list of solids directly: for a fixture that is not a map.
static func survey_solids(
	boxes: Array[Solid], zones: DotTimerZoneSet, starts: Array[Vector3], declared: Array,
	t: DotFpsTunables, tick_rate: int
) -> Dictionary:
	var s := new()
	s._configure(t, tick_rate)
	s.solids = boxes
	return s._run(zones, starts, declared, [])


## A solid from a centre, a size and an optional basis, in units — `G2GGeometry.box`'s
## arguments.
static func solid(at: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> Solid:
	var out := Solid.new()
	out.xform = Transform3D(basis, at)
	out.inverse = out.xform.affine_inverse()
	out.size = size
	out.upright = basis.y.normalized().dot(Vector3.UP) > 0.9999

	var low := Vector3(INF, INF, INF)
	var high := -low

	for corner in _corners(out):
		low = low.min(corner)
		high = high.max(corner)

	out.bounds = AABB(low, high - low)
	return out


func _configure(t: DotFpsTunables, tick_rate: int) -> void:
	_tunables = t
	_tick_rate = tick_rate
	hull = 2.0 * G2GUnits.to_units(t.radius)
	headroom = G2GUnits.to_units(t.crouch_height)
	step = G2GReach.step(t)
	climb = G2GReach.climb_limit(t)
	cos_limit = cos(t.max_slope_radians())


func _collect(map: Node3D) -> void:
	for child in map.get_children():
		var body := child as StaticBody3D

		if body == null:
			continue

		for part in body.get_children():
			var shape := part as CollisionShape3D

			if shape == null or not (shape.shape is BoxShape3D):
				continue

			var xform := body.transform * shape.transform
			var one := solid(
				G2GUnits.vector_to_units(xform.origin),
				G2GUnits.vector_to_units((shape.shape as BoxShape3D).size),
				xform.basis
			)
			one.body = body
			solids.append(one)


func _run(
	zones: DotTimerZoneSet, starts: Array[Vector3], declared: Array, courses: Array
) -> Dictionary:
	var slots := _slots()

	_rasterise()
	_find_cells()
	_join_regions()

	var boxes := _zone_boxes(zones)
	var pits: Array[Box] = []
	for box in boxes:
		if box.kind == DotTimerZone.Kind.RESPAWN:
			pits.append(box)

	_link_regions(boxes, pits)
	_link_courses(courses)

	# Forward from every start. A start in the air falls to whatever is under it, which
	# is what a player put there does.
	var from: Dictionary = {}
	var startless: Array[String] = []

	for at in starts:
		var node := _fall(at.x, at.z, at.y + _TOL, pits)
		if node == -1:
			node = _cell_near(at)

		if node >= 0:
			from[_node_region[node]] = true
			_escapes[_node_region[node]] = true
		else:
			startless.append("(%.0f, %.0f, %.0f)%s" % [
				at.x, at.y, at.z, " falls into a pit" if node == -2 else " is over nothing",
			])

	var reached := _flood(from.keys(), _out)

	var back: Array[Dictionary] = []
	for _i in range(_out.size()):
		back.append({})
	for a in range(_out.size()):
		for b: int in _out[a]:
			back[b][a] = true

	var safe := _flood(_escapes.keys(), back)

	var unreached: Array[String] = []
	var trapped: Array[String] = []
	var reached_cells := 0
	var used: Dictionary = {}

	for region in range(_region_count.size()):
		var what := _describe(region)

		if not reached.has(region):
			var by := _declared_by(region, declared)
			if by < 0:
				unreached.append(what)
			else:
				used[by] = true
		else:
			reached_cells += _region_count[region]
			if not safe.has(region):
				trapped.append(what)

	# A declaration that covers nothing unreached is stale: the ground it excused is
	# reached now, or gone, and leaving it would excuse the next thing built there.
	var stale: Array[String] = []
	for i in range(declared.size()):
		if not used.has(i):
			stale.append(str((declared[i] as Dictionary).get("why", "declaration %d" % i)))

	return {
		"cells": _node_col.size(),
		"stale_declarations": stale,
		"reached_cells": reached_cells,
		"regions": _region_count.size(),
		"slots": slots,
		"unreached": unreached,
		"trapped": trapped,
		"startless": startless,
		"void_falls": _void_falls,
		"course_links": _course_links,
		"course_problems": _course_problems,
		"standable_tilted": _standable_tilted(),
	}


func _describe(region: int) -> String:
	var low := _region_low[region]
	var high := _region_high[region]
	return "%d cells from (%.0f, %.0f, %.0f) to (%.0f, %.0f, %.0f)" % [
		_region_count[region], low.x, low.y, low.z, high.x, high.y, high.z,
	]


static func _zone_boxes(zones: DotTimerZoneSet) -> Array[Box]:
	var out: Array[Box] = []
	if zones == null:
		return out
	for zone in zones.zones:
		if zone.shape != DotTimerZone.Shape.BOX:
			continue
		var box := Box.new()
		box.kind = zone.kind
		box.from = G2GUnits.vector_to_units(zone.from)
		box.to = G2GUnits.vector_to_units(zone.to)
		out.append(box)
	return out


## Tilted solids whose upward face is standable: a slab somebody may call a ramp that the
## movement treats as floor. Reported, not judged — a walkable ramp is a legitimate
## thing to build, and a SURF ramp that is walkable is not surf.
func _standable_tilted() -> Array[String]:
	var out: Array[String] = []
	for s in solids:
		if s.upright:
			continue
		# The broad face: the one across the slab's thinnest dimension. The other four
		# are its edges, a slab's thickness across, and a 60° bank's edge is 30° from
		# level — standable, and not what anybody means by the ramp.
		var thin := 0
		for axis in range(1, 3):
			if s.size[axis] < s.size[thin]:
				thin = axis
		var best := absf(s.xform.basis[thin].normalized().y)
		if best >= cos_limit:
			out.append("the slab at (%.0f, %.0f, %.0f), %.1f° from level" % [
				s.xform.origin.x, s.xform.origin.y, s.xform.origin.z, rad_to_deg(acos(best)),
			])
	return out


# --- Slots -------------------------------------------------------------------

func _slots() -> Array[String]:
	var found: Array[String] = []

	for i in range(solids.size()):
		var a := solids[i]

		for j in range(i + 1, solids.size()):
			var b := solids[j]

			if not a.bounds.grow(hull).intersects(b.bounds):
				continue

			# Side by side over more than a step: a crack between two floors a player
			# steps over is not a passage.
			var band := minf(a.bounds.end.y, b.bounds.end.y) \
				- maxf(a.bounds.position.y, b.bounds.position.y)
			if band <= step:
				continue

			var gap := _gap(a, b)

			if gap > 0.01 and gap < hull:
				var at := (a.xform.origin + b.xform.origin) * 0.5
				found.append("%.0f u between the solids at (%.0f, %.0f, %.0f) and (%.0f, %.0f, %.0f), near (%.0f, %.0f, %.0f)" % [
					gap, a.xform.origin.x, a.xform.origin.y, a.xform.origin.z,
					b.xform.origin.x, b.xform.origin.y, b.xform.origin.z, at.x, at.y, at.z,
				])

	return found


## The clear air between two solids. Two upright boxes are measured from above, exactly,
## and only where their facing sides run side by side for a hull's width (two boxes
## meeting at a corner are not a corridor). A tilted one is measured in 3D, sampled
## along both boxes' edges, which is where the least distance between two boxes lies.
func _gap(a: Solid, b: Solid) -> float:
	if a.upright and b.upright:
		var pa := _footprint(a)
		var pb := _footprint(b)

		if _polygons_overlap(pa, pb):
			return 0.0
		if not _side_by_side(pa, pb):
			return INF

		var best := INF
		for k in range(4):
			for p in pb:
				best = minf(best, _point_segment(p, pa[k], pa[(k + 1) % 4]))
			for p in pa:
				best = minf(best, _point_segment(p, pb[k], pb[(k + 1) % 4]))
		return best

	if _boxes_overlap(a, b):
		return 0.0

	return minf(_edge_distance(a, b), _edge_distance(b, a))


## Whether two footprints face each other along at least a hull's width: projected on
## the axis they are separated along, the other axis's extents overlap by that much.
func _side_by_side(pa: PackedVector2Array, pb: PackedVector2Array) -> bool:
	for poly in [pa, pb]:
		var p := poly as PackedVector2Array
		for k in range(2):
			var along := (p[(k + 1) % 4] - p[k]).normalized()
			var across := Vector2(-along.y, along.x)
			var a_lo := INF
			var a_hi := -INF
			var b_lo := INF
			var b_hi := -INF
			var c_lo := INF
			var c_hi := -INF
			var d_lo := INF
			var d_hi := -INF
			for v in pa:
				a_lo = minf(a_lo, v.dot(along))
				a_hi = maxf(a_hi, v.dot(along))
				c_lo = minf(c_lo, v.dot(across))
				c_hi = maxf(c_hi, v.dot(across))
			for v in pb:
				b_lo = minf(b_lo, v.dot(along))
				b_hi = maxf(b_hi, v.dot(along))
				d_lo = minf(d_lo, v.dot(across))
				d_hi = maxf(d_hi, v.dot(across))
			# Separated across this edge's normal, overlapping along the edge.
			var separated := c_hi < d_lo or d_hi < c_lo
			if separated and minf(a_hi, b_hi) - maxf(a_lo, b_lo) >= hull:
				return true
	return false


func _link_regions(boxes: Array[Box], pits: Array[Box]) -> void:
	# Standing in a finish or a reset is a way out.
	for box in boxes:
		if box.kind != DotTimerZone.Kind.END and box.kind != DotTimerZone.Kind.RESPAWN:
			continue

		var ix0 := maxi(0, int(floor((box.from.x - _origin.x) / CELL)))
		var ix1 := mini(_nx - 1, int(floor((box.to.x - _origin.x) / CELL)))
		var iz0 := maxi(0, int(floor((box.from.z - _origin.y) / CELL)))
		var iz1 := mini(_nz - 1, int(floor((box.to.z - _origin.y) / CELL)))

		for iz in range(iz0, iz1 + 1):
			for ix in range(ix0, ix1 + 1):
				var zcol := ix + iz * _nx
				for n in range(_col_first[zcol], _col_first[zcol] + _col_count[zcol]):
					if box.has(_node_at(n) + Vector3(0.0, 8.0, 0.0)):
						_escapes[_node_region[n]] = true

	for n in range(_node_col.size()):
		var region := _node_region[n]
		var at := _node_at(n)
		var col := _node_col[n]
		var ix := col % _nx
		var iz := col / _nx
		var edge := false

		for d in SIDES:
			var jx := ix + d.x
			var jz := iz + d.y
			var level := false

			if jx >= 0 and jz >= 0 and jx < _nx and jz < _nz:
				var ncol := jx + jz * _nx
				for m in range(_col_first[ncol], _col_first[ncol] + _col_count[ncol]):
					if absf(_node_y[m] - _node_y[n]) <= step:
						level = true
						break

			if level:
				continue

			var jcol := jx + jz * _nx
			var inside_grid := jx >= 0 and jz >= 0 and jx < _nx and jz < _nz

			if inside_grid and _solid_between(jcol, at.y + step, at.y + headroom):
				if not _too_tall(jcol, at.y):
					edge = true
				continue

			if inside_grid and _floor_near(jcol, at.y):
				var kx := jx + d.x
				var kz := jz + d.y
				var beyond := kx >= 0 and kz >= 0 and kx < _nx and kz < _nz
				if not (beyond and _solid_between(kx + kz * _nx, at.y + step, at.y + headroom)
						and _too_tall(kx + kz * _nx, at.y)):
					edge = true
				continue

			edge = true

			var x := _origin.x + (float(jx) + 0.5) * CELL
			var z := _origin.y + (float(jz) + 0.5) * CELL
			var landed := _fall(x, z, at.y, pits)

			if landed >= 0 and _node_region[landed] != region:
				_out[region][_node_region[landed]] = true
			elif landed == -2:
				_escapes[region] = true

		if edge:
			_region_edge[region].append(n)

	_link_jumps()


## Where a player who leaves the ground over (x, z) at [param y] comes to rest: a cell,
## -2 for a fall into a respawn volume, or -1 for a fall into nothing. A face nobody can
## stand on is slid down along its fall line, one cell at a time.
func _fall(x: float, z: float, y: float, pits: Array[Box]) -> int:
	var cx := x
	var cz := z
	var top := y

	for _i in range(SLIDE_LIMIT):
		var ix := int(floor((cx - _origin.x) / CELL))
		var iz := int(floor((cz - _origin.y) / CELL))
		var col := ix + iz * _nx
		var spans: PackedFloat32Array = PackedFloat32Array()

		if ix >= 0 and iz >= 0 and ix < _nx and iz < _nz:
			spans = _spans.get(col, PackedFloat32Array())

		var best := -1
		for k in range(0, spans.size(), 5):
			if spans[k + 1] <= top + _TOL and (best < 0 or spans[k + 1] > spans[best + 1]):
				best = k

		if best < 0:
			for pit in pits:
				if cx >= pit.from.x and cx <= pit.to.x and cz >= pit.from.z \
						and cz <= pit.to.z and pit.from.y < top:
					return -2
			_void_falls += 1
			return -1

		if spans[best + 2] > 0.5:
			for n in range(_col_first[col], _col_first[col] + _col_count[col]):
				if absf(_node_y[n] - spans[best + 1]) < 0.01:
					return n
			# Standable but no room: a hull's width from something. Stop here.
			return -1

		var down := Vector2(spans[best + 3], spans[best + 4])
		if down.length() < 1e-4:
			return -1
		down = down.normalized() * CELL
		top = spans[best + 1]
		cx += down.x
		cz += down.y

	return -1


## A declared CHAIN course's bodies, linked in order, if [G2GReach] says a perfect strafe
## runs it from its start line. `headless_run` asserts the same verdict, so a course that
## is not a chain fails there; here it is simply not a way forward.
func _link_courses(courses: Array) -> void:
	for course: Object in courses:
		if int(course.get("kind")) != G2GReach.Kind.CHAIN:
			continue

		var bodies: Array = course.get("bodies")
		var routes := G2GReach.measure(bodies)
		if not bool(G2GReach.chain(routes, _tunables, _tick_rate, 1.0)["ok"]):
			_course_problems.append("%s is not a chain even strafing perfectly" % course.get("name"))
			continue

		var regions: Array[int] = []
		for body: Node3D in bodies:
			var node := _cell_on(body)
			if node < 0:
				_course_problems.append("%s: the body at %s has no standable cell on it" % [
					course.get("name"), G2GUnits.vector_to_units(body.transform.origin),
				])
			regions.append(_node_region[node] if node >= 0 else -1)

		for i in range(regions.size() - 1):
			if regions[i] >= 0 and regions[i + 1] >= 0 and regions[i] != regions[i + 1]:
				if not _out[regions[i]].has(regions[i + 1]):
					_out[regions[i]][regions[i + 1]] = true
					_course_links += 1


## The standable cell on top of a level body's centre.
func _cell_on(body: Node3D) -> int:
	for s in solids:
		if s.body != body:
			continue
		var top := s.bounds.end.y
		var at := s.xform.origin
		var ix := int(floor((at.x - _origin.x) / CELL))
		var iz := int(floor((at.z - _origin.y) / CELL))
		for ring in range(0, 3):
			for dz in range(-ring, ring + 1):
				for dx in range(-ring, ring + 1):
					var jx := ix + dx
					var jz := iz + dz
					if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
						continue
					var col := jx + jz * _nx
					for n in range(_col_first[col], _col_first[col] + _col_count[col]):
						if absf(_node_y[n] - top) < 0.5:
							return n
	return -1


func _link_jumps() -> void:
	var regions := _region_count.size()

	for a in range(regions):
		for b in range(regions):
			if a == b or _out[a].has(b):
				continue

			var rise := _region_low[b].y - _region_high[a].y
			if rise > climb:
				continue

			var reach := G2GReach.run_reach(rise, _tunables)
			var bounds_a := AABB(_region_low[a], _region_high[a] - _region_low[a])
			var bounds_b := AABB(_region_low[b], _region_high[b] - _region_low[b])

			if _plan_gap(bounds_a, bounds_b) - CELL > reach:
				continue

			if _can_jump(a, b):
				_out[a][b] = true


## The clear air between two boxes seen from above, 0 when their footprints overlap.
static func _plan_gap(a: AABB, b: AABB) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dz := maxf(0.0, maxf(a.position.z - b.end.z, b.position.z - a.end.z))
	return Vector2(dx, dz).length()


## Units per bucket of a region's edge cells, for [method _can_jump].
const BUCKET := 128.0

var _edge_buckets: Dictionary = {}


func _buckets_of(region: int) -> Dictionary:
	if _edge_buckets.has(region):
		return _edge_buckets[region]

	var out: Dictionary = {}
	for n in _region_edge[region]:
		var at := _node_at(n)
		var key := Vector2i(floori(at.x / BUCKET), floori(at.z / BUCKET))
		var list: PackedInt32Array = out.get(key, PackedInt32Array())
		list.append(n)
		out[key] = list

	_edge_buckets[region] = out
	return out


func _can_jump(a: int, b: int) -> bool:
	var target := AABB(_region_low[b], _region_high[b] - _region_low[b])
	var buckets := _buckets_of(b)

	for n in _region_edge[a]:
		var from := _node_at(n)
		var best_reach := G2GReach.run_reach(_region_low[b].y - from.y, _tunables)

		if _plan_gap(AABB(from, Vector3.ZERO), target) - CELL > best_reach:
			continue

		var r := int(ceil((best_reach + CELL) / BUCKET))
		var bx := floori(from.x / BUCKET)
		var bz := floori(from.z / BUCKET)

		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var list: PackedInt32Array = buckets.get(Vector2i(bx + dx, bz + dz), PackedInt32Array())
				for m in list:
					var to := _node_at(m)
					var rise := to.y - from.y
					if rise > climb:
						continue
					# Centre to centre, less a cell: lip to lip, with the half cell either
					# side of each edge cell's centre given back.
					var gap := Vector2(to.x - from.x, to.z - from.z).length() - CELL
					if gap <= G2GReach.run_reach(rise, _tunables):
						return true

	return false


# --- Reading the graph ----------------------------------------------------------

## A standable cell close to [param at], at or a little under it: for a start that sits
## against a wall, where the column straight down has no room for the hull.
func _cell_near(at: Vector3) -> int:
	var ix := int(floor((at.x - _origin.x) / CELL))
	var iz := int(floor((at.z - _origin.y) / CELL))
	var best := -1

	for ring in range(1, 4):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var jx := ix + dx
				var jz := iz + dz
				if jx < 0 or jz < 0 or jx >= _nx or jz >= _nz:
					continue
				var col := jx + jz * _nx
				for n in range(_col_first[col], _col_first[col] + _col_count[col]):
					if _node_y[n] <= at.y + _TOL and _node_y[n] >= at.y - 64.0:
						if best < 0 or _node_y[n] > _node_y[best]:
							best = n
		if best >= 0:
			return best

	return -1


## The index of the declaration covering every cell of [param region] (all of them inside
## the declared boxes, and the first box that holds one is the one credited), or -1. Per
## cell rather than by the region's bounds, because a region can be a ring whose bounds
## are the whole map.
func _declared_by(region: int, declared: Array) -> int:
	if declared.is_empty():
		return -1

	var boxes: Array[AABB] = []
	for entry: Variant in declared:
		boxes.append(((entry as Dictionary)["box"] as AABB).grow(CELL))

	var first := -1

	for n in range(_node_col.size()):
		if _node_region[n] != region:
			continue
		var at := _node_at(n)
		var inside := -1
		for i in range(boxes.size()):
			if boxes[i].has_point(at):
				inside = i
				break
		if inside < 0:
			return -1
		if first < 0:
			first = inside

	return first
