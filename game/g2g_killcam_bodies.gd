extends RefCounted

const G2GPlayer := preload("g2g_player.gd")
const G2GRig := preload("g2g_rig.gd")

## G2GPlayer hooks for dot-replay's [DotKillcamHost]: how a drawn body is read and posed.

## Skip keys: jump, the key a runner's hand is already on.
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "ui_cancel"]

var _alive: Dictionary = {}


## Gives [param host] g2gfast's skip keys, cull layer and body hooks.
func configure(host: DotKillcamHost) -> void:
	host.log_channel = "g2g.killcam"
	host.skip_actions = SKIP_ACTIONS
	host.no_id = &""
	# The local rig sits on its own layer, which a first-person view culls.
	host.camera_cull_extra = 1 << (G2GRig.LAYER_LOCAL_BODY - 1)
	host.state_fn = state_of
	host.place_body_fn = place_body
	host.restore_body_fn = restore_body
	host.can_play_fn = func(data: Dictionary) -> bool: return data.get("killer") != data.get("victim")


## The client calls this when a player dies or returns: a body is drawn only while alive.
func set_alive(id: StringName, alive: bool) -> void:
	_alive[id] = alive


# [feet, yaw, pitch, alive, eye height]: where the body was drawn, not where the tick put it.
func state_of(p: G2GPlayer) -> Array:
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


static func place_body(p: G2GPlayer, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float, touched: Dictionary) -> void:
	var rig := p.rig
	if rig == null or rig.person == null:
		return
	if not touched.has(p):
		touched[p] = [rig.global_transform, rig.visible, rig.person.hide_head]
	rig.visible = shown
	if not shown:
		return
	rig.global_position = feet
	rig.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
	rig.person.hide_head = false
	rig.person.set_motion({"on_floor": true, "aim": deg_to_rad(pitch)})
	rig.person.animate(speed, 0.0)


static func restore_body(p: G2GPlayer, saved: Array) -> void:
	var rig: G2GRig = p.rig
	if rig == null:
		return
	rig.global_transform = saved[0]
	rig.visible = saved[1]
	if rig.person != null:
		rig.person.hide_head = saved[2]
