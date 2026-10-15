extends RefCounted

## A route for the rule-based bots across a map nobody wrote a route for, from dot-npc-ai's
## navigation annotations (`DotNpcAiNavAnnotator`): the links it finds (a drop off a ledge, a jump
## up onto one, a jump across a gap) joined to the walkable mesh into one graph, and the way
## through it from the spawn to the goal as the points [code]g2g_route_bot.gd[/code] drives.
##
## [b]Why the bots had none.[/b] Only bhop_grove has a route file, so every other map's bot aimed
## straight at the finish and stopped at the first wall. The mesh alone does not help on a bhop
## map: every block is an island, so a walked path ends at the edge of the first one. The links
## are what join the islands, and a link is also what tells the bot WHERE to jump.
##
## [b]Never in a tick.[/b] A map's colliders are parsed in one engine call (milliseconds); the
## bake runs on a worker thread where there are threads; the annotator is a [DotJob] stepped a
## few items at a time; the graph, the search and the thinning are cursors over arrays. Every
## [method step] takes a budget in microseconds and returns when it is spent, so a server calls
## it once a tick with a millisecond and carries on. The annotations are cached by their own key
## ([method DotNpcAiNavAnnotator.cache_key]), so a map the server has seen skips that phase; the
## bake is not cached (a mesh is not worth the disk, and it is off the main thread).
##
## [b]A walk through polygons, a link through a node of its own.[/b] Each polygon of the mesh is
## a node of an [AStar3D] at its centre, joined to its neighbours. A link is a node midway
## between its two ends with a weight over 1, so the search prefers a walk to a jump and a drop to
## a gap; a jump the bot can miss is a worse bargain than a longer walk. Weights are by kind
## ([constant WEIGHTS]); change them there.
##
## [b]When the goal cannot be reached[/b] (a staged map's finish is behind doors this graph does
## not know, a surf map is ramps the mesh left out) the route ends at the reachable polygon
## nearest the goal, and the bot aims at the goal from there as it always did.

const CHANNEL := "g2g.bots.nav"

enum State { IDLE, BAKING, ANNOTATING, GRAPH, PLAN, READY, FAILED }

## Cost of crossing a link, as a multiple of walking the same distance. A drop is the cheapest
## (nothing to miss), a jump up is a jump the bot must time, and a gap is the one that kills a run.
const WEIGHTS := {
	DotNpcAiNavAnnotations.LINK_DROP: 1.5,
	DotNpcAiNavAnnotations.LINK_JUMP_UP: 3.0,
	DotNpcAiNavAnnotations.LINK_JUMP_GAP: 4.0,
}
## Link kinds a bot follows. A ladder, a teleport and a ride are declared by a game, and this
## one declares none.
const FOLLOWED := [
	DotNpcAiNavAnnotations.LINK_DROP,
	DotNpcAiNavAnnotations.LINK_JUMP_UP,
	DotNpcAiNavAnnotations.LINK_JUMP_GAP,
]

## A gap is judged at this multiple of the running speed: the route bot chains hops and strafes
## in the air, and a bhop map's gaps are laid out for a player who has gained speed, so the
## walking reach (about 3 m) is shorter than every block's gap on them.
const GAP_SPEED := 2.5

const CELL := 0.175
const CELL_HEIGHT := 0.1
## Items of the annotator a step (its `slice`). A slice of 24 cost 45 ms at its worst on a large
## map (the outline, a dozen rays an item); 4 keeps a step well inside a tick's share.
const SLICE := 1
## How far apart polygon lookups search, and the grid they search, metres.
const GRID := 2.0
## How far a link's end may be from the polygon it is snapped to, metres.
const SNAP := 1.5
## Thinning: a walked point stays when the walk would otherwise cut it by more than this.
const TOLERANCE := 0.5
## Metres within which a walked point is passed, a link's ledge, and its landing.
const WALK_RADIUS := 1.5
const LEDGE_RADIUS := 0.6
const LANDING_RADIUS := 0.9

var state: State = State.IDLE
## The route-bot points, once [constant State.READY]; empty when there is no way.
var points: Array[Dictionary] = []
var annotations: DotNpcAiNavAnnotations = null
## Where the work is and what it cost, for [method describe]: milliseconds per phase, the
## slowest single step, and whether the annotations came from the cache.
var phase_ms: Dictionary = {}
var worst_step_ms := 0.0
var worst_by_phase: Dictionary = {}
var from_cache := false
var reached_goal := false
## Polygons the spawn can walk or jump to, for [method describe].
var reachable_count := 0
var link_edges := 0
var failure := ""

