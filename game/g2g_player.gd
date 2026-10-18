extends Node3D

const G2GCamera := preload("g2g_camera.gd")
const G2GConfig := preload("g2g_config.gd")
const G2GLadderMode := preload("g2g_ladder_mode.gd")
const G2GMapMechanics := preload("g2g_map_mechanics.gd")
const G2GMovement := preload("g2g_movement.gd")
const G2GRig := preload("g2g_rig.gd")
const G2GUnits := preload("g2g_units.gd")

## One player: the movement, the rig they are drawn as, the camera they look through,
## and their timer.
##
## [b]The bridge between the addons, which is where the bugs are.[/b] What this file
## alone knows:
##
## - the timer is ticked from the movement loop, after the move, with the position the
##   move produced;
## - a style has two halves and they are applied together;
## - the rig is drawn from the state — crouch, yaw — and never the other way round;
## - a camera mode is cosmetic: the controller aims from the eye whichever is active.
##
## Positions are metres by the time they reach here. Everything genre-unit-shaped
## was converted in [G2GMovement].

const CHANNEL := "g2g.player"

## Whether an admin's help was on last tick, so [method _on_simulated] logs the edge.
var _assisted := false

signal finished(run: DotTimerRun)

## The map did something to this player that the GAME has to finish: a sinking block
## carried them into its plate ([code]G2GMapMechanics.Event.BLOCK_SANK[/code]) or a lethal
## hurt volume killed them ([code]HURT[/code]). [param index] is the block or volume. Fired
## on every machine that simulates the player; only the server acts on it.
signal map_event(event: int, index: int)

## A beacon on this player sent out a ripple: once a second while it is on, and once the
## moment it comes on. Client side, from [method present]; the client plays the ping here.
signal beacon_pulsed(at: Vector3)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Whether a command is sampled from the input devices each tick. The person at the
## keyboard only; a bot and every remote player leave it off.
@export var samples_input: bool = false

## Whether this player owns a camera. Only the local player does; a remote player's
## copy is drawn and never looked through.
@export var has_camera: bool = false

## Whether the person at the keyboard sees their own body in FIRST person.
##
## Off, which is what this genre has always shown and what a runner reading a landing
## off the floor in front of them wants. It is a setting because it is a taste, not a
## rule — `show_own_body` in [G2GPresentation]'s schema — and it changes nothing the
## simulation can see: the head and hat stay culled either way, because those mounts
## are at the eye. See [member G2GRig.owner_sees_head].
var show_own_body: bool = false:
	set(value):
		show_own_body = value
		_apply_own_body()

## What the loaded map's brush entities do: water, pushes, gravity, conveyors, sinking
## blocks, hurt. Set by [method set_mechanics]; null on a map that has none.
var mechanics: G2GMapMechanics = null

## This player's memory of those volumes. See [G2GMapMechanics.Rider].
var rider := G2GMapMechanics.Rider.new()

## Swimming, in the map's water. Registered on every player on every map, the same on
## every machine because the mode's id is on the wire; with no water it is never entered.
var swim := DotFpsSwimMode.new()

## Climbing, on the map's ladders. Registered beside [member swim], for the same reason.
var ladder := G2GLadderMode.new()

var controller: DotFpsController = null

## The motor's velocity, under the name the load gate asks any body for. Without it (and
## [method is_on_floor]) the gate counts this node as already at rest and lifts its cover
## with the body still in the air.
var velocity: Vector3:
	get:
		return controller.state.velocity if controller != null else Vector3.ZERO
var sampler: DotFpsSampler = null
var rig: G2GRig = null
var camera: G2GCamera = null

## This player's timer. Owned by the game's [DotTimerManager].
var timer: DotTimer = null

## How this player's body fell on their last death: the server's pick
## ([method G2GCombat.decide_death]), carried on DEATH to every client. Null before one.
var death: DotPlayerDeath = null

var movement_style: DotFpsStyle = null
var timer_style: DotTimerStyle = null

## Set on a ghost: the player is driven by a replay rather than by commands, and
## its timer is never fed. See [method G2GGame.spawn_ghost].
var replay: DotTimerReplayPlayer = null

