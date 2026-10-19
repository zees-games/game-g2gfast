extends Node

## A module reload leaves ONE link under the server, and a real client over a real socket
## still hears the server's RPCs afterwards.
##
## [codeblock]
## godot --headless --path . res://examples/headless_link.tscn
## [/codeblock]
##
## The bug this guards: the bridge added its link under `Server` with a bare add_child, nothing
## freed it when the module unloaded, a reload left two, Godot renamed the live one `@Node@n`,
## and every RPC to a real client was dropped without an error. Reloaded twice BEFORE the
## client joins: a reload mid-session leaves the new bridge not knowing who is seated, which is
## a different matter. Signing on is the proof, since HELLO is a server RPC.

const G2GClient := preload("../game/g2g_client.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GNetLink := preload("../game/net/g2g_net_link.gd")

const PORT := 28796
const DATA := "user://g2g_link"
const MODULE := "res://game/g2g_module.gd"
const MAP := &"bhop_g2g_intro"
const SECTIONS := 3
const CHECKS := 9

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server_side: Node = null
var _client_side: Node = null
var _server: DotServer = null
var _game: G2GGame = null
var _link: DotClientLink = null
var _client: G2GClient = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast -- module reload and the link")
	DotPaths.remove_tree(DATA)
	DirAccess.make_dir_recursive_absolute(DATA)
	if await _boot():
		await _test_reload()
		await _test_client_hears_the_server()
	await _teardown()
	_finish()


func _boot() -> bool:
	_section("a g2gfast server boots")
	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())

	var config := DotServerConfig.new()
	config.hostname = "g2gfast link"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "enet"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "error"
	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)
	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots", str(booted.error)):
		_done()
		return false

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = MAP
	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = g2g_config
	_server_side.add_child(_game)
	await _until(func() -> bool: return _game.maps != null and _game.maps.current != null, 10.0)

	var loaded: DotResult = await _load_module()
	_check(loaded.ok, "the module loads", str(loaded.error))
	_done()
	return loaded.ok


## The punishment store path is a static on the module script and a reload does not keep what a
## test set, so it is set again every time: a reload that wrote the real store would be this
## suite's doing.
func _load_module() -> DotResult:
	(load(MODULE) as GDScript).set("punishments_file", "%s/punishments.json" % DATA)
	return await _server.modules.load_module(MODULE)


func _links() -> int:
	var n := 0
	for child in _server.get_children():
		if child.get_script() == G2GNetLink:
			n += 1
	return n


func _test_reload() -> void:
	_section("a module reload leaves one live link")
	for _i in range(2):
		_check(_server.modules.unload_module("g2gfast").ok, "the module unloads")
		_check((await _load_module()).ok, "and loads again")
		await _settle(3)
	await _settle(5)
	var links := _links()
	_check(links == 1 and _server.has_node(NodePath(String(G2GNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to (%d)" % links)
	_done()


func _test_client_hears_the_server() -> void:
	_section("a real client over a socket still hears the server")
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Ada"
	_link.transport_preference = "udp"
	_link.udp_address = ""
	_client_side.add_child(_link)
	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.connect_to_server("127.0.0.1:%d" % PORT)
	await _until(func() -> bool: return spawned[0] or _link.is_playing(), 30.0)
	_client = (load("res://game/g2g.tscn") as PackedScene).instantiate() as G2GClient
	_client_side.add_child(_client)
	_client.mouse_capture_override = true
	_client.presentation.settings.local_store = DotSettingsStoreMemory.new()
	_client.presentation.settings.load_now()
	var told := await _until(func() -> bool:
		return _client.player != null and _client.net != null and _client.net.clock.is_synced() \
			and _client.game.maps.current != null, 30.0)
	_check(told, "the client is told who it is and loads the map from the reloaded server")
	_check(_links() == 1, "and there is still exactly one link")
	_done()


func _teardown() -> void:
	if _link != null:
		_link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	if _server != null and _server.has_method("shutdown"):
		_server.shutdown("done")
	for _i in range(10):
		await get_tree().process_frame
	DotPaths.remove_tree(DATA)


func _until(condition: Callable, seconds: float) -> bool:
	var left := seconds
	while left > 0.0:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		left -= get_process_delta_time()
	return bool(condition.call())


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("== %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL %s %s" % [what, detail])
	return ok


func _finish() -> void:
	var total := _passed + _failed
	if _completed != _entered or _entered != SECTIONS:
		_failed += 1
		print("FAIL sections: %d entered, %d completed, %d expected" % [_entered, _completed, SECTIONS])
	if total != CHECKS:
		_failed += 1
		print("FAIL checks: %d ran, %d expected" % [total, CHECKS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
