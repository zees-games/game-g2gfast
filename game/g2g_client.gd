extends "g2g_client_netcode.gd"

func _ready() -> void:
	# First, before anything can be drawn: the map arrives after this node is in the tree.
	_build_gate()

	link = platform.link as Node
	_offline = platform.offline

	game = G2GGame.new()
	game.name = "Game"
	var config := G2GConfig.new()
	# The family's layered configuration: exported defaults < JSON < environment < argv.
	# It was missing here, so a client was the one thing in this repository that could
	# not be configured at all -- `--g2g-initial-map surf_kitsune` reached the server
	# and the suites and went nowhere on the client, which always played whatever the
	# export happened to default to. The layers are read BEFORE the two lines below,
	# because those two are not preferences: a client is not the authority whatever a
	# config file says.
	var layered := config.load_layered()
	if not layered.ok:
		DotLog.warn("g2g.client", "the configuration did not load cleanly",
			{"why": layered.error.message})

	# Alone, nobody is waiting for the next map: no clock, unless one was configured.
	if _offline:
		config.map_seconds = config.offline_map_seconds

	# A client is never the authority. Its timer is a display; its records go nowhere.
	config.authoritative = _offline
	config.initial_map = config.initial_map if _offline else &""
	game.config = config
	if _offline:
		_offer_solo_maps()
	game.covered = _covered
	add_child(game)
	_wire_gate_to_maps()

	# Connected before anything can create a player. `JOIN` is what creates the local
	# one and it arrives after `HELLO` has already said who we are — see [method _watch].
	game.player_added.connect(_on_player_added)

	presentation = G2GPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result("g2g.client", "the presentation layer", presentation.setup())
	_wire_chat_window()
	_build_overlays()
	if _offline:
		_build_workbench()

	# Every effect drawn is somewhere on the map that just went away, and the landing
	# watcher would otherwise read the first frame on the new one as a fall.
	game.map_ready.connect(func(map: DotMapDef) -> void: presentation.on_map_changed(map.id if map != null else &""))
	G2GMapConfig.wire_client(platform, game)
	game.map_ready.connect(func(map: DotMapDef) -> void:
		if map != null:
			platform.map_changed(String(map.id)))

	_build_ragdolls()
	_build_killcam()

	zone_outlines = G2GZoneOutlines.new()
	zone_outlines.name = "ZoneOutlines"
	add_child(zone_outlines)
	game.map_ready.connect(func(_map: DotMapDef) -> void: zone_outlines.refresh(game.timers.zones))
	# The first map may already be up: an offline game loads it inside its own _ready.
	if game.maps != null and game.maps.current != null:
		zone_outlines.refresh(game.timers.zones)

	zone_editor = G2GZoneEditor.new()
	zone_editor.name = "ZoneEditor"
	zone_editor.game = game
	zone_editor.client = self
	zone_editor.outlines = zone_outlines
	zone_editor.offline = _offline
	zone_editor.send_line = func(line: String) -> void:
		if link != null and link.has_method("send_chat"):
			link.send_chat(line, false)
	zone_editor.changed.connect(func() -> void: zone_outlines.refresh(game.timers.zones))
	add_child(zone_editor)

	if _offline:
		for _i in range(60):
			await get_tree().process_frame
			if game.maps != null and game.maps.current != null:
				break
		player = game.add_player(&"local", "Player", true)
		_watch(&"local")
	else:
		var netted := _build_netcode()
		DotLog.result("g2g.client", "netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()

	# The server browser. Built on every client, connected or not: looking for a
	# server is what you do when you are not on one, and a browser that only existed
	# while you were already playing would be a browser nobody could reach.
	servers = G2GBrowser.new()
	servers.name = "Servers"
	add_child(servers)

	var listed := servers.setup()
	DotLog.result("g2g.client", "the server browser", listed)

	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result("g2g.client", "avatar actions", platform.add_avatar_actions(net, _avatar_figure))

	_grab_mouse()
	set_process(true)


func open_menu(page: StringName = &"") -> void:
	if menu == null:
		return
	_refresh_menu_words()
	menu.open(page)
