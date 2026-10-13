extends RefCounted

## A player's own movement, run ahead of time on a copy of their state: the simulator a
## surf bot plans with and checks its next half-second against.
##
## [b]Why the real motor and not a model of it.[/b] Surfing is the motor's clip-and-
## air-accelerate rule meeting a map's collision, tick by tick; a re-implementation is a
## second copy of that rule that drifts, and a bot planned on the copy falls off the
## original. [DotFpsMotor] is deterministic and query-only (its [DotFpsPhysicsBody] reads
## the physics space and never moves anything), so a second motor over the same space,
## the same tunables and the same modifiers is the game itself, with nothing to drift.
## `headless_imported`'s surf section checks the three properties this depends on: a
## simulated tick leaves the live player, its motor and its controller untouched; the same
## start and inputs give the same end; and the simulation's end is where the live player
## ends after the same commands.
##
## [b]What it does not copy.[/b] The motor only. The game's volume modes (water, ladders)
## are not registered, so a simulated player in water or on a ladder moves as if in air;
## the map's mechanics (pushes, gravity volumes, conveyors, lethal hurt) are run when
## [member mechanics] is set, on a rider of the simulation's own. Neither lies on a surf
## ride on the maps this has been run on; a map whose line goes through a booster needs
## [member mechanics], and one through water needs the modes.
##
## [b]The action vocabulary is relative to the velocity.[/b] An action is a wish
## direction at an angle to where the player is going (or, nearly standing still, to a
## reference yaw), with the view kept along the velocity and the angle made with the
## strafe and forward keys. Relative, because the same action means the same thing on
## the left face of a ramp at 600 u/s and at 900 u/s, which is what lets one recorded
## action be reused from a nearby state; with the view along the velocity, because that
## is what a player watching the bot expects to see.

const G2GMapMechanics := preload("g2g_map_mechanics.gd")

enum Event {
	NONE,
	## Inside the goal (the next stage's line, the door to it, or the finish).
	GOAL,
	## Inside a pit (a RESPAWN or SLAY zone), a lethal hurt volume or a door that does not
	## lead to the goal.
	PIT,
	## Below the lowest point the course allows.
	BELOW,
}

## Below this horizontal speed (m/s, about 60 u/s) the velocity has no direction worth
## steering by, and an action is taken relative to the reference yaw instead.
const HEADING_SPEED := 1.143

## The actions, by index: [angle off the heading in degrees (+ is left), jump]. NAN is
## no movement key at all. Index 0 is coasting. Kept short on purpose: every action is a
## branch of the planner's search and a candidate in the pilot's veto.
const ACTIONS: Array = [
	[NAN, false],
	[-90.0, false], [-60.0, false], [-30.0, false], [0.0, false],
	[30.0, false], [60.0, false], [90.0, false],
	[0.0, true],
]

var motor: DotFpsMotor = null
var body: DotFpsPhysicsBody = null
var delta := 1.0 / 128.0
## `func(position: Vector3) -> Event`: where the course says a position is. Unset, every
## position is [constant Event.NONE].
var oracle: Callable = Callable()
## The map's volumes, run after each motor tick on [member rider]. Null for none.
var mechanics: G2GMapMechanics = null
var rider := G2GMapMechanics.Rider.new()
## Motor ticks this simulator has run, and the microseconds they took: the compute cost.
var steps := 0
var usec := 0


## A simulator for the player [param controller] moves, over the physics space
## [param node] is in, at [param tick_rate] ticks a second.
static func for_controller(controller: DotFpsController, node: Node3D, tick_rate: int) -> RefCounted:
	var sim: RefCounted = (load("res://game/g2g_surf_sim.gd") as GDScript).new()
	sim.setup(controller.tunables, controller.motor, controller.body as DotFpsPhysicsBody, node, tick_rate)
	return sim


## Builds the motor. [param live_motor] and [param live_body] are read for what this one
## must share with them (the modifiers in order, the collision masks and the excluded
## collider) and never written.
func setup(tunables: DotFpsTunables, live_motor: DotFpsMotor, live_body: DotFpsPhysicsBody,
		node: Node3D, tick_rate: int) -> void:
	body = DotFpsPhysicsBody.new()
	body.collision_mask = tunables.collision_mask
	if live_body != null:
		body.pass_out_mask = live_body.pass_out_mask
		body.exclude = live_body.exclude.duplicate()
	var _bound := body.bind(node)
	# A copy: the controller re-gates abilities on its tunables every tick, and nothing a
	# simulation does may reach the live player's.
	motor = DotFpsMotor.new(tunables.duplicate() as DotFpsTunables, body)
	motor.set_tick_rate(tick_rate)
	delta = 1.0 / float(maxi(tick_rate, 1))
	if live_motor != null:
		var i := 0
		while live_motor.modifier_at(i) != null:
			var _id := motor.register_modifier(live_motor.modifier_at(i))
			i += 1


## One tick of [param state] (changed in place) under [param command]; where it ended.
func step(state: DotFpsState, command: DotFpsCommand) -> Event:
	var began := Time.get_ticks_usec()
	motor.simulate(state, command, delta)
	var event := Event.NONE
	if mechanics != null and mechanics.simulate(rider, motor, state, delta) == G2GMapMechanics.Event.HURT:
		event = Event.PIT
	steps += 1
	usec += Time.get_ticks_usec() - began
	if event == Event.NONE and oracle.is_valid():
		event = oracle.call(state.position)
	return event


## The direction the player is going, as a yaw: the velocity's, or [param reference]
## when there is too little of it to have one.
static func heading_of(state: DotFpsState, reference: float) -> float:
	var flat := Vector2(state.velocity.x, state.velocity.z)
	if flat.length() < HEADING_SPEED:
		return reference
	return rad_to_deg(atan2(-flat.x, -flat.y))


## The command for action [param action] from [param state]. With the view at the heading
## (yaw h), forward is (-sin h, -cos h) and right is (cos h, -sin h); a wish at angle a to
## the left of it is forward*cos(a) - right*sin(a), so the keys are (-sin a, cos a).
static func command_for(action: int, state: DotFpsState, reference: float) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	var row: Array = ACTIONS[action]
	c.yaw = heading_of(state, reference)
	var angle: float = row[0]
	if not is_nan(angle):
		var a := deg_to_rad(angle)
		c.move = Vector2(-sin(a), cos(a))
	c.set_button(DotFpsCommand.BUTTON_JUMP, bool(row[1]))
	return c