var _mesh: NavigationMesh = null
var _world: World3D = null
var _body: DotFpsTunables = null
var _start := Vector3.ZERO
var _goal := Vector3.ZERO
var _seeds := PackedVector3Array()
var _cache_dir := ""
## Whether a point is somewhere the course puts a bot back from (a pit, below the floor): a
## floor there is on the mesh and a drop onto it is a link, and both are a death, not a route.
var _avoid: Callable = Callable()
var _blocked: Dictionary = {}
var _generation := 0
var _baked := false
var _job: DotNpcAiNavAnnotator = null
var _started_us := 0
var _phase_started_us := 0

var _vertices := PackedVector3Array()
var _centres := PackedVector3Array()
var _polygons: Array = []
var _cursor := 0
var _step_no := 0
var _edge_owner: Dictionary = {}
var _canon: PackedInt32Array = PackedInt32Array()
var _seen: Dictionary = {}
var _grid: Dictionary = {}
var _graph := AStar3D.new()
var _adj: Array = []
var _linked: Array[Dictionary] = []


## Starts the work for the map under [param root], whose physics are in [param world]: a body as
## [param body] moves, from [param start] to [param goal] (metres). Spawns are the seeds that
## decide which floors count. [param cache_dir] is where annotations are kept by key.
func begin(root: Node3D, world: World3D, body: DotFpsTunables, start: Vector3, goal: Vector3,
		seeds: PackedVector3Array, cache_dir: String, avoid: Callable = Callable()) -> void:
	cancel()
	_generation += 1
	_world = world
	_body = body
	_start = start
	_goal = goal
	_seeds = seeds
	_cache_dir = cache_dir
	_avoid = avoid
	_started_us = Time.get_ticks_usec()
	_phase_started_us = _started_us

	_mesh = NavigationMesh.new()
	_mesh.cell_size = CELL
	_mesh.cell_height = CELL_HEIGHT
	# Whole cells, rounded the safe way, as DotBotNav does (the baker would do it and warn).
	_mesh.agent_radius = ceilf(body.radius / CELL - 0.001) * CELL
	_mesh.agent_height = ceilf(body.stand_height / CELL_HEIGHT - 0.001) * CELL_HEIGHT
	_mesh.agent_max_climb = floorf(body.step_height / CELL_HEIGHT + 0.001) * CELL_HEIGHT
	_mesh.agent_max_slope = body.max_slope_angle
	_mesh.region_min_size = 2.0
	_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_mesh, source, root)
	phase_ms["parse"] = _lap()
	state = State.BAKING
	if DotPlatform.has_threads():
		NavigationServer3D.bake_from_source_geometry_data_async(_mesh, source, _on_baked.bind(_generation))
	else:
		NavigationServer3D.bake_from_source_geometry_data(_mesh, source)
		_baked = true


## Abandons the work (a map change). A bake still on its thread lands on nothing.
func cancel() -> void:
	_generation += 1
	state = State.IDLE
	points = []
	annotations = null
	_job = null
	_mesh = null
	_baked = false
	_graph = AStar3D.new()
	_adj = []
	_grid = {}
	_edge_owner = {}
	_blocked = {}
	_linked = []
	_polygons = []
	phase_ms = {}
	worst_step_ms = 0.0
	worst_by_phase = {}
	from_cache = false
	reached_goal = false
	failure = ""


func is_working() -> bool:
	return state != State.IDLE and state != State.READY and state != State.FAILED


func _on_baked(generation: int) -> void:
	if generation == _generation:
		_baked = true


## Works until [param budget_usec] is spent or there is nothing left. True while there is more.
func step(budget_usec: int) -> bool:
	var deadline := Time.get_ticks_usec() + budget_usec
	while is_working():
		var began := Time.get_ticks_usec()
		match state:
			State.BAKING:
				if not _baked:
					return true
				_finish_bake()
			State.ANNOTATING:
				_step_annotating()
			State.GRAPH:
				_step_graph(deadline)
			State.PLAN:
				_plan()
		var took := (Time.get_ticks_usec() - began) / 1000.0
		worst_step_ms = maxf(worst_step_ms, took)
		var phase: String = State.keys()[state].to_lower()
		worst_by_phase[phase] = maxf(float(worst_by_phase.get(phase, 0.0)), took)
		if Time.get_ticks_usec() >= deadline:
			break
	return is_working()


func _lap() -> float:
	var now := Time.get_ticks_usec()
	var ms := snappedf((now - _phase_started_us) / 1000.0, 0.1)
	_phase_started_us = now
	return ms


