extends "g2g_game_build.gd"

## g2gfast: the simulation. Maps, timers, styles, records, and every player.
##
## [b]A bunny-hop and surf server in the competitive-shooter shape[/b]: the genre's cvars and
## units, a timer with zones, styles, a records table and a rotation. Headless it is the server.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## Movement lives in dot-player-controller, timing in dot-timer, maps in dot-map, records in
## dot-leaderboard; this file adds the joins (tick order, the unit boundary, when a cvar change
## reaches thirty players), which is where the bugs have been.

func _ready() -> void:
	if config == null:
		config = G2GConfig.new()
	if not body_rules.changed.is_connected(_apply_bodies):
		body_rules.changed.connect(_apply_bodies)
	if not view_rules.changed.is_connected(_on_view_rules_changed):
		view_rules.changed.connect(_on_view_rules_changed)

	config_binder = G2GConfig.make_binder(config, config_file)
	var loaded := config_binder.load_layers()

	if not loaded.ok:
		DotLog.error(CHANNEL, "the g2gfast configuration is not usable", {
			"why": loaded.error.message
		})
		# Strict (a dedicated server): a typo in a config file stops the boot.
		if config_binder.strict:
			DotGameConfigBinder.fail_boot(get_tree(), loaded)
			return

	authoritative = config.authoritative
	tick_rate = _resolve_tick_rate()
	# Snapped to float32 before anything derives from it: that is the precision
	# the wire carries, and a server has to move its players with the values its
	# clients were sent. See [method G2GConfig.snap_movement].
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	DotRegistry.register(DotRegistry.scoped_name(SERVICE, service_scope), self)

	DotLog.info(CHANNEL, "g2gfast starting", {
		"config": config.describe_summary(),
		"tick_rate": tick_rate,
		"authoritative": authoritative,
	})

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	avatar_schema = G2GAvatars.schema()
	avatar_catalogue = G2GAvatars.catalogue()

	_build_styles()
	_build_boards()
	_build_timers()
	_build_progress()
	_build_layers()
	_build_maps()
	_build_player_stack()

	if authoritative:
		await _open_records_store()
		await retire_legacy_records()

	set_physics_process(true)

	if config.initial_map != &"":
		_adopt_descriptor_owner()
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)


func _build_timers() -> void:
	timers = DotTimerManager.new()
	timers.name = "Timers"

	var timer_config := DotTimerConfig.new()
	timer_config.tick_rate = 0
	timer_config.default_tick_rate = tick_rate
	timer_config.authoritative = authoritative
	timer_config.record_runs = true
	timer_config.records_directory = config.records_directory
	timer_config.record_replays = config.record_replays
	timer_config.fastest_expected_speed = G2GUnits.to_metres(config.max_velocity)
	timer_config.points_formula = config.points_formula
	timer_config.points_weighting = config.points_weighting
	timer_config.enforce_stages = config.enforce_stages
	timer_config.resume_seconds = config.resume_seconds
	timers.config = timer_config

	# Assigned before the manager is in the tree, so its configuration keeps it rather
	# than building the file store. Opened in `_open_records_store`, before the first map.
	if authoritative and config.records_database.strip_edges() != "":
		timers.store = _records_store_from_config()

	add_child(timers)
	tick_rate = timers.tick_rate

	var timer_styles := DotTimerStyle.defaults()
	for style in timer_styles:
		# The community timers' `startinair`, on: a bunny-hopper leaves the start pad mid-hop far
		# more often than not, and a run that only begins from a grounded exit is
		# one most players never start. The prespeed clamp is what stops the "build
		# speed outside and dive through" trick this switch was for.
		style.allow_air_start = true
	timers.set_styles(timer_styles)

	var replays_ready := replays.setup(config.records_directory if config.record_replays else "")
	if not replays_ready.ok:
		DotLog.warn(CHANNEL, "replays will not persist", {"why": replays_ready.error.message})
	timers.record_accepted.connect(_on_record_accepted)
	timers.record_refused.connect(_on_record_refused)
	timers.run_filed.connect(_on_timer_filed)
	# A section filed on its own moves the player's best for it; the panel's gold and its
	# sum of best read that. Refreshed here and not in the HUD, because online the HUD has no
	# store and the server tells it.
	# Only a section that improved: a slower crossing changes none of the bests, and each
	# refresh awaits n + 1 store reads and sends a message.
	timers.section_filed.connect(
		func(result: Dictionary) -> void:
			if bool(result.get("improved", true)):
				refresh_stage_reference(match_id(result["player"]))
	)
	timers.practice_finished.connect(_on_practice_finished)
	timers.start_refused.connect(
		func(id: StringName, reason: String) -> void: announced.emit(match_id(id), reason, false)
	)
	# Restarts only: `!end` asks for the end zone and the command puts the player there
	# itself. Spawning first would spend a start site's cooldown on a player leaving it.
	timers.teleport_requested.connect(
		func(id: StringName, _zone: DotTimerZone, why: StringName) -> void:
			if why != &"end":
				spawn_player(match_id(id))
	)
	timers.points_changed.connect(_on_points_changed)
	timers.effect_requested.connect(_on_effect_requested)
	timers.stage_requested.connect(_on_stage_requested)
	timers.player_finished.connect(_on_player_finished)


