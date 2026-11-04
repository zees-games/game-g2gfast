extends "g2g_game_state.gd"

## `sv_falldamage*` (dot-combat), explicitly off: a run is made of long drops and a landing must
## never cost the run or a life. No DotFallDamage is built, so only an edit here turns it on.
var fall_rules: DotFallDamageRules = make_fall_rules()

## Moves aside every record filed under a [method is_legacy_key] player.
##
## Before records were keyed by account they were keyed by the session's `u<userid>`, a
## server-local counter. Such a row cannot be mapped back to an account (the number was
## reused after every restart, so even "the same u12" is not one person), and left in
## place it ranks a stranger's time as a runner who can never be reached again and lets a
## new seat that draws the same number inherit it. So the rows are written to
## `legacy_records.jsonl` (in [member G2GConfig.records_directory], else `user://`) and
## then removed with [method DotTimerManager.wipe_player], which re-scores every board
## and total they touched. Nothing is lost silently and nothing is deleted before it is
## written; the store needs no migration of its own, because the test is the key's shape
## and a store of any kind answers [code]records_on_map[/code].
##
## Idempotent: a second run finds nothing. Returns how many rows were moved.
func retire_legacy_records() -> int:
	if not authoritative or timers == null or timers.store == null:
		return 0
	var store := timers.store
	var listed: DotResult = await store.maps()
	if not listed.ok:
		return 0
	var legacy := {}
	for row in (listed.value as Array):
		var on_map: DotResult = await store.records_on_map(StringName(str((row as Dictionary).get("map", ""))))
		if not on_map.ok:
			continue
		for record in (on_map.value as Array):
			if is_legacy_key((record as DotTimerRecord).player_id):
				legacy[(record as DotTimerRecord).player_id] = true
	if legacy.is_empty():
		return 0

	var base := config.records_directory.strip_edges()
	var path := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var out := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if out == null:
		DotLog.error(CHANNEL, "legacy records could not be archived; they stay where they are", {
			"path": path, "why": error_string(FileAccess.get_open_error()),
		})
		return 0
	out.seek_end()

	var moved := 0
	for key in legacy:
		var theirs: DotResult = await store.records_of(key, {"stage": -1})
		if not theirs.ok:
			continue
		for record in (theirs.value as Array):
			out.store_line(JSON.stringify((record as DotTimerRecord).to_dictionary()))
		out.flush()
		var wiped: DotResult = await timers.wipe_player(key)
		if wiped.ok:
			moved += int(wiped.value)
	out.close()
	DotLog.info(CHANNEL, "records keyed by a session number were moved aside", {
		"players": legacy.size(), "records": moved, "archive": path,
	})
	return moved


## Reads maps.yml and applies it. Called at boot and by [method rescan_maps], so an operator
## who edits the file runs `g2g_maps_reload`.
##
## Two layers, weakest first: the game's own shipped `res://maps.yml` and the server's
## [member G2GConfig.map_rotation_file]. The merge, the wildcards and the rules for what a
## rotation does are dot-map's [DotMapRotationFile]; this game only supplies the paths.
##
## A file that is present and unreadable is an ERROR and changes nothing: rotating every
## map is a better failure than rotating none.
func load_rotation() -> DotResult:
	var paths := PackedStringArray()
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)
	if found == "" and stem != "" and (dir != "" or stem != G2GConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates",
			{"file": stem, "config_dir": dir})
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate):
			paths.append(candidate)
	var read := DotMapRotationFile.load_files(paths, "game-g2gfast")
	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates",
			{"why": read.error.message})
		rotation_file = null
		rotation_source = ""
		apply_rotation()
		return read
	rotation_file = read.value
	rotation_source = ", ".join(rotation_file.sources)
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {"paths": rotation_source, "active": rotation_file.active_name()})
	apply_rotation()
	return read


## Whether [param id] is in rotation. A map the catalogue does not hold is not.
func in_rotation(id: StringName) -> bool:
	var map: DotMapDef = maps.catalogue.get_map(id) if maps != null and maps.catalogue != null else null
	return map != null and map.in_rotation and map.enabled


## Where zones drawn in-game for map [param id] are saved and read from.
static func user_zones_path(id: StringName) -> String:
	return "user://zones/%s.json" % String(id)


