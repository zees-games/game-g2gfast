extends RefCounted

## Rides a surf stage from what the planner found: it does what the nearest remembered
## state did, and looks a second and a half ahead before trusting that.
##
## [b]The cache is rides.[/b] Every tick of every ride the planner found (from perturbed
## starts, and again from wherever an earlier pilot failed) is an entry: position,
## velocity, the action taken. [method nearest] finds the entry closest to the bot's own
## state -- position, plus velocity times [constant VELOCITY_SECONDS], so a state going
## the wrong way is far from one going the right way at the same place.
##
## [b]Copying the nearest action, once the cache is dense; tracking while it is not.[/b]
## By default the bot takes the nearest entry's action ([method policy]): one grid lookup
## a tick. With only the five rides searched from the starts that arrived from 15 to 25%
## of perturbed starts, because an action is only right for the state it was taken from
## and a bot a little off the line repeats a little-off action until it is far off it.
## [member tracking] fixes that for a sparse cache: every [member track_every] ticks it
## tries each action on the simulator for that many ticks and takes the one ending
## nearest where the remembered ride was that many ticks later, keeping to one ride
## ([method _follow]); it went to 50 to 80%. But once the repair rounds have filled the
## cache (twenty-six rides on surf_beginner stage 1) copying beats tracking, 92% against
## 72% of fifty perturbed starts, at half the cost: a dense cache already has an entry
## from nearly every state the bot reaches, and tracking's eight-tick target is a worse
## guide than the action the planner chose there. Tracking costs
## [constant G2GSurfSim.ACTIONS] times [member track_every] motor ticks every
## [member track_every] ticks, nine a tick.
##
## [b]The veto.[/b] Every [member check_every] ticks the pilot also runs the remembered
## actions forward [member horizon] ticks. If that future ends in a pit or below the
## course, it tries every action held for [member check_every] ticks and then the
## remembered ones, and holds the one whose future survives with the best score. The
## idea, simulating the input about to be sent and refusing one whose future is a fall,
## is the classic bot library's move check. The horizon is long because a launch that
## is going to fall short is decided long before it falls: at 96 ticks, 118 of 119
## vetoes found no action that survived.

const G2GSurfSim := preload("g2g_surf_sim.gd")
const G2GUnits := preload("g2g_units.gd")

## Seconds of velocity weighed against one metre of position in the nearest-state lookup.
const VELOCITY_SECONDS := 0.25
## Grid cell for the lookup, metres (128 units).
const CELL := 2.4384
## Floats per entry: x, y, z, vx, vy, vz, action.
const STRIDE := 7

var entries := PackedFloat32Array()
## Per entry: the index one past the last entry of its ride.
var _ride_end := PackedInt32Array()
## Cell (Vector3i) -> PackedInt32Array of entry indices.
var _grid: Dictionary = {}
var reference_yaw := 0.0
## The simulator tracking and the veto run on. Without one the pilot only copies actions.
var sim: RefCounted = null
## `func(state) -> float`, higher is further along. The course's [code]score[/code].
var score: Callable = Callable()

## Ticks each tracked action is held, and whether to track at all.
var track_every := 8
var tracking := false
## How often the future is checked, and how far ahead (ticks).
var check_every := 24
var horizon := 192
## Statistics: futures checked, vetoes taken, how many of those found no way out, and
## motor ticks spent tracking.
var checks := 0
var vetoes := 0
var hopeless := 0

var _override := -1
var _override_left := 0
var _tracked := -1
var _tracked_left := 0
var _following := -1
var _tick := 0


## Builds the lookup from [param data] (the cache file's stage entry, genre units).
func load_stage(data: Dictionary) -> void:
	var rides := PackedFloat32Array()
	for row: Variant in data.get("entries", []):
		var r: Array = row
		var p := G2GUnits.vector_to_metres(Vector3(r[0], r[1], r[2]))
		var v := G2GUnits.vector_to_metres(Vector3(r[3], r[4], r[5]))
		rides.append_array([p.x, p.y, p.z, v.x, v.y, v.z, float(r[6])])
	var lengths := PackedInt32Array()
	for n: Variant in data.get("lengths", []):
		lengths.append(int(n))
	load_entries(rides, lengths, float(data.get("reference_yaw", 0.0)))


