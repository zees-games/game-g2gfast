extends RefCounted

## A bot that drives the REAL movement along a recorded run, and says where it could not.
##
## [b]Why not play the replay.[/b] A ghost (G2GPlayer.replay) puts each frame's pose
## straight into the state: it goes through walls, never lands, and finishes every map
## whatever the map's collision is. That shows a run; it proves nothing about the map.
## This one is the opposite. It has only commands -- the same `DotFpsCommand` a person
## sends -- and the recording is a line to keep to, so a run it cannot repeat is a place
## where the map is not the map the run was made on: a block moved, a brush lost, a lip
## a few units too tall, a teleport that lands somewhere else.
##
## Each tick it finds the recorded frame it is nearest to (searching forward from the last
## one, so a course that passes the same spot twice does not jump back), asks for the
## velocity the recording had there plus a pull back onto the line, and copies the frame's
## jump and duck. In the air the wish is spent the way `route_bot._air` spends it, turning
## this velocity into the wanted one -- which under this game's air acceleration can be
## almost anything in a tick. On the ground it runs at the point a few ticks ahead.
##
## [b]It fails loudly.[/b] Further than [member leave_distance] from the nearest frame,
## for longer than [member leave_ticks], it stops and [member left_at] holds the frame and
## the place: "left the recorded line at frame N, (x, y, z)". That spot is where to look
## for the collision fault.

const G2GUnits := preload("../game/g2g_units.gd")

## Units from the nearest frame beyond which the bot is off the line.
const LEAVE_UNITS := 64.0
## Ticks it may be off before that counts: a landing a few units long recovers.
const LEAVE_TICKS := 32
## Frames ahead aimed at on the ground.
const LEAD_FRAMES := 8
## How far forward (frames) the nearest-frame search looks each tick. Behind it looks
## only a little: the bot never goes back along a run.
const SEARCH_AHEAD := 192
const SEARCH_BEHIND := 8
## Per second: on the ground, how hard a step off the line is steered back onto it.
const GROUND_PULL := 16.0
## Units the recording may be above a grounded bot before the bot is behind a jump.
const STEP_UNITS := 18.0
## Frames ahead aimed at in the air: about thirty units at a bhop's speed, near enough
## to follow a turn and far enough not to chase the spot it is passing.
const AIR_LEAD_FRAMES := 16
## Frames before a recorded landing from which the air aims at the landing itself.
const LAND_LEAD_FRAMES := 24
## Sideways speed (u/s) wanted before the bot turns rather than tends its speed.
const TURN_DEADBAND := 4.0
## Speed (u/s) short or over before it strafes to gain or wishes back to brake.
const SPEED_DEADBAND := 10.0

var replay: DotTimerReplay = null
## The frames driven: from the first recorded (the run-up included) to the finish.
var first := 0
var last := 0
## The nearest recorded frame, updated each tick.
var index := 0
var leave_distance := G2GUnits.to_metres(LEAVE_UNITS)
var leave_ticks := LEAVE_TICKS
## Set once the bot has been off the line too long: {"frame", "at" (units), "off" (units)}.
var left_at: Dictionary = {}
## The furthest anyone has been from the line while still on it, in units.
var worst := 0.0

## Where the player was on the last tick driven: a pit has already moved them by the
## time it says so.
var last_seen := Vector3.ZERO

var _off_for := 0
var _side := 1.0
var _jump_at := -1
var _jump_held := false
var _has_buttons := false
var _rate := 128


func _init(p_replay: DotTimerReplay = null) -> void:
	replay = p_replay
	if replay != null:
		# From the recording's first frame, not the run's: the pre-roll is the run-up, and
		# a bot dropped at the start line at speed zero is not where the run was.
		first = 0
		last = replay.run_end_frame()
		index = first
		_rate = maxi(replay.tick_rate, 1)
		_has_buttons = replay_has_buttons()


## The recorded spot the run starts from, and the way it faced.
func start_position() -> Vector3:
	return replay.frames[first].position


func start_yaw() -> float:
	return replay.frames[first].yaw


## How far along the run the bot is, 0..1.
func progress() -> float:
	return float(index - first) / float(maxi(last - first, 1))