## [method map_rows] as dot-menu's map menu draws them: the kind as the mode, the tier under
## it, "combat" for a map for the deathmatch layer, and "not in rotation" in the warning colour
## (every map, not the rotation: an operator keeps maps installed the rotation does not play).
static func menu_rows(rows: Array) -> Array:
	var out: Array = []
	for m: Dictionary in rows:
		var tags: Array = []
		if str(m.get("kind", "")) == "arena":
			tags.append("combat")
		if bool(m.get("workshop", false)):
			tags.append("Workshop")
		if bool(m.get("download", false)):
			tags.append("downloads when chosen")
		var rotating := bool(m.get("rotation", true))
		if not rotating:
			tags.append("not in rotation")
		out.append({"id": str(m.get("id", "")), "name": str(m.get("name", m.get("id", "?"))),
			"mode": str(m.get("kind", "")).capitalize(), "detail": "tier %d" % int(m["tier"]) if int(m.get("tier", 0)) > 0 else "",
			"tags": tags, "current": bool(m.get("current", false)), "warn": not rotating})
	return out


## Every map in the catalogue as the M screen shows it, by id: `{id, name, tier, kind,
## rotation, current}`. The offline client reads it directly; a server sends it.
func map_rows() -> Array:
	var out: Array = []
	if maps == null or maps.catalogue == null:
		return out
	var current: StringName = maps.current.id if maps.current != null else &""
	var list: Array[DotMapDef] = maps.catalogue.maps.duplicate()
	list.sort_custom(func(a: DotMapDef, b: DotMapDef) -> bool: return String(a.id) < String(b.id))
	for map in list:
		out.append({
			"id": String(map.id), "name": map.label(), "tier": map.tier,
			"kind": String(map.kind), "rotation": map.in_rotation and map.enabled,
			"current": map.id == current, "workshop": G2GMapCatalogue.is_workshop(map),
		})
	for raw in offered_maps:
		if maps.catalogue.has(StringName(raw)):
			continue
		out.append({
			"id": raw, "name": raw, "tier": 0, "kind": "", "rotation": true,
			"current": false, "download": true,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return out


## Every map on disk. See [G2GMapCatalogue] — there is no list here on purpose.
func _map_catalogue() -> DotMapCatalogue:
	return G2GMapCatalogue.discover(_map_roots())


## Extra places to look for imported maps, from the configuration.
func _map_roots() -> PackedStringArray:
	var out := PackedStringArray()
	if config != null and not config.maps_directory.is_empty():
		out.append(config.maps_directory)
	return out


## Pick up maps added to or removed from the disk since this server booted.
##
## [b]Why a server needs this at all:[/b] the point of an imported map is that an
## operator drops one in, and a game that only reads the disk once makes them restart
## to play it — which on a live server means kicking everybody to add a map.
##
## The map being played is deliberately NOT unloaded when it disappears from the disk.
## Its scene is already resident, the players on it are mid-run, and taking the world
## out from under them to enforce a directory listing is a worse outcome than letting
## the current map finish and never being chosen again.
func rescan_maps() -> Dictionary:
	if maps == null or maps.catalogue == null:
		return {"added": [], "removed": [], "total": 0}

	var playing: StringName = maps.current.id if maps.current != null else &""
	var change := G2GMapCatalogue.rescan(maps.catalogue, _map_roots())
	var _rotation := load_rotation()

	if playing != &"" and not maps.catalogue.has(playing):
		DotLog.warn(CHANNEL, "the map being played is no longer on disk",
			{"map": String(playing)})

	DotLog.info(CHANNEL, "map catalogue rescanned", {
		"added": change["added"].size(),
		"removed": change["removed"].size(),
		"total": change["total"],
	})
	maps_rescanned.emit(change)
	return change


# --- Movement cvars --------------------------------------------------------

## Rebuilds the movement from [member config] and hands it to every player.
##
## [b]What `sv_autobunnyhopping 1` does, and every run in progress is abandoned by
## it.[/b] The tunables are an input to the simulation, so a run that was half on one
## set and half on another is not comparable with anything — the same reason a tick
## rate change abandons runs. It costs everybody one attempt, and a server changing
## its movement is a server whose operator is asking for exactly that.
func apply_movement() -> void:
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	for id in players:
		var player: G2GPlayer = players[id]

		# The client restores map cvars on EXIT_TREE, after the players have left; a motor cannot be rebuilt outside the tree.
		if not player.is_inside_tree():
			continue

		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)

		var applied := player.set_movement(tunables)

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not take the new movement", {
				"player": String(id), "why": applied.error.message
			})

	DotLog.info(CHANNEL, "movement applied", {
		"autobhop": config.auto_bhop,
		"airaccel": config.air_accelerate,
		"gravity": config.gravity,
		"fingerprint": tunables.fingerprint(),
	})

	movement_changed.emit(config)