## Builds the lookup from rides in metres (the planner's), [param lengths] entries each.
func load_entries(rides: PackedFloat32Array, lengths: PackedInt32Array, yaw: float) -> void:
	# A copy: packed arrays are shared by reference, and the planner keeps appending to
	# the one it hands in, which left the ride ends short of the entries.
	entries = rides.duplicate()
	reference_yaw = yaw
	_ride_end = PackedInt32Array()
	var at := 0
	for n: int in lengths:
		for _i in range(n):
			_ride_end.append(at + n)
		at += n
	while _ride_end.size() < size():
		_ride_end.append(size())
	_grid.clear()
	for i in range(size()):
		var key := _cell(Vector3(entries[i * STRIDE], entries[i * STRIDE + 1], entries[i * STRIDE + 2]))
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		(_grid[key] as PackedInt32Array).append(i)


func size() -> int:
	return entries.size() / STRIDE


## Start over (a new ride): nothing held.
func reset() -> void:
	_override = -1
	_override_left = 0
	_tracked = -1
	_tracked_left = 0
	_following = -1
	_tick = 0


## The index of the entry nearest [param state], or -1 with no entries.
func nearest(state: DotFpsState) -> int:
	var best := -1
	var best_d := INF
	var centre := _cell(state.position)
	for radius in [1, 2]:
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if radius == 2 and absi(dx) < 2 and absi(dy) < 2 and absi(dz) < 2:
						continue
					var bucket: Variant = _grid.get(centre + Vector3i(dx, dy, dz))
					if bucket == null:
						continue
					for i: int in bucket:
						var d := _distance(i, state.position, state.velocity)
						if d < best_d:
							best_d = d
							best = i
		if best >= 0:
			return best
	for i in range(size()):
		var d := _distance(i, state.position, state.velocity)
		if d < best_d:
			best_d = d
			best = i
	return best


## The action the nearest remembered state took, or 0 (coast) with no entries.
func policy(state: DotFpsState) -> int:
	var i := nearest(state)
	return 0 if i < 0 else int(entries[i * STRIDE + 6])


## This tick's command for a player in [param state].
func command(state: DotFpsState) -> DotFpsCommand:
	if _override_left <= 0 and sim != null and horizon > 0 and _tick % check_every == 0:
		_check(state)
	_tick += 1
	var action := -1
	if _override_left > 0:
		action = _override
		_override_left -= 1
	elif tracking and sim != null:
		if _tracked_left <= 0:
			_tracked = _track(state)
			_tracked_left = track_every
		action = _tracked
		_tracked_left -= 1
	else:
		action = policy(state)
	return G2GSurfSim.command_for(action, state, reference_yaw)


## The action whose [member track_every]-tick future ends nearest where the nearest
## remembered ride was that many ticks later. One that reaches the goal wins outright;
## one that falls is never chosen while another does not.
func _track(state: DotFpsState) -> int:
	var i := _follow(state)
	if i < 0:
		return 0
	var target := mini(i + track_every, _ride_end[i] - 1)
	var best := int(entries[i * STRIDE + 6])
	var best_d := INF
	for action in range(G2GSurfSim.ACTIONS.size()):
		var s := state.duplicate_state()
		var event := G2GSurfSim.Event.NONE
		for _t in range(track_every):
			event = sim.step(s, G2GSurfSim.command_for(action, s, reference_yaw))
			if event != G2GSurfSim.Event.NONE:
				break
		if event == G2GSurfSim.Event.GOAL:
			return action
		if event != G2GSurfSim.Event.NONE:
			continue
		var d := _distance(target, s.position, s.velocity)
		if d < best_d:
			best_d = d
			best = action
	return best


## The entry to track from: the next stretch of the ride already being followed, unless
## another ride is much nearer. [b]Sticky, because the rides disagree.[/b] Re-matching to
## the globally nearest entry every 8 ticks hopped between rides on different lines (one
## face of an A-frame ramp and the other, a high line and a low one), and a mix of two
## good lines is a bad one.
func _follow(state: DotFpsState) -> int:
	var anywhere := nearest(state)
	if anywhere < 0 or _following < 0 or _following >= size():
		_following = anywhere
		return anywhere
	var best := -1
	var best_d := INF
	var end := mini(_ride_end[_following], _following + FOLLOW_WINDOW)
	for i in range(_following, end):
		var d := _distance(i, state.position, state.velocity)
		if d < best_d:
			best_d = d
			best = i
	if best < 0 or best_d > SWITCH_RATIO * _distance(anywhere, state.position, state.velocity) + SWITCH_SLACK:
		best = anywhere
	_following = best
	return best