## How long a ghost stands at the finish before starting over.
const REPLAY_HOLD_SEC := 2.0

var _replay_hold: float = 0.0
var _replay_previous: Vector3 = Vector3.ZERO
var _replay_moving: bool = false

## The tunables this player was built with, before any style. See [method set_movement].
var base_tunables: DotFpsTunables = null

## The collision layers this player's movement sweeps against.
##
## [b]Not `DotFpsTunables`' default of 1, and it has to be re-applied.[/b] One means
## bit 0, which is right only while every body in the game is on bit 0 — the state a
## layout exists to end. `set_movement` replaces the whole tunables object on every
## `sv_airaccelerate`, so a mask written once at build time is a mask the first cvar
## change silently throws away and a player who walks through every placed block.
var collision_mask: int = 1

var tick_rate: int = 128

## An administrator's `blind`: this player's own screen is blacked out.
##
## [b]Set on the server and replicated to the OWNER ONLY[/b] (`G2GPlayerNet.net_blind`).
## Nobody else's screen changes, so nobody else needs to know. `G2GHud` draws it. It
## changes nothing the simulation can see, so unlike noclip or a speed step it does not
## taint a run: a blinded runner is being made slower, never faster.
var blinded: bool = false

## An administrator's `beacon`: a pulsing ring and a column over this player that every
## client draws, and a ping every client hears, until it is turned off.
##
## Set on the server and replicated to everybody (`G2GPlayerNet.net_beacon`), who each
## draw it in [method present].
var beacon: bool = false

## One of the server's bots (`g2g_bots.gd`): no timer, no statistics, no peer.
var is_bot: bool = false

## The weapon in this player's hand under deathmatch, or empty. Written by `G2GCombat`
## on the authority and replicated to the owner alone (`G2GPlayerNet.net_weapon`), because
## a client has no combat layer and `G2GHud`'s ammunition counter has to name something.
var held_weapon: StringName = &""

## The marker [member beacon] draws, while it does. Client side; built and freed by
## [method present].
var beacon_marker: DotFxBeacon = null


func _ready() -> void:
	if base_tunables == null:
		base_tunables = G2GMovement.tunables_for(G2GConfig.new())

	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL: the game owns the tick, so the timer can be fed the position the move
	# just produced. See game-playground's docs/simulation.md for the ordering argument.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = base_tunables
	# Every player, both ends: an admin's noclip is a modifier whose index travels on the
	# wire. See dot-player-controller's DotFpsAdminModifiers.
	controller.admin_abilities = true
	base_tunables.collision_mask = collision_mask
	# The genre's water, not a sandbox's: 200 u/s at most (its 0.8 of the run speed), and
	# a player who presses nothing sinks at 60 u/s rather than floating up, so a pit full
	# of water is climbed out of by holding jump -- which is how these maps were built.
	swim.swim_speed = G2GUnits.to_metres(200.0)
	swim.idle_sink_speed = G2GUnits.to_metres(60.0)
	swim.accelerate = 10.0
	swim.waist = G2GUnits.to_metres(36.0)
	swim.float_depth = G2GUnits.to_metres(56.0)
	swim.exit_speed = G2GUnits.to_metres(300.0)
	swim.exit_reach = G2GUnits.to_metres(24.0)
	controller.extra_modes = [swim, ladder]
	# body_ref left unset so it resolves to this node. `of_self()` would resolve to
	# the CONTROLLER, a plain Node, and setup() would refuse — the player would then
	# simply never move, with nine failures pointing anywhere but here.
	add_child(controller)

	controller.simulated.connect(_on_simulated)

	rig = G2GRig.new()
	rig.name = "Rig"
	add_child(rig)

	if has_camera:
		camera = G2GCamera.new()
		camera.name = "Camera"
		add_child(camera)

		# [b]Here, and not left to the first [method present].[/b] `visible_to_owner`
		# defaults to true because that is right for everybody else's rig, and the
		# local one was corrected once a frame from `present()` — so the correct value
		# was never the starting value, and any frame `present()` did not finish drew
		# the player's own avatar at point-blank range. `present()` is a `_process`
		# body, where a script error aborts the call and the game carries on, which is
		# exactly how this repository lost its footsteps for a week. Start correct.
		_apply_own_body()

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		DotFpsSampler.register_default_actions(sampler)


