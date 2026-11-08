extends Node

const ReplayFollow := preload("replay_follow.gd")

## A real client rides a map's recorded run on a real server, so a record is filed the way a person's is.
##
##     godot --headless --fixed-fps 128 --path . tools/ride_online.tscn -- tmcdev.net:6106 bhop_grove
##     ... -- HOST:PORT MAP [NAME] [SECONDS]
##
## The client is the shipped one (res://game/g2g.tscn) joined over the wire; only its input is replaced: the
## player's sampler hands the movement the command [ReplayFollow] works out from where the player is, as
## follow_replay does offline. The server decides the time. Prints the admission time (connect to seated)
## and the ride's progress, then exits. The map must already be on the server.

class Driver extends DotFpsSampler:
	var follow: Object = null
	var player: Object = null

	func sample(delta: float = 0.0) -> DotFpsCommand:
		if follow == null or player == null:
			return DotFpsCommand.new()
		var c: DotFpsCommand = follow.command(player.controller.state, player.controller.tunables, delta)
		follow.last_seen = player.controller.state.position
		return c


func _ready() -> void:
	# The server routes RPCs by node path relative to its own root ("Server"); scope this tree the same way (see tmc_host.gd).
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), get_path())
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var address := args[0] if args.size() > 0 else "127.0.0.1:27015"
	var id := StringName(args[1] if args.size() > 1 else "bhop_grove")
	var who := args[2] if args.size() > 2 else "e2e3-ride-bot"
	var seconds := float(args[3]) if args.size() > 3 else 220.0
	var why: Array = []
	var replay := ReplayFollow.load_for(id, why)
	if replay == null:
		print("[ride] %s: %s" % [id, why[0]])
		get_tree().quit(1)
		return
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = who
	link.transport_preference = "udp"
	link.udp_address = address
	add_child(link)
	var began := Time.get_ticks_msec()
	link.connect_to_server(address)
	while not link.is_playing() and Time.get_ticks_msec() - began < 90000:
		await get_tree().create_timer(0.05).timeout
	if not link.is_playing():
		print("[ride] never joined %s" % address)
		get_tree().quit(1)
		return
	print("[ride] link playing after %.2f s" % ((Time.get_ticks_msec() - began) / 1000.0))
	var client: Node = (load("res://game/g2g.tscn") as PackedScene).instantiate()
	client.set("mouse_capture_override", true)
	add_child(client)
	var settings: Object = client.get("presentation").get("settings")
	settings.set("local_store", DotSettingsStoreMemory.new())
	settings.call("load_now")
	while client.get("player") == null and Time.get_ticks_msec() - began < 120000:
		await get_tree().create_timer(0.05).timeout
	var player: Object = client.get("player")
	if player == null:
		print("[ride] never seated")
		get_tree().quit(1)
		return
	print("[ride] seated after %.2f s (admission, connect to player)" % ((Time.get_ticks_msec() - began) / 1000.0))
	var driver := Driver.new(player.controller.tunables)
	driver.follow = ReplayFollow.new(replay)
	driver.player = player
	player.sampler = driver
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) / 1000.0 < seconds:
		await get_tree().create_timer(2.0).timeout
		var s: DotFpsState = player.controller.state
		var el := (Time.get_ticks_msec() - t0) / 1000.0
		print("[ride] t %.0f s frame %d/%d at %s speed %.0f left=%s" % [el, driver.follow.index, driver.follow.last, str(s.position.snapped(Vector3.ONE)), Vector2(s.velocity.x, s.velocity.z).length(), str(driver.follow.left_at)])
		if driver.follow.index >= driver.follow.last - 2:
			print("[ride] reached the last recorded frame")
			await get_tree().create_timer(4.0).timeout
			break
	print("[ride] done")
	get_tree().quit()
