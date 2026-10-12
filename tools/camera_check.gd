extends SceneTree

## The third-person camera (G2GCamera's boom, dot-core's DotCameraBoom) flown round the walls
## of the start map, armed; `mp_forceview` and the older `sv_allow_thirdperson` through the
## camera's own path; with a display, both views of the real player.
##
##   godot --headless --path . --script tools/camera_check.gd          # the checks
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/camera_check.gd   # and frames

const G2GCamera := preload("../game/g2g_camera.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")

var _game: G2GGame = null
var _failed := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotFpsSampler.register_default_actions()
	var config := G2GConfig.new()
	config.auto_bhop = true
	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = config
	root.add_child(_game)
	_run.call_deferred()


func _run() -> void:
	while _game.maps == null or _game.maps.current == null:
		await process_frame
	var me := _game.add_player(&"local", "gamemann", true)
	me.sampler = null
	for i in 6:
		await physics_frame

	var camera: G2GCamera = me.camera
	var offset := Vector3(0.0, camera.third_person_height, camera.third_person_distance)
	var pivots := DotCameraCheck.pivots_near_walls(root.get_world_3d(), AABB(Vector3(-200, -60, -200), Vector3(400, 160, 400)), 1, 1.6, 4.0, 3.0, 40)
	var got := {}
	for pivot in pivots:
		got = DotCameraCheck.add(got, DotCameraCheck.fly(root.get_world_3d(), DotCameraCheck.orbit_path(pivot), offset, 1))
	_check(not got.is_empty() and DotCameraCheck.passed(got), "third person round %d places by the walls: %s" % [pivots.size(), DotCameraCheck.summary(got) if not got.is_empty() else "no places"])

	_check(camera.toggle() and camera.is_third_person(), "the view key goes to third person")
	_game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	_check(not camera.is_third_person() and not camera.toggle(), "mp_forceview 1: back in first person, and the key refuses")
	_game.view_rules.force_view = DotPlayerViewRules.THIRD_ONLY
	_check(camera.is_third_person() and not camera.toggle(), "mp_forceview 2: held in third person")
	_game.view_rules.force_view = DotPlayerViewRules.ANY
	_check(not _game.config.allow_thirdperson == false, "and the config's switch follows the rule")

	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute("screenshots/cameras")
		var _first := camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
		await _shot(me, "g2gfast_view_first")
		var _third := camera.set_mode(G2GCamera.Mode.THIRD_PERSON)
		await _shot(me, "g2gfast_view_third")

	print("all passed" if not _failed else "FAILED")
	quit(1 if _failed else 0)


func _shot(me: G2GPlayer, file: String) -> void:
	for i in 10:
		me.present(1.0 / 60.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := root.get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true