## A teleport moved the player: the nearest frame is wherever it landed, so search the
## recording forward for the first frame flagged as a teleport near the new spot.
func teleported(at: Vector3) -> void:
	for i in range(index, last + 1):
		var f: DotTimerReplay.Frame = replay.frames[i]
		if f.flags & DotTimerReplay.FLAG_TELEPORT and f.position.distance_to(at) < leave_distance * 2.0:
			index = i
			return


## This tick's command. Off the line too long, it returns an empty command and
## [member left_at] says where.
## When a pit catches the bot while it is already off the line, that is where it left it:
## sets [member left_at] and says so. A bot ON the line that falls into a pit is a fault in
## the map or the drive, and stays a put-back.
func left_while_off(at: Vector3) -> bool:
	if not left_at.is_empty():
		return true
	if _off_for <= 0:
		return false
	var here: DotTimerReplay.Frame = replay.frames[index]
	left_at = {
		"frame": index,
		"at": G2GUnits.vector_to_units(here.position).round(),
		"was": G2GUnits.vector_to_units(at).round(),
		"off": G2GUnits.to_units(at.distance_to(here.position)),
	}
	return true


func command(state: DotFpsState, tunables: DotFpsTunables, delta: float) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	if not left_at.is_empty():
		return c
	var at := state.position
	index = _nearest(at)
	var here: DotTimerReplay.Frame = replay.frames[index]
	var off := at.distance_to(here.position)
	if off > leave_distance:
		_off_for += 1
		if _off_for > leave_ticks:
			left_at = {
				"frame": index,
				"at": G2GUnits.vector_to_units(here.position).round(),
				"was": G2GUnits.vector_to_units(at).round(),
				"off": G2GUnits.to_units(off),
			}
			return c
	else:
		_off_for = 0
		worst = maxf(worst, G2GUnits.to_units(off))

	var next: DotTimerReplay.Frame = replay.frames[mini(index + 1, replay.frames.size() - 1)]
	var ahead: DotTimerReplay.Frame = replay.frames[mini(index + LEAD_FRAMES, replay.frames.size() - 1)]
	var line_velocity := (next.position - here.position) * float(_rate)
	if next.flags & DotTimerReplay.FLAG_TELEPORT:
		line_velocity = Vector3.ZERO

	var buttons := _buttons(here)
	c.set_button(DotFpsCommand.BUTTON_JUMP, _wants_jump(state, at))
	c.set_button(DotFpsCommand.BUTTON_CROUCH, buttons & DotFpsCommand.BUTTON_CROUCH != 0)
	c.pitch = here.pitch

	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	if state.is_grounded():
		# Ground acceleration is strong enough to point the velocity wherever the wish
		# points, so the wish is the line's own velocity there plus a pull back onto it.
		# Aiming at a point ahead instead cuts every turn wide, because the recording's
		# velocity lags its aim on a bend and the point ahead does not.
		var back := Vector3(here.position.x - at.x, 0.0, here.position.z - at.z)
		var go := Vector3(line_velocity.x, 0.0, line_velocity.z) + back * GROUND_PULL
		if go.length() < G2GUnits.to_metres(5.0):
			go = Vector3(ahead.position.x - at.x, 0.0, ahead.position.z - at.z)
		# Steer the velocity, not the heading: the wish is the change wanted this tick
		# (the line's velocity less the velocity after this tick's friction), and its size
		# the least that delivers it. A fixed full wish, or a wish straight back, over- or
		# undershoots by several ticks' worth on the ground and a hop leaves slow.
		var kept := flat * maxf(1.0 - tunables.friction * delta, 0.0)
		var want_v := go
		if want_v.length() > tunables.max_speed:
			want_v = want_v.normalized() * tunables.max_speed
		var err := want_v - kept
		var need := err.length()
		if need < G2GUnits.to_metres(2.0):
			c.yaw = rad_to_deg(atan2(-go.x, -go.z)) if go.length() > 0.01 else here.yaw
			c.move = Vector2(0.0, clampf(want_v.length() / tunables.max_speed, 0.0, 1.0)) \
				if go.length() > 0.01 else Vector2.ZERO
			return c
		var dir := err / need
		var wish_speed := maxf(need / maxf(tunables.accelerate * delta, 0.001),
			need + maxf(flat.dot(dir), 0.0))
		c.yaw = rad_to_deg(atan2(-dir.x, -dir.z))
		c.move = Vector2(0.0, clampf(wish_speed / tunables.max_speed, 0.0, 1.0))
		return c

	# Air: pure pursuit. The velocity wanted points at the recorded spot [constant
	# AIR_LEAD_FRAMES] ahead, at the line's own speed there. A wish only adds speed
	# along itself up to `sv_maxairwishspeed` (30 u/s) past what the velocity already
	# has along it, so a wish anywhere near the velocity does nothing at all: a turn is
	# a wish at right angles to the velocity, toward the side wanted, and that is also
	# how a player strafes. Speed is gained by alternating sides, and shed by wishing
	# straight back.
	var aim: DotTimerReplay.Frame = replay.frames[mini(index + AIR_LEAD_FRAMES, last)]
	var to_aim := Vector3(aim.position.x - at.x, 0.0, aim.position.z - at.z)
	var line_speed := Vector2(line_velocity.x, line_velocity.z).length()
	var want := to_aim.normalized() * line_speed if to_aim.length() > 0.01 else Vector3.ZERO
	# Near a landing, aim the landing itself. A bot a tick behind the recording is a few
	# units lower at every point of the same arc and comes down short; the speed that
	# puts it over the recorded landing when its own feet reach that height is the one
	# that keeps a lip the recording only just made.
	var land := _landing_after(index)
	if land >= 0 and land - index <= LAND_LEAD_FRAMES:
		var spot: Vector3 = replay.frames[land].position
		var to_spot := Vector3(spot.x - at.x, 0.0, spot.z - at.z)
		var g := tunables.gravity
		var vy := state.velocity.y
		var disc := vy * vy - 2.0 * g * (spot.y - at.y)
		if disc >= 0.0 and to_spot.length() > 0.01:
			var t := (vy + sqrt(disc)) / g
			if t > delta:
				want = to_spot.normalized() * (to_spot.length() / t)
	var speed := flat.length()
	if speed < 0.5:
		c.yaw = rad_to_deg(atan2(-want.x, -want.z)) if want != Vector3.ZERO else here.yaw
		c.move = Vector2(0.0, 1.0) if want != Vector3.ZERO else Vector2.ZERO
		return c
	var heading := flat / speed
	var side := Vector3(-heading.z, 0.0, heading.x)  # a quarter-turn of the velocity
	var across := want.dot(side)
	var run := tunables.max_speed
	var short := want.length() - speed
	# Short of speed: a full strafe at right angles adds the most any wish can, and on
	# the side the line bends toward it turns as well -- which is what a player's strafe
	# is. Only with no turn wanted does it alternate sides, gaining straight on.
	if short > G2GUnits.to_metres(SPEED_DEADBAND):
		if absf(across) > G2GUnits.to_metres(TURN_DEADBAND):
			_side = signf(across)
		else:
			_side = -_side
		var w := side * _side
		c.yaw = rad_to_deg(atan2(-w.x, -w.z))
		c.move = Vector2(0.0, 1.0)
		return c
	if absf(across) > G2GUnits.to_metres(TURN_DEADBAND):
		var w := side * signf(across)
		c.yaw = rad_to_deg(atan2(-w.x, -w.z))
		c.move = Vector2(0.0, clampf(absf(across) / run, 0.0, 1.0))
		return c
	if short < -G2GUnits.to_metres(SPEED_DEADBAND):
		var w := -heading
		c.yaw = rad_to_deg(atan2(-w.x, -w.z))
		c.move = Vector2(0.0, clampf(-short / (tunables.air_accelerate * run * delta), 0.0, 1.0))
	else:
		c.yaw = rad_to_deg(atan2(-heading.x, -heading.z))
	return c