# --- Movement and style ----------------------------------------------------

## Hands the player the loaded map's mechanics (null for none). A map change calls this
## for everybody; whatever the last map was doing to them is forgotten.
func set_mechanics(value: G2GMapMechanics) -> void:
	mechanics = value
	rider.reset()
	swim.volumes = value.water if value != null else ([] as Array[AABB])
	ladder.volumes = value.ladders if value != null else ([] as Array[AABB])
	if controller != null and controller.state != null and controller.motor != null \
			and ((controller.state.mode == swim.mode_id and swim.volumes.is_empty())
				or (controller.state.mode == ladder.mode_id and ladder.volumes.is_empty())):
		controller.motor.set_mode(controller.state, DotFpsState.Mode.AIR)


## Hands the player a new base movement, keeping whatever style they are on.
##
## What a cvar change does to every player at once. The controller rebuilds its motor
## from the new base; the run is the game's to abandon, which it does before calling
## this.
func set_movement(tunables: DotFpsTunables) -> DotResult:
	base_tunables = tunables
	controller.tunables = tunables
	# Re-applied, because this is a NEW tunables object: `G2GMovement.tunables_for`
	# builds one from the config and the config has no idea what a collision layer is.
	tunables.collision_mask = collision_mask

	# `set_style` derives from the controller's stored base, which was the OLD
	# tunables. Clearing that lets setup() adopt the new base, and re-applying the
	# style then derives from it — rather than compounding on a base that has moved.
	controller._base_tunables = null

	var result := controller.set_style(movement_style)

	if sampler != null:
		sampler.tunables = controller.tunables

	return result


## Sets which collision layers this player's movement sweeps against.
##
## Called by `G2GGame` once the stack is up, because the layout is the stack's. Applied to
## whatever tunables are current and remembered for the ones `set_movement` builds next.
func use_collision_mask(mask: int) -> void:
	collision_mask = mask

	if controller != null and controller.tunables != null:
		controller.tunables.collision_mask = mask

	if base_tunables != null:
		base_tunables.collision_mask = mask


## Both halves of a style, together.
func set_style(movement: DotFpsStyle, ranking: DotTimerStyle) -> DotResult:
	movement_style = movement
	timer_style = ranking

	if timer != null:
		timer.set_style(ranking)

	var result := controller.set_style(movement)

	if not result.ok:
		DotLog.warn(CHANNEL, "a style did not apply to a player's movement", {
			"player": String(name), "why": result.error.message,
		})

	if sampler != null:
		sampler.tunables = controller.tunables

	return result


## Puts the player somewhere, stopped. Ends their run unless [param keep_run].
##
## [b]Ending the run is right for everything that calls this except one.[/b] A respawn,
## a `!s3`, a checkpoint load and an admin moving somebody are all a player leaving
## the route, and a time that carried across one would not be a time. A map's own
## door is the exception: a `TELEPORT` zone is how a staged map joins one section to
## the next, and it is PART of the route. `G2GGame._on_effect_requested` is the only
## caller that passes true.
func teleport(to: Vector3, yaw: float = INF, keep_run: bool = false) -> void:
	_teleported = true
	controller.state.position = to
	controller.state.velocity = Vector3.ZERO
	# A push the player was in is not one they are in now: without this, leaving it by a
	# teleport (a booster into a stage gate) adds its speed at the far end, and a block
	# being timed carries over to wherever the player lands.
	rider.reset()

	if is_finite(yaw):
		controller.state.yaw = yaw

		if sampler != null:
			sampler.yaw = yaw

	global_position = to

	if timer != null and not keep_run:
		timer.stop(DotTimer.REASON_TELEPORT)


## Whether the motor stands on something. Named for [CharacterBody3D] because that is what
## [DotLoadGate] asks a settling body; see [member velocity].
func is_on_floor() -> bool:
	return controller != null and controller.state.is_grounded()


# --- The tick --------------------------------------------------------------