# --- Players ---------------------------------------------------------------

## match id -> record key, for the players who have one. See [method record_key].
var _record_keys: Dictionary = {}
## record key -> match id, the other way, for what the timer manager reports back.
var _match_ids: Dictionary = {}


## The key the timers, the records, the boards and the statistics know a player by.
##
## [b]Not the match id.[/b] The match id (`u<userid>`) is dot-server's sequential,
## server-local counter: it names a seat for the length of one connection, and the same
## account reconnecting is a new number (and a restarted server hands the old numbers to
## strangers). A record keyed by it was a different runner at every connection, and could
## be inherited. The key is the account's [code]session.uid()[/code] (a guest's is per
## device), given to [method add_player]. A player added without one (a solo game, the
## ghost, a client's copy, a test) is known by the match id, which is then also the key.
## A display name is never a key.
func record_key(id: StringName) -> StringName:
	return _record_keys.get(id, id)


## The match id a timer-manager key belongs to; the key itself when none does.
func match_id(key: StringName) -> StringName:
	return _match_ids.get(key, key)


## True for a key that is a server-local session number (`u<digits>`): the keying records
## carried before they were keyed by account. See [method retire_legacy_records].
static func is_legacy_key(key: StringName) -> bool:
	var text := String(key)
	return text.length() > 1 and text.begins_with("u") and text.substr(1).is_valid_int() and not text.contains("-")


func _claim_record_key(id: StringName, key: StringName) -> void:
	if key == &"" or key == id:
		return
	if _match_ids.has(key) and _match_ids[key] != id:
		# The same account twice at once would share one timer, and the second seat's
		# runs would be filed under the first's. It keeps its match id as its key: a
		# legacy-shaped key, which is never ranked.
		DotLog.warn(CHANNEL, "an account is already playing; this seat has no records", {
			"player": String(id), "key": String(key),
		})
		return
	_record_keys[id] = key
	_match_ids[key] = id


func _release_record_key(id: StringName) -> void:
	var key: StringName = _record_keys.get(id, &"")
	_record_keys.erase(id)
	if key != &"":
		_match_ids.erase(key)


static func make_fall_rules() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	rules.enabled = false
	return rules


func ghost() -> G2GPlayer:
	return players.get(GHOST_ID)


func remove_player(id: StringName) -> void:
	if effects != null:
		effects.on_player_removed(id)

	if not players.has(id):
		return

	maps.time_limit.unrock(id)
	timers.remove_player(record_key(id))
	(players[id] as G2GPlayer).queue_free()
	players.erase(id)
	_samples.erase(id)
	_standings.erase(id)
	player_removed.emit(id)
	# After the signal: the statistics layer files the player's last readings under it.
	_release_record_key(id)


