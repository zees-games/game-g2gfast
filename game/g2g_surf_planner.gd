extends RefCounted

## Finds a way down a surf stage by trying inputs on the real motor, offline.
##
## [b]A beam search over held actions.[/b] From the start, every action in
## [constant G2GSurfSim.ACTIONS] is held for [member hold] ticks on a copy of each state
## in the beam; a child that enters a pit or falls below the course is dropped, one that
## reaches the goal ends the search, and the rest are ranked by the course's score
## (progress plus energy) and cut back to [member width]. All children are the same age,
## so the first to arrive is the fastest the beam found.
##
## [b]One survivor per cell.[/b] Without it the beam fills with forty copies of the one
## line that is ahead right now -- all on the same face, a unit apart -- and when that
## line turns out to end in a pit there is nothing else left. Children are bucketed by
## position (a [member cell]-unit grid), speed and whether they are on the ground, and
## only the best of each bucket survives, which keeps the other face and the slower,
## higher lines alive long enough to be needed.
##
## This is the search the study (`game-dev/docs/surf-bots-study.md`) recommends: the
## motor is deterministic, so a found sequence of actions is a proof, and the cost is
## paid once per map, not per bot.

const G2GSurfPilot := preload("g2g_surf_pilot.gd")
const G2GSurfSim := preload("g2g_surf_sim.gd")
const G2GUnits := preload("g2g_units.gd")

## Beam width: states kept after each step.
var width := 32
## Ticks each action is held.
var hold := 8
## Bucket size in units for the one-per-cell rule, and speed bucket in u/s.
var cell := 48.0
var speed_bucket := 100.0
## Give up after this many seconds of simulated ride.
var seconds := 20.0
## Ranked children examined per step, for the report.
var expanded := 0


## Searches from [param start] (not changed). Returns `{"found": bool, "actions":
## PackedByteArray (one per held step), "ticks": int (to the goal), "why": String}`.
func search(start: DotFpsState, course: RefCounted, sim: RefCounted) -> Dictionary:
	var reference: float = course.reference_yaw()
	var beam: Array = [{"state": start.duplicate_state(), "actions": PackedByteArray(), "score": 0.0}]
	var steps := int(seconds / (sim.delta * float(hold)))
	var deaths := 0
	for depth in range(steps):
		var best: Dictionary = {}
		for node: Dictionary in beam:
			for action in range(G2GSurfSim.ACTIONS.size()):
				var s: DotFpsState = (node["state"] as DotFpsState).duplicate_state()
				var event := G2GSurfSim.Event.NONE
				var t := 0
				while t < hold:
					event = sim.step(s, G2GSurfSim.command_for(action, s, reference))
					t += 1
					if event != G2GSurfSim.Event.NONE:
						break
				expanded += 1
				var actions: PackedByteArray = (node["actions"] as PackedByteArray).duplicate()
				actions.append(action)
				if event == G2GSurfSim.Event.GOAL:
					return {"found": true, "actions": actions, "ticks": depth * hold + t, "why": ""}
				if event != G2GSurfSim.Event.NONE:
					deaths += 1
					continue
				var key := _key(s)
				var score: float = course.score(s)
				if not best.has(key) or float(best[key]["score"]) < score:
					best[key] = {"state": s, "actions": actions, "score": score}
		if best.is_empty():
			return {"found": false, "actions": PackedByteArray(), "ticks": depth * hold,
				"why": "every line ended in a pit after %.2f s (%d deaths)" % [depth * hold * sim.delta, deaths]}
		var ranked: Array = best.values()
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
		beam = ranked.slice(0, width)
	return {"found": false, "actions": PackedByteArray(), "ticks": steps * hold,
		"why": "no line reached the goal in %.0f s" % seconds}


## The ride [param actions] makes from [param start], tick by tick, until it reaches the
## goal: `{"entries": PackedFloat32Array (x, y, z, vx, vy, vz, action per tick, metres),
## "ticks": int, "event": Event}`. The search's answer replayed, which is the same ride
## because the motor is deterministic, and what the pilot learns from.
static func trajectory(start: DotFpsState, actions: PackedByteArray, hold_ticks: int, course: RefCounted, sim: RefCounted) -> Dictionary:
	var reference: float = course.reference_yaw()
	var s := start.duplicate_state()
	var entries := PackedFloat32Array()
	var event := G2GSurfSim.Event.NONE
	var ticks := 0
	for action: int in actions:
		for _t in range(hold_ticks):
			entries.append_array([s.position.x, s.position.y, s.position.z,
				s.velocity.x, s.velocity.y, s.velocity.z, float(action)])
			event = sim.step(s, G2GSurfSim.command_for(action, s, reference))
			ticks += 1
			if event != G2GSurfSim.Event.NONE:
				return {"entries": entries, "ticks": ticks, "event": event}
	return {"entries": entries, "ticks": ticks, "event": event}