func simulate(tick: int, delta: float) -> void:
	if replay != null:
		_play_replay(delta)
		return

	# A body the load gate froze is not moved by the game's tick either: the gate switches
	# the node's processing off, which this direct call would walk straight past.
	if not can_process():
		return

	if sampler != null:
		# While the gate settles the body under its cover the keys are off but the body
		# still falls and lands (neutral command), and the sampler is left unread so a
		# mouse turn does not pile up behind the cover.
		if has_meta(DotLoadGate.SETTLING_META):
			controller.apply_command(DotFpsCommand.new())
		else:
			controller.apply_command(sampler.sample(delta))

	controller.simulate_tick(tick, delta)


## A ghost's tick: the replay's pose goes straight into the state, so everything
## that reads the state — the rig, the HUD's speed, the net behaviour — sees a
## player, and nothing that moves one runs.
func _play_replay(delta: float) -> void:
	replay.advance(delta)
	var frame := replay.sample()
	if frame == null:
		return

	var s := controller.state

	# Derived from the last frame, not stored: a replay carries poses, and the speed
	# a HUD or a spectator reads has to come from the difference between two of them.
	# A flag rather than a zero-vector sentinel, because a replay that passes through
	# the world origin is an ordinary replay.
	s.velocity = (
		(frame.position - _replay_previous) / maxf(delta, 0.0001) if _replay_moving
		else Vector3.ZERO
	)
	_replay_moving = true
	_replay_previous = frame.position
	s.position = frame.position
	s.yaw = frame.yaw
	s.pitch = frame.pitch
	global_position = frame.position

	if replay.progress() >= 1.0:
		_replay_hold += delta
		_replay_moving = false
		if _replay_hold >= REPLAY_HOLD_SEC:
			_replay_hold = 0.0
			_replay_moving = false
			replay.seek(0.0)


func _on_simulated(_tick: int, state: DotFpsState) -> void:
	if mechanics != null and replay == null:
		var step := 1.0 / float(maxi(controller.tick_rate, 1))
		var event := mechanics.simulate(rider, controller.motor, state, step)
		# A ladder wins over water, as in the engine these maps are from (its ladder move is
		# asked before its water move): surf_life_of_duck's climb-out pit is four ladder
		# walls over water, and with water asked last a climber was put back to swimming
		# every tick.
		if not swim.volumes.is_empty() and state.mode != ladder.mode_id:
			swim.update(controller.motor, state)
		if not ladder.volumes.is_empty():
			ladder.update(controller.motor, state)
		if event != G2GMapMechanics.Event.NONE:
			map_event.emit(event, rider.last_index)

	global_position = state.position

	if timer == null:
		return

	# [b]An admin's help makes a run assisted, every tick it is on.[/b] Noclip abandons the
	# run it interrupts (`G2GModTools`), but a noclipped player can fly into a start zone
	# and out again and begin a new one — and a speed or gravity step is help on the
	# ground. `taint` is dot-timer's own "assisted" mark, which `can_record` refuses, so
	# the run still finishes and still shows and is simply never filed. Every tick rather
	# than at the moment it is granted, because a run started afterwards has to carry it
	# too. Freeze is not here: it can only cost a runner time.
	if (
		DotFpsAdminModifiers.is_noclipped(controller)
		or not is_equal_approx(DotFpsAdminModifiers.speed_of(controller), 1.0)
		or not is_equal_approx(DotFpsAdminModifiers.gravity_of(controller), 1.0)
	):
		timer.taint()
		# Logged on the edge, not the tick: an operator asking "why was this run not
		# filed" wants the moment the help went on, not 128 lines a second of it.
		if not _assisted:
			_assisted = true
			DotLog.info(CHANNEL, "an admin's help is on this player; their runs are assisted", {
				"player": String(name),
				"noclip": DotFpsAdminModifiers.is_noclipped(controller),
				"speed": DotFpsAdminModifiers.speed_of(controller),
				"gravity": DotFpsAdminModifiers.gravity_of(controller),
			})
	elif _assisted:
		_assisted = false
		DotLog.info(CHANNEL, "an admin's help is off this player", {"player": String(name)})

	if (
		movement_style != null
		and movement_style.prespeed_limit > 0.0
		and timer.in_zone(DotTimerZone.Kind.START)
	):
		state.velocity = DotTimerRules.clamp_prespeed(
			state.velocity, G2GUnits.to_metres(movement_style.prespeed_limit)
		)

	var speed_zone := timer.effect(DotTimerZone.Kind.SPEED_LIMIT)

	if speed_zone != null:
		state.velocity = DotTimerRules.apply_speed_limit(state.velocity, speed_zone)


