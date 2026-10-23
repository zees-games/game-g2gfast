extends SceneTree

## Renders the end of a solo deathmatch: one runner kills another for the last point, then frames
## of the final killcam, the winner reveal and the board go to screenshots/killcam/.
## Run by render_killcam.sh under xvfb.

const OUT_DIR := "res://screenshots/killcam"
## Seconds after the kill each frame is taken.
const SHOTS := [1.0, 3.0, 7.5, 9.0, 10.5, 12.0, 14.0]

var client: Node = null
var _calm := false


func _initialize() -> void:
	_calm = "--reduce-motion" in OS.get_cmdline_user_args()
	var scene: PackedScene = load("res://game/g2g.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var store := DotSettingsStoreMemory.new()
	var presentation: Object = client.get("presentation")
	presentation.get("settings").set("local_store", store)
	presentation.get("settings").call("load_now")
	if _calm:
		presentation.get("settings").call("set_value", &"reduce_motion", true)
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.maps.current != null and client.get("player") != null:
			break
	var combat = game.combat
	print("combat %s, match state %d" % [str(combat != null), int(combat.match_node.state) if combat != null else -1])
	var me = client.get("player")
	var rival = game.add_player(&"u92", "Rival", false)
	await _wait(1.0)
	var start: Vector3 = me.controller.state.position
	var forward := Vector3(sin(deg_to_rad(me.controller.state.yaw)), 0.0, cos(deg_to_rad(me.controller.state.yaw)))
	rival.teleport(start + forward * -4.0)
	for i in range(60):
		if combat.match_node.state == DotMatch.State.LIVE:
			break
		await _wait(0.25)
	print("match state %d" % int(combat.match_node.state))
	await _wait(4.0)

	var mine: DotPlayerScore = combat.match_node.scoreboard.find(str(combat.entity_for(&"u92")))
	combat.match_node.rules.score_limit = (mine.score if mine != null else 0) + 1
	var victim_entity: int = combat.entity_for(me.player_id)
	var damage := DotDamage.make(combat.entity_for(&"u92"), victim_entity, 500.0, combat.manager.damage_type(&""))
	damage.tick = game.current_tick()
	damage.weapon_id = &"deagle"
	combat._on_entity_killed(victim_entity, damage)
	print("kill noted: %s" % str(client.get("killcam").get("buffer").call(&"events_between", 0.0, 1.0e9, &"kill")))

	var last := 0.0
	for at_sec: float in SHOTS:
		await _wait(at_sec - last)
		last = at_sec
		await process_frame
		var kc: Object = client.get("killcam")
		var reveal: Object = client.get("winner_reveal")
		print("t=%.1f state=%d killcam=%s reveal=%s" % [at_sec, int(combat.match_node.state),
			str(kc.call(&"is_playing")), str(reveal.call(&"is_active"))])
		var path := ProjectSettings.globalize_path("%s/g2g%s_%03d.png" % [OUT_DIR, "_calm" if _calm else "", int(at_sec * 10.0)])
		root.get_texture().get_image().save_png(path)
	quit(0)