## The spawn zone of [param track] in the zones the timer holds, or of the main run, or null.
func _zone_spawn(track: int) -> DotTimerZone:
	if timers == null or timers.zones == null:
		return null
	var spawn := timers.zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	if spawn == null and track != DotTimerTrack.MAIN:
		spawn = timers.zones.first_of_kind(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	return spawn


func current_map_node() -> G2GMap:
	return maps.world as G2GMap if maps != null else null


# --- The tick --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if external_tick:
		return

	var step := 1.0 / float(maxi(tick_rate, 1))
	_accumulator += delta
	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		_tick += 1
		_simulate_tick(step)

	if _accumulator >= step:
		_accumulator = 0.0


## True while the client's load gate covers the screen. Set only by a client; a server and
## every suite leave it empty, so nothing here ever waits for a cover that does not exist.
func is_covered() -> bool:
	return covered.is_valid() and bool(covered.call())


## The tick this game is on.
##
## Read rather than reconstructed. `_tick` is advanced by three different callers —
## the accumulator in `_physics_process`, `tick_once` from a netcode bridge, and
## `tick_timers_only` on a client — and anything deriving its own would be a fourth
## copy of a number that already exists.
func current_tick() -> int:
	return _tick


## One authoritative tick driven from outside, at a tick number the driver chose.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))

	if player_stack != null:
		player_stack.tick(tick)


## Feeds every timer from the players' current positions without moving anybody.
##
## The client's tick: prediction moved the local player through its behaviour and
## snapshots moved everybody else, so the only thing left to do per tick is what the
## server does after its moves — time them.
func tick_timers_only(tick: int) -> void:
	_tick = tick
	_feed_timers()


## Move every player, then time the tick with the position the move produced.
func _simulate_tick(step: float) -> void:
	# [b]Under the client's load cover only the local body moves[/b], and only while the gate
	# settles it onto the floor. The map clock, the bots, the hunters, combat, effects and
	# above all the timers wait: a run that started (or a start zone that fired) behind the
	# cover would be a time the player never played.
	if is_covered():
		for id in players:
			var body: G2GPlayer = players[id]
			if body.has_camera:
				body.simulate(_tick, step)
		return

	maps.advance(step)

	# The bots' keys, before anybody moves: see `g2g_bots.gd`.
	if bots != null:
		bots.call("drive", step)

	for id in players:
		(players[id] as G2GPlayer).simulate(_tick, step)

	# After the moves and before the timers, which is where every per-tick measurement
	# in this game belongs: the counters it reads are what the move just produced, and
	# the distance it measures is the distance that move covered.
	if progress != null:
		progress.sample(step)

	# In the order their inputs are produced: combat resolves shots against the world as the
	# tick ends (half a tick at surf speed is two metres), the hunters see where players ended up.
	if combat != null:
		combat.tick(step)
		weapon_layer.tick(step)

	if hunters != null:
		hunters.tick(step)

	if props != null:
		props.tick(step)

	# Before the timers, and it has to be: an effect that changes how somebody moves
	# has already changed it by the time the timer measures the tick, and one applied
	# after would be a tick of movement the run was not told about.
	if effects != null:
		effects.tick(step)

	if spectate != null:
		spectate.tick(step)

	_feed_timers()


func _feed_timers() -> void:
	if is_covered():
		return

	for id in players:
		var player: G2GPlayer = players[id]
		if player.timer == null or player.replay != null:
			continue
		var sample: DotTimerSample = _samples[id]
		player.fill_sample(sample)
		timers.tick_player(
			record_key(id), sample.position, sample.velocity, sample.grounded, sample.alive,
			player.controller.state.yaw, player.controller.state.pitch, sample.buttons,
			player.replay_flags()
		)


# --- Maps ------------------------------------------------------------------

func change_map(id: StringName) -> DotResult:
	# [b]Before the change, not after it.[/b] `DotMapSession.change_to` refuses an id the
	# catalogue does not hold, and on a browser client the catalogue holds nothing until
	# the pack is mounted -- so without this line a client joining a server whose map it
	# has never seen is told "no such map" about a map that is sitting on the CDN.
	var content := await ensure_map_content(id)

	if not content.ok:
		return content

	# [b]Through the protocol on a server with clients, and only there.[/b] The session's
	# own `change_to` swaps this process's world and nothing else; it is what the ad-hoc
	# version called, and then broadcast the map id to clients that had not been asked
	# whether they could load it. A client never takes this branch: its map changes when
	# the host tells it to, through `DotMapSyncClient`, which calls the session directly.
	if map_sync != null and authoritative:
		return await map_sync.change_to(id)

	return await maps.change_to(id)


func _on_map_changing(_from: DotMapDef, _to: DotMapDef) -> void:
	remove_player(GHOST_ID)
	for id in players:
		var player: G2GPlayer = players[id]
		player.forget_probes()
		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)


func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	if not rotation_ends_maps:
		DotLog.debug(CHANNEL, "the map clock ran out; the vote decides", {"reason": String(reason)})
		return

	var next := maps.rotation.choose(players.size())
	if next == null:
		return

	DotLog.info(CHANNEL, "changing map", {"reason": String(reason), "to": String(next.id)})

	var changed: DotResult = await change_map(next.id)
	if not changed.ok:
		maps.time_limit.extend(120.0)


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


