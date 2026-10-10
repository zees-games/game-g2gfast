extends RefCounted

const G2GUnits := preload("g2g_units.gd")

## What an imported map's brush entities DO to a player, run once a tick.
##
## `tools/bsp_mechanics.py` reads them out of the .bsp into the manifest's `mechanics`
## block; this is the other half. Every volume is an [AABB] in metres, and every
## question is a box test against the player's own hull, for the reason
## [DotFpsSwimMode] gives: an [Area3D] answers after the physics step on the main loop,
## and a client replaying ten ticks of prediction cannot ask one where it WAS. A box list
## gives the server and the client's replay the same answer for the same state.
##
## What it runs, and how faithfully:
##
## - [b]A push[/b] (`trigger_push`) is the engine's base velocity: while the hull is
##   inside, the player is displaced by the push on top of their own velocity, which
##   gravity and friction never touch; on leaving, the push is added to the velocity, so
##   a booster sends you on at its speed. A "once" push is added on entering, and a
##   "leave" one on leaving: the genre's jump pad, a thin trigger on a block's top whose
##   OnEndTouch sets the player's base velocity, so jumping off it launches and standing
##   on it does not. An upward push lifts a player off the ground. What the player was pushed by last tick is kept
##   per TICK rather than per call, so a client replaying a tick reads the same "last
##   tick" the server did.
## - [b]Gravity[/b] (`trigger_gravity`) scales the fall while airborne inside.
## - [b]A conveyor[/b] (`func_conveyor`) carries a player standing on its top.
## - [b]Water[/b] is [DotFpsSwimMode]'s; [member water] is what it is handed.
## - [b]A sinking block[/b] (a touch-opened `func_door` over a teleport) is timed PER
##   PLAYER: stand on it longer than its delay and [method simulate] says so, and the game
##   sends that player where the plate under it would have. The door never moves, so a
##   player landing on a block can never find it already sunk by somebody else.
## - [b]Hurt[/b] (`trigger_hurt`) of 100 or more is a death; less is ignored, because a
##   timer run has no health.

enum Event { NONE, BLOCK_SANK, HURT }

## Damage at or above this is a death in Source (every player has 100).
const LETHAL_DAMAGE := 100.0

## How far a foot may be off a block's top and still be standing on it, metres.
const STAND_TOLERANCE := 3.0 * G2GUnits.METRES_PER_UNIT

## How far below the feet a volume still touches the player, metres.
const TOUCH_BELOW := 2.0 * G2GUnits.METRES_PER_UNIT

## Ticks of push history a rider keeps. A client replays at most this many.
const HISTORY := 256

var water: Array[AABB] = []
var pushes: Array[Dictionary] = []      # {box: AABB, push: Vector3 m/s, once: bool, leave: bool}
var gravity: Array[Dictionary] = []     # {box, scale}
var hurt: Array[Dictionary] = []        # {box, damage}
var conveyors: Array[Dictionary] = []   # {box, push}
var blocks: Array[Dictionary] = []      # {box, delay, destination, yaw}
var ladders: Array[AABB] = []


## One player's memory of the volumes: which pushes held them on which tick, and which
## block they are standing on and since when.
class Rider:
	extends RefCounted
	var pushed: Dictionary = {}     # tick -> [Vector3 base push, PackedInt32Array once ids]
	var block: int = -1
	var block_time: float = 0.0
	## The block or hurt volume [method G2GMapMechanics.simulate] last reported.
	var last_index: int = -1

	func reset() -> void:
		pushed.clear()
		block = -1
		block_time = 0.0


## Reads the manifest's `mechanics` block. A manifest written before there was one reads
## as nothing, which is what such a map has always had.
func read(manifest: Dictionary) -> void:
	var block: Dictionary = manifest.get("mechanics", {})
	for v: Variant in block.get("water", []):
		water.append(_box(v))
	for v: Variant in block.get("ladders", []):
		ladders.append(_box(v))
	for v: Variant in block.get("push", []):
		var d: Dictionary = v
		pushes.append({"box": _box(d), "push": G2GUnits.vector_to_metres(_vec(d.get("push"))),
			"once": bool(d.get("once", false)), "leave": bool(d.get("leave", false))})
	for v: Variant in block.get("gravity", []):
		var d: Dictionary = v
		gravity.append({"box": _box(d), "scale": float(d.get("scale", 1.0))})
	for v: Variant in block.get("hurt", []):
		var d: Dictionary = v
		hurt.append({"box": _box(d), "damage": float(d.get("damage", 0.0))})
	for v: Variant in block.get("conveyors", []):
		var d: Dictionary = v
		conveyors.append({"box": _box(d), "push": G2GUnits.vector_to_metres(_vec(d.get("push")))})
	for v: Variant in block.get("blocks", []):
		var d: Dictionary = v
		blocks.append({"box": _box(d), "delay": float(d.get("delay", 0.1)), "touch": bool(d.get("touch", false)),
			"destination": G2GUnits.vector_to_metres(_vec(d.get("destination"))),
			"yaw": float(d.get("destination_yaw", 0.0))})


func is_empty() -> bool:
	return water.is_empty() and pushes.is_empty() and gravity.is_empty() and hurt.is_empty() \
		and conveyors.is_empty() and blocks.is_empty()


