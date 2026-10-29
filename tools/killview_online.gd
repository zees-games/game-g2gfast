extends Node

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")

## One process of tools/killview_online.sh: a real dedicated server, a killer client and a victim client
## over ENet. The server kills the victim once both are seated; the victim saves its screen and logs
## the kill view's state. Roles: --role server|killer|victim, --port, --data DIR, --camera 0|1.

var role := "server"
var port := 27310
var data := ""
var camera := "1"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": role = args[i + 1]
			"--port": port = int(args[i + 1])
			"--data": data = args[i + 1]
			"--camera": camera = args[i + 1]
	name = "KillviewOnline"
	DotLog.set_level(DotLog.Level.WARN)
	DirAccess.make_dir_recursive_absolute(data)
	if role == "server":
		_serve.call_deferred()
	else:
		_play.call_deferred()


func _serve() -> void:
	var config := DotServerConfig.new()
	config.hostname = "killview"
	config.port = port
	config.bind_address = "*"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = data + "/admins.json"
	config.bans_path = data + "/bans.json"
	config.audit_log_path = data + "/audit.jsonl"
	config.hibernate_when_empty = false
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.autoexec_config = ""
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	add_child(server)
	for _i in range(120):
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var gc := G2GConfig.new()
	gc.records_directory = ""
	gc.map_seconds = 0.0
	gc.initial_map = &"bhop_g2g_intro"
	gc.deathmatch = true
	var game := G2GGame.new()
	game.config = gc
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	(load("res://game/g2g_module.gd") as GDScript).set("punishments_file", data + "/punishments.json")
	var loaded: DotResult = await server.modules.load_module("res://game/g2g_module.gd")
	if not loaded.ok:
		printerr("server: module failed: ", loaded.error.message)
		get_tree().quit(1)
		return
	server.console.find_cvar("mp_killview").force_set("1")
	server.console.find_cvar("mp_killview_camera").force_set(camera)
	print("server: ready on udp/%d, combat %s" % [port, str(game.combat != null)])
	var killed := false
	var moved_at := -1.0
	var ticks := 0
	while not FileAccess.file_exists(data + "/stop"):
		await get_tree().create_timer(0.25).timeout
		ticks += 1
		var killer := _find(game, "killer")
		var victim := _find(game, "victim")
		if ticks % 8 == 0:
			print("server: players %s, match state %d" % [str(game.players.keys()),
				int(game.combat.match_node.state) if game.combat != null else -1])
		if killed or killer == null or victim == null or game.combat == null:
			continue
		if game.combat.match_node.state != DotMatch.State.LIVE or not FileAccess.file_exists(data + "/go"):
			continue
		if moved_at < 0.0:
			var kp: Vector3 = killer.controller.state.position
			victim.teleport(kp + Vector3(0.0, 0.0, -3.0), INF, true)
			moved_at = Time.get_ticks_msec() / 1000.0
			print("server: victim moved 3 m ahead of the killer")
		if Time.get_ticks_msec() / 1000.0 - moved_at < 2.5:
			continue
		var kid: int = game.combat.entity_for(killer.player_id)
		var vid: int = game.combat.entity_for(victim.player_id)
		var damage := DotDamage.make(kid, vid, 500.0, game.combat.manager.damage_type(&""))
		damage.tick = game.current_tick()
		damage.weapon_id = &"deagle"
		print("server: kill %s(%d) -> %s(%d), killer at %s, victim at %s" % [killer.player_id, kid,
			victim.player_id, vid, str(killer.controller.state.position), str(victim.controller.state.position)])
		game.combat.manager.apply_damage(damage)
		killed = true
	print("server: stopped")
	get_tree().quit()


func _find(game: Node, display: String) -> Object:
	for p: Object in game.players.values():
		if p.display_name == display:
			return p
	return null


func _play() -> void:
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = role
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % port
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % port)
	var began := Time.get_unix_time_from_system()
	while not link.is_playing() and Time.get_unix_time_from_system() - began < 40.0:
		await get_tree().create_timer(0.1).timeout
	if not link.is_playing():
		printerr("%s: never joined" % role)
		get_tree().quit(1)
		return
	var client: Node = (load("res://game/g2g.tscn") as PackedScene).instantiate()
	client.set("mouse_capture_override", true)
	add_child(client)
	var settings: Object = client.get("presentation").get("settings")
	settings.set("local_store", DotSettingsStoreMemory.new())
	settings.call("load_now")
	while client.get("player") == null and Time.get_unix_time_from_system() - began < 60.0:
		await get_tree().create_timer(0.1).timeout
	print("%s: seated, player %s" % [role, str(client.get("player") != null)])
	if role == "killer":
		while not FileAccess.file_exists(data + "/stop"):
			await get_tree().create_timer(0.25).timeout
		get_tree().quit()
		return
	await get_tree().create_timer(3.0).timeout
	var go := FileAccess.open(data + "/go", FileAccess.WRITE)
	go.store_string("1")
	go.close()
	var shot := 0
	var dead := false
	var t := 0.0
	var kc: Object = client.get("killcam")
	while t < 14.0:
		await get_tree().create_timer(0.4).timeout
		t += 0.4
		var kv := client.find_child("KillView", true, false)
		var alive := true
		var view: Object = kv.get("view") if kv != null else null
		print("victim t=%.1f x=%s killview_active=%s killcam_playing=%s" % [t, str(alive),
			str(view.call("is_active")) if view != null else "no view", str(kc != null and kc.call("is_playing"))])
		if view != null and view.call("is_active"):
			dead = true
			print("  ", view.call("describe"))
			var cam: Camera3D = view.get("camera")
			var rows := []
			for pl: Node3D in client.get("game").players.values():
				rows.append("%s@%s vis=%s" % [pl.display_name, str(pl.global_position.snapped(Vector3(0.01, 0.01, 0.01))), str(pl.is_visible_in_tree())])
			print("  camera ", str(cam.global_position.snapped(Vector3(0.01, 0.01, 0.01))), " fwd ", str((-cam.global_basis.z).snapped(Vector3(0.01, 0.01, 0.01))), " bodies ", rows, " posed ", str(view.get("_posed")).left(300))
		if dead:
			await get_tree().process_frame
			get_viewport().get_texture().get_image().save_png("%s/victim_%02d.png" % [data, shot])
			shot += 1
	var stop := FileAccess.open(data + "/stop", FileAccess.WRITE)
	stop.store_string("1")
	stop.close()
	get_tree().quit()