# --- Timer events ----------------------------------------------------------

## `!s <n>` and `!rs` land here: [method DotTimerManager.request_stage] has already
## stopped the run and handed over the stage zone, and moving the player is the game's
## half. [b]Nothing listened until 2026-09-28[/b], so every stage destination on every
## map -- authored, imported, and checked for standability by `headless_imported` -- was
## a spot no command ever sent anybody to.
func _on_stage_requested(timer_key: StringName, _number: int, zone: DotTimerZone) -> void:
	var player_id := match_id(timer_key)
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return
	player.teleport(zone.destination, zone.destination_yaw)


## Sends a player to stage [param number]'s spot on the track they are on. The run
## stops: a stage restart is practice, never a time.
##
## Refused, with the run untouched, for a stage that has nowhere to stand: see
## [constant G2GBspMap.NO_RESTART]. The refusal comes first because the timer's own
## `request_stage` stops the run before the game is asked to move anybody.
func request_stage(id: StringName, number: int) -> DotResult:
	var why: Variant = _no_restart_reason(id, number)
	if why != null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED,
			"Stage %d has no start to send you to: %s" % [number, why])
	return timers.request_stage(record_key(id), number)


## Sends a player back to the start of the stage they are in (stage 1 before the first
## line). Shavit's `!rs`. In a stage with no restart, the start of the nearest stage
## before it that has one -- the section that stage line splits.
func restart_stage(id: StringName) -> DotResult:
	var found := timers.player(record_key(id))
	if found == null:
		return timers.restart_stage(record_key(id))
	var number := maxi(found.timer.run.stage, 1)
	while number > 1 and _no_restart_reason(id, number) != null:
		number -= 1
	return timers.request_stage(record_key(id), number)


## The reason stage [param number] on [param id]'s track cannot be restarted, or null.
func _no_restart_reason(id: StringName, number: int) -> Variant:
	var found := timers.player(record_key(id))
	if found == null or timers.zones == null:
		return null
	var zone := timers.zones.stage_zone(found.timer.track, number)
	if zone == null or not zone.payload.has(G2GBspMap.NO_RESTART):
		return null
	return str(zone.payload[G2GBspMap.NO_RESTART])


func _on_player_finished(timer_key: StringName, run: DotTimerRun) -> void:
	var player: G2GPlayer = players.get(match_id(timer_key))
	if player == null:
		return

	# Statistics in genre units, because that is what a record's viewer reads.
	var stats := player.controller.stats.to_dictionary()
	stats["max_speed"] = G2GUnits.to_units(float(stats.get("max_speed", 0.0)))
	stats["avg_speed"] = G2GUnits.to_units(float(stats.get("avg_speed", 0.0)))
	stats["max_jump_speed"] = G2GUnits.to_units(float(stats.get("max_jump_speed", 0.0)))

	timers.note_stats(timer_key, stats)
	player.controller.stats.reset()
	player.finished.emit(run)


func _on_record_refused(timer_key: StringName, run: DotTimerRun, reason: String) -> void:
	run_filed.emit(match_id(timer_key), run, 0, reason)


## Re-files the points board for everybody whose total moved. Everybody, not only the
## finisher: a new record re-scores every row on its board, and a removal or wipe moves
## the totals of people who did nothing. Replaced, not "kept if better" — see
## `running_total` on the board.
func _on_points_changed(player_ids: Array) -> void:
	if boards == null or timers.store == null:
		return
	for raw in player_ids:
		var id := StringName(str(raw))
		var standing: DotResult = await timers.store.player_rank(id)
		var info: DotResult = await timers.store.player_info(id)
		if not standing.ok:
			continue
		var name := str((info.value as Dictionary).get("name", raw)) if info.ok and info.value is Dictionary else str(raw)
		await boards.replace_async(&"points", {}, id, name, float(standing.value["points"]))


func _on_practice_finished(timer_key: StringName, run: DotTimerRun, would: int, total: int, reason: String) -> void:
	var id := match_id(timer_key)
	if would > 0:
		announced.emit(id, "%s — not recorded (%s). It would have placed %d / %d." % [
			run.formatted_time(), reason.trim_suffix("."), would, total + 1,
		], false)