func _fail(why: String) -> void:
	failure = why
	state = State.FAILED
	points = []
	DotLog.warn(CHANNEL, "bots cannot plan through this map", {"why": why})


# --- Bake and annotate ---------------------------------------------------------

func _finish_bake() -> void:
	phase_ms["bake"] = _lap()
	if _mesh.get_polygon_count() == 0:
		_fail("the bake found nowhere to walk")
		return
	_job = DotNpcAiNavAnnotator.new(_mesh, _world)
	_job.agent_radius = _body.radius
	_job.stand_height = _body.stand_height
	_job.climb = _body.step_height
	# What a jump is asked to make: the same limits G2GReach holds the courses to, with a tenth
	# off so a link is one the bot clears with room, not one it clears by luck.
	_job.jump_up = _body.climb_limit()
	_job.gap_max = _body.jump_reach(0.0, _body.max_speed * GAP_SPEED) * 0.9
	_job.slice = SLICE
	_job.seeds = _seeds
	# Links only. A bot hides nowhere and holds nothing, so what the annotator spends most of its
	# time on (watchers, spots, the routes that find chokepoints) is turned down to the least it
	# will take, and the key says so (the settings are in it).
	_job.watchers = 4
	_job.routes = 0
	_job.max_candidates = 16
	_job.max_hiding = 4
	var key := _job.cache_key()
	var path := "%s/%s.json" % [_cache_dir, key]
	var cached := DotNpcAiNavAnnotations.load_file(path, key)
	if cached.ok:
		annotations = cached.value
		from_cache = true
		phase_ms["annotate"] = _lap()
		state = State.GRAPH
		_cursor = 0
		_step_no = 0
		return
	state = State.ANNOTATING


func _step_annotating() -> void:
	if _job.step():
		return
	phase_ms["annotate"] = _lap()
	if not _job.result.ok:
		_fail("annotation failed: %s" % _job.result.error.message)
		return
	annotations = _job.result.value
	var saved := annotations.save("%s/%s.json" % [_cache_dir, _job.cache_key()])
	if not saved.ok:
		DotLog.debug(CHANNEL, "annotations not cached", {"error": saved.error.message})
	state = State.GRAPH
	_cursor = 0
	_step_no = 0


# --- The graph -----------------------------------------------------------------
#
# Step 0 reads the mesh, 4 gives vertices at one place one id (so two polygons meeting along an
# edge are neighbours whether or not the bake shared a vertex index), 1 joins polygons that share an edge, 2 buckets them for lookups,
# 3 adds the links; each a cursor over its own array.

func _step_graph(deadline: int) -> void:
	match _step_no:
		0:
			_vertices = _mesh.get_vertices()
			_canon = PackedInt32Array()
			_canon.resize(_vertices.size())
			_seen = {}
			_edge_owner = {}
			_polygons = []
			_centres = PackedVector3Array()
			_graph.reserve_space(_mesh.get_polygon_count() + annotations.links.size())
			_step_no = 4
			_cursor = 0
		4:
			var count := _vertices.size()
			while _cursor < count and Time.get_ticks_usec() < deadline:
				var v := _vertices[_cursor]
				var key := Vector3i(roundi(v.x * 50.0), roundi(v.y * 50.0), roundi(v.z * 50.0))
				if not _seen.has(key):
					_seen[key] = _cursor
				_canon[_cursor] = _seen[key]
				_cursor += 1
			if _cursor >= count:
				_seen = {}
				_step_no = 1
				_cursor = 0
		1:
			var count := _mesh.get_polygon_count()
			while _cursor < count and Time.get_ticks_usec() < deadline:
				_add_polygon(_cursor)
				_cursor += 1
			if _cursor >= count:
				_step_no = 2
				_cursor = 0
		2:
			var count := _polygons.size()
			while _cursor < count and Time.get_ticks_usec() < deadline:
				_bucket(_cursor)
				_cursor += 1
			if _cursor >= count:
				_step_no = 3
				_cursor = 0
		3:
			var count := annotations.links.size()
			while _cursor < count and Time.get_ticks_usec() < deadline:
				_add_link(annotations.links[_cursor], _cursor)
				_cursor += 1
			if _cursor >= count:
				phase_ms["graph"] = _lap()
				state = State.PLAN