func fill_sample(sample: DotTimerSample) -> void:
	var state := controller.state
	sample.position = state.position
	sample.velocity = state.velocity
	sample.grounded = state.is_grounded()
	sample.alive = true
	sample.buttons = state.previous_buttons


# --- Drawing ---------------------------------------------------------------

## Draws the state. Per frame, from the client, never from the tick.
##
## [b]The player we drive is drawn BETWEEN ticks, not on them.[/b] The simulation
## steps at [code]sv_tickrate[/code] and the screen does not, so drawing
## [code]controller.state[/code] directly quantises every motion — the camera, the
## eye, the body — to the tick rate. At the browser's 60 frames against a 128-tick
## server that is 2.133 ticks a frame: six frames advance two ticks and the seventh
## advances three, so the view moves 74 mm, 74, 74, 74, 74, 74, 112 and starts over,
## eight times a second. Measured, not reasoned about — see
## [code]examples/jitter_probe.tscn[/code]. It is the whole of the "it is very
## jittery in the browser" report, and it is why the run felt wrong while every
## number on the HUD was right.
##
## [method DotFpsController.render_state] is the cure and has been there since the
## controller was written; nothing called it. See its own note for the second half of
## why — it refused every drive but the one no networked game uses.
##
## Only for a player this machine simulates. A remote player's position arrives
## already interpolated by [DotNetInterpolator] through
## [code]G2GPlayerNet._net_interpolated[/code], and its controller has no second tick
## to blend from: [member has_camera] is the local player in both the offline and the
## networked case, which is exactly the set that is simulated here.
func present(delta: float) -> void:
	var state := controller.render_state() if has_camera else controller.state
	var yaw := state.yaw
	var pitch := state.pitch

	# The view as of THIS frame's mouse, not as of the last tick. See [member view_now].
	if has_camera and view_now != null:
		yaw = (view_now as Vector2).x
		pitch = (view_now as Vector2).y

	rig.set_crouch(state.crouch_fraction)
	rig.move(state, delta)
	rig.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))

	# The rig hangs off this node, which only moves on a tick — so in third person the
	# body would step even with a smooth camera. Written globally rather than by moving
	# this node, because this node is the controller's body and the tick writes it.
	if has_camera:
		rig.global_position = state.position + drawn_offset

	if camera != null:
		var eye := controller.motor.eye_position(state) if controller.motor != null else state.position
		eye += drawn_offset if has_camera else Vector3.ZERO
		camera.global_position = eye
		camera.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
		camera.look(pitch, delta)
		_apply_own_body()

	_present_beacon(delta, state.position)


## Draws [member beacon], and says when it pings.
##
## Placed at the DRAWN position — the render state on the local player, the interpolated
## one on a remote player — for the reason [DotFxBeacon] is top level.
##
## [b]Not hidden on a death, where game-arena's is.[/b] A runner here has no death a
## client can see: the deathmatch layer's health is the server's, a body that dies stays
## where it fell until the respawn a moment later, and the respawn is a teleport of the
## same node — so the flag and the marker simply follow it.
func _present_beacon(delta: float, at: Vector3) -> void:
	if not beacon:
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return

	if beacon_marker == null:
		beacon_marker = _new_beacon_marker()
		beacon_marker.name = "Beacon"
		add_child(beacon_marker)

	beacon_marker.local_view = camera != null
	beacon_marker.global_position = at

	if beacon_marker.advance(delta):
		beacon_pulsed.emit(at)