## One tick of the volumes on [param state], after the motor has moved it. Returns an
## [enum Event] the game acts on (a block that sank, a lethal hurt); the index of the
## block or hurt volume is in [member Rider.last_index].
func simulate(rider: Rider, motor: DotFpsMotor, state: DotFpsState, delta: float) -> Event:
	if motor == null or state.mode == DotFpsState.Mode.NOCLIP:
		rider.reset()
		return Event.NONE

	var tunables := motor.tunables
	var height := tunables.height_at(state.crouch_fraction)
	var r := tunables.radius
	# Two units under the feet as well: a trigger lying ON the floor (surf_fruits' pushes
	# are 1-unit sheets) is touched by a player standing on it, and a box test of the hull
	# alone only grazes it. The same two units RNGFix gives a landing player, for the same
	# reason: a thin ground trigger must not be missable by standing exactly on its top.
	var reach := TOUCH_BELOW
	var hull := AABB(state.position - Vector3(r, reach, r), Vector3(r * 2.0, height + reach, r * 2.0))

	_pushes(rider, motor, state, hull, delta)

	if not state.is_grounded():
		for g: Dictionary in gravity:
			if (g["box"] as AABB).intersects(hull):
				state.velocity.y += (1.0 - float(g["scale"])) * tunables.gravity * delta
				break
	else:
		for c: Dictionary in conveyors:
			if _standing_on(c["box"], state.position, r):
				_displace(motor, state, c["push"], delta)
				break

	for i in hurt.size():
		var h: Dictionary = hurt[i]
		if float(h["damage"]) >= LETHAL_DAMAGE and (h["box"] as AABB).intersects(hull):
			rider.last_index = i
			rider.block = -1
			return Event.HURT

	return _blocks(rider, state, r, hull, delta)


func _impulse(motor: DotFpsMotor, state: DotFpsState, push: Vector3) -> void:
	state.velocity += push
	if push.y > 0.0 and state.is_grounded():
		motor.set_mode(state, DotFpsState.Mode.AIR)


func _pushes(rider: Rider, motor: DotFpsMotor, state: DotFpsState, hull: AABB, delta: float) -> void:
	if pushes.is_empty():
		return
	var base := Vector3.ZERO
	var once := PackedInt32Array()
	for i in pushes.size():
		var p: Dictionary = pushes[i]
		if not (p["box"] as AABB).intersects(hull):
			continue
		if p["once"]:
			once.append(i)
		else:
			base += p["push"]

	var before: Array = rider.pushed.get(state.tick - 1, [Vector3.ZERO, PackedInt32Array()])
	var was: Vector3 = before[0]
	var was_once: PackedInt32Array = before[1]

	for i in once:
		if not was_once.has(i) and not pushes[i]["leave"]:
			_impulse(motor, state, pushes[i]["push"])
	for i in was_once:
		# The ids are the last tick's; a map change in between can leave one past the end.
		if i < pushes.size() and not once.has(i) and pushes[i]["leave"]:
			_impulse(motor, state, pushes[i]["push"])

	if base != Vector3.ZERO:
		if base.y > 0.0 and state.is_grounded():
			motor.set_mode(state, DotFpsState.Mode.AIR)
		_displace(motor, state, base, delta)
	elif was != Vector3.ZERO:
		# Out of it this tick: the base velocity becomes the player's own, which is what
		# makes a booster a booster rather than a moving walkway.
		state.velocity += was

	if base != Vector3.ZERO or not once.is_empty():
		rider.pushed[state.tick] = [base, once]
	else:
		rider.pushed.erase(state.tick)
	if rider.pushed.size() > HISTORY:
		for t: Variant in rider.pushed.keys():
			if int(t) < state.tick - HISTORY:
				rider.pushed.erase(t)


## Moves [param state] by [param velocity] for one tick through the motor's own sweep,
## leaving the player's own velocity as it was: a base velocity is not the player's.
func _displace(motor: DotFpsMotor, state: DotFpsState, velocity: Vector3, delta: float) -> void:
	var own := state.velocity
	state.velocity = velocity
	motor.move_and_slide(state, delta)
	state.velocity = own


func _blocks(rider: Rider, state: DotFpsState, r: float, hull: AABB, delta: float) -> Event:
	if blocks.is_empty() or not state.is_grounded():
		rider.block = -1
		rider.block_time = 0.0
		return Event.NONE

	var on := -1
	for i in blocks.size():
		var b: Dictionary = blocks[i]
		# A door block is stood ON (its top); a trap is the map's own teleport volume over
		# a block, so it is touched: the grounded hull in it, two units under the feet too.
		if b["touch"]:
			if (b["box"] as AABB).intersects(hull):
				on = i
				break
		elif _standing_on(b["box"], state.position, r * 0.9):
			on = i
			break

	if on < 0:
		rider.block = -1
		rider.block_time = 0.0
		return Event.NONE

	if on != rider.block:
		rider.block = on
		rider.block_time = 0.0
	rider.block_time += delta

	if rider.block_time >= float(blocks[on]["delay"]):
		rider.last_index = on
		rider.block = -1
		rider.block_time = 0.0
		return Event.BLOCK_SANK
	return Event.NONE


func _standing_on(box: AABB, feet: Vector3, reach: float) -> bool:
	var top := box.end.y
	if absf(feet.y - top) > STAND_TOLERANCE:
		return false
	return feet.x > box.position.x - reach and feet.x < box.end.x + reach \
		and feet.z > box.position.z - reach and feet.z < box.end.z + reach


static func _box(v: Variant) -> AABB:
	var d: Dictionary = v
	var lo := G2GUnits.vector_to_metres(_vec(d.get("min")))
	var hi := G2GUnits.vector_to_metres(_vec(d.get("max")))
	return AABB(lo, hi - lo).abs()


static func _vec(a: Variant) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"water %d, pushes %d, gravity %d, hurt %d, conveyors %d, blocks %d, ladders %d"
			% [water.size(), pushes.size(), gravity.size(), hurt.size(), conveyors.size(),
				blocks.size(), ladders.size()],
	])