func _add_polygon(i: int) -> void:
	var polygon := _mesh.get_polygon(i)
	var centre := Vector3.ZERO
	for v in polygon:
		centre += _vertices[v]
	centre /= float(maxi(polygon.size(), 1))
	_polygons.append(polygon)
	_centres.append(centre)
	_graph.add_point(i, centre)
	if _avoid.is_valid() and bool(_avoid.call(centre)):
		_blocked[i] = true
		_graph.set_point_disabled(i, true)
	_adj.append([])
	for k in range(polygon.size()):
		var a := _canon[polygon[k]]
		var b := _canon[polygon[(k + 1) % polygon.size()]]
		var key := (mini(a, b) << 24) | maxi(a, b)
		if _edge_owner.has(key):
			var other: int = _edge_owner[key]
			if other != i and not _graph.are_points_connected(i, other):
				_graph.connect_points(i, other, true)
				_adj[i].append(other)
				_adj[other].append(i)
		else:
			_edge_owner[key] = i


func _bucket(i: int) -> void:
	var polygon: PackedInt32Array = _polygons[i]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in polygon:
		var p := _vertices[v]
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	for cx in range(floori(lo.x / GRID), floori(hi.x / GRID) + 1):
		for cz in range(floori(lo.y / GRID), floori(hi.y / GRID) + 1):
			var key := Vector2i(cx, cz)
			if not _grid.has(key):
				_grid[key] = []
			_grid[key].append(i)


## The polygon under [param at] (its floor within a metre of it), or else the nearest centre
## within [constant SNAP]; -1 when nowhere.
func polygon_at(at: Vector3) -> int:
	var best := -1
	var best_dy := 1.0
	var cx := floori(at.x / GRID)
	var cz := floori(at.z / GRID)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Variant = _grid.get(Vector2i(cx + dx, cz + dz))
			if bucket == null:
				continue
			for i: int in bucket:
				var height := _height_in(i, at)
				if not is_nan(height) and absf(at.y - height) < best_dy:
					best_dy = absf(at.y - height)
					best = i
	if best >= 0:
		return best
	var near := SNAP
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Variant = _grid.get(Vector2i(cx + dx, cz + dz))
			if bucket == null:
				continue
			for i: int in bucket:
				var c := _centres[i]
				var d := Vector2(c.x - at.x, c.z - at.z).length()
				if d < near and absf(c.y - at.y) < SNAP:
					near = d
					best = i
	return best


## The polygon whose centre is nearest [param at] within [param within] metres (a spawn pad the
## bake eroded away has a floor a step off it); -1 when none. A scan, used once.
func _nearest_centre(at: Vector3, within: float) -> int:
	var best := -1
	var best_d := within
	for i in range(_centres.size()):
		var d := _centres[i].distance_to(at)
		if d < best_d:
			best_d = d
			best = i
	return best


## Polygon [param i]'s floor under [param at] seen from above, or NAN when [param at] is not over it.
func _height_in(i: int, at: Vector3) -> float:
	var polygon: PackedInt32Array = _polygons[i]
	var a := _vertices[polygon[0]]
	for k in range(1, polygon.size() - 1):
		var b := _vertices[polygon[k]]
		var c := _vertices[polygon[k + 1]]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 0.000001:
			continue
		var u := ((b.z - c.z) * (at.x - c.x) + (c.x - b.x) * (at.z - c.z)) / d
		var v := ((c.z - a.z) * (at.x - c.x) + (a.x - c.x) * (at.z - c.z)) / d
		if u >= -0.01 and v >= -0.01 and u + v <= 1.01:
			return u * a.y + v * b.y + (1.0 - u - v) * c.y
	return NAN


func _add_link(link: Dictionary, index: int) -> void:
	var kind := int(link["kind"])
	if not FOLLOWED.has(kind):
		return
	var from: Vector3 = link["from"]
	var to: Vector3 = link["to"]
	var a := polygon_at(from)
	var b := polygon_at(to)
	if a < 0 or b < 0 or a == b or _blocked.has(a) or _blocked.has(b):
		return
	if _avoid.is_valid() and (bool(_avoid.call(from)) or bool(_avoid.call(to))):
		return
	var id := _polygons.size() + index
	_graph.add_point(id, (from + to) * 0.5, float(WEIGHTS[kind]))
	_graph.connect_points(a, id, false)
	_graph.connect_points(id, b, false)
	_adj[a].append(b)
	link_edges += 1
	_linked.append({"id": id, "from": from, "to": to, "kind": kind})


# --- The way ---------------------------------------------------------------------