## Recomputes [signal standing_changed] for a player, from the store (cached reads).
func refresh_standing(id: StringName) -> void:
	if not authoritative or timers == null or timers.store == null or maps == null or maps.current == null:
		return
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return
	var map_id := maps.current.id
	var track: int = player.timer.track
	var style: StringName = player.timer.run.style_id
	var store := timers.store
	var key := record_key(id)
	var best: DotResult = await store.best_for(map_id, track, style, key)
	var top: DotResult = await store.top(map_id, track, style, 1)
	var rank: DotResult = await store.rank_of(map_id, track, style, key)
	var total: DotResult = await store.count_on(map_id, track, style)
	if not players.has(id):
		return
	var standing := {
		"pb": (best.value as DotTimerRecord).time if best.ok and best.value is DotTimerRecord else 0.0,
		"wr": (top.value[0] as DotTimerRecord).time if top.ok and not (top.value as Array).is_empty() else 0.0,
		"rank": int(rank.value) if rank.ok else 0,
		"total": int(total.value) if total.ok else 0,
	}
	_standings[id] = standing
	standing_changed.emit(id, standing)
	await refresh_stage_reference(id)


## Recomputes [signal stage_reference_changed] for a player. A map with no stages says
## nothing: there is no panel to feed.
##
## Awaits the per-section bests before peeking them, because a database-backed store
## answers [code]peek_best[/code] from a cache that only a fetch fills; the first read after a
## map change would otherwise find nothing and the panel would show dashes until the next
## finish.
func refresh_stage_reference(id: StringName) -> void:
	if not authoritative or timers == null or timers.store == null or maps == null or maps.current == null:
		return
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return
	var track: int = player.timer.track
	var sections := timers.stage_count(track) + 1
	if sections <= 1:
		return
	var key := record_key(id)
	var style: StringName = player.timer.run.style_id
	for section in range(1, sections + 1):
		await timers.store.best_for(maps.current.id, track, style, key, section)
	if not players.has(id):
		return
	var reference := stage_reference(id)
	if not reference.is_empty():
		stage_reference_changed.emit(id, reference)


## What the splits panel compares [param id] against, from the store's cache (peeks, never
## waits), or empty with no store, no player or no stages:
## [code]{map, track, style, stages, pb: {splits, total}, wr: {splits, total}, bests}[/code].
## [code]splits[/code] are cumulative times by stage number (as
## [member DotTimerRecord.splits]), [code]total[/code] the same record's finish time and
## [code]bests[/code] the player's best time by section number, 1..stages + 1.
func stage_reference(id: StringName) -> Dictionary:
	if timers == null or timers.store == null or maps == null or maps.current == null:
		return {}
	var player: G2GPlayer = players.get(id)
	if player == null or player.timer == null:
		return {}
	var track: int = player.timer.track
	var stages := timers.stage_count(track)
	if stages <= 0:
		return {}
	var map_id := maps.current.id
	var style: StringName = player.timer.run.style_id
	var key := record_key(id)
	var store := timers.store

	var top: Variant = store.peek_top(map_id, track, style, 1)
	if top is Array:
		top = (top as Array)[0] if not (top as Array).is_empty() else null
	var bests := {}
	for section in range(1, stages + 2):
		var found: Variant = store.peek_best(map_id, track, style, key, section)
		if found is DotTimerRecord and (found as DotTimerRecord).time > 0.0:
			bests[section] = (found as DotTimerRecord).time
	return {
		"map": map_id, "track": track, "style": style, "stages": stages,
		"pb": _reference_of(store.peek_best(map_id, track, style, key)),
		"wr": _reference_of(top),
		"bests": bests,
	}


## A record's splits and total as the panel takes them; empty ones for no record. Copied:
## a record's splits are a Dictionary, and handing out the stored reference is the aliasing
## bug this family has had before.
static func _reference_of(record: Variant) -> Dictionary:
	if not (record is DotTimerRecord):
		return {"splits": {}, "total": 0.0}
	return {"splits": (record as DotTimerRecord).splits.duplicate(true), "total": (record as DotTimerRecord).time}
