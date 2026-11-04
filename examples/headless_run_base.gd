extends DotGameCheckSuite

const G2GAvatars := preload("../game/g2g_avatars.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GClient := preload("../game/g2g_client.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GEffects := preload("../game/g2g_effects.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GEvents := preload("../game/net/g2g_events.gd")
const G2GMap := preload("../game/g2g_map.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GReplays := preload("../game/g2g_replays.gd")
const G2GRig := preload("../game/g2g_rig.gd")
const G2GStats := preload("../game/g2g_stats.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GReach := preload("../game/g2g_reach.gd")

const BhopIntro := preload("res://maps/bhop_g2g_intro.gd")
const SurfIntro := preload("res://maps/surf_g2g_intro.gd")
const BhopStages := preload("res://maps/bhop_g2g_stages.gd")
const ProgressKeysCheck := preload("res://examples/progress_keys_check.gd")

## The surf map's start height, for the bonus-route bounds check below.
const START_Y := 2048.0

var _entered := 0
var _completed := 0
var game: G2GGame = null


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _near(value: float, expected: float, epsilon: float, what: String) -> void:
	_check(absf(value - expected) <= epsilon, what, "%.4f vs %.4f" % [value, expected])


## Walks forward before hopping, which is what a bunny-hopper actually does.
##
## [b]This is the genre's physics being faithful, not a bug, and it cost an hour.[/b] On
## the tick a jump fires the player is already airborne when acceleration runs, so a
## held jump key from a standstill never gets a ground-acceleration tick and creeps at
## the 30 u/s air cap for ever. Those games do exactly the same — their jump check runs
## before `WalkMove` — which is why every bhop run begins with a prestrafe.
func _prestrafe(id: StringName, ticks: int = 80) -> void:
	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)
	await _drive(id, walk, ticks)


func _drive(id: StringName, command: DotFpsCommand, ticks: int) -> void:
	var player: G2GPlayer = game.players[id]
	for _i in range(ticks):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame


# --- Spectating ------------------------------------------------------------

## Watching somebody run, which on a timer server is the point rather than a
## consolation for being dead.
func _test_spectating() -> void:
	_section("spectating")

	if game.spectate == null:
		_check(false, "the spectate layer is built")
		return

	_check(true, "the spectate layer is built")

	# A plain timer server has no sides and nobody dead, and both of those would stop
	# every other game's spectator policy dead: `force_camera 1` would restrict the
	# camera to a team that is everybody, and "dead players only" would make every
	# runner unwatchable, which is the one thing this layer exists for.
	_check(
		game.spectate.manager.rules.force_camera == 0,
		"anybody may watch anybody on a timer server",
		str(game.spectate.manager.rules.force_camera)
	)
	_check(
		game.spectate.manager.rules.allow_while_alive,
		"and a living player may watch, because standing in the start zone is not death"
	)

	var watcher := game.add_player(&"watcher", "Watcher", false)
	_check(watcher != null, "a second player joins")
	await get_tree().physics_frame

	var res := game.spectate.watch(&"watcher", &"bot")
	_check(res.ok, "and can watch the runner", str(res.error))
	_check(
		game.spectate.target_of(&"watcher") == &"bot",
		"the target is who was asked for",
		String(game.spectate.target_of(&"watcher"))
	)

	game.tick_once(game.current_tick() + 1)

	var seen := game.spectate.camera_for(&"watcher")
	var runner: G2GPlayer = game.players[&"bot"]
	_check(
		seen.origin.distance_to(runner.eye_position()) < 0.01,
		"and the camera is at the runner's eyes rather than at their feet or the origin",
		"%v against %v" % [seen.origin, runner.eye_position()]
	)

	# `!spec` with no name, which is what a spectator actually types.
	var best := game.spectate.watch_best(&"watcher")
	_check(best.ok, "watching whoever is furthest into a run picks somebody", str(best.error))

	# Free roam: on by default, a toggle, seeded from where the camera was, and the cvars'
	# rules refuse it.
	var rules := game.spectate.manager.rules
	_check(rules.allow_roaming and rules.roaming_permitted(), "free roam is on by default")
	_check(game.spectate.can_roam(&"watcher"), "and offered to a watcher")
	var before := game.spectate.camera_for(&"watcher")
	var roam := game.spectate.toggle_roam(&"watcher")
	_check(roam.ok and game.spectate.is_roaming(&"watcher"), "the free-roam key enters a roam", str(roam.error))
	_check(game.spectate.manager.view("watcher").free_position.distance_to(before.origin) < 0.01,
		"seeded from the camera it left")
	var free := DotSpectatorFreeCam.new()
	free.rules = rules
	free.seed_from(before)
	var moved := free.step(Vector3(0.0, 0.0, 1.0), false, false, 0.5)
	_check(moved.origin.distance_to(before.origin) > 1.0, "and the free camera flies forward")
	var back := game.spectate.toggle_roam(&"watcher")
	_check(back.ok and not game.spectate.is_roaming(&"watcher") and game.spectate.is_spectating(&"watcher"),
		"the same key goes back onto a player", str(back.error))
	var _again := game.spectate.toggle_roam(&"watcher")
	_check(rules.set_cvar("mp_freeroam", "0"), "mp_freeroam 0 is a valid value")
	game.tick_once(game.current_tick() + 1)
	_check(not game.spectate.is_roaming(&"watcher") and not game.spectate.can_roam(&"watcher"),
		"and takes a roamer back to a player and hides the offer")
	var refused := game.spectate.toggle_roam(&"watcher")
	_check(not refused.ok and not game.spectate.is_roaming(&"watcher"), "while off a roam is refused with a reason",
		refused.error.message if not refused.ok else "")
	var _on := rules.set_cvar("mp_freeroam", "1")
	_check(rules.set_cvar("mp_forcecamera", "1") and not rules.roaming_permitted(),
		"mp_forcecamera 1 switches it off, whatever mp_freeroam says")
	var _zero := rules.set_cvar("mp_forcecamera", "0")
	_check(rules.roaming_permitted(), "and 0 gives it back")

	game.spectate.stop(&"watcher")
	_check(
		not game.spectate.is_spectating(&"watcher"),
		"and it can be turned off"
	)

	game.remove_player(&"watcher")
	await get_tree().physics_frame
	_done()


# --- Effects, and the rule that makes them safe here ------------------------

## A movement effect is a style, and a style you did not choose is a record you did not
## set. This is the section that pins that.
func _test_effects_and_the_run() -> void:
	_section("effects")

	# The stock configuration has neither deathmatch nor hunters, so there is no
	# effects layer — which is correct and is itself worth asserting: a timer server
	# that built one would be a timer server carrying a system nothing could reach.
	_check(
		game.effects == null,
		"a plain timer server has no effects layer at all"
	)

	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.hunters = true

	var hunted := G2GGame.new()
	hunted.config = config
	add_child(hunted)

	for _i in range(60):
		await get_tree().process_frame
		if hunted.maps != null and hunted.maps.current != null:
			break

	_check(hunted.effects != null, "a hunted server builds one")

	if hunted.effects == null:
		hunted.queue_free()
		remove_child(hunted)
		return

	var runner := hunted.add_player(&"run", "Runner", true)
	runner.sampler = null
	await get_tree().physics_frame

	# Not in a run yet: the slow is allowed.
	var idle := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(idle.ok, "a slow lands on somebody who is not running", str(idle.error))
	hunted.effects.remove(G2GEffects.MAULED, &"run")

	# And the movement actually changes, which is the half that has to work for the
	# refusal below to be worth anything.
	var base := runner.base_tunables.max_speed
	var _again := hunted.effects.apply(G2GEffects.MAULED, &"run")
	hunted.tick_once(hunted.current_tick() + 1)
	_check(
		runner.controller.tunables.max_speed < base,
		"and it actually slows them",
		"%.2f from %.2f" % [runner.controller.tunables.max_speed, base]
	)

	for _i in range(30):
		hunted.tick_once(hunted.current_tick() + 1)
	_check(
		runner.controller.tunables.max_speed > 0.1,
		"without compounding to a standstill over thirty ticks",
		"%.4f" % runner.controller.tunables.max_speed
	)
	hunted.effects.remove(G2GEffects.MAULED, &"run")

	# Now in a run. The whole point of the layer.
	runner.timer.run.status = DotTimerRun.Status.RUNNING
	var refused := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(
		not refused.ok,
		"and is REFUSED on a ranked run: a style you did not choose is a record you did "
		+ "not set"
	)
	_check(
		refused.code() == DotError.CODE_FORBIDDEN,
		"with a forbidden code rather than a silent no-op",
		refused.code()
	)

	# A bleed is not a movement effect and lands regardless, which is the other half of
	# the split: being chased still has to hurt.
	var bled := hunted.effects.apply(G2GEffects.BLEEDING, &"run")
	_check(
		bled.ok or bled.code() != DotError.CODE_FORBIDDEN,
		"while a bleed lands during a run, because it cannot change a time",
		str(bled.error)
	)

	# And the server that wants hunted runs to count anyway pays for it in the field
	# dot-timer has had since it was written and nothing had ever set.
	hunted.effects.allow_movement_during_runs = true
	var tainting := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(tainting.ok, "a server may allow it", str(tainting.error))
	_check(
		runner.timer.run.tainted,
		"and the run is tainted, which is what keeps it off a board beside a clean one"
	)

	hunted.queue_free()
	remove_child(hunted)
	await get_tree().process_frame
	_done()


# --- Units and view --------------------------------------------------------

func _test_units() -> void:
	_section("genre units")
	_near(G2GUnits.to_metres(72.0), 1.3716, 0.0001, "a 72-unit player is 1.37 m")
	_near(G2GUnits.to_units(G2GUnits.to_metres(3500.0)), 3500.0, 0.001, "and the round trip is exact")
	_check(G2GUnits.format_speed(G2GUnits.to_metres(250.0)) == "250", "speed formats as whole units")
	_near(G2GUnits.sensitivity_to_degrees(2.5), 0.055, 0.0001, "sensitivity 2.5 is 0.055°/count")
	_done()


func _test_source_fov() -> void:
	_section("the genre field of view")
	# fov_desired 90 is 90° horizontal on a 4:3 frame. Vertical is 2·atan(tan(45°)·3/4).
	var vertical := G2GUnits.horizontal_fov_to_vertical(90.0)
	_near(vertical, 73.74, 0.01, "fov_desired 90 is 73.74° vertical")

	# On a 16:9 screen that vertical angle widens to what those games show.
	var horizontal_16_9 := rad_to_deg(2.0 * atan(tan(deg_to_rad(vertical) * 0.5) * 16.0 / 9.0))
	_near(horizontal_16_9, 106.26, 0.05, "which is 106.26° horizontal at 16:9, exactly the genre's")

	# The obvious mistake, named so it stays a mistake.
	var naive_16_9 := rad_to_deg(2.0 * atan(tan(deg_to_rad(90.0) * 0.5) * 16.0 / 9.0))
	_check(naive_16_9 > 120.0, "handing 90 straight to a vertical fov would be over 120° wide", "%.1f" % naive_16_9)

	_near(G2GUnits.horizontal_fov_to_vertical(75.0), 59.8, 0.1, "and 75 is 59.8°")
	_done()


func _test_movement_from_config() -> void:
	_section("movement cvars become tunables")
	var config := G2GConfig.new()
	var t := G2GMovement.tunables_for(config)

	_check(t.validate().ok, "the default configuration builds valid tunables", t.validate().error.message if not t.validate().ok else "")
	_near(t.gravity, G2GUnits.to_metres(800.0), 0.001, "sv_gravity 800 is 15.24 m/s²")
	_near(t.max_speed, G2GUnits.to_metres(250.0), 0.001, "250 u/s run speed")
	_near(t.max_air_wish_speed, G2GUnits.to_metres(30.0), 0.001, "the 30 u/s air cap")
	# Jump height reproduces the launch speed: h = v²/2g = 57 units under 800.
	_near(G2GUnits.to_units(t.jump_height), 57.0, 0.1, "jump height is 57 units, so the launch is 302 u/s")
	_near(G2GUnits.to_units(t.jump_velocity()), G2GUnits.JUMP_VELOCITY, 0.5, "and the motor's launch speed agrees")
	_near(t.stand_height, G2GUnits.to_metres(72.0), 0.001, "the hull is 72 units tall")
	_check(t.auto_hop, "auto-hop follows the config, on by default")
	_check(t.bhop_speed_cap_scale == 0.0, "and hopping builds speed")

	config.auto_bhop = false
	config.enable_bunnyhopping = false
	config.jump_buffer = 0.05
	var strict := G2GMovement.tunables_for(config)
	_check(not strict.auto_hop, "sv_autobunnyhopping 0 turns it off")
	_near(strict.jump_buffer_time, 0.05, 0.0001, "and the easy-bhop window applies then")
	_near(strict.bhop_speed_cap_scale, 1.1, 0.0001, "sv_enablebunnyhopping 0 applies CS's landing cap")

	config.air_accelerate = 150.0
	_near(G2GMovement.tunables_for(config).air_accelerate, 150.0, 0.001, "sv_airaccelerate passes through")

	# The layering an operator uses.
	var layered := G2GConfig.new()
	layered.apply_dictionary({"auto_bhop": false, "air_accelerate": 150, "fov_desired": 100})
	_check(not layered.auto_bhop and layered.air_accelerate == 150.0 and layered.fov_desired == 100.0,
		"a config file layer moves the cvars")
	_done()


# --- Boot ------------------------------------------------------------------

## Stands in for dot-cloud: records the content id asked for and has nothing.
class _RecordingCloud extends RefCounted:
	var asked: Array[String] = []

	func ensure(id: StringName, version: String = "") -> DotResult:
		asked.append(String(id) if version == "" else "%s@%s" % [id, version])
		return DotResult.fail(DotError.CODE_HTTP, "Not on this origin.")


## Stands in for dot-server's game manager while it is loading a game's scene.
class _LoadingGames extends RefCounted:
	var loading: DotGameDescriptor = null
	var running: DotGameDescriptor = null

	func pending() -> DotGameDescriptor:
		return loading

	func current() -> DotGameDescriptor:
		return running


## The first map a server fetches is fetched from the owner its game descriptor names.
##
## dot-server builds the game's scene before it applies the descriptor's `cvars:`, and
## `sv_map_content_owner` is the module's, registered later still, so the boot fetch used to
## run with no owner and ask for the unowned pack. Fails with
## [method G2GGame._adopt_descriptor_owner] taken out.
func _test_boot_map_owner() -> void:
	_section("booting: the first map comes from the owner the game descriptor names")
	const MISSING := &"surf_not_in_this_build"
	const CLOUD := &"g2g_headless_run_cloud"
	const GAMES := &"g2g_headless_run_games"

	var cloud := _RecordingCloud.new()
	var games := _LoadingGames.new()
	games.loading = DotGameDescriptor.new()
	games.loading.cvars = {G2GConfig.MAP_CONTENT_OWNER_CVAR: "someone"}
	DotRegistry.register(CLOUD, cloud)
	DotRegistry.register(GAMES, games)

	# Third: dot-server putting the previous game back after the pending one's scene was
	# missing. pending() is the game that failed; current() is the one being restored.
	var failed := DotGameDescriptor.new()
	failed.scene = "res://not_this_game/missing.tscn"
	failed.cvars = {G2GConfig.MAP_CONTENT_OWNER_CVAR: "the_failed_game"}
	var restored := DotGameDescriptor.new()
	restored.scene = "res://g2g_restored_by_headless_run.tscn"
	restored.cvars = {G2GConfig.MAP_CONTENT_OWNER_CVAR: "restored"}

	# Fourth: a descriptor that names its maps (DotGameDescriptor.maps), pinned by the
	# installer. The pinned pack and version win over the owner cvar.
	var pinned := DotGameDescriptor.new()
	pinned.cvars = {G2GConfig.MAP_CONTENT_OWNER_CVAR: "someone"}
	if "maps" in pinned:
		pinned.set("maps", PackedStringArray(["pinner/%s@0.0.0-abc123" % MISSING]))

	var booted := await _boot_owner_cases(games, CLOUD, GAMES, MISSING, failed, restored, pinned)

	_check(cloud.asked.size() == 4 and cloud.asked[0] == "someone/%s" % MISSING,
		"a server loaded for a descriptor naming an owner asks for <owner>/<map>", str(cloud.asked))
	_check(booted[0].config.map_content_owner == "someone",
		"and keeps that owner for every fetch after", booted[0].config.map_content_owner)
	_check(cloud.asked.size() == 4 and cloud.asked[1] == String(MISSING),
		"with no game being loaded the owner is the config's own (none)", str(cloud.asked))
	_check(cloud.asked.size() == 4 and cloud.asked[2] == "restored/%s" % MISSING,
		"a previous game put back after a failed change takes its own owner, not the failed game's",
		str(cloud.asked))
	_check(cloud.asked.size() == 4 and cloud.asked[3] == "pinner/%s@0.0.0-abc123" % MISSING,
		"a descriptor naming its maps gets each at the pack and version the installer pinned",
		str(cloud.asked))
	_check(Array(booted[3].config.content_maps) == [String(MISSING)],
		"and that list is the map set the server offers", str(booted[3].config.content_maps))

	for g in booted:
		remove_child(g)
		g.queue_free()
	DotRegistry.unregister_instance(CLOUD, cloud)
	DotRegistry.unregister_instance(GAMES, games)
	_done()


func _boot_owner_cases(games: _LoadingGames, cloud_service: StringName, games_service: StringName,
			missing: StringName, failed: DotGameDescriptor, restored: DotGameDescriptor,
			pinned: DotGameDescriptor) -> Array[G2GGame]:
	# Every case fails its fetch on purpose; the engine's error stream would read as a broken run.
	var booted: Array[G2GGame] = []
	var mirrored := DotLog.mirror_to_engine
	DotLog.mirror_to_engine = false

	for case in ["descriptor", "none", "restore", "pinned"]:
		var with_descriptor: bool = case != "none"
		if case == "restore":
			games.loading = failed
			games.running = restored
		if case == "pinned":
			games.loading = pinned
			games.running = null
		var config := G2GConfig.new()
		config.records_directory = ""
		config.map_seconds = 0.0
		config.initial_map = missing
		var g := G2GGame.new()
		g.config = config
		g.map_content_service = cloud_service
		g.game_manager_service = games_service if with_descriptor else &"g2g_headless_run_nothing"
		if case == "restore":
			g.scene_file_path = restored.scene
		add_child(g)
		booted.append(g)
		for _i in range(5):
			await get_tree().process_frame

	DotLog.mirror_to_engine = mirrored
	return booted


func _test_boot() -> void:
	_section("booting")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"

	game = G2GGame.new()
	game.config = config
	add_child(game)

	for _i in range(60):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps.current != null and game.maps.current.id == &"bhop_g2g_intro", "the bhop map loads")
	_check(game.timers.tick_rate == game.tick_rate and game.timers.tick_rate_matches_engine(), "the timer counts in the engine's rate")

	var zones := game.timers.zones
	_check(zones != null and zones.problems().is_empty(), "the map's zones are well formed", ", ".join(zones.problems()) if zones else "no zones")
	_check(zones != null and zones.playable_tracks() == PackedInt32Array([0, 1, 2, 3, 4]), "with a main track and four bonuses", str(zones.playable_tracks()) if zones else "")
	_check(zones != null and zones.stage_count(0) == 3, "and three stages")
	# [b]Stages on a track that is not the main one.[/b] `stage_count` takes a track and
	# every stage zone in this repository was on track 0, so the argument had only ever
	# been passed one value — a per-track count that is only ever asked about one track
	# is a constant with a parameter on it. The needle has two.
	_check(zones != null and zones.stage_count(2) == 2, "two of which are on a bonus track", str(zones.stage_count(2)) if zones else "")
	# [b]Asked on THIS map, not only on the surf one.[/b] A RESPAWN zone carries a track
	# and catches nobody on another, so a bonus without one is a player who falls out of
	# the world for ever while the same mistake on the main route puts them back on the
	# pad. The hand-written check this was had only ever been asked on the surf map —
	# and this map's two bonuses had no respawn zone at all until a bot was driven off
	# one of them and kept falling. It is dot-timer's `route_problems()` now, and
	# `_test_zone_files_match` asks it of every map.
	_check(zones != null and zones.route_problems().is_empty(),
		"and every bonus here puts a fallen player back",
		", ".join(zones.route_problems()) if zones else "no zones")
	_check(zones != null and zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate).is_empty(),
		"and no zone a 3500 u/s player passes through between ticks")

	var bot := game.add_player(&"bot", "Bot", true)
	_check(bot != null and bot.timer != null, "a local player joins with a timer")

	# A local player samples the input devices every tick, and a headless run has
	# none — so the sampler produces an empty command that overrides anything the
	# test applies. The bot keeps the camera and the rig of a local player and is
	# DRIVEN instead, which is what a bot is.
	bot.sampler = null
	_check(bot.camera != null, "and a camera")
	_check(bot.rig != null, "and a rig")

	await get_tree().physics_frame
	_check(bot.global_position.distance_to(game.current_map_node().spawn_for(0)) < 1.0, "at the map's spawn")
	_done()


func _test_avatars() -> void:
	_section("avatars")
	var schema := game.avatar_schema
	_check(schema.validate_schema().ok, "the stock schema validates", schema.validate_schema().error.message if not schema.validate_schema().ok else "")

	var bot: G2GPlayer = game.players[&"bot"]
	_check(bot.rig.avatar != null, "the player was dressed")

	# A member's site avatar, translated into this game's schema. The site's document is the
	# Kenney skins spelt `skin-c`; without a translation every member is stock here.
	var site_avatars = preload("res://game/g2g_avatars.gd")
	var site_doc := DotAvatar.make(&"builtin")
	site_doc.set_part(&"top", &"top.skin-c")
	site_doc.set_part(&"face", &"face.skin-k")
	var as_ours: DotAvatar = site_avatars.from_site(site_doc)
	_check(
		as_ours != null and site_avatars.schema().validate(as_ours).ok and as_ours.part_in(&"body") == &"body_kenney_c" and as_ours.part_in(&"head") == &"head_kenney_k",
		"a member's site avatar becomes this game's, and its schema accepts it",
		str(as_ours.to_dict()) if as_ours != null else "null"
	)
	var unknown_skin := DotAvatar.make(&"builtin")
	unknown_skin.set_part(&"top", &"top.skin-z")
	unknown_skin.set_part(&"face", &"face.skin-z")
	var not_site := DotAvatar.make(&"elsewhere")
	not_site.set_part(&"top", &"skin-c")
	_check(
		site_avatars.from_site(unknown_skin) == null and site_avatars.from_site(not_site) == null,
		"a skin this game does not draw, or a document that is not the site's, is stock"
	)
	_check(bot.rig.person != null and bot.rig.person.from_art, "with a body: one of the family's people")
	_check(bot.rig.person != null and bot.rig.person.skeleton() != null and bot.rig.person.skeleton().find_bone("Head") >= 0, "and a head")

	# Deterministic in the id, so the same player is the same character everywhere.
	var a := G2GAvatars.stock_avatar(&"alice")
	var b := G2GAvatars.stock_avatar(&"alice")
	_check(a.equals(b), "a stock avatar is the same for the same player every time")
	_check(schema.validate(a).ok, "and conforms to the schema")

	# A player's own document over the same schema dresses the same rig.
	var own := DotAvatar.make(G2GAvatars.SCHEMA_ID)
	own.set_part(G2GAvatars.SLOT_BODY, &"body_slim")
	own.set_part(G2GAvatars.SLOT_HEAD, &"head_box")
	own.set_part(G2GAvatars.SLOT_HAT, &"hat_cone")
	own.set_colour(G2GAvatars.SLOT_BODY, 0, Color.RED)

	var dressed := bot.rig.dress(own, schema, game.avatar_catalogue)
	_check(dressed.ok and int(dressed.value) == 3, "a player's own avatar dresses all three slots", str(dressed.value))
	_check(bot.rig.hat_mount.get_child_count() == 1, "including the hat")

	# One from a newer client with a part this build does not have is conformed,
	# never refused: a player is never invisible because their hat is from the future.
	var future := DotAvatar.make(G2GAvatars.SCHEMA_ID)
	future.set_part(G2GAvatars.SLOT_BODY, &"body_stock")
	future.set_part(G2GAvatars.SLOT_HEAD, &"head_stock")
	future.set_part(G2GAvatars.SLOT_HAT, &"hat_from_2031")
	var redressed := bot.rig.dress(future, schema, game.avatar_catalogue)
	_check(redressed.ok and int(redressed.value) >= 2, "an unknown part is dropped rather than refusing the whole avatar", str(redressed.value))

	bot.rig.dress(G2GAvatars.stock_avatar(&"bot"), schema, game.avatar_catalogue)
	_done()


func _test_cameras() -> void:
	_section("first and third person")
	var bot: G2GPlayer = game.players[&"bot"]
	var camera := bot.camera

	_check(camera.mode == G2GCamera.Mode.FIRST_PERSON, "starts in first person")
	_near(camera.vertical_fov(), G2GUnits.horizontal_fov_to_vertical(90.0), 0.01, "with the genre field of view")
	_check(camera.first.current, "and the first-person camera active")
	_check((camera.first.cull_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1))) == 0, "which culls the player's own rig")

	_check(camera.toggle(), "toggling switches to third person")
	_check(camera.third.current and not camera.first.current, "and the third-person camera takes over")
	_check(camera.third.cull_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1)), "which draws the rig")

	bot.present(1.0 / 60.0)
	_check(bot.rig.visible_to_owner, "and the rig is shown to its owner")

	camera.allow_third_person = false
	camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
	_check(not camera.toggle(), "a server that forbids third person refuses the toggle")
	_check(camera.mode == G2GCamera.Mode.FIRST_PERSON, "and the view stays first person")
	camera.allow_third_person = true

	# Both cameras track the aim. Third person is cosmetic: the controller aims from
	# the eye whichever is active.
	bot.controller.state.pitch = -30.0
	bot.present(1.0 / 60.0)
	_near(rad_to_deg(camera.first.rotation.x), -30.0, 0.01, "the first-person camera pitches with the view")
	_near(rad_to_deg(camera.arm.rotation.x), -30.0, 0.01, "and so does the third-person arm")
	bot.controller.state.pitch = 0.0
	await get_tree().process_frame
	_done()