func _plan() -> void:
	var from := polygon_at(_start)
	if from < 0:
		from = _nearest_centre(_start, 8.0)
	if from < 0:
		var nearest := INF
		for c in _centres:
			nearest = minf(nearest, c.distance_to(_start))
		_fail("the spawn is not on the mesh (start %s, %d polygons, nearest centre %.2f m, %d buckets)" % [_start, _polygons.size(), nearest, _grid.size()])
		return
	var goal := polygon_at(_goal)
	var reach := _reachable(from)
	reachable_count = reach.size()
	reached_goal = goal >= 0 and reach.has(goal)
	if not reached_goal:
		goal = _nearest_reachable(from)
	if goal < 0:
		_fail("nothing reachable")
		return
	var ids := _graph.get_id_path(from, goal)
	points = _points_for(ids)
	phase_ms["plan"] = _lap()
	state = State.READY
	DotLog.info(CHANNEL, "bots have a route", {
		"points": points.size(), "reached_goal": reached_goal, "from_cache": from_cache,
		"links": annotations.link_counts(), "phases_ms": phase_ms, "worst_step_ms": snappedf(worst_step_ms, 0.1)})


## Every polygon [param from] reaches over walks and links, as a dictionary of polygon -> true.
func _reachable(from: int) -> Dictionary:
	var seen := {from: true}
	var queue: Array[int] = [from]
	var head := 0
	while head < queue.size():
		var at: int = queue[head]
		head += 1
		for next: int in _adj[at]:
			if not seen.has(next) and not _blocked.has(next):
				seen[next] = true
				queue.append(next)
	return seen


## The reachable polygon nearest the goal, by the flat distance with a quarter of the height
## (a goal above a floor is further than one beside it).
func _nearest_reachable(from: int) -> int:
	var best := -1
	var best_d := INF
	for i: int in _reachable(from):
		var c := _centres[i]
		var d := Vector2(c.x - _goal.x, c.z - _goal.z).length() + absf(c.y - _goal.y) * 0.25
		if d < best_d:
			best_d = d
			best = i
	return best


## Route-bot points for [param ids], a path of polygons and link nodes: a link becomes its ledge
## and its landing, a walk is thinned to the points a straight line would cut.
func _points_for(ids: PackedInt64Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var walk: Array[Vector3] = []
	var count := _polygons.size()
	for id in ids:
		if id < count:
			walk.append(_centres[id])
			continue
		var link: Dictionary = {}
		for l in _linked:
			if int(l["id"]) == id:
				link = l
				break
		if link.is_empty():
			continue
		_flush(walk, out, link["from"])
		var ledge := _point(link["from"], LEDGE_RADIUS, false)
		ledge["hop"] = int(link["kind"]) == DotNpcAiNavAnnotations.LINK_JUMP_GAP
		out.append(ledge)
		out.append(_point(link["to"], LANDING_RADIUS, int(link["kind"]) == DotNpcAiNavAnnotations.LINK_DROP))
		walk = []
	_flush(walk, out, Vector3.INF)
	return out


## Thinned [param walk] appended to [param out]; the first point is dropped when it is where the
## last link landed, and a trailing walk that ends at a link's ledge is dropped at the ledge.
func _flush(walk: Array[Vector3], out: Array[Dictionary], _until: Vector3) -> void:
	if walk.size() < 2:
		return
	for p in _thin(walk):
		out.append(_point(p, WALK_RADIUS, false))


## Douglas-Peucker: the points a polyline needs to stay within [constant TOLERANCE] of itself.
func _thin(line: Array[Vector3]) -> Array[Vector3]:
	var keep := PackedByteArray()
	keep.resize(line.size())
	keep[0] = 1
	keep[line.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, line.size() - 1)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var far := -1
		var far_d := TOLERANCE
		for i in range(span.x + 1, span.y):
			var seg := Geometry3D.get_closest_point_to_segment(line[i], line[span.x], line[span.y])
			var d := seg.distance_to(line[i])
			if d > far_d:
				far_d = d
				far = i
		if far >= 0:
			keep[far] = 1
			stack.append(Vector2i(span.x, far))
			stack.append(Vector2i(far, span.y))
	var out: Array[Vector3] = []
	for i in range(line.size()):
		if keep[i] == 1:
			out.append(line[i])
	return out


static func _point(at: Vector3, radius: float, walk: bool) -> Dictionary:
	return {"at": at, "radius": radius, "max": 0.0, "walk": walk, "hop": false, "land": true, "door": false}


func describe() -> Dictionary:
	return {
		"state": State.keys()[state].to_lower(), "points": points.size(), "reached_goal": reached_goal,
		"from_cache": from_cache, "reachable": reachable_count, "blocked": _blocked.size(), "link_edges": link_edges, "polygons": _polygons.size(), "phases_ms": phase_ms, "worst_step_ms": snappedf(worst_step_ms, 0.1), "worst_by_phase": worst_by_phase,
		"links": annotations.link_counts() if annotations != null else {}, "failure": failure,
	}
