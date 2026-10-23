extends Node

## The final killcam. Client side: every frame drawn goes into dot-replay's [DotKillcamBuffer]
## (what the snapshots already brought, no new traffic), every kill is noted, and when the match
## ends on one, [DotKillcam] replays it from the killer's eye before the podium.
## The length is the server's `mp_killcam_time`, sent with the match's end; 0 skips to [signal over].

const G2GPlayer := preload("g2g_player.gd")
const G2GRig := preload("g2g_rig.gd")

const CHANNEL := "g2g.killcam"

## Skip keys: jump, the key a runner's hand is already on.
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "ui_cancel"]

## The killcam is over (or never began); the end-of-match flow goes on from here.
signal over(skipped: bool)

## Every G2GPlayer to record, this frame.
var players_fn: Callable = Callable()

## G2GPlayer for a session id, or null.
var player_for_fn: Callable = Callable()

## The killcam's length in seconds; 0 disables.
var seconds_fn: Callable = func() -> float: return 7.0

## Seconds, monotonic. Injected by a test.
var now_fn: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

## Shown as-is in the banner: the weapon id's words.
var weapon_name_fn: Callable = func(id: String) -> String: return id.capitalize()

## Nodes hidden while the replay runs (the HUD, the view model): anything with `visible`.
var hide_while_playing: Array = []

var buffer := DotKillcamBuffer.new()
var killcam: DotKillcam = null
var camera: Camera3D = null

var _previous_camera: Camera3D = null
var _touched: Dictionary = {}
var _hidden: Dictionary = {}
var _alive: Dictionary = {}


func _ready() -> void:
	killcam = DotKillcam.new()
	killcam.name = "Killcam"
	killcam.skip_actions = SKIP_ACTIONS
	add_child(killcam)
	killcam.started.connect(_on_started)
	killcam.frame_drawn.connect(_apply)
	killcam.finished.connect(_on_finished)
	camera = Camera3D.new()
	camera.name = "KillcamCamera"
	add_child(camera)


func is_playing() -> bool:
	return killcam != null and killcam.is_active()


## Records this frame. Called once a frame after every body is presented; while the replay runs
## it re-applies the replayed frame instead, over what presentation just drew.
func frame() -> void:
	if is_playing():
		if killcam.state == DotKillcam.State.WAITING:
			_record()
		return
	_record()


## A kill this client was told about.
func note_kill(killer_id: StringName, victim_id: StringName, weapon: String, headshot: bool = false) -> void:
	buffer.note_event(now_fn.call(), &"kill", {
		"killer": killer_id, "victim": victim_id, "weapon": weapon, "headshot": headshot,
	})


## The match ended: replay its last kill if there is one to show. False means [signal over] has
## already been emitted and nothing will play.
func match_ended() -> bool:
	if killcam == null or is_playing():
		return is_playing()
	killcam.max_seconds = maxf(float(seconds_fn.call()), 0.0)
	var kill := buffer.last_event(&"kill")
	var killer_id := StringName(kill["data"].get("killer", &"")) if not kill.is_empty() else &""
	var killer: Node = _player(killer_id)
	if not killcam.enabled() or killer == null or killer_id == StringName(kill["data"].get("victim", &"")):
		over.emit(false)
		return false
	var victim: Node = _player(StringName(kill["data"].get("victim", &"")))
	var played := killcam.play(buffer, kill, {
		"killer": String(killer.get(&"display_name")),
		"victim": String(victim.get(&"display_name")) if victim != null else "",
		"weapon": weapon_name_fn.call(String(kill["data"].get("weapon", ""))),
		"hint": "Jump to skip",
	})
	if not played.ok:
		DotLog.debug(CHANNEL, "no final killcam", {"why": played.error.message})
		over.emit(false)
		return false
	return true


func skip() -> void:
	if killcam != null:
		killcam.skip()


func _player(id: StringName) -> Node:
	if id == &"" or not player_for_fn.is_valid():
		return null
	var p: Variant = player_for_fn.call(id)
	return p as Node if p is Node and is_instance_valid(p) else null