# --- Auto-bhop -------------------------------------------------------------

func _test_auto_bhop_gate() -> void:
	_section("auto-bhop is the server's decision")
	var bot: G2GPlayer = game.players[&"bot"]

	# With sv_autobunnyhopping 1, holding jump chains hops. This is what the game is for.
	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	await _prestrafe(&"bot")
	bot.controller.stats.reset()
	await _drive(&"bot", hold, 300)
	var hops_on := bot.controller.stats.jumps
	_check(hops_on >= 3, "holding jump with autobhop on chains hops", "%d" % hops_on)

	# With it off, a held key jumps once: the next press has to be a new press on the
	# landing tick, and a held key is not a press.
	game.config.auto_bhop = false
	game.apply_movement()
	_check(not bot.controller.tunables.auto_hop, "sv_autobunnyhopping 0 reaches the player's tunables")
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	await _prestrafe(&"bot")
	bot.controller.stats.reset()
	await _drive(&"bot", hold, 300)
	var hops_off := bot.controller.stats.jumps
	_check(hops_off <= 1, "and with it off a held key hops once", "%d" % hops_off)

	# The cvar change abandons a run in progress: half a run on each movement is a
	# run on neither.
	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	# The start pad is 512 units long and the spawn is 400 units in; at 250 u/s the
	# line is two seconds away.
	await _drive(&"bot", forward, 400)
	_check(bot.timer.run.is_active(), "a run is going", str(bot.controller.state.describe()))
	game.config.air_accelerate = 150.0
	game.apply_movement()
	_check(not bot.timer.run.is_active(), "and changing sv_airaccelerate abandons it")
	game.config.air_accelerate = 1000.0
	game.apply_movement()
	_done()