## The first recorded frame on the ground at or after [param from], or -1.
func _landing_after(from: int) -> int:
	for i in range(from, mini(last, from + LAND_LEAD_FRAMES * 4) + 1):
		if replay.frames[i].flags & DotTimerReplay.FLAG_GROUNDED:
			return i
	return -1


## The recording's next take-off at or after frame [param from]: the first frame whose
## jump is pressed after one where it was not, or -1.
func _next_jump(from: int) -> int:
	for i in range(maxi(from, first + 1), last + 1):
		if _buttons(replay.frames[i]) & DotFpsCommand.BUTTON_JUMP \
				and not (_buttons(replay.frames[i - 1]) & DotFpsCommand.BUTTON_JUMP):
			return i
	return -1


## Whether to hold jump this tick. A take-off is copied by PLACE, not by tick: the bot
## jumps once it has reached the frame the recording jumped on (nearest frame, or past it
## along the line), and holds the key until it is in the air -- a one-tick press made
## from a frame the bot was matched to a tick early is a press the motor never sees,
## and a jump taken late is a run off the end of a block.
func _wants_jump(state: DotFpsState, at: Vector3) -> bool:
	if _jump_at < 0 or _jump_at < index - SEARCH_BEHIND:
		_jump_at = _next_jump(index)
	if _jump_at < 0:
		return false
	if not state.is_grounded():
		if _jump_held:
			# Airborne: that take-off is done.
			_jump_held = false
			_jump_at = _next_jump(maxi(index, _jump_at) + 1)
		return false
	# A take-off that went nowhere -- clipped a lip, came straight back down -- leaves
	# the bot on the ground while the recording is in the air above it. Jump again.
	var here: DotTimerReplay.Frame = replay.frames[index]
	if not (here.flags & DotTimerReplay.FLAG_GROUNDED) \
			and here.position.y - at.y > G2GUnits.to_metres(STEP_UNITS):
		return true
	var take_off: Vector3 = replay.frames[_jump_at].position
	var before: Vector3 = replay.frames[maxi(_jump_at - 1, first)].position
	var along := Vector2(take_off.x - before.x, take_off.z - before.z)
	var past := along.length() > 0.0001 \
		and Vector2(at.x - take_off.x, at.z - take_off.z).dot(along) >= 0.0
	if index + 1 >= _jump_at or past:
		_jump_held = true
	return _jump_held