func _key(s: DotFpsState) -> Vector4i:
	var u := G2GUnits.vector_to_units(s.position) / cell
	return Vector4i(int(floor(u.x)), int(floor(u.y)), int(floor(u.z)),
		int(G2GUnits.to_units(s.velocity.length()) / speed_bucket) * 2 + (1 if s.is_grounded() else 0))


## Builds a stage's cache: a ride searched from each of [param starts], then up to
## [param rounds] rounds of repair. A round rides the pilot (on what is in the cache so
## far, veto and all) from each of [param repairs] on [param ride_sim]; for every ride that
## does not arrive it searches again from the state [constant REPAIR_BACK] ticks before
## the failure (then twice that, then the ride's start) and adds what it finds. The
## cache grows exactly where the pilot goes wrong -- the states its own mistakes lead
## to, which no search from the start ever visits -- and stops growing when a round
## fails nowhere. [param say] gets one line per search.
##
## Returns `{"rides": PackedFloat32Array (the entries), "lengths": PackedInt32Array
## (entries per ride), "seconds": Array (each ride's
## length), "searches": int, "found": int, "rounds": Array (failures per round)}`.
func build(starts: Array, repairs: Array, rounds: int, course: RefCounted, sim: RefCounted,
		ride_sim: RefCounted, say: Callable) -> Dictionary:
	var rides := PackedFloat32Array()
	var seconds: Array = []
	var lengths := PackedInt32Array()
	var searches := 0
	var found_count := 0
	var per_round: Array = []
	for i in range(starts.size()):
		searches += 1
		var t0 := Time.get_ticks_msec()
		var ride := _search_ride(starts[i], course, sim)
		if ride.is_empty():
			say.call("start %d: no ride, %.1f s searching" % [i, (Time.get_ticks_msec() - t0) / 1000.0])
			continue
		found_count += 1
		rides.append_array(ride["entries"])
		lengths.append(int(ride["ticks"]))
		seconds.append(snappedf(float(ride["ticks"]) * sim.delta, 0.01))
		say.call("start %d: a ride of %.2f s, %.1f s searching" % [i, float(ride["ticks"]) * sim.delta, (Time.get_ticks_msec() - t0) / 1000.0])
	var max_ticks := int(seconds_limit() / sim.delta)
	for round in range(rounds):
		var pilot := G2GSurfPilot.new()
		pilot.load_entries(rides, lengths, course.reference_yaw())
		pilot.sim = sim
		pilot.score = course.score
		var failures := 0
		for j in range(repairs.size()):
			var r: Dictionary = pilot.ride(repairs[j], ride_sim, max_ticks)
			if int(r["event"]) == G2GSurfSim.Event.GOAL:
				continue
			failures += 1
			var trail: Array = r["trail"]
			var at := trail.size() - 1
			for back in [REPAIR_BACK, REPAIR_BACK * 2, 1 << 30]:
				var k := maxi(0, at - back / 16)
				searches += 1
				var t0 := Time.get_ticks_msec()
				var ride := _search_ride(trail[k], course, sim)
				if ride.is_empty():
					if k == 0:
						say.call("round %d, ride %d: failed and no ride from its start either" % [round, j])
						break
					continue
				found_count += 1
				rides.append_array(ride["entries"])
				lengths.append(int(ride["ticks"]))
				seconds.append(snappedf(float(ride["ticks"]) * sim.delta, 0.01))
				# The next ride of this round already learns from this repair.
				pilot.load_entries(rides, lengths, course.reference_yaw())
				say.call("round %d, ride %d: %s at %.2f s; a ride of %.2f s from %.2f s in, %.1f s searching" % [
					round, j, "fell" if int(r["event"]) != G2GSurfSim.Event.NONE else "stalled",
					float(r["ticks"]) * sim.delta, float(ride["ticks"]) * sim.delta, float(k * 16) * sim.delta,
					(Time.get_ticks_msec() - t0) / 1000.0])
				break
		per_round.append(failures)
		say.call("round %d: %d of %d rides failed; the cache has %d entries" % [round, failures, repairs.size(), rides.size() / G2GSurfPilot.STRIDE])
		if failures == 0:
			break
	return {"rides": rides, "lengths": lengths, "seconds": seconds, "searches": searches, "found": found_count, "rounds": per_round}


## Ticks back from a failure the repair search starts (a second at 128 Hz).
const REPAIR_BACK := 128


func seconds_limit() -> float:
	return seconds


## One search and its replay, or {} when the search found nothing.
func _search_ride(from: DotFpsState, course: RefCounted, sim: RefCounted) -> Dictionary:
	var found := search(from, course, sim)
	if not bool(found["found"]):
		return {}
	var ride := trajectory(from, found["actions"], hold, course, sim)
	if int(ride["event"]) != G2GSurfSim.Event.GOAL:
		push_error("a found ride did not replay to the goal: the motor is not deterministic")
		return {}
	return ride