func _test_zone_files_match() -> void:
	_section("the shipped zone files match the maps")
	# Every hand-written map the catalogue finds, and not a list of them.
	#
	# [b]This was `["bhop_g2g_intro", "surf_g2g_intro"]`, and there are three.[/b]
	# `bhop_g2g_stages` was never checked against its own sidecar, so the file in
	# `maps/` drifted away from what the map builds and nothing said a word — the same
	# stale copied list this tree has now had in `setup.sh`, `tools/check.sh`,
	# `tools/package_check.sh`, both bootstrap scripts and `tools/export_zones.gd`,
	# which is the file this loop exists to check the output of and which stopped
	# carrying a list for exactly this reason.
	for id in _hand_written_map_ids():
		var loaded := DotTimerZoneSet.load_json("res://maps/%s.zones.json" % id)
		var built: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		_check(loaded.ok and (loaded.value as DotTimerZoneSet).fingerprint() == built.fingerprint(),
			"%s's file matches what the map builds" % id)
		# `[track-zone-1]`: every route on every map, not whichever map a section
		# happens to have loaded. The respawn-on-bonuses check below was only ever asked
		# of the two maps other sections load, and `bhop_g2g_stages`' bonus had no pit.
		_check(built.route_problems().is_empty(),
			"%s's every route has a start, a finish, a spawn and a pit" % id,
			", ".join(built.route_problems()))
		var facing := _stage_facing_problems(built)
		_check(facing.is_empty(), "%s's every stage restart faces the way the route goes on" % id,
			", ".join(facing))
	await get_tree().process_frame
	_done()