func _build_maps() -> void:
	maps = DotMapSession.new()
	maps.name = "Maps"
	maps.world_ref = DotNodeRef.of_path(^"../World")
	add_child(maps)

	maps.catalogue = _map_catalogue()

	if config.catalogue_path != "":
		DotLog.result(CHANNEL, "loading the map catalogue",
			maps.load_catalogue(config.catalogue_path))

	maps.rotation = DotMapRotation.of(maps.catalogue)
	maps.rotation.cooldown = 1
	maps.time_limit.duration = config.map_seconds
	load_rotation()
	# A map that arrives later (a rescan, a fetched pack) is judged against the same file.
	maps_rescanned.connect(func(_change: Dictionary) -> void: apply_rotation())

	maps.changing.connect(_on_map_changing)
	maps.changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)


func add_player(
	id: StringName, display_name: String, local: bool = false, avatar: DotAvatar = null,
	bot: bool = false, p_record_key: StringName = &""
) -> G2GPlayer:
	if players.has(id):
		return players[id]

	_claim_record_key(id, p_record_key)

	var player := G2GPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.tick_rate = tick_rate
	player.samples_input = local
	player.has_camera = local

	# The layout's player mask rather than the magic 1. With placed blocks on the prop
	# layer, a mask of 1 is a player who walks through every one of them.
	if player_stack != null:
		player.collision_mask = player_stack.player_collision_mask()
	player.base_tunables = tunables
	add_child(player)

	var added := timers.add_player(record_key(id), display_name)
	if not added.ok:
		DotLog.warn(CHANNEL, "could not give a player a timer", {
			"player": String(id), "why": added.error.message
		})

	player.timer = timers.timer_for(record_key(id))
	player.set_style(movement_styles[&"normal"], timers.style_for(&"normal"))

	# A bot (`g2g_bots.gd`) runs no timer and counts towards nothing, as the ghost does: its
	# rides are the bots layer's to judge, and a board or a statistic with a bot in it is
	# one nobody trusts.
	player.is_bot = bot
	if bot:
		timers.remove_player(record_key(id))
		player.timer = null

	if player.camera != null:
		player.camera.fov_desired = config.fov_desired
		player.camera.others_fn = func() -> Array:
			var out: Array = []
			for other_id in players:
				if players[other_id] != player and is_instance_valid(players[other_id]):
					out.append(players[other_id])
			return out
		player.camera.allow_third_person = config.allow_thirdperson and view_rules.allows_third()
		player.camera.forced_third = not view_rules.allows_first()
		player.camera.set_mode(
			G2GCamera.Mode.THIRD_PERSON if config.default_thirdperson and config.allow_thirdperson
			else G2GCamera.Mode.FIRST_PERSON
		)

	# Their own avatar when they have one, a stock character when they do not. The
	# stock one is a real document over the same schema, so nothing about drawing
	# changes the day the platform hands one over.
	player.rig.set_meta(&"player_key", String(id))
	var dressed := player.rig.dress(
		avatar if avatar != null else G2GAvatars.stock_avatar(id),
		avatar_schema, avatar_catalogue
	)
	if not dressed.ok:
		DotLog.warn(CHANNEL, "a player could not be dressed", {
			"player": String(id), "why": dressed.error.message
		})

	players[id] = player
	_apply_bodies()
	_samples[id] = DotTimerSample.new()
	player.set_mechanics(mechanics)
	player.map_event.connect(_on_map_event.bind(id))

	if progress != null and not bot:
		# Not awaited: an achievement store may be remote and a join may not wait on
		# it. Readings that arrive during the load are still counted — see
		# `G2GProgress.begin`.
		progress.begin(id, display_name)

	spawn_player(id)
	player_added.emit(player)

	return player