## How far along its ride (entries) the followed entry may move in one look, how much
## nearer (squared distance, times) another ride must be to switch to it, and a floor
## under that in square metres so two rides a few centimetres apart do not trade places.
const FOLLOW_WINDOW := 48
const SWITCH_RATIO := 4.0
const SWITCH_SLACK := 0.25


## Runs the remembered actions [param ticks] ahead from a copy of [param state], first
## holding [param first] for [member check_every] ticks when it is not -1. Returns
## `[survived: bool, score (survived) or ticks survived (fell)]`.
func future(state: DotFpsState, first: int, ticks: int) -> Array:
	var s := state.duplicate_state()
	for t in range(ticks):
		var action := first if first >= 0 and t < check_every else policy(s)
		var event: int = sim.step(s, G2GSurfSim.command_for(action, s, reference_yaw))
		if event == G2GSurfSim.Event.GOAL:
			return [true, INF]
		if event != G2GSurfSim.Event.NONE:
			return [false, float(t)]
	return [true, float(score.call(s)) if score.is_valid() else 0.0]


func _check(state: DotFpsState) -> void:
	checks += 1
	var plain := future(state, -1, horizon)
	if bool(plain[0]):
		return
	vetoes += 1
	var best := -1
	var best_score := -INF
	var longest := -1
	var longest_t := -1.0
	for action in range(G2GSurfSim.ACTIONS.size()):
		var f := future(state, action, horizon)
		if bool(f[0]):
			if float(f[1]) > best_score:
				best_score = float(f[1])
				best = action
		elif float(f[1]) > longest_t:
			longest_t = float(f[1])
			longest = action
	if best < 0:
		# No way out in sight: put the fall off as long as possible, which is the most
		# time for the next check to find one.
		hopeless += 1
		best = longest
	if best >= 0:
		_override = best
		_override_left = check_every
		_tracked_left = 0


## Rides from [param start] (not changed) on [param ride_sim] for at most
## [param max_ticks]. Returns `{"event": Event, "ticks": int, "trail": Array of
## DotFpsState}`, the trail a copy of the state every [param keep_every] ticks (the first
## is the start), which is where the planner's repair starts looking from.
func ride(start: DotFpsState, ride_sim: RefCounted, max_ticks: int, keep_every: int = 16) -> Dictionary:
	reset()
	var s := start.duplicate_state()
	var trail: Array[DotFpsState] = []
	var event := G2GSurfSim.Event.NONE
	var t := 0
	while t < max_ticks and event == G2GSurfSim.Event.NONE:
		if t % keep_every == 0:
			trail.append(s.duplicate_state())
		event = ride_sim.step(s, command(s))
		t += 1
	return {"event": event, "ticks": t, "trail": trail}


func _distance(i: int, position: Vector3, velocity: Vector3) -> float:
	var o := i * STRIDE
	var dp := Vector3(entries[o], entries[o + 1], entries[o + 2]) - position
	var dv := (Vector3(entries[o + 3], entries[o + 4], entries[o + 5]) - velocity) * VELOCITY_SECONDS
	return dp.length_squared() + dv.length_squared()


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL)))


## A ride's entries as the cache file keeps them: genre units, a tenth of a unit.
static func entries_to_rows(rides: PackedFloat32Array) -> Array:
	var rows: Array = []
	for i in range(rides.size() / STRIDE):
		var o := i * STRIDE
		var p := G2GUnits.vector_to_units(Vector3(rides[o], rides[o + 1], rides[o + 2]))
		var v := G2GUnits.vector_to_units(Vector3(rides[o + 3], rides[o + 4], rides[o + 5]))
		rows.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1), snappedf(p.z, 0.1),
			snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1), int(rides[o + 6])])
	return rows