## Stage zones whose `!s` yaw faces away from where the route goes next: the next stage
## line on the same track, or its finish. `[stage-yaw-1]`: three maps' main routes
## faced a restarted player back up the course, and nothing asked.
static func _stage_facing_problems(zones: DotTimerZoneSet) -> PackedStringArray:
	var out := PackedStringArray()
	for zone: DotTimerZone in zones.of_kind(DotTimerZone.Kind.STAGE):
		var next := zones.stage_zone(zone.track, int(zone.number) + 1)
		if next == null:
			next = zones.first_of_kind(DotTimerZone.Kind.END, zone.track)
		if next == null:
			continue
		var ahead := next.centre() - zone.destination
		ahead.y = 0.0
		var yaw := deg_to_rad(zone.destination_yaw)
		var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
		if facing.dot(ahead.normalized()) <= 0.0:
			out.append("%s stage %d (yaw %.0f)" % [
				DotTimerTrack.name_of(zone.track), int(zone.number), zone.destination_yaw])
	return out


## The hand-written maps: the ones with a script of their own, discovered rather than
## named. Deliberately the same question `tools/export_zones.gd` asks, because a map
## this suite does not know about is a map the exporter never wrote a file for.
func _hand_written_map_ids() -> Array:
	var out: Array = []
	for map in G2GMapCatalogue.scan():
		if not bool(map.meta.get("imported", false)):
			out.append(String(map.id))
	out.sort()
	return out


# --- What the movement can reach --------------------------------------------

## A hand-written map's script, built but never added to the tree: [method G2GMap._build]
## makes the bodies and declares the courses, and nothing else is needed to read them.
func _built_map(id: String) -> Node3D:
	var map: Node3D = (load("res://maps/%s.gd" % id) as GDScript).new()
	map.call("_build")
	return map