func _buttons(f: DotTimerReplay.Frame) -> int:
	return f.buttons if _has_buttons else _buttons_from_flags(f)


## Whether the recording carries the buttons held (format 2), rather than only flags.
func replay_has_buttons() -> bool:
	for f: DotTimerReplay.Frame in replay.frames:
		if f.buttons != 0:
			return true
	return false


static func _buttons_from_flags(f: DotTimerReplay.Frame) -> int:
	var b := 0
	if f.flags & DotTimerReplay.FLAG_JUMPED:
		b |= DotFpsCommand.BUTTON_JUMP
	if f.flags & DotTimerReplay.FLAG_DUCKED:
		b |= DotFpsCommand.BUTTON_CROUCH
	return b


func _nearest(at: Vector3) -> int:
	var best := index
	var best_d := INF
	for i in range(maxi(first, index - SEARCH_BEHIND), mini(last, index + SEARCH_AHEAD) + 1):
		var d := at.distance_squared_to(replay.frames[i].position)
		if d < best_d:
			best_d = d
			best = i
	return best


func describe() -> Dictionary:
	return {
		"frames": last - first + 1,
		"index": index,
		"progress": progress(),
		"worst": worst,
		"left_at": left_at,
	}


## Drives [param bot] in [param game] along [param replay] from the run's first frame
## until the game's own timer finishes the run, a pit puts the bot back, the bot leaves
## the line, or [param seconds] run out. One tick per physics frame, like every bot here.
## Returns {"finished": seconds or -1, "put_back": units or null, "left_at": {}, "ticks",
## "progress", "worst"}: what the tool prints and the suite asserts.
static func drive(game: Node, bot: Node, replay: DotTimerReplay, seconds: float) -> Dictionary:
	var follow := new(replay)
	var tree := game.get_tree()
	var finished: Array[float] = []
	var put_back: Array = []
	var on_effect := func(pid: StringName, zone: DotTimerZone) -> void:
		if pid != bot.player_id:
			return
		match zone.kind:
			DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
				# A pit that ends an excursion already off the line is the line being
				# left, not the map failing a bot that was on it: report the frame.
				if put_back.is_empty() and not follow.left_while_off(follow.last_seen):
					put_back.append(G2GUnits.vector_to_units(follow.last_seen).round())
			DotTimerZone.Kind.TELEPORT:
				(func() -> void: follow.teleported(bot.controller.state.position)).call_deferred()
	var on_finish := func(run: DotTimerRun) -> void:
		finished.append(run.time())
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finish)
	bot.timer.stop()
	bot.teleport(follow.start_position(), follow.start_yaw())
	# Nothing held while it settles. The controller re-applies the last command it was
	# given, so a bot handed over from another drive (headless_imported's route section)
	# walked off the start at 30 u/s on whatever that drive last held, and the follow
	# began a frame late from a different state than the tool's: enough, on bhop_grove,
	# to meet a door over a pit 6 u lower and take the pit.
	var still := DotFpsCommand.new()
	still.yaw = follow.start_yaw()
	bot.controller.apply_command(still)
	await tree.physics_frame

	var delta := 1.0 / float(game.tick_rate)
	# `FOLLOW_LOG_EVERY=8` traces the drive.
	var log_every := int(OS.get_environment("FOLLOW_LOG_EVERY"))
	var ticks := int(seconds * float(game.tick_rate))
	var t := 0
	while t < ticks and finished.is_empty() and put_back.is_empty() and follow.left_at.is_empty():
		var c := follow.command(bot.controller.state, bot.controller.tunables, delta)
		if log_every > 0 and t % log_every == 0:
			var s: DotFpsState = bot.controller.state
			var f: DotTimerReplay.Frame = replay.frames[follow.index]
			var f2: DotTimerReplay.Frame = replay.frames[mini(follow.index + 1, replay.frames.size() - 1)]
			print("[follow]   t %5d  frame %5d  at %s u  line %s u  %4.0f u/s (line %4.0f)  %s  move %s yaw %.0f%s" % [
				t, follow.index, str(G2GUnits.vector_to_units(s.position).round()),
				str(G2GUnits.vector_to_units(f.position).round()),
				G2GUnits.to_units(Vector2(s.velocity.x, s.velocity.z).length()),
				G2GUnits.to_units(Vector2(f2.position.x - f.position.x, f2.position.z - f.position.z).length() * float(replay.tick_rate)),
				"ground" if s.is_grounded() else "air", str(c.move.snapped(Vector2.ONE * 0.01)), c.yaw,
				" JUMP" if c.is_pressed(DotFpsCommand.BUTTON_JUMP) else ""])
		follow.last_seen = bot.controller.state.position
		bot.controller.apply_command(c)
		await tree.physics_frame
		t += 1
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finish)
	return {
		"finished": finished[0] if not finished.is_empty() else -1.0,
		"put_back": put_back[0] if not put_back.is_empty() else null,
		"left_at": follow.left_at,
		"ticks": t,
		"frame": follow.index,
		"progress": follow.progress(),
		"worst": follow.worst,
		"recorded": replay.time,
	}