func _record() -> void:
	if not players_fn.is_valid():
		return
	var shot := {}
	for p: Variant in players_fn.call():
		var row := _state_of(p as G2GPlayer)
		if not row.is_empty():
			shot[p.get(&"player_id")] = row
	var _kept := buffer.push_frame(now_fn.call(), shot)


## Called by the client when a player dies or returns: the killcam draws a body only while alive.
func set_alive(id: StringName, alive: bool) -> void:
	_alive[id] = alive


# [feet, yaw, pitch, alive, eye height]: where the body was drawn, not where the tick put it.
func _state_of(p: G2GPlayer) -> Array:
	if p.controller == null:
		return []
	var st := p.controller.state
	var eye_h := 1.6
	var feet := p.global_position
	var yaw := st.yaw
	var pitch := st.pitch
	if p.controller.motor != null:
		eye_h = p.controller.motor.eye_position(st).y - st.position.y
	if p.has_camera:
		st = p.controller.render_state()
		feet = st.position + p.drawn_offset
		yaw = st.yaw
		pitch = st.pitch
		if p.view_now is Vector2:
			yaw = (p.view_now as Vector2).x
			pitch = (p.view_now as Vector2).y
	return [feet, yaw, pitch, bool(_alive.get(p.player_id, true)), eye_h]


func _on_started(_kill: Dictionary) -> void:
	_previous_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _previous_camera != null and _previous_camera != camera:
		camera.fov = _previous_camera.fov
		# The local rig sits on its own layer, which a first-person view culls: the killer's rig
		# is hidden instead, and a victim's own body must show.
		camera.cull_mask = _previous_camera.cull_mask | (1 << (G2GRig.LAYER_LOCAL_BODY - 1))
	camera.make_current()
	for n: Variant in hide_while_playing:
		if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
			_hidden[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)
	DotLog.info(CHANNEL, "final killcam", killcam.describe())


func _apply(s: Dictionary) -> void:
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	var killer_id := StringName(killcam.kill()["data"].get("killer", &""))
	if not camera.current:
		camera.make_current()
	for id: Variant in b:
		var p: G2GPlayer = _player(StringName(id)) as G2GPlayer
		if p == null:
			continue
		var rb: Array = b[id]
		var ra: Array = a.get(id, rb)
		var feet: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var yaw := rad_to_deg(lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
		var pitch := lerpf(ra[2], rb[2], alpha)
		var alive: bool = rb[3] if alpha >= 0.5 else ra[3]
		if StringName(id) == killer_id:
			camera.global_position = feet + Vector3(0.0, float(rb[4]), 0.0)
			camera.global_rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)
			_place_body(p, feet, yaw, false, 0.0, 0.0)
		else:
			var from: Vector3 = ra[0]
			var to: Vector3 = rb[0]
			var speed := from.distance_to(to) * 60.0
			_place_body(p, feet, yaw, alive, pitch, speed)


func _place_body(p: G2GPlayer, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float) -> void:
	var rig := p.rig
	if rig == null or rig.person == null:
		return
	if not _touched.has(p):
		_touched[p] = [rig.global_transform, rig.visible, rig.person.hide_head]
	rig.visible = shown
	if not shown:
		return
	rig.global_position = feet
	rig.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
	rig.person.hide_head = false
	rig.person.set_motion({"on_floor": true, "aim": deg_to_rad(pitch)})
	rig.person.animate(speed, 0.0)


func _on_finished(skipped: bool) -> void:
	for p: Variant in _touched:
		if is_instance_valid(p):
			var rig: G2GRig = (p as G2GPlayer).rig
			if rig != null:
				rig.global_transform = _touched[p][0]
				rig.visible = _touched[p][1]
				if rig.person != null:
					rig.person.hide_head = _touched[p][2]
	_touched.clear()
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe_lines() -> PackedStringArray:
	var out := buffer.describe_lines()
	if killcam != null:
		out.append_array(killcam.describe_lines())
	return out