## Puts the record's replay on the map as a player everybody sees.
##
## A ghost is a [G2GPlayer] with [member G2GPlayer.replay] set, so it replicates
## through the same bridge as a person: the server drives it, clients interpolate
## it, and a browser client that could not decode a replay still sees the run.
func spawn_ghost(track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> G2GPlayer:
	if not authoritative or not config.show_replay_bot or maps.current == null:
		return null

	var best := replays.best(maps.current.id, track, style_id)
	if best == null:
		return null

	remove_player(GHOST_ID)

	var player := add_player(
		GHOST_ID, "WR %s · %s" % [DotTimerRun.format_time(best.time), best.player_name], false
	)
	if player == null:
		return null

	var replay_player := DotTimerReplayPlayer.new()
	var loaded := replay_player.load_replay(best)
	if not loaded.ok:
		remove_player(GHOST_ID)
		return null

	timers.remove_player(GHOST_ID)
	player.timer = null
	player.replay = replay_player
	replay_player.play()
	return player


func spawn_player(id: StringName) -> void:
	var player: G2GPlayer = players.get(id)
	if player == null:
		return

	# A spawn follows a join, a track or style change, a map change and a restart —
	# every moment the board a player is measured against may have changed.
	refresh_standing(id)

	var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
	var map := current_map_node()

	# [b]The director chooses among the map's own starts; the map is the fallback.[/b]
	# `G2GPlayerStack.refresh_spawns` copies every track's start into it, so this is not
	# a second set of spawns — it is the per-site cooldown, the occupancy check and, with
	# `sv_deathmatch` on, the protection window that is granted inside `choose` and
	# nowhere else. Without this call the director was fed every start on every map and
	# asked nothing for the life of the server.
	if player_stack != null:
		var chosen := player_stack.choose_start(id, track)

		if chosen.ok:
			var choice := chosen.value as DotSpawnChoice
			# Degrees out, for the same reason radians went in: `DotFpsState.yaw` is in
			# degrees and `DotFpsController` converts at exactly this boundary too.
			player.teleport(
				choice.transform.origin,
				rad_to_deg(choice.transform.basis.get_euler().y)
			)
			return

	if map != null:
		player.teleport(map.spawn_for(track), map.spawn_yaw_for(track))
	else:
		# A Workshop map is a plain scene, not a G2GMap, so its spawn is the one its zones
		# file states (`Kind.SPAWN`, falling back to the main run's) and nothing else says.
		var spawn := _zone_spawn(track)
		if spawn != null:
			player.teleport(spawn.destination, spawn.destination_yaw)
		else:
			player.teleport(Vector3(0.0, 2.0, 0.0), 0.0)


func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: G2GPlayer = players.get(id)
	if player == null or not movement_styles.has(style_id):
		return false

	var ranking := timers.style_for(style_id)
	if ranking == null:
		return false

	var changed := player.set_style(movement_styles[style_id], ranking).ok
	refresh_standing(id)
	return changed


func _on_map_changed(map: DotMapDef, loaded: Node) -> void:
	if weapon_layer != null:
		weapon_layer.clear()
	var g2g_map := loaded as G2GMap

	# An imported map learns its data here, before `timer_zones()` below: the zones come out of
	# the manifest, and an unbuilt map returns an empty set without erroring.
	var bsp := loaded as G2GBspMap
	if bsp != null:
		bsp.global_worlds = config != null and config.global_worlds
		bsp.build_from(map)

	var zones: DotTimerZoneSet = g2g_map.timer_zones() if g2g_map != null else null

	# Zones somebody drew in-game (Z offline, `g2g_zone_save` on a server) win over the
	# map's own. They were saved to this path from the day the console could draw a zone
	# and read from nowhere, so a saved zone set lasted until the next map change.
	# The authority's only: a client mirrors the server's zones, and a file it drew
	# offline for the same map would put its outlines, its stage count and its HUD on a
	# set the server is not timing.
	var drawn := user_zones_path(map.id)
	if authoritative and FileAccess.file_exists(drawn):
		var loaded_zones := DotTimerZoneSet.load_json(drawn)
		if loaded_zones.ok:
			zones = loaded_zones.value
			DotLog.info(CHANNEL, "zones drawn in-game replace the map's own", {"map": String(map.id), "path": drawn})
		else:
			DotLog.warn(CHANNEL, "a saved zone file could not be read; the map's own zones are used",
				{"path": drawn, "why": loaded_zones.error.message})

	if zones == null and maps.zones_json != "":
		var parsed := DotTimerZoneSet.from_json(maps.zones_json)
		if parsed.ok:
			zones = parsed.value

	timers.set_zones(zones)

	mechanics = G2GMapMechanics.new()
	mechanics.lethal_damage = config.lethal_damage
	if bsp != null:
		mechanics.read(bsp.manifest)
	if not mechanics.is_empty():
		DotLog.debug(CHANNEL, "the map's brush entities", {
			"map": String(map.id), "mechanics": mechanics.describe_lines()[0]})
	for id in players:
		(players[id] as G2GPlayer).set_mechanics(mechanics)

	for id in players:
		spawn_player(id)

	map_ready.emit(map)
	spawn_ghost()


func _on_effect_requested(timer_key: StringName, zone: DotTimerZone) -> void:
	var player_id := match_id(timer_key)
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return

	match zone.kind:
		DotTimerZone.Kind.RESPAWN when zone.payload.has(G2GBspMap.SENDS_TO):
			# The map's own pit, sending the player where its trigger_teleport aims: the
			# start of the section they fell out of, the far side of a gate. The run goes
			# on, as it does in Source -- a fall costs the time it takes, not the run.
			# Until 2026-10-08 every pit put the player back at the track's spawn, which
			# on a staged map restarted the whole run from section one.
			player.teleport(zone.destination, zone.destination_yaw, true)
		DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
			spawn_player(player_id)
		DotTimerZone.Kind.TELEPORT:
			# A door, and a door keeps the run: this is how a staged map joins one
			# section to the next. It stopped the run for as long as the importer has
			# been making doors, so surf_kitsune -- the map `doorways` was written for
			# -- could not be timed past its first section, and nothing said so.
			player.teleport(zone.destination, zone.destination_yaw, true)
		_:
			pass


## A map volume finished something only the server may: a block sank under a player
## who stayed on it, or a lethal hurt volume caught one. See [G2GMapMechanics].
func _on_map_event(event: int, index: int, player_id: StringName) -> void:
	if not authoritative or mechanics == null:
		return
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return
	match event:
		G2GMapMechanics.Event.BLOCK_SANK:
			if index >= 0 and index < mechanics.blocks.size():
				var block: Dictionary = mechanics.blocks[index]
				# Where the plate under the block sends people, with the run kept -- the
				# same as falling into it, which is what standing on a block is in Source.
				player.teleport(block["destination"], float(block["yaw"]), true)
		G2GMapMechanics.Event.HURT:
			spawn_player(player_id)


## R, and R twice. [param mode] is one of `G2GEvents.RESTART_*`:
##
## - TRACK: the start of the track the player is on. What R always was, and what `!r` is.
## - STAGE: one R. The start of the stage the player is in, on a map with stages and a run
##   past its first line — the genre's `!rs`, which stops the run, because a stage restart
##   is practice. Anywhere else (no run, stage 1, a map with no stages) it is TRACK, so a
##   single R in a start zone or on a linear map still means "again from the top".
## - MAIN: two Rs. The main track's start zone, from a bonus as well, which is the only
##   way back to the main route that does not need a command.
##
## [b]Spectating ends here too.[/b] A player who pressed R wants to run, and leaving them
## watching somebody else while their own body was moved is a key that looks broken.
func restart(id: StringName, mode: int) -> DotResult:
	if not players.has(id):
		return DotResult.fail(DotError.CODE_STATE, "No such player.")

	if spectate != null and spectate.is_spectating(id):
		spectate.stop(id)

	var found := timers.player(record_key(id)) if timers != null else null
	var track := found.timer.track if found != null else DotTimerTrack.MAIN

	match mode:
		G2GEvents.RESTART_STAGE:
			var run := found.timer.run if found != null else null
			var staged := timers.stage_count(track) > 1
			if staged and run != null and run.is_running() and run.stage > 1:
				return restart_stage(id)
		G2GEvents.RESTART_MAIN:
			if track != DotTimerTrack.MAIN:
				var _switched := timers.set_player_track(record_key(id), DotTimerTrack.MAIN)

	spawn_player(id)
	return DotResult.success(null)


func _on_record_accepted(record: DotTimerRecord, _previous: DotTimerRecord, rank: int) -> void:
	var scope := {
		"map": String(record.map_id), "track": str(record.track), "style": String(record.style_id),
	}

	# A seat with no account (no identity, or the account already playing) keeps its session
	# number as its key, and a session number is nobody: its time stands for this process
	# only and is moved aside at the next start, so the boards never get a row for it (the run itself is still announced).
	var ranked := not is_legacy_key(record.player_id)

	if ranked:
		_bind_board_reporter()
		await boards.submit_async(&"fastest", scope, record.player_id, record.player_name, record.time)

	# Completions are a counter. Points are NOT: they used to be added here too, record
	# by record, so every improvement added the run's whole worth on top of what the
	# previous best had already added — a total that grew with every retry of the same
	# map. The real total is the timer store's (re-scored when a record moves, weighted
	# down a player's list) and is filed in `_on_timer_filed`.
	var totals := DotStatSet.new()
	totals.add(&"completions", 1.0)
	if ranked:
		await boards.add_stats(record.player_id, totals)

	var who := timers.player(record.player_id)
	if who != null:
		run_filed.emit(match_id(record.player_id), who.last_finished, rank, "")
		# The ghost chases the server record: a new one replaces it on the spot.
		if rank == 1 and who.last_replay != null and replays.offer(who.last_replay, record):
			if maps.current != null and record.map_id == maps.current.id:
				spawn_ghost(record.track, record.style_id)


## Says what a finish meant, and moves the player's standing and points.
func _on_timer_filed(result: Dictionary) -> void:
	var id := match_id(result["player"])
	var record: DotTimerRecord = result["record"]
	var previous: DotTimerRecord = result["previous"]
	var leader: DotTimerRecord = result["previous_record"]
	var where := "%s%s" % [
		DotTimerTrack.name_of(record.track),
		"" if record.style_id == &"normal" else " · " + String(record.style_id),
	]

	if bool(result["world_record"]):
		var beat := ""
		if leader != null and leader.player_id != record.player_id:
			beat = ", beating %s by %s" % [leader.player_name, DotTimerRun.format_time(leader.time - record.time)]
		elif leader != null:
			beat = ", improving it by %s" % DotTimerRun.format_time(leader.time - record.time)
		announced.emit(id, "NEW RECORD: %s %s on %s (%s)%s" % [
			record.player_name, record.formatted_time(), String(record.map_id), where, beat,
		], true)
	elif bool(result["improved"]):
		var gain := " (-%s)" % DotTimerRun.format_time(previous.time - record.time) if previous != null else ""
		announced.emit(id, "Personal best %s%s — rank %d / %d" % [
			record.formatted_time(), gain, int(result["rank"]), int(result["total"]),
		], false)
	else:
		announced.emit(id, "%s, %s behind your best — rank %d / %d" % [
			record.formatted_time(),
			DotTimerRun.format_time(record.time - previous.time) if previous != null else "",
			int(result["rank"]), int(result["total"]),
		], false)

	refresh_standing(id)


## The standing [method refresh_standing] last worked out for [param id], or empty.
func standing_of(id: StringName) -> Dictionary:
	return _standings.get(id, {})


## What the Tab board says about [param id]: their style, their best on this map and
## track, and where it places them. From the standing [method refresh_standing] last worked
## out — which runs on every spawn, style change and filing — so a board held open twice a
## second costs no store reads at all.
func board_fields(id: StringName) -> Dictionary:
	var player: G2GPlayer = players.get(id)
	var standing: Dictionary = _standings.get(id, {})
	var style := ""
	if player != null and player.timer_style != null:
		style = player.timer_style.display_name
	return {
		"style": style,
		"best": float(standing.get("pb", 0.0)) if float(standing.get("pb", 0.0)) > 0.0 else -1.0,
		"rank": int(standing.get("rank", 0)),
		"of": int(standing.get("total", 0)),
		"ghost": player != null and player.replay != null,
	}


# --- Diagnostics -----------------------------------------------------------

func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("map          %s" % (String(maps.current.id) if maps != null and maps.current != null else "-"))
	out.append("players      %d" % players.size())
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if timers.tick_rate_matches_engine() else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("autobhop     %s" % ("on" if config.auto_bhop else "off"))
	out.append("movement     airaccel %.0f  accel %.1f  gravity %.0f  friction %.1f  maxvel %.0f" % [
		config.air_accelerate, config.accelerate, config.gravity, config.friction, config.max_velocity,
	])
	out.append("time left    %s" % time_left_text())

	if progress != null:
		out.append_array(progress.describe_lines())

	if combat != null:
		out.append_array(combat.describe_lines())

	if hunters != null:
		out.append_array(hunters.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	if bots != null:
		out.append_array(bots.call("describe_lines"))

	for id in players:
		out.append("  %s" % str((players[id] as G2GPlayer).describe()))
	return out


## The map's time left as an operator should read it: the vote's clock when there is a
## vote — "no limit" when that vote has none, "stopped" while a ballot holds it or it has
## run out — and
## the map session's otherwise.
##
## "no limit" here where the HUD shows nothing: a status line is read when somebody asks,
## and an absent row reads as a diagnostic that forgot to say, not as a clock that is off.
func time_left_text() -> String:
	if clock_fn.is_valid():
		var state: Dictionary = clock_fn.call()

		if not bool(state.get("has_clock", false)):
			return "no limit"

		var total := int(state.get("seconds_left", 0))
		return "%d:%02d%s" % [
			total / 60, total % 60, "" if bool(state.get("running", false)) else " (stopped)"
		]

	return maps.time_limit.formatted_remaining() if maps != null else "-"


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)