## The marker, sized to this game's hull: a runner is 32 units across, 0.61 m, and a ring as
## wide as the stock one would read as a mark beside them rather than under them. The column
## starts above a standing runner's head (72 units, 1.37 m) so it never crosses the body.
##
## [b]The ping is off on purpose.[/b] It plays through the game's own dot-audio catalogue
## (`G2GPresentation.BEACON_SOUND`, from [signal beacon_pulsed]), which the volume sliders
## and the hide-others setting already govern; the stock voice would be heard twice and obey
## neither. Red-orange because no prototype texture is, so it reads as a mark on any map.
func _new_beacon_marker() -> DotFxBeacon:
	var marker := DotFxBeacon.new()
	marker.ring_radius = 0.56
	marker.column_height = 14.0
	marker.column_base = 1.7
	marker.colour = Color(1.0, 0.28, 0.18)
	marker.ping_enabled = false
	return marker


## Settles what the owner's own camera draws of their own rig.
##
## Three states rather than two, and the third is the one the setting adds:
##
## [codeblock]
## third person          the whole rig      the camera is behind the head
## first, body on        the body only      the head and hat are AT the eye
## first, body off       nothing            the default, and the genre's
## [/codeblock]
##
## Called from [method present] every frame AND the moment the camera is built, so the
## first value is the right one rather than the first correction. Nobody else's rig
## goes through here: this is only ever the player holding the camera.
func _apply_own_body() -> void:
	if rig == null or camera == null:
		return

	var third := camera.is_third_person()

	# The head before the whole rig, so the single `_apply_visibility` that matters is
	# the one run with both flags already settled.
	rig.owner_sees_head = third
	rig.visible_to_owner = third or show_own_body


func speed() -> float:
	return controller.state.horizontal_speed()


func eye_position() -> Vector3:
	return controller.motor.eye_position(controller.state)


func aim_direction() -> Vector3:
	return DotFpsMotor.aim_for(controller.state.yaw, controller.state.pitch)


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"name": display_name,
		"style": String(movement_style.id) if movement_style != null else "-",
		"speed": "%s u/s" % G2GUnits.format_speed(speed()),
		"view": camera.describe()["mode"] if camera != null else "-",
		"run": str(timer.run) if timer != null else "-",
		"blinded": blinded,
		"beacon": beacon,
	}


## Set by [method teleport], read once by [method replay_flags].
var _teleported: bool = false


## The view to draw this frame, (yaw, pitch) in degrees, or null for the simulated
## state's. Set every frame by the client from `DotFpsSampler.look_now()`.
##
## [b]Because a frame with no tick in it would otherwise not turn.[/b] The state's angles
## change only when a tick runs, and with the display faster than the server's 128 ticks
## some frames run none: at 144 Hz one in nine drew the view where the last frame left it
## while the mouse moved, and the next frame turned twice as far -- 96 frozen and 96
## doubled of 864 in `examples/headless_feel.tscn`, and at 240 Hz it would be nearly every
## other frame. The sampler's angles are the ones the next command will carry, so
## drawing them shows nothing the simulation will not do.
var view_now: Variant = null


## Added to where the local player is drawn this frame: what is left of the last
## prediction corrections, easing to zero. Set every frame by the client from
## `DotNetPredictor.visual_offset`; zero offline.
##
## [b]A correction moves the simulation at once and the eye over a tenth of a second.[/b]
## When a snapshot says the prediction was wrong, the predictor rewinds and replays, and
## the state jumps. Drawn straight, the camera jumps with it: 1 to 30 cm in one frame on
## a lossy link (`examples/headless_feel.tscn`), and a few millimetres on every snapshot
## even on a clean one, because the replay starts from the server's quantised state.
## dot-net has always computed the offset that hides it, and nothing here read it.
var drawn_offset: Vector3 = Vector3.ZERO


## This tick's dot-timer replay flags: ducked, jumped and teleported. A replay declared all
## three from the start and nothing wrote them, so a ghost never crouched or jumped and was
## smeared across every teleport. Read once a tick, by whatever feeds the timer.
func replay_flags() -> int:
	var flags := 0
	if controller != null and controller.state != null:
		var state := controller.state
		if state.crouch_fraction > 0.5:
			flags |= DotTimerReplay.FLAG_DUCKED
		if state.time_since_jump < 1.5 / float(maxi(controller.tick_rate, 1)):
			flags |= DotTimerReplay.FLAG_JUMPED
	if _teleported:
		flags |= DotTimerReplay.FLAG_TELEPORT
		_teleported = false
	return flags