## One line saying how a [method drive] went, the way the tool and the suite both print it.
static func summary(result: Dictionary) -> String:
	if float(result["finished"]) >= 0.0:
		return "finished in %.2f s (recorded %.2f s), never more than %.0f u off the line" % [
			result["finished"], result["recorded"], result["worst"]]
	if not (result["left_at"] as Dictionary).is_empty():
		var left: Dictionary = result["left_at"]
		return "left the recorded line at frame %d, %s u (the bot was at %s u, %.0f u off)" % [
			left["frame"], str(left["at"]), str(left["was"]), left["off"]]
	if result["put_back"] != null:
		return "put back by a pit from %s u at frame %d (%.0f%% of the run)" % [
			str(result["put_back"]), result["frame"], float(result["progress"]) * 100.0]
	return "not finished after %d ticks, at frame %d (%.0f%% of the run)" % [
		result["ticks"], result["frame"], float(result["progress"]) * 100.0]


## The recording kept for [param id] (`maps/routes/<id>.replay`), or null, with why.
static func load_for(id: StringName, why: Array = []) -> DotTimerReplay:
	var path := "res://maps/routes/%s.replay" % id
	if not FileAccess.file_exists(path):
		why.append("no %s" % path)
		return null
	var parsed := DotTimerReplay.load_from(path)
	if not parsed.ok:
		why.append("%s: %s" % [path, parsed.error.message])
		return null
	var replay: DotTimerReplay = parsed.value
	if replay.frames.size() < 2:
		why.append("%s has no frames" % path)
		return null
	return replay
