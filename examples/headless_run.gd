extends Node

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

## Runs g2gfast headless: units, the genre field of view, a stock avatar on a rig,
## first and third person, auto-bhop gated by the config, and a bot down both maps.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## [/codeblock]

const BhopIntro := preload("res://maps/bhop_g2g_intro.gd")
const SurfIntro := preload("res://maps/surf_g2g_intro.gd")
const BhopStages := preload("res://maps/bhop_g2g_stages.gd")

const CHECKS := 252

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 27

## The surf map's start height, for the bonus-route bounds check below.
const START_Y := 2048.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — headless run")
	print("")

	# `-- --only=<method>[,<method>...]` boots and runs those sections in that order, for
	# working on one or finding which earlier one leaves state behind: the totals are not
	# checked and the exit code is the sections' alone.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			await _test_boot()
			for method in arg.substr(7).split(",", false):
				await Callable(self, method).call()
			print("ONLY %s: %d passed, %d failed (totals not checked)" % [arg.substr(7), _passed, _failed])
			get_tree().quit(1 if _failed > 0 else 0)
			return

	_test_units()
	_test_source_fov()
	_test_movement_from_config()
	await _test_boot()
	await _test_boot_map_owner()
	_test_avatars()
	await _test_cameras()
	await _test_auto_bhop_gate()
	await _test_zone_files_match()
	_test_reach()
	await _test_bhop_run()
	await _test_stage_command()
	await _test_needle_bonus()
	await _test_ridge_bonus()
	await _test_weave_bonus()
	await _test_bend_bonus()
	await _test_stages_descent()
	await _test_hairpin_bonus()
	await _test_stutter_bonus()
	await _test_surf_run()
	await _test_bonus_track()
	await _test_the_fall_line()
	await _test_ghost()
	await _test_progression()
	await _test_spectating()
	await _test_effects_and_the_run()
	# Last, on its own map load: the stages map's surf bonus is sensitive to what ran
	# before it (`[bank-hang-1]`), and a section placed ahead of it moved that ride.
	await _test_restart_key()

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


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

	var booted: Array[G2GGame] = []

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
		config.initial_map = MISSING
		var g := G2GGame.new()
		g.config = config
		g.map_content_service = CLOUD
		g.game_manager_service = GAMES if with_descriptor else &"g2g_headless_run_nothing"
		if case == "restore":
			g.scene_file_path = restored.scene
		add_child(g)
		booted.append(g)
		for _i in range(5):
			await get_tree().process_frame

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

## Every jump a hand-written map declares, against what the movement can do.
##
## [b]`[reach-1]`, asked of this game.[/b] game-playground's jump course was
## unfinishable past platform three and game-arena's three maps had routes nothing had
## ever climbed, and every check over all of them passed, because a box count and a
## zone file cannot tell a platform from a wall. Each map here says which of its bodies
## are a route and which reach a route is sized for (`G2GMap.add_course`); the rise and
## the gap are read off the geometry by [G2GReach], and the reach is read off the
## tunables the server applies. Nothing in this function is a number about a map.
func _test_reach() -> void:
	_section("what the movement can reach")

	var t := G2GMovement.tunables_for(game.config)
	var sweep := reach_sweep(t, game.tick_rate)

	# The one number here that is written down, and it is the genre's rather than a
	# map's: 301.99 u/s against 800 must peak at 57, or the units crossed wrongly.
	_near(G2GReach.apex(t), 57.0, 0.5, "a jump peaks at the 57 units the genre's players know")

	for line in sweep["lines"]:
		print(line)

	_check(
		(sweep["undeclared"] as Array).is_empty(),
		"every bhop map declares the courses it asks a player to jump",
		", ".join(sweep["undeclared"])
	)
	_check(
		(sweep["refused"] as Array).is_empty(),
		"and every body a course names is a level box a route can be read off",
		", ".join(sweep["refused"])
	)
	_check(
		(sweep["too_high"] as Array).is_empty(),
		"no route rises past what a jump climbs",
		"; ".join(sweep["too_high"])
	)
	_check(
		(sweep["too_far"] as Array).is_empty(),
		"no RUN route is wider than a jump from the lip at run speed",
		"; ".join(sweep["too_far"])
	)
	_check(
		(sweep["unchainable"] as Array).is_empty(),
		"and no CHAIN is out of reach from its start line even strafing perfectly",
		"; ".join(sweep["unchainable"])
	)

	# [b]The check can say no, and the cvar is why it matters.[/b] With
	# `sv_enablebunnyhopping 0` the landing cap trims every take-off to 275 u/s, so a
	# chain can only ever add one hop's strafing to that — and bhop_g2g_intro's main
	# route asks for a period no such hop spans. That is a property of the map a server
	# operator needs to know before turning the cvar off, and it is also the proof that
	# the chain arithmetic refuses something rather than approving everything.
	var capped_config: G2GConfig = game.config.duplicate()
	capped_config.enable_bunnyhopping = false
	var capped := G2GMovement.tunables_for(capped_config)
	var intro := _built_map("bhop_g2g_intro")
	var main_routes := G2GReach.measure((intro.courses[0] as Object).get("bodies"))
	var verdict := G2GReach.chain(main_routes, capped, game.tick_rate, 1.0)
	print("  ..    with sv_enablebunnyhopping 0, bhop_g2g_intro's main line falls at %s (%.0f u short)"
		% [(main_routes[int(verdict["at"])] as G2GReach.Route).name if not verdict["ok"] else "nothing", float(verdict["short"])])
	_check(
		not bool(verdict["ok"]),
		"and with the landing cap on, bhop_g2g_intro's main line is not a route at all",
		"it chained to the end at %.0f u/s" % float(verdict["top"])
	)
	intro.free()
	_done()


## A hand-written map's script, built but never added to the tree: [method G2GMap._build]
## makes the bodies and declares the courses, and nothing else is needed to read them.
func _built_map(id: String) -> Node3D:
	var map: Node3D = (load("res://maps/%s.gd" % id) as GDScript).new()
	map.call("_build")
	return map


## Every declared course on every hand-written map, decided. Separate from the checks
## so the numbers can be printed whether or not anything fails — a detail line only
## shows on a failure, and the widths and the strafe a chain needs are the measurement.
func reach_sweep(t: DotFpsTunables, tick_rate: int) -> Dictionary:
	var out := {
		"lines": [], "undeclared": [], "refused": [], "too_high": [], "too_far": [],
		"unchainable": [], "restarts": [],
	}

	out["lines"].append(
		"  ..    a jump peaks at %.1f u, climbs %.1f; from the lip at %.0f u/s it clears %.0f flat, %.0f onto +24, %.0f down 48; a perfect strafe adds %.0f u/s a tick"
		% [G2GReach.apex(t), G2GReach.climb_limit(t), G2GReach.run_speed(t),
			G2GReach.run_reach(0.0, t), G2GReach.run_reach(24.0, t), G2GReach.run_reach(-48.0, t),
			G2GReach.strafe_gain(t, tick_rate)]
	)

	for id in _hand_written_map_ids():
		var map := _built_map(id)
		var zones: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		var courses: Array = map.get("courses")

		if courses.is_empty():
			out["lines"].append("  ..    %s declares no course" % id)
			if id.begins_with("bhop_"):
				out["undeclared"].append(id)

		for course: Object in courses:
			var refused: Array = []
			var routes := G2GReach.measure(course.get("bodies"), refused)
			var label := "%s %s" % [id, course.get("name")]

			for index in refused:
				out["refused"].append("%s body %d" % [label, index])

			var widest := 0.0
			var widest_route: G2GReach.Route = null

			for route: G2GReach.Route in routes:
				widest = maxf(widest, route.gap)
				if widest_route == null or route.gap > widest_route.gap:
					widest_route = route

				if G2GReach.walked(route, t):
					continue

				if route.rise > G2GReach.climb_limit(t):
					out["too_high"].append("%s %s rises %.0f u" % [label, route.name, route.rise])
					continue

				if int(course.get("kind")) == G2GReach.Kind.RUN:
					var reach := G2GReach.run_reach(route.rise, t)
					if route.gap > reach:
						out["too_far"].append("%s %s is %.0f u against %.0f" % [label, route.name, route.gap, reach])

			# [b]Against the reach from the widest gap's OWN height[/b], which is what the
			# check above asks. This printed the flat reach whatever the landing, so the
			# ridge read "widest 192 u against a standing jump's 189" -- a failure on the
			# page for a gap that is a drop of 48 with 222 to spare, and passing.
			if int(course.get("kind")) == G2GReach.Kind.RUN:
				out["lines"].append("  ..    %s: RUN, %d jumps, widest %s" % [
					label, routes.size(), _reach_text(widest_route, t)])
				continue

			var needed := G2GReach.strafe_needed(routes, t, tick_rate)
			var from_start := G2GReach.chain(routes, t, tick_rate, 1.0)

			if not bool(from_start["ok"]):
				out["unchainable"].append("%s falls at %s, %.0f u short" % [
					label, (routes[int(from_start["at"])] as G2GReach.Route).name, float(from_start["short"])
				])

			out["lines"].append("  ..    %s: CHAIN, %d hops, widest %.0f u, from the start line needs %s"
				% [label, routes.size(), widest, _percent(needed)])

			# `!s<n>` puts a player on a stage line at a standstill, so from there the
			# chain begins again at run speed rather than at what the stages before it
			# built. Found by the stage zone's own destination, not by an index.
			for zone in zones.zones:
				if zone.kind != DotTimerZone.Kind.STAGE or zone.track != int(course.get("track")):
					continue

				var at := G2GUnits.vector_to_units(zone.destination)
				var from_index := -1

				for i in range(routes.size()):
					var landing := G2GReach.footprint((routes[i] as G2GReach.Route).to_body)
					if Geometry2D.is_point_in_polygon(Vector2(at.x, at.z), landing["corners"]):
						from_index = i + 1
						break

				var restart := G2GReach.strafe_needed(routes, t, tick_rate, from_index) if from_index >= 0 else 2.0
				out["restarts"].append([label, int(zone.number), restart])
				out["lines"].append("  ..      !s%d from a standstill%s: needs %s" % [
					int(zone.number),
					"" if from_index >= 0 else " (its destination is on no body of the course)",
					_percent(restart),
				])

		map.free()

	return out


## "192 u down 48, inside the 222 a jump from its lip reaches": a RUN gap beside the
## reach [method reach_sweep] judges it by, which depends on the landing's height.
static func _reach_text(route: G2GReach.Route, t: DotFpsTunables) -> String:
	if route == null:
		return "none"
	var height := ""
	if route.rise > 0.5:
		height = " onto +%.0f" % route.rise
	elif route.rise < -0.5:
		height = " down %.0f" % -route.rise
	var reach := G2GReach.run_reach(route.rise, t)
	return "%.0f u%s, %s the %.0f a jump from its lip reaches there" % [
		route.gap, height, "inside" if route.gap <= reach else "PAST", reach]


static func _percent(fraction: float) -> String:
	if fraction > 1.0:
		return "more than a perfect strafe — nobody can"
	if fraction <= 0.0:
		return "no strafe at all"
	return "%d%% of a perfect strafe" % int(ceil(fraction * 100.0))


# --- Runs ------------------------------------------------------------------

## `!s <n>` and `!rs`: the game moves the player the timer names, facing on, and stops
## the run. `[stage-yaw-1]` found nothing listened to `stage_requested`.
func _test_stage_command() -> void:
	_section("a stage restart")
	var bot: G2GPlayer = game.players[&"bot"]
	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var sent := game.request_stage(&"bot", 2)
	var zone: DotTimerZone = sent.value if sent.ok else null
	_check(zone != null and bot.global_position.distance_to(zone.destination) < 0.01,
		"`!s 2` puts the player on stage 2's own spot",
		str(bot.global_position) if zone == null else "%s vs %s" % [bot.global_position, zone.destination])
	_check(zone != null and is_equal_approx(bot.controller.state.yaw, zone.destination_yaw),
		"facing the stage's own yaw", "%.1f" % bot.controller.state.yaw)
	_check(not bot.timer.run.is_running(), "and no run is going: a stage restart is practice")
	_check(not game.request_stage(&"bot", 9).ok, "a stage the track does not have is refused")

	var back := game.restart_stage(&"bot")
	_check(back.ok and bot.global_position.distance_to((back.value as DotTimerZone).destination) < 0.01
			and int((back.value as DotTimerZone).number) == 1,
		"`!rs` before any stage line is stage 1")

	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## R and R twice: `G2GGame.restart`, which both the offline client and the server's
## RESTART request call. One R is the start of the stage you are in, and the start of the
## track when you are in none; two are the main start zone, from a bonus too.
func _test_restart_key() -> void:
	_section("R once is the stage, R twice is the start")
	var loaded: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(loaded.ok, "bhop_g2g_intro loads, for its staged main route and its bonuses")
	await get_tree().physics_frame
	var bot: G2GPlayer = game.players[&"bot"]
	var map: G2GMap = game.current_map_node() as G2GMap
	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var start := bot.global_position

	# A run past the first stage line, put there directly: driving one is what the route
	# sections are for, and what is being asked here is only where R sends it.
	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.RUNNING
	bot.timer.run.stage = 2
	var once := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	var stage_two := game.timers.zones.stage_zone(DotTimerTrack.MAIN, 2)
	_check(once.ok and stage_two != null and bot.global_position.distance_to(stage_two.destination) < 0.01,
		"one R in stage 2 is the start of stage 2", "%s" % bot.global_position)
	_check(not bot.timer.run.is_running(), "and stops the run, because a stage restart is practice")

	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.RUNNING
	bot.timer.run.stage = 1
	var _first := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.global_position.distance_to(start) < 0.01, "in stage 1 it is the start zone")

	bot.teleport(start + Vector3(0.0, 0.0, -40.0), 0.0)
	bot.timer.run.status = DotTimerRun.Status.STOPPED
	bot.timer.run.stage = 3
	var _idle := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.global_position.distance_to(start) < 0.01, "and with no run going it is the start zone too")

	game.timers.set_player_track(&"bot", 1)
	var bonus_spawn := map.spawn_for(1) if map != null else Vector3.ZERO
	var _bonus := game.restart(&"bot", G2GEvents.RESTART_STAGE)
	_check(bot.timer.track == 1 and bot.global_position.distance_to(bonus_spawn) < 1.0,
		"on a bonus one R is the bonus's start", "%s vs %s" % [bot.global_position, bonus_spawn])
	var _twice := game.restart(&"bot", G2GEvents.RESTART_MAIN)
	_check(bot.timer.track == DotTimerTrack.MAIN and bot.global_position.distance_to(start) < 0.01,
		"and two are the main start zone")

	var watcher := game.add_player(&"watcher", "Watcher", false)
	await get_tree().physics_frame
	var _watching := game.spectate.watch(&"watcher", &"bot")
	var _r := game.restart(&"watcher", G2GEvents.RESTART_STAGE)
	_check(not game.spectate.is_spectating(&"watcher"), "R stops spectating: a player who pressed it wants to run")
	game.remove_player(&"watcher")

	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


func _test_bhop_run() -> void:
	_section("a bhop run")
	var bot: G2GPlayer = game.players[&"bot"]
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var finished: Array[DotTimerRun] = []
	var filed := []
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))
	game.run_filed.connect(func(_id: StringName, _run: DotTimerRun, rank: int, reason: String) -> void: filed.append([rank, reason]))

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	await _prestrafe(&"bot", 100)
	bot.controller.stats.reset()

	var top := 0.0
	for i in range(900):
		bot.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
		top = maxf(top, bot.speed())
		if not finished.is_empty():
			break

	_check(bot.timer.runs_started >= 1, "leaving the start pad starts the run")
	# Kept, not gained: a straight-line hopper has no strafe to gain from, so the
	# most it can do is not lose the prestrafe to friction — which a held key on a
	# server with autobhop does, and a tapped one usually does not.
	_check(G2GUnits.to_units(top) >= 240.0, "and hopping keeps the run speed friction would have taken", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.stats.perfect_ratio() > 0.9, "with the hops perfect, because the key is held", "%.2f" % bot.controller.stats.perfect_ratio())

	# A straight-line bot cannot strafe, so it falls at the wide gaps — and the
	# respawn zone then abandons its run, which is correct. Start a fresh one and put
	# it in the finish: the run machinery, not the bot's driving, is under test.
	if finished.is_empty():
		game.spawn_player(&"bot")
		await get_tree().physics_frame

		# Driven until the run starts rather than for a fixed 420 ticks. That number
		# was tuned when `DotTimer.effect_requested` was emitted by nothing, so the
		# map's respawn zone did nothing and a fallen bot simply kept going: now it
		# is put back on the start pad, and a fixed drive long enough to leave the
		# pad is also long enough to fall off, be reset, and be standing on the pad
		# again with no run at the moment the check runs.
		var waited := 0

		while not bot.timer.run.is_running() and waited < 600:
			await _prestrafe(&"bot", 20)
			waited += 20

		_check(bot.timer.run.is_running(), "a fresh run is going", "%d ticks" % waited)
		var end := game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0)
		bot.controller.state.position = end.centre() + Vector3.UP * 0.3
		bot.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
		var forward := DotFpsCommand.new()
		forward.move = Vector2(0.0, 1.0)
		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes once", "%d" % finished.size())
	if finished.size() == 1:
		_check(finished[0].stats.has("max_speed") and float(finished[0].stats["max_speed"]) > 100.0,
			"with statistics in genre units", str(finished[0].stats.get("max_speed")))
	for _i in range(5):
		await get_tree().process_frame
	_check(filed.size() == 1, "and is offered to the store", str(filed))

	var page: DotResult = await game.boards.page(&"fastest", {"map": "bhop_g2g_intro", "track": "0", "style": "normal"})
	_check((page.value as Array).size() >= 1 or (filed.size() == 1 and filed[0][1] != ""),
		"and reaches the leaderboard, or says why not", str(filed))
	_done()


## Whether a bot at [param z_units] on the needle should be holding jump this tick.
##
## [b]The map's arithmetic, not a copy of it.[/b] `-z_units` is how far down the route
## the bot has come; the blocks repeat every `BLOCK_LENGTH + NEEDLE_GAP`, occupying the
## first `BLOCK_LENGTH` of each cycle. Jump in the last thirty units of a block and
## nowhere else: airborne the answer stops mattering, because with `auto_hop` a jump is
## taken on the landing tick and the key is long since released by then.
##
## Nothing before the start line, where the bot is building the speed it will spend.
func _needle_jumps_at(z_units: float) -> bool:
	if z_units >= 0.0:
		return false

	var cycle := BhopIntro.BLOCK_LENGTH + BhopIntro.NEEDLE_GAP

	return fposmod(-z_units, cycle) >= BhopIntro.BLOCK_LENGTH - 30.0


## `the needle`: a bonus a scripted bot can run from its start line to its finish.
##
## [b]This is the first route in this repository a bot completes end to end, and the
## map was shaped so that it could be.[/b] Every other bonus here is checked by putting
## a bot on the pad, driving it, and asserting where it ENDED — because a straight-line
## bot cannot strafe, cannot gain speed, and so cannot clear a gap that demands a gain.
## `bhop_g2g_intro`'s main route is exactly such a gap by its tenth block, and the surf
## bonuses need a strafe to stay on a bank at all.
##
## The needle keeps its gap at a constant 96 units, which a player at run speed clears
## without gaining anything, and puts the difficulty in the landing instead. That makes
## it hard for a person and possible for a bot — and a route a bot can run is a route
## whose geometry, zones, stage splits and finish are all checked by something other
## than reading them.
##
## So the assertions here are the ones the other bonuses cannot make: the run starts at
## the start line, BOTH stage splits are crossed in order, and the finish line ends it.
## A block moved 100 units fails this; it fails nothing anywhere else.
func _test_needle_bonus() -> void:
	_section("the needle, run end to end")

	var bot: G2GPlayer = game.players[&"bot"]
	var needle := DotTimerTrack.of_bonus(2)

	_check(game.timers.set_player_track(&"bot", needle), "a player can switch to the needle")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(needle)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"and spawns on its own pad rather than the main one",
		"%.1f m from the main spawn"
			% bot.global_position.distance_to(game.current_map_node().spawn_for(DotTimerTrack.MAIN))
	)

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so `reset = true` inside
	# one never reached this function and "without ever being put back" could not fail.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))

	# [b]Jumped AT the gaps, not held.[/b] This is the whole reason the route is
	# runnable, and it was measured here rather than assumed: a bot that holds jump on a
	# server with `sv_autobunnyhopping 1` leaves the ground on the tick it lands, so
	# `accelerate` never gets a grounded tick to work in and there is no strafe to gain
	# in the air — so it bleeds to `sv_maxairwishspeed`, which is 30 u/s. Driven that way
	# it carried the prestrafe across two gaps and fell at the third, every time.
	#
	# Pressing jump only in the last thirty units of a block keeps it grounded for the
	# rest of each one, which is where `accelerate` puts the speed back. The window is
	# read out of the MAP's own constants rather than written down here, so moving a
	# block moves the bot's jump with it; a copied number would be this tree's own stale
	# list at the size of a test that silently stops proving anything.
	await _prestrafe(&"bot", 120)

	var started := false
	var top := 0.0
	var deepest := 0.0
	var resets := 0

	for _i in range(2600):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_needle_jumps_at(G2GUnits.vector_to_units(bot.global_position).z)
		)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		deepest = minf(deepest, G2GUnits.vector_to_units(bot.global_position).z)

		if reset[0]:
			resets += 1
			reset[0] = false

		if bot.timer.run.is_active():
			started = true

		if not finished.is_empty():
			break

	print("  ..    needle: top %.0f u/s, reached z %.0f u, %d resets" % [top, deepest, resets])

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)

	_check(started, "leaving its pad starts a run on the needle's own track")
	_check(
		deepest <= BhopIntro.needle_end_z(),
		"and the bot reaches the far end of the blocks rather than falling short",
		"reached %.0f u of %.0f" % [deepest, BhopIntro.needle_end_z()]
	)
	_check(
		splits == [1, 2],
		"crossing both of its stage lines, in order",
		"%s, ended at %s u, %s u/s" % [
			str(splits),
			str(G2GUnits.vector_to_units(bot.global_position).round()),
			G2GUnits.format_speed(bot.speed())
		]
	)
	_check(
		finished.size() == 1 and finished[0].track == needle,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished" % finished.size()
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## Whether a bot at [param z_units] on the ridge should be holding jump: in the last
## twenty units of the start pad or of any block, read off the MAP's own list of blocks
## so moving one moves the jump with it. Twenty rather than the needle's thirty because
## the ridge's gaps are wider, and every unit before the lip is a unit off the reach.
func _ridge_jumps_at(z_units: float) -> bool:
	var edges: Array = [BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5]
	for block: Dictionary in BhopStages.ridge_blocks():
		edges.append(float(block["far"]))
	for far: float in edges:
		if z_units >= far and z_units - far <= 20.0:
			return true
	return false


## `the ridge`, `bhop_g2g_stages` bonus 2, run end to end by a bot that cannot strafe:
## up five steps, along a crest that narrows to 80 units, down five drops, through
## both stage splits into the finish, without once being put back. The second route
## here a bot runs from start line to finish, and shaped RUN for the needle's reason.
func _test_ridge_bonus() -> void:
	_section("the ridge, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var ridge := DotTimerTrack.of_bonus(2)
	var zones := game.timers.zones
	_check(zones != null and zones.playable_tracks() == PackedInt32Array([0, 1, 2, 3, 4])
		and zones.stage_count(ridge) == 2,
		"with a second bonus that has two stages (and a third, the weave, and a fourth, the bend)",
		str(zones.playable_tracks()) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", ridge), "a player can switch to the ridge")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so `reset = true` inside
	# one never reached this function and "without ever being put back" could not fail.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	await _prestrafe(&"bot", 120)

	var started := false
	var resets := 0
	var top := 0.0
	var deepest := 0.0
	var highest := -INF
	var entry := G2GUnits.vector_to_units(bot.global_position)
	var descent := _DescentLedger.new()

	for _i in range(4000):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_ridge_jumps_at(G2GUnits.vector_to_units(bot.global_position).z)
		)
		var before := G2GUnits.vector_to_units(bot.global_position)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		var at := G2GUnits.vector_to_units(bot.global_position)
		if not reset[0]:
			descent.add(before.y - at.y, bot.controller.state)
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		deepest = minf(deepest, at.z)
		highest = maxf(highest, at.y)
		if reset[0]:
			resets += 1
			reset[0] = false
		if bot.timer.run.is_active():
			started = true
		if not finished.is_empty():
			break

	print("  ..    ridge: top %.0f u/s, highest %.0f u, reached z %.0f u, %d resets, %s" % [
		top, highest, deepest, resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	# `[surf-ramp-1]`'s question, asked of this route: where its descent comes from.
	var pad := BhopStages.ridge_pad()
	print("  ..    ridge descent: %.0f u covered of a %.0f u route, %s" % [
		entry.z - deepest, entry.z - pad.z, descent.describe()])

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	_check(started, "leaving its pad starts a run on the ridge's own track")
	_check(highest >= 120.0, "the bot climbs to the crest", "highest %.0f u" % highest)
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(
		finished.size() == 1 and finished[0].track == ridge,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())]
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()

## Where every timed route on `bhop_g2g_stages` gets its descent from (`[surf-ramp-1]`).
##
## [b]Printed, not asserted, as `surf_g2g_intro`'s was.[/b] A check named after surf
## is satisfied by a player falling, so the honest detector is the numbers themselves:
## how far a bot got against how long the route is, and how much of the height it lost
## while standing on the surface the route is named after, against in the air.
##
## The main route is a CHAIN nobody scripted can run (it needs a strafe), so its answer
## is read off `_course()`; the ridge's is from `_test_ridge_bonus`'s own drive; the
## surf bonus is driven here, and since `[stages-slabs-1]` asserted: its slabs stand at
## `BONUS_RAMP_PITCH` (50°), past the 45.57° a player can stand on, so a bot that holds into
## the west face rides it to the finish (at 45 it landed on the slope and stopped).
##
## [b]Still timing-dependent, and the cause is not here[/b] (2026-10-12): the rider hangs in
## the crease between the slabs at x 6144 with 11.5 m/s along it and its position frozen
## (dot-player-controller's surf-crease hang), and when it lets go depends on the tick the ride
## starts on. Started 0 to 100 physics frames later it finishes in 1243 to 1288 ticks; 300
## later, it never lets go. In the full run that start tick moves with the machine's load, which
## is the flake. Queue item `g2gfast-surf-crease-hang-1`.
## How far west of the crease between the stages bonus's slabs the descent's bot lets go of
## the face, in units.
const CREASE_RELEASE := 48.0


func _test_stages_descent() -> void:
	_section("where bhop_g2g_stages' descent comes from")

	var course := BhopStages._course()
	var up := 0.0
	var down := 0.0
	var y := BhopStages.FLOOR_Y
	for block: Dictionary in course:
		var step := float(block["y"]) - y
		if step > 0.0:
			up += step
		else:
			down -= step
		y = float(block["y"])
	print("  ..    main: not ridden (a CHAIN needs a strafe no scripted bot has); the finish is %.0f u under the start, %.0f u down in stage 4's drops and %.0f u up in stage 3's climb, every unit of it between blocks, in the air" % [
		BhopStages.FLOOR_Y - y, down, up])

	var on_stages: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(on_stages.ok, "the stages map is loaded for its bonus")
	if not on_stages.ok:
		_done()
		return
	# The movement a fresh server has: the sections before this one set what they need and
	# do not all put it back (in the full run the ride got two thirds of the way; alone, all).
	var fresh := G2GConfig.new()
	for field in G2GConfig.MOVEMENT_FIELDS:
		game.config.set(field, fresh.get(field))
	game.apply_movement()
	var bot: G2GPlayer = game.players[&"bot"]
	var surf := DotTimerTrack.of_bonus(1)
	_check(game.timers.set_player_track(&"bot", surf), "a player can switch to the surf bonus")
	game.spawn_player(&"bot")
	# A command of nothing for the tick after the spawn. Without it the controller repeats the
	# last command it was given (a starved tick does), which is the previous section's: in the
	# full run the bot began the ride turned to -81.6 degrees and already moving, so where it
	# went depended on which sections ran before this one and how they ended.
	bot.controller.apply_command(DotFpsCommand.new())
	await get_tree().physics_frame

	var reset: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true
	var on_finished := func(_run: DotTimerRun) -> void: finished[0] = true
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	# Off the pad's front edge over the west slab rather than down the middle: the two
	# slabs' low edges are 318 u apart, and a player walking straight off the pad falls
	# between them into the pit. So sideways first, to 200 u west of the centre line,
	# then forward along -Z and nothing else.
	var entry := G2GUnits.vector_to_units(bot.global_position)
	var deepest := entry.z
	var descent := _DescentLedger.new()
	var ticks := 0

	# Then the single-bank rule (`_test_single_bank`): once on the face, hold west (into it)
	# while below a line partway up it, let go above, and forward throughout.
	var hold_line := BhopStages.BONUS_X - 520.0
	for i in range(2400):
		var at := G2GUnits.vector_to_units(bot.global_position)
		var c := DotFpsCommand.new()
		c.yaw = 0.0
		if at.y > 900.0:
			# On the pad: across to the west slab's side, then off its FRONT edge (its side
			# is in front of where the slabs begin).
			c.move = Vector2(-1.0, 0.0) if at.x > BhopStages.BONUS_X - 200.0 else Vector2(0.0, 1.0)
		else:
			# Never into the face once in the crease between the slabs: pressed into one face
			# with the other underneath, the motor's duplicate-plane early-out pins the rider
			# there (dot-player-controller's crease hang), and whether a ride reached the crease
			# pressing or not depended on what the sections before this one left in the world.
			var into := at.x > hold_line and at.x < BhopStages.BONUS_X - CREASE_RELEASE
			c.move = Vector2(-1.0 if into else 0.0, 1.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		ticks = i + 1
		var now := G2GUnits.vector_to_units(bot.global_position)
		if reset[0] or finished[0]:
			break
		descent.add(at.y - now.y, bot.controller.state)
		deepest = minf(deepest, now.z)

	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var finish_z := BhopStages.START_Z - 3072.0
	print("  ..    surf bonus: %.0f u covered of a %.0f u route in %d ticks, %s; %s" % [
		entry.z - deepest, entry.z - finish_z, ticks, descent.describe(),
		"finished" if finished[0] else ("put back by the pit" if reset[0] else "not finished")])
	_check(finished[0] and not reset[0], "the surf bonus is surfed: a bot holding into the face rides it to the finish",
		"%.0f u of %.0f, %s" % [entry.z - deepest, entry.z - finish_z, "put back by the pit" if reset[0] else "not finished"])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## Height lost, split by what the player was on when it was lost: a face tilted more
## than 30° (the named surface on a surf route), level ground, or nothing. Height
## GAINED is not subtracted from any bucket -- a jump's rise is not descent -- so the
## three add up to more than start minus finish on a route that climbs.
class _DescentLedger:
	var on_slope := 0.0
	var on_flat := 0.0
	var in_air := 0.0

	func add(dropped: float, state: DotFpsState) -> void:
		if dropped <= 0.0:
			return
		if not state.is_grounded():
			in_air += dropped
		elif state.ground_normal.angle_to(Vector3.UP) > deg_to_rad(30.0):
			on_slope += dropped
		else:
			on_flat += dropped

	func describe() -> String:
		var total := on_slope + on_flat + in_air
		return "%.0f u of descent: %.0f standing on a slope, %.0f on level ground, %.0f in the air (%d%%)" % [
			total, on_slope, on_flat, in_air, int(round(100.0 * in_air / maxf(total, 1.0)))]


## Which hairpin piece a bot at [param at] (x, z units) is over, never going backwards
## from [param current]: -1 is the start pad. A piece counts once the bot is inside its
## footprint, which it is only on landing or on the way down to it.
func _hairpin_piece(blocks: Array, current: int, at: Vector2) -> int:
	for i in range(blocks.size() - 1, current, -1):
		var centre: Vector3 = blocks[i]["centre"]
		var half: Vector2 = (blocks[i]["extent"] as Vector2) * 0.5
		if absf(at.x - centre.x) <= half.x and absf(at.y - centre.z) <= half.y:
			return i
	return current


## `the weave`, `bhop_g2g_stages` bonus 3: fourteen blocks, each off to the other side of
## the one before, run end to end by the hairpin's kind of bot.
##
## [b]It takes the line, not the zigzag.[/b] It faces a point just inside the inner edge
## of the block it is jumping for (the edge on the centre line), and jumps in the last
## twenty units before its line of travel leaves the block it is on.
## That is the route's whole question. Holding forward along -Z, as the ridge's bot does,
## lands between the blocks on the first jump. The pace is asserted as well as the
## finish: covering the route at under 80% of run speed would mean the bot stopped to
## line jumps up, and a route that only works at a crawl is not a RUN line.
func _test_weave_bonus() -> void:
	_section("the weave, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var weave := DotTimerTrack.of_bonus(3)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(weave) == 2,
		"with a third bonus that has two stages",
		str(zones.stage_count(weave)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", weave), "a player can switch to the weave")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopStages.weave_blocks()
	var pad := BhopStages.weave_pad()
	# The start pad as piece -1, so the bot has something to leave from.
	var start_rect := Rect2(BhopStages.WEAVE_X - 128.0, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5,
		256.0, BhopStages.RIDGE_PAD_LENGTH)

	var route_length := 0.0
	var last := Vector2(BhopStages.WEAVE_X, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5)
	for block: Dictionary in blocks:
		var middle := Vector2((block["centre"] as Vector3).x, (block["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle
	route_length += last.distance_to(Vector2(pad.x, pad.z + 192.0))

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so a bool set inside
	# one never reaches this function.
	var reset: Array[bool] = [false]
	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true
	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)
	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	var resets := 0
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)
	var goal := 0

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)
		var rect := start_rect if piece < 0 else _block_rect(blocks[piece])
		# The line a player takes: past the blocks' INNER corners, the ones on the
		# centre line, because that is where one block meets the next. So aim 32 units
		# in from the inner edge of the block it is jumping for, 48 past its near edge,
		# on the ground and in the air alike; and keep that block as the aim until
		# landing on it, because passing over its footprint on the way down is not
		# reaching it.
		var grounded := bot.controller.state.is_grounded()
		if grounded and rect.has_point(at):
			goal = piece + 1
		var target := Vector2(pad.x, pad.z + 128.0)
		if goal < blocks.size():
			var next: Vector3 = blocks[goal]["centre"]
			var half: Vector2 = (blocks[goal]["extent"] as Vector2) * 0.5
			var inward := -signf(next.x - BhopStages.WEAVE_X)
			target = Vector2(next.x + inward * (half.x - 32.0), next.z + half.y - 48.0)
		var aim := target - at
		var to_lip := _rect_exit(rect, at, aim.normalized()) if grounded and rect.has_point(at) else -1.0
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
			goal = 0
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    weave: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, block %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, furthest + 1, blocks.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest == blocks.size() - 1, "the bot reaches the last block", "block %d of %d" % [furthest + 1, blocks.size()])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(finished.size() == 1 and finished[0].track == weave,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every jump is taken on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## `the bend`, `bhop_g2g_stages` bonus 4: ten blocks round a 640-unit left-hand arc,
## each 22.5 degrees on from the last (30 on the drops), climbing then dropping onto a finish that faces
## nearly back the way the run began.
##
## [b]It turns on every jump.[/b] It faces the middle of the block it is jumping for,
## 32 units short of it, and jumps in the last twenty units before its line of travel
## leaves the block it is on -- both measured in that block's own frame, since every
## block is turned. Holding one heading, as the ridge's bot does, leaves the arc at the
## second block. The pace is asserted as for the weave: a RUN line that only works at a
## crawl is not one.
func _test_bend_bonus() -> void:
	_section("the bend, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_stages")
	_check(changed.ok, "the stages map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var bend := DotTimerTrack.of_bonus(4)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(bend) == 2,
		"with a fourth bonus that has two stages",
		str(zones.stage_count(bend)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", bend), "a player can switch to the bend")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopStages.bend_blocks()
	var pad: Dictionary = BhopStages.bend_pad()
	var pad_centre: Vector3 = pad["centre"]
	# The start pad and the finish pad as pieces too, in the blocks' own shape.
	var start := {"centre": Vector3(BhopStages.BEND_X, 0.0, BhopStages.START_Z), "yaw": 0.0,
		"width": 256.0, "length": BhopStages.RIDGE_PAD_LENGTH}
	var pieces: Array = []
	for block: Dictionary in blocks:
		pieces.append({"centre": block["centre"], "yaw": block["yaw"], "width": block["width"],
			"length": BhopStages.BEND_BLOCK_LENGTH})
	pieces.append({"centre": pad_centre, "yaw": pad["yaw"], "width": 256.0, "length": 384.0})

	var route_length := 0.0
	var last := Vector2(BhopStages.BEND_X, BhopStages.START_Z - BhopStages.RIDGE_PAD_LENGTH * 0.5)
	for piece_of: Dictionary in pieces:
		var middle := Vector2((piece_of["centre"] as Vector3).x, (piece_of["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	var reset: Array[bool] = [false]
	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true
	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)
	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	var resets := 0
	var fell: Array[String] = []
	var furthest := -1
	var piece := -1
	var goal := 0
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		for i in range(pieces.size() - 1, piece, -1):
			if _bend_local(pieces[i], at).has_point(Vector2.ZERO):
				piece = i
				break
		var on: Dictionary = start if piece < 0 else pieces[piece]
		var grounded := bot.controller.state.is_grounded()
		var standing := _bend_local(on, at).has_point(Vector2.ZERO)
		if grounded and standing:
			goal = piece + 1
		var next: Dictionary = pieces[mini(goal, pieces.size() - 1)]
		var next_centre: Vector3 = next["centre"]
		var target := Vector2(next_centre.x, next_centre.z)
		var aim := target - at
		if goal < pieces.size() - 1:
			aim = aim.normalized() * maxf(aim.length() - 32.0, 1.0)
		var to_lip := -1.0
		if grounded and standing:
			var local := _bend_local(on, at)
			var direction := aim.normalized().rotated(deg_to_rad(float(on["yaw"])))
			to_lip = _rect_exit(local, Vector2.ZERO, direction)
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0 and goal < pieces.size())
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			fell.append("from piece %d at %s" % [piece, str(here.round())])
			reset[0] = false
			piece = -1
			goal = 0
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    bend: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, piece %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, furthest + 1, pieces.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest >= blocks.size() - 1, "the bot reaches the last block", "piece %d of %d" % [furthest + 1, pieces.size()])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets: %s" % [resets, ", ".join(fell)])
	_check(finished.size() == 1 and finished[0].track == bend,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every jump is taken on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## A bend piece's footprint in its own frame (x across, y along; forward is -y), offset so
## that [param at] is the origin: has_point(ZERO) is "standing over it", and _rect_exit
## from ZERO is the distance to its edge.
static func _bend_local(piece: Dictionary, at: Vector2) -> Rect2:
	var centre: Vector3 = piece["centre"]
	var d := (at - Vector2(centre.x, centre.z)).rotated(deg_to_rad(float(piece["yaw"])))
	var half := Vector2(float(piece["width"]), float(piece["length"])) * 0.5
	return Rect2(-half - d, half * 2.0)


## A block's footprint as a Rect2 in (x, z).
static func _block_rect(block: Dictionary) -> Rect2:
	var centre: Vector3 = block["centre"]
	var extent: Vector2 = block["extent"]
	return Rect2(Vector2(centre.x, centre.z) - extent * 0.5, extent)


## How far from [param at], along the unit [param direction], until it leaves [param rect].
static func _rect_exit(rect: Rect2, at: Vector2, direction: Vector2) -> float:
	var best := INF
	for axis in 2:
		var d := direction[axis]
		if absf(d) < 1e-6:
			continue
		var bound := rect.end[axis] if d > 0.0 else rect.position[axis]
		best = minf(best, (bound - at[axis]) / d)
	return best


## `the hairpin`, `bhop_g2g_intro` bonus 3, run end to end by a bot that cannot strafe:
## out, a right turn onto a climb, a right turn at the top, and back down a stair of
## drops, through both corner splits into the finish without once being put back.
##
## [b]The first route here a bot has to STEER.[/b] The needle's and the ridge's bots
## hold forward along -Z; this one reads the map's own list of blocks, aims at the edge
## of whichever block it is over that the route leaves by, and jumps in the last twenty
## units before that edge — so on a corner it lands going one way, runs a diagonal to
## the exit edge and leaves going the other. Moving a block or a corner moves the aim
## and the jump with it.
func _test_hairpin_bonus() -> void:
	_section("the hairpin, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(changed.ok, "the intro map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var hairpin := DotTimerTrack.of_bonus(3)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(hairpin) == 2,
		"with a third bonus that has two stages",
		str(zones.stage_count(hairpin)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", hairpin), "a player can switch to the hairpin")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopIntro.hairpin_blocks()
	var pad := BhopIntro.hairpin_pad()

	# The route's length along its centre line: pad edge, block to block, into the pad.
	var route_length := 0.0
	var last := Vector2(BhopIntro.HAIRPIN_X, BhopIntro.START_Z)
	for block: Dictionary in blocks:
		var middle := Vector2((block["centre"] as Vector3).x, (block["centre"] as Vector3).z)
		route_length += last.distance_to(middle)
		last = middle
	route_length += last.distance_to(Vector2(pad.x, pad.z))

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value, so `reset = true` inside
	# one never reached this function and "without ever being put back" could not fail.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	var started := false
	var resets := 0
	var top := 0.0
	var highest := -INF
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(5000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)

		var exit := Vector2(BhopIntro.HAIRPIN_X, BhopIntro.START_Z)
		var heading := Vector2(0.0, -1.0)
		if piece >= 0:
			exit = blocks[piece]["exit"]
			heading = blocks[piece]["heading"]

		# Aim through the middle of the edge the route leaves by, and past it, so the bot
		# arrives at the lip square to the gap rather than sliding along it. Once past
		# the lip it is in the air over the gap, and aims at the far edge of the next
		# piece instead: a point it has already reached is a point it hovers over.
		var to_lip := (exit - at).dot(heading)
		var aim := exit + heading * 96.0 - at
		if to_lip < 0.0:
			aim = ((blocks[piece + 1]["exit"] as Vector2) if piece + 1 < blocks.size()
				else Vector2(pad.x, pad.z)) - at
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		covered += Vector2(now.x - previous.x, now.z - previous.z).length()
		previous = now
		top = maxf(top, G2GUnits.to_units(bot.speed()))
		highest = maxf(highest, now.y)
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
		if bot.timer.run.is_active():
			started = true
		if not finished.is_empty():
			break

	print("  ..    hairpin: covered %.0f u of a %.0f u route, top %.0f u/s, highest %.0f u, block %d of %d, %d resets, %s" % [
		covered, route_length, top, highest, furthest + 1, blocks.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	_check(started, "leaving its pad starts a run on the hairpin's own track")
	_check(furthest == blocks.size() - 1, "the bot reaches the last block, both corners behind it",
		"block %d of %d" % [furthest + 1, blocks.size()])
	_check(highest >= 112.0, "and climbs to the top corner", "highest %.0f u" % highest)
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(
		finished.size() == 1 and finished[0].track == hairpin,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())]
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()


## `the stutter`, `bhop_g2g_intro` bonus 4, run end to end by the hairpin's kind of bot:
## three flat stones and a runway, four rollers and a runway, and five drops of 48 onto
## stones with one runway among them, through both runway splits into the finish.
##
## [b]What it proves is that every stone CATCHES a lip jump.[/b] The bot jumps in the last
## twenty units of whatever it is on, so each landing is where a jump from the lip at the
## speed it has comes down; a stone sized too short throws it off the far end, one sized
## too long lands it early, and either way the next jump is taken from the wrong place.
## The height it reaches at the top of the rollers and the pace are asserted as well as
## the finish, so a route that only works at a crawl fails.
func _test_stutter_bonus() -> void:
	_section("the stutter, run end to end")

	var changed: DotResult = await game.change_map(&"bhop_g2g_intro")
	_check(changed.ok, "the intro map loads")

	var bot: G2GPlayer = game.players[&"bot"]
	var stutter := DotTimerTrack.of_bonus(4)
	var zones := game.timers.zones
	_check(zones != null and zones.stage_count(stutter) == 2,
		"with a fourth bonus that has two stages",
		str(zones.stage_count(stutter)) if zones else "no zones")
	_check(game.timers.set_player_track(&"bot", stutter), "a player can switch to the stutter")

	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var blocks: Array = BhopIntro.stutter_blocks()
	var pad := BhopIntro.stutter_pad()
	var route_length := BhopIntro.START_Z - (pad.z - BhopIntro.STUTTER_FINISH_LENGTH * 0.5)

	var splits: Array[int] = []
	var finished: Array[DotTimerRun] = []
	# An array, not a bool: a lambda captures a local by value.
	var reset: Array[bool] = [false]

	var on_split := func(id: StringName, number: int, _split: float) -> void:
		if id == &"bot":
			splits.append(number)

	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	var on_finished := func(run: DotTimerRun) -> void: finished.append(run)

	game.timers.player_staged.connect(on_split)
	game.timers.effect_requested.connect(on_effect)
	bot.timer.run_finished.connect(on_finished)

	var resets := 0
	var stood: Dictionary = {}
	# How far onto each block the bot came down, from its near edge: what a stone has to
	# contain. Printed, not asserted; the assertion is that it stood on every block.
	var landed_at: Array[float] = []
	var was_grounded := true
	var furthest := -1
	var piece := -1
	var covered := 0.0
	var run_ticks := 0
	var previous := G2GUnits.vector_to_units(bot.global_position)

	for _i in range(4000):
		var here := G2GUnits.vector_to_units(bot.global_position)
		var at := Vector2(here.x, here.z)
		piece = _hairpin_piece(blocks, piece, at)

		var exit := Vector2(BhopIntro.STUTTER_X, BhopIntro.START_Z)
		if piece >= 0:
			exit = blocks[piece]["exit"]
		# Straight down -Z, aimed at the route's centre line so a drift is corrected.
		var to_lip := at.y - exit.y
		var aim := Vector2(BhopIntro.STUTTER_X, at.y - 256.0) - at
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		c.yaw = rad_to_deg(atan2(-aim.x, -aim.y))
		c.set_button(DotFpsCommand.BUTTON_JUMP, to_lip >= 0.0 and to_lip <= 20.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		var now := G2GUnits.vector_to_units(bot.global_position)
		if bot.timer.run.is_active():
			covered += Vector2(now.x - previous.x, now.z - previous.z).length()
			run_ticks += 1
		previous = now
		# Stood ON it: grounded, over its footprint, at its height. Passing over a stone
		# in the air is not landing on it.
		if piece >= 0 and bot.controller.state.is_grounded() \
				and absf(now.y - (blocks[piece]["centre"] as Vector3).y) < 4.0:
			stood[piece] = true
		var grounded := bot.controller.state.is_grounded()
		if grounded and not was_grounded and piece >= 0 \
				and absf(now.y - (blocks[piece]["centre"] as Vector3).y) < 4.0:
			var near: float = (blocks[piece]["exit"] as Vector2).y + (blocks[piece]["extent"] as Vector2).y
			landed_at.append(near - now.z)
		was_grounded = grounded
		furthest = maxi(furthest, piece)
		if reset[0]:
			resets += 1
			reset[0] = false
			piece = -1
		if not finished.is_empty():
			break

	game.timers.player_staged.disconnect(on_split)
	game.timers.effect_requested.disconnect(on_effect)
	bot.timer.run_finished.disconnect(on_finished)

	var run_speed := G2GUnits.to_units(game.tunables.max_speed)
	var shallow := INF
	var deep := -INF
	for d in landed_at:
		shallow = minf(shallow, d)
		deep = maxf(deep, d)
	print("  ..    stutter: %d landings on its blocks, %.0f to %.0f u past the near edge: %s" % [
		landed_at.size(), shallow, deep, str(landed_at.map(func(d: float) -> int: return roundi(d)))])
	var pace := covered / (float(run_ticks) / float(game.tick_rate)) if run_ticks > 0 else 0.0
	print("  ..    stutter: %.0f u covered of a %.0f u route in %d ticks, %.0f u/s against a run of %.0f, stood on %d, block %d of %d, %d resets, %s" % [
		covered, route_length, run_ticks, pace, run_speed, stood.size(), furthest + 1, blocks.size(), resets,
		"finished in %.2f s" % finished[0].time() if not finished.is_empty() else "not finished"
	])

	_check(furthest == blocks.size() - 1, "the bot reaches the last stone", "block %d of %d" % [furthest + 1, blocks.size()])
	_check(stood.size() == blocks.size(), "standing on every one of its blocks: each stone catches a lip jump",
		"stood on %d of %d: %s" % [stood.size(), blocks.size(), str(stood.keys())])
	_check(splits == [1, 2], "crossing both of its stage lines, in order", str(splits))
	_check(resets == 0, "without ever being put back", "%d resets" % resets)
	_check(finished.size() == 1 and finished[0].track == stutter,
		"and the finish line ends the run, on the bonus's own track",
		"%d finished, ended at %s u" % [finished.size(), str(G2GUnits.vector_to_units(bot.global_position).round())])
	_check(pace >= run_speed * 0.8, "at no less than 80% of run speed: every stone is left on the move",
		"%.0f u/s against %.0f" % [pace, run_speed])

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	_done()

func _test_surf_run() -> void:
	_section("a surf run")
	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	_check(changed.ok, "the surf map loads")
	game.config.air_accelerate = 150.0
	game.apply_movement()

	var bot: G2GPlayer = game.players[&"bot"]
	await get_tree().physics_frame

	# Off the front of the start platform first: the spawn is 320 units from its
	# edge and the strafing below carries the bot sideways, not forward.
	await _prestrafe(&"bot", 420)

	var airborne := 0
	var top := 0.0
	var started := bot.timer.run.is_active()
	var yaw := 0.0
	var descended := 0

	# Stopped at the pit, and that is not a tidy-up.
	#
	# The map's respawn zone works now — `DotTimer.effect_requested` was declared,
	# forwarded and connected, and emitted by NOTHING, so a bot that missed the ramps
	# fell out of the level and kept falling. Measured over a flat 1500 ticks, every
	# one of those falling ticks counted as "not grounded", and this check passed on
	# a bot that was nowhere near the map. The bot descends for about 500 ticks and
	# then hits the pit; over that window it is airborne for 94% of them, which is
	# what the check was always meant to say.
	#
	# An Array, not a bool: a GDScript lambda captures locals by value, so a flag set
	# inside a signal handler reads false outside it — and the first version of this
	# fix broke out of nothing and reported "468 of 1500".
	var reset: Array[bool] = [false]
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.effect_requested.connect(on_reset)

	# Where the bot actually gets to, so the assertions below can be read against it.
	var entry_z := bot.global_position.z
	var deepest_z := entry_z
	var splits: Array[int] = []
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	bot.timer.stage_reached.connect(on_stage)

	for i in range(1500):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		if bot.timer.run.is_active():
			started = true
		if not bot.controller.state.is_grounded():
			airborne += 1
		top = maxf(top, bot.speed())
		descended += 1
		deepest_z = minf(deepest_z, bot.global_position.z)

		if reset[0]:
			break

	game.timers.effect_requested.disconnect(on_reset)
	bot.timer.stage_reached.disconnect(on_stage)

	# [b]The number nobody had, PRINTED rather than asserted.[/b] Every check below
	# passes, and every one of them is satisfied by a bot that is FALLING: not grounded
	# because it is in mid-air, "surf speed" because that is what four seconds of
	# gravity is worth, and the respawn zone catching it is asserted as a feature. What
	# none of them says is how much of this route was ridden, and the answer is a
	# under 5% of it with neither split crossed.
	#
	# The cause is the map rather than the bot: `G2GGeometry.ramp` rotates about
	# `Vector3.FORWARD`, which banks a slab in X and Y and leaves its Z extent
	# horizontal, so both of this map's ramps are LEVEL along their length and give a
	# player nothing. The descent comes from the stepped valley floor between them. That
	# is `[surf-ramp-1]`, and it is the same finding game-playground's `pg_surf_intro`
	# made about itself — these two maps were built the same way.
	#
	# The main run is deliberately NOT reshaped: it has records against it and a scored
	# route is Christian's to change. `the fall line` below is the route on this map
	# where the answer is the ramp.
	var travelled := entry_z - deepest_z
	var route := G2GUnits.to_metres(8192.0)
	print(
		"        the main run: %.1f m of a %.0f m route, %d of 2 splits, top %s u/s"
		% [travelled, route, splits.size(), G2GUnits.format_speed(top)]
	)

	_check(
		reset[0],
		"missing the ramps drops the bot into the pit, which puts it back",
		"%d ticks" % descended
	)

	_check(started, "leaving the start platform starts a run")
	_check(
		airborne > descended * 6 / 10,
		"most of the descent is spent not grounded, which is surf",
		"%d of %d ticks" % [airborne, descended]
	)
	_check(G2GUnits.to_units(top) > 500.0, "and the bot reaches surf speed, twice its run speed", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.motor.stuck_ticks == 0, "without the slide ever running out of iterations")
	game.config.air_accelerate = 1000.0
	game.apply_movement()
	_done()


func _test_bonus_track() -> void:
	_section("the bonus track")
	var bot: G2GPlayer = game.players[&"bot"]
	_check(game.timers.set_player_track(&"bot", DotTimerTrack.of_bonus(1)), "a player can switch to the bonus")
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var spawn := game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1))
	_check(bot.global_position.distance_to(spawn) < 1.0, "and spawns at the bonus's own spawn")
	_check(bot.timer.track == DotTimerTrack.of_bonus(1), "and their timer is on it")

	await _test_single_bank()
	await _test_transfer_bonus()

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	_done()


## Bonus 1 on the surf map, driven from its pad into its finish.
##
## [b]A bank ridden by holding into it, which is the one surf skill a scripted bot has.[/b]
## The bank is level along its length, so nothing but the entry speed carries a rider
## down it, and gravity pulls them toward the low lip the whole way; holding strafe INTO
## the bank (+X) pushes them back up it. So the bot holds right while it is below a line
## on the bank and lets go above it, and never touches forward: forward-and-right is a
## real strafe, it gains speed, and a rider going much over 500 u/s leaves the end of this
## bank above the finish pad's height and lands past it (see below).
##
## The line is read off the map. Only the strip of bank between its low lip and the far
## edge of the finish pad lies over the pad, and the bot rides three quarters of a hull
## up from the lip — inside that strip, and on a line measured to finish from a
## standstill (see the numbers where `line` is set).
##
## [b]What this decides, and what it deliberately does not.[/b] It fails if the bot falls
## off the route (the respawn zone fires), if it never reaches the end of the bank, or
## if it reaches the end and does not finish — every one of which is the geometry being
## wrong. Unlike the transfer below, it asserts NOTHING about a bot that was put back,
## because a check that passes on the respawn is the one `[bonus-run-2]` found passing
## loudest in exactly the case it was written for.
func _test_single_bank() -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var bonus := DotTimerTrack.of_bonus(1)

	game.config.air_accelerate = 150.0
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var lip := SurfIntro.bonus_bank_lip_x()
	# Three quarters of a hull up from the lip. Measured 2026-09-24 from a standstill
	# spawn, once dot-player-controller 94f1c87 had removed the freeze: lines at +8, +16,
	# +24, +64 and +96 finish (1,299 to 1,676 ticks, 1 to 7 stalled slides each); +32,
	# where this sat, and +48 do not -- the rider sheds its forward speed mid-bank and
	# hangs against it. +32 finished here only because the sections before this one
	# leave the bot about 30 u/s of sideways drift, which is not a line to rely on.
	var line := lip + G2GUnits.PLAYER_HALF_WIDTH * 1.5
	var end_z := SurfIntro.bonus_bank_end_z()

	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var reset: Array[bool] = [false]
	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_finish := func(run: DotTimerRun) -> void: finished[0] = run.track == bonus
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	bot.timer.run_started.connect(on_start)
	bot.timer.run_finished.connect(on_finish)
	game.timers.effect_requested.connect(on_reset)

	var ticks := 0
	var rode_to := 0.0
	var ride_y_top := -INF
	var ride_y_low := INF
	var top := 0.0
	var still := 0
	var last := bot.global_position
	var duplicates_before := bot.controller.motor.duplicate_plane_ticks

	for i in range(2600):
		var at := G2GUnits.vector_to_units(bot.global_position)
		var c := DotFpsCommand.new()
		c.yaw = 0.0

		if bot.controller.state.is_grounded() and at.y > SurfIntro.START_Y - 64.0:
			# On the pad: across to the line first, then straight off the front, so the
			# bot arrives on the bank already over the strip it is going to ride.
			c.move = Vector2(1.0, 0.0) if at.x < line else Vector2(0.0, 1.0)
		else:
			c.move = Vector2(1.0 if at.x < line else 0.0, 0.0)

		bot.controller.apply_command(c)
		await get_tree().physics_frame
		ticks = i + 1

		at = G2GUnits.vector_to_units(bot.global_position)

		# On the bank: over its length, and with its feet on its face rather than above
		# it — the pad's front lies over the bank's near end, and so does the fall off
		# its far one.
		if at.z >= end_z - 32.0 and absf(at.y - SurfIntro.bonus_bank_surface_y(at.x)) < 32.0:
			rode_to = minf(rode_to, at.z)
			ride_y_top = maxf(ride_y_top, at.y)
			ride_y_low = minf(ride_y_low, at.y)
			top = maxf(top, -G2GUnits.to_units(bot.controller.state.velocity.z))

		# A rider who has not moved in a second and a half is not riding. The freeze
		# this was written for (velocity intact, no ground covered, one duplicate-plane
		# stall every tick) is gone since dot-player-controller 94f1c87; kept, because
		# a stall is exactly what a movement change would bring back.
		still = still + 1 if bot.global_position.distance_to(last) < 0.001 else 0
		last = bot.global_position

		if finished[0] or reset[0] or still > 192:
			break

	# Read before the movement is rebuilt, which starts the counters again.
	var duplicates := bot.controller.motor.duplicate_plane_ticks - duplicates_before

	bot.timer.run_started.disconnect(on_start)
	bot.timer.run_finished.disconnect(on_finish)
	game.timers.effect_requested.disconnect(on_reset)
	game.config.air_accelerate = 1000.0
	game.apply_movement()

	# The `[surf-ramp-1]` answer for this route, printed beside the ride: the bank is
	# level along its length, so the height a rider loses on it is only what holding the
	# line costs, and the descent of the route is the fall off its far end.
	print(
		"        the single bank: rode x %.0f to z %.0f of %.0f, %.0f u of height on the bank, "
		% [line, rode_to, end_z, ride_y_top - ride_y_low]
		+ "forward at up to %.0f u/s, then a %.0f u fall to the pad; %d ticks, %d of them a stalled slide"
		% [top, ride_y_low - SurfIntro.BONUS_FINISH_Y, ticks, duplicates]
	)

	_check(started[0], "leaving its pad starts a run on the single bank's track")
	_check(
		rode_to <= end_z + 32.0,
		"and a bot holding into the bank rides it to its far end",
		"left it at z %.0f of %.0f%s" % [
			rode_to, end_z,
			", frozen in place with %.0f u/s on the clock" % G2GUnits.to_units(bot.speed()) if still > 192 else "",
		]
	)
	_check(
		finished[0] and not reset[0],
		"and lands in the finish, on the bonus's own track, without being put back",
		"%s at %s after %d ticks" % [
			"put back by the respawn zone" if reset[0]
				else ("frozen on the bank" if still > 192 else "did not finish"),
			str(G2GUnits.vector_to_units(bot.global_position).round()),
			ticks,
		]
	)

	await _test_fast_bank_exit(line)

	game.spawn_player(&"bot")
	await get_tree().physics_frame


## A rider leaving bonus 1's bank at 900 u/s comes down in its finish (`[surf-finish-1]`).
##
## [b]Launched rather than ridden[/b], because the bot above holds a line and never
## strafes, so it leaves the bank at a few hundred u/s and could not find out that the
## pad only caught those. Put on the bank's far end at the ridden line and at the top of
## the strip over the pad, just past the bank's end, given 900 u/s along the run and no
## input, and followed until it lands. Armed against the 512-unit pad this replaced: both
## came down in the pit.
func _test_fast_bank_exit(line: float) -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var finish := game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 1)
	# Just clear of the bank's end, so the hull is in the air rather than half on the
	# slab's corner, which snags a launch into a drop straight down past the pad.
	var end_z := SurfIntro.bonus_bank_end_z() - G2GUnits.PLAYER_HALF_WIDTH - 4.0
	var top_x := SurfIntro.BONUS_X + SurfIntro.BONUS_FINISH_SIZE * 0.5 - G2GUnits.PLAYER_HALF_WIDTH
	for x: float in [line, top_x]:
		var from := Vector3(x, SurfIntro.bonus_bank_surface_y(x) + 2.0, end_z)
		bot.teleport(from * G2GUnits.METRES_PER_UNIT, 0.0)
		await get_tree().physics_frame
		bot.controller.state.velocity = Vector3(0.0, 0.0, -900.0 * G2GUnits.METRES_PER_UNIT)
		var landed := Vector3.INF
		for _i in range(300):
			var c := DotFpsCommand.new()
			c.yaw = 0.0
			bot.controller.apply_command(c)
			await get_tree().physics_frame
			var at := G2GUnits.vector_to_units(bot.global_position)
			if at.y < SurfIntro.BONUS_FINISH_Y + 2.0 or (
					bot.controller.state.is_grounded() and at.y < SurfIntro.BONUS_FINISH_Y + 64.0):
				landed = at
				break
		_check(
			finish != null and landed.is_finite() and finish.contains(landed * G2GUnits.METRES_PER_UNIT + Vector3.UP * 0.1),
			"a rider leaving the bank at 900 u/s from x %.0f comes down in its finish" % x,
			"came down at %s; the finish is z %.0f to %.0f" % [
				str(landed.round()), SurfIntro.BONUS_FINISH_NEAR_Z,
				SurfIntro.BONUS_FINISH_NEAR_Z - SurfIntro.BONUS_FINISH_LENGTH]
		)


## Bonus 2 on the surf map: two ramps banked opposite ways, with a gap.
##
## [b]The check that matters is the last one, and it is the only one an assertion
## about the zone file cannot make.[/b] Bonus 1 is a single bank -- get on it, hold
## it, ride it down -- and a bot that can do that can do it on any single bank. This
## route ends the first ramp in mid-air and asks the player to catch a second one
## banked the other way, so a bot that reaches the finish has proved the two pieces
## of geometry actually line up. Numbers that are 200 units out produce a route that
## looks perfect in a screenshot and drops every player into the pit.
func _test_transfer_bonus() -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var transfer := DotTimerTrack.of_bonus(2)

	_check(game.timers.set_player_track(&"bot", transfer), "and to the transfer bonus")

	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(transfer)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"which has a spawn of its own, away from the first bonus's",
		"%.1f m apart" % spawn.distance_to(game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1)))
	)

	game.config.air_accelerate = 150.0
	game.apply_movement()

	# Off the pad first, then strafe. Same shape as the main surf run: the spawn is
	# behind the lip and the strafing below carries the bot sideways, not forward.
	await _prestrafe(&"bot", 300)

	var started := false
	var finished := false
	var yaw := 0.0
	var entry := bot.global_position
	var rode := entry
	var travelled := 0.0

	# [b]An Array, not a bool, and this one was a bool.[/b] A GDScript lambda captures a
	# local by VALUE, so a flag set inside a signal handler reads false everywhere
	# outside it. `_test_surf_run` twenty lines up carries a comment saying exactly
	# this, and the same mistake was live here the whole time: `reset` was written only
	# by the handler below, so it was false on every tick of every run since this test
	# was written. The loop therefore never broke early, the bot fell off the route, the
	# respawn zone put it back, and the check that read its position afterwards was
	# reading the pad -- and passed. See docs/gdscript-hazards.md.
	var reset: Array[bool] = [false]

	var watch := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.effect_requested.connect(watch)

	for i in range(2000):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		if bot.timer.run.is_active():
			started = true

		if bot.timer.track == transfer and not bot.timer.run.is_active() and started:
			finished = true
			break

		if reset[0]:
			break

		# Read BEFORE the respawn zone fires, which is the whole point -- see below.
		rode = bot.global_position
		travelled = maxf(travelled, entry.z - rode.z)

	game.timers.effect_requested.disconnect(watch)
	game.config.air_accelerate = 1000.0
	game.apply_movement()

	_check(started, "leaving its pad starts a run on the bonus's own track")

	# [b]This check used to read `bot.global_position` AFTER the loop and it was
	# reading the pad.[/b] It asserted that the bot ended "between its pad and its
	# floor", which is the thing the geometry has to be right for -- and the loop
	# breaks on `reset`, by which time the respawn zone has already teleported the bot
	# back to the pad. So the position it read was the spawn, every time, and the check
	# passed most loudly in exactly the case it was written to catch: a bot that fell
	# off the route entirely. Driving it is what showed this -- the bot ends at the
	# spawn to a tenth of a metre.
	#
	# What a crude bot alternating strafe every ninety ticks can actually prove is not
	# that it cleared the route; it is not a surfer and never will be. It is that a
	# player who loses the bank is PUT BACK rather than falling for ever, which is the
	# bug the bonus tracks shipped with. So that is what is asserted, and how far it
	# got is printed, because the distance is the number every question about this
	# route is really about. See `[bonus-run-2]`: bonus 1 is a single bank and bonus 2
	# needs a transfer in mid-air, and neither is completable by a bot that cannot
	# air-strafe. `the fall line` is the route on this map that is, and it is driven to
	# its finish in `_test_the_fall_line`.
	var spawn_m := game.current_map_node().spawn_for(transfer)
	# [b]2,000 ticks, not 1,200, and the number is load-bearing.[/b] At 1,200 the bot
	# had fallen to y -48.6 m and the respawn zone -- whose roof is 1,536 units under
	# the map's finish -- was ten units below it, so the loop ended with the bot in
	# mid-air and `reset` still false. The check below then passed by being asked about
	# nothing at all, which is the same failure in a different costume. A falling player
	# has a long way to go before this map catches them, and the window has to cover it.
	print(
		"        the transfer: rode %.1f m to y %.1f, %s"
		% [
			travelled, rode.y,
			"put back on its pad" if reset[0]
				else ("still on the route" if rode.y > G2GUnits.to_metres(START_Y - 1700.0)
					else "below the route's floor and still falling"),
		]
	)

	_check(
		reset[0] and bot.global_position.distance_to(spawn_m) < 1.0,
		"and a bot that loses the bank is put back on its pad rather than falling for ever",
		"reset=%s, %.1f m from the pad" % [
			reset[0], bot.global_position.distance_to(spawn_m)
		]
	)

	# The respawn zone the bonus tracks did not have. With it, a bot that does fall is
	# put back on the pad instead of falling for ever -- so "not reset" now means it
	# stayed on the route rather than meaning nothing was watching.
	var surf_zones := game.timers.zones
	_check(
		surf_zones != null and surf_zones.route_problems().is_empty(),
		"and a bonus that is missed puts the player back, like the main track",
		", ".join(surf_zones.route_problems()) if surf_zones else "no zones"
	)


## `surf_g2g_intro`'s third bonus — the route where the descent comes from the ramp.
##
## [b]This exists because of the measurement in [method _test_surf_run].[/b] Both of
## this map's main ramps are banked about the run axis and level along their length, so
## the descent on every other route here comes from the floor; a scripted strafer covers
## under 5% of a 156 m route and crosses neither split, while two checks over it pass about
## a player who is falling into the pit. The fall line is a single face pitched past the
## standable limit and descending ALONG the run, so gravity accelerates the player down
## it — which is the thing the map was supposed to be about and was not.
##
## It is straight, and that is deliberate for the same reason `_test_needle_bonus` gives
## about a constant gap: a scripted bot cannot air-strafe, so a route that needs turning
## is a route no suite ever runs end to end. Here the bot holds forward and nothing else.
func _test_the_fall_line() -> void:
	_section("the fall line — surf_g2g_intro's third bonus")

	var bot: G2GPlayer = game.players[&"bot"]
	var fall := DotTimerTrack.of_bonus(3)
	var zones := game.timers.zones

	_check(
		zones != null and zones.playable_tracks() == PackedInt32Array([0, 1, 2, 3]),
		"the surf map has four routes now rather than three",
		str(zones.playable_tracks()) if zones else "no zones"
	)

	# [b]Asked per track, rather than of `problems()`.[/b] A zone carries a track, so a
	# set that is complete for track 0 and partial for track 3 passes `problems()` —
	# which is a per-zone check — while being an unfinishable route. This was four
	# checks walking this track's kinds by name; it is dot-timer's `route_problems()`
	# now, which asks the same of every route. See `[track-zone-1]`.
	_check(
		zones != null and zones.route_tracks().has(fall)
			and zones.route_problems().is_empty(),
		"the fall line has its own start, finish, spawn and pit",
		", ".join(zones.route_problems()) if zones else "no zones"
	)

	_check(
		zones != null and zones.stage_count(fall) == SurfIntro.FALL_SPLITS.size(),
		"and a split for each fraction the map names",
		"%d" % (zones.stage_count(fall) if zones else -1)
	)

	# The face has to be unstandable or none of this is surf, and it is asked of the
	# tunables this game actually runs a player with rather than of a number written
	# down a second time here. The pitch is the one thing about this route that cannot
	# be changed without changing what the route IS.
	var max_slope: float = bot.controller.tunables.max_slope_angle
	_check(
		SurfIntro.FALL_PITCH > max_slope,
		"its bed is steeper than a player can stand on",
		"%.0f° against %.1f°" % [SurfIntro.FALL_PITCH, max_slope]
	)

	# A player here is the fastest thing on the map, so it is the route where a thin
	# line is certain to be passed through between ticks rather than merely likely.
	_check(
		zones != null and zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate).is_empty(),
		"and no zone a 3500 u/s player crosses without entering"
	)

	_check(game.timers.set_player_track(&"bot", fall), "the track switches to the fall line")
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(fall)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"which spawns on its own pad, away from the other three",
		"%.1f m from the main spawn" % spawn.distance_to(game.current_map_node().spawn_for(0))
	)

	game.config.air_accelerate = 150.0
	game.apply_movement()

	# Arrays, because a GDScript lambda captures a local by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var reset: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	bot.timer.run_started.connect(on_start)
	bot.timer.stage_reached.connect(on_stage)
	bot.timer.run_finished.connect(on_finish)
	game.timers.effect_requested.connect(on_reset)

	# Off the pad, then nothing but forward. No jump pattern and no strafe: on a face
	# nobody can stand on there is no ground to leave.
	await _prestrafe(&"bot", 60)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = 0.0

	var ticks := 0
	var airborne := 0
	var top := 0.0
	var entry_z := bot.global_position.z
	var entry_y := bot.global_position.y

	for i in range(1400):
		bot.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i + 1

		if not bot.controller.state.is_grounded():
			airborne += 1

		top = maxf(top, bot.speed())

		if finished[0] or reset[0]:
			break

	bot.timer.run_started.disconnect(on_start)
	bot.timer.stage_reached.disconnect(on_stage)
	bot.timer.run_finished.disconnect(on_finish)
	game.timers.effect_requested.disconnect(on_reset)

	game.config.air_accelerate = 1000.0
	game.apply_movement()

	# The whole difference between the two routes, stated as a number and printed
	# beside the main run's. A detail line shows only when a check fails, and this is
	# the figure every future question about this map is really about.
	print(
		"        the fall line: %.1f m travelled, chute is %.0f m, in %d ticks, top %s u/s"
		% [
			entry_z - bot.global_position.z,
			G2GUnits.to_metres(SurfIntro.FALL_RUN),
			ticks,
			G2GUnits.format_speed(top),
		]
	)

	_check(started[0], "leaving its pad starts a run on the fall line's own track")
	_check(
		G2GUnits.to_units(top) > 1200.0,
		"the bed makes the player fast, which this map's own ramps never do",
		"%s u/s" % G2GUnits.format_speed(top)
	)
	_check(splits == [1, 2], "it crosses both splits, in order", str(splits))
	_check(
		finished[0] and not reset[0],
		"and reaches the finish holding nothing but forward",
		"gave up at tick %d, y %.1f, z %.1f%s" % [
			ticks, bot.global_position.y, bot.global_position.z,
			", put back by the respawn zone" if reset[0] else "",
		]
	)
	_check(not bot.timer.run.is_active(), "and the run is over rather than still running")
	_check(
		bot.controller.motor.stuck_ticks == 0,
		"without the slide ever running out of iterations",
		"%d stuck ticks" % bot.controller.motor.stuck_ticks
	)
	_check(
		entry_y - bot.global_position.y > G2GUnits.to_metres(SurfIntro.fall_drop() * 0.9),
		"and the descent is the ramp's, not a fall past it",
		"%.1f m of %.1f m" % [
			entry_y - bot.global_position.y, G2GUnits.to_metres(SurfIntro.fall_drop())
		]
	)

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)
	_done()


# --- The ghost -------------------------------------------------------------

static func _fake_replay(map_id: StringName, seconds: float, tick_rate: int) -> DotTimerReplay:
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = tick_rate
	replay.time = seconds
	replay.player_name = "Ghost"
	var frames := int(seconds * float(tick_rate))
	for i in range(frames):
		var t := float(i) / float(maxi(frames - 1, 1))
		replay.append(Vector3(0.0, 1.0, 7.0 - 30.0 * t), 90.0 * t, 0.0)
	return replay


func _test_ghost() -> void:
	_section("the world-record ghost")
	var map_id: StringName = game.maps.current.id
	var replay := _fake_replay(map_id, 3.0, game.tick_rate)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.track = DotTimerTrack.MAIN
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 3.0

	_check(game.replays.offer(replay, record), "a record's replay is kept")
	var slower := _fake_replay(map_id, 4.0, game.tick_rate)
	record.time = 4.0
	_check(not game.replays.offer(slower, record), "a slower one is not")
	_check(game.replays.best(map_id, 0, &"normal") == replay, "and the best is the fast one")

	var ghost := game.spawn_ghost()
	_check(ghost != null and ghost.replay != null and ghost.timer == null, "the ghost is a player with a replay and no timer")
	_check(ghost != null and ghost.display_name.begins_with("WR 0:03.000"), "named for the record", ghost.display_name if ghost else "")
	var before := ghost.global_position if ghost != null else Vector3.ZERO
	for _i in range(64):
		await get_tree().physics_frame
	var after := ghost.global_position if ghost != null else Vector3.ZERO
	_check(before.distance_to(after) > 1.0, "and it runs the map", "%.2f m in half a second" % before.distance_to(after))
	_check(ghost != null and G2GUnits.to_units(ghost.speed()) > 100.0, "at the replay's speed", G2GUnits.format_speed(ghost.speed()) if ghost else "")
	_check(game.players.size() >= 2 and game.timers.player(G2GGame.GHOST_ID) == null, "without a timer to feed")

	# Persistence: a second keeper over the same directory finds it.
	var dir := "user://g2gfast-test-replays-%d" % Time.get_ticks_usec()
	var keeper := G2GReplays.new()
	_check(keeper.setup(dir).ok, "a keeper opens a directory")
	record.time = 3.0
	_check(keeper.offer(replay, record), "and writes a replay there")
	var again := G2GReplays.new()
	again.setup(dir)
	var found := again.best(map_id, 0, &"normal")
	_check(found != null and found.frames.size() == replay.frames.size() and absf(found.time - 3.0) < 0.001,
		"which a fresh keeper reads back", str(found.describe()) if found else "none")
	_check(again.best(&"surf_kitsune2", 0, &"normal") == null and again.best(&"surf_kitsune3", 0, &"normal") == null,
		"and two ids that differ by a digit do not share a file")
	for file in DirAccess.get_files_at(dir.path_join("replays")):
		DirAccess.remove_absolute(dir.path_join("replays").path_join(file))
	DirAccess.remove_absolute(dir.path_join("replays"))
	DirAccess.remove_absolute(dir)

	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	# The surf run above may have filed a record of its own, in which case surf has
	# a ghost too — its own, never the bhop map's.
	var swapped := game.ghost()
	_check(changed.ok and (swapped == null or swapped.replay.replay.map_id == &"surf_g2g_intro"),
		"a map change swaps the ghost for that map's own, or none",
		str(changed.error) if not changed.ok else String(swapped.replay.replay.map_id) if swapped else "")
	changed = await game.change_map(map_id)
	for _i in range(4):
		await get_tree().process_frame
	_check(changed.ok and game.ghost() != null, "and it is back with its map")

	# [b]The look guard, on the predicate rather than through a client.[/b] Nothing in
	# this suite stands a `G2GClient` up, so the honest thing this can check is the
	# contract the motion handler branches on. `Input.mouse_mode` is not the thing to
	# assert against: the dummy display server pins it to VISIBLE and drops every write
	# without erroring, which is why `game-arena`'s identical guard has never been
	# exercised by anything either.
	var look := G2GClient.new()
	_check(not look.mouse_drives_view(),
		"a released cursor is not a look input")
	look.mouse_capture_override = true
	_check(look.mouse_drives_view(),
		"and a captured one is")
	look.free()
	_done()


# --- Progression ------------------------------------------------------------

## dot-stats and dot-achievements, over the runs this suite actually made.
##
## [b]Every check here is against a number the runs above PRODUCED.[/b] A progression
## suite that files its own readings and reads them back is testing dot-stats, which
## dot-stats already does; what is untested anywhere else is whether a finish in this
## game reaches those two addons at all.
func _test_progression() -> void:
	_section("progression")

	var progress := game.progress

	# `_check` in this suite returns void, so the guard is a plain test with the
	# report beside it rather than the `if not _check(...)` shape the other suites in
	# this family use.
	_check(progress != null, "the server keeps progress")

	if progress == null:
		return

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	# Every stat an achievement reads must be one the schema declares. Nothing in
	# either addon can check this: dot-achievements does not know the schema exists
	# and dot-stats does not know the catalogue does.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	# --- What the runs above filed ---------------------------------------

	var values := progress.session_values(&"bot")

	_check(
		values.get_value(G2GStats.RUNS_STARTED, 0.0) > 0.0,
		"runs started were counted",
		"%d" % int(values.get_value(G2GStats.RUNS_STARTED, 0.0))
	)
	_check(
		values.get_value(G2GStats.RUNS_FINISHED, 0.0) > 0.0,
		"and so were finishes",
		"%d" % int(values.get_value(G2GStats.RUNS_FINISHED, 0.0))
	)

	# A best time is LOWEST, and the distinction between "held zero" and "never seen"
	# is what stops every player's personal best being zero the moment the feature
	# ships. A finished run means there IS a time, so it must be above zero.
	_check(
		values.get_value(G2GStats.BEST_TIME, 0.0) > 0.0,
		"a best time was filed as a time rather than as a zero",
		"%.3f s" % values.get_value(G2GStats.BEST_TIME, 0.0)
	)

	_check(
		values.get_value(G2GStats.JUMPS, 0.0) > 0.0,
		"the movement counters were read off the controller",
		"%d jumps" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	# The counters are a running total the game RESETS on every finish, so filing the
	# total on each sample would add the whole history every tick. At 128 Hz over the
	# runs above that would be six figures for a few hundred jumps.
	_check(
		values.get_value(G2GStats.JUMPS, 0.0) < 100000.0,
		"and filed as deltas rather than as the running total each tick",
		"%d" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	_check(
		values.get_value(G2GStats.PERFECT_JUMPS, 0.0)
			<= values.get_value(G2GStats.JUMPS, 0.0),
		"perfect jumps never exceed jumps"
	)

	# In units, because everything a player reads in this game is. A top speed under
	# a hundred would be metres per second wearing the wrong label.
	_check(
		values.get_value(G2GStats.TOP_SPEED, 0.0) > 100.0,
		"top speed was filed in genre units",
		"%.0f u/s" % values.get_value(G2GStats.TOP_SPEED, 0.0)
	)

	# Distance is the one figure this layer measures itself, and it refuses a jump of
	# more than half a metre in one tick — a respawn, a stage warp or a `!r`. The bot
	# above was teleported into the finish zone at least once, so a distance equal to
	# the map's whole length would mean the guard is not working.
	var distance := values.get_value(G2GStats.DISTANCE, 0.0)
	_check(distance > 0.0, "distance was measured", "%.0f m" % distance)
	_check(
		distance < 100000.0,
		"and a teleport was not counted as travel",
		"%.0f m" % distance
	)

	# --- Achievements ----------------------------------------------------

	_check(
		progress.achievements.is_unlocked("bot", &"g2g.first_finish"),
		"finishing a course unlocked the achievement for it"
	)

	# The differencing. A player with N session finishes must hold N lifetime
	# finishes, not the running sum 1+2+...+N that a direct signal connection makes.
	var held := progress.achievements.progress_of("bot")

	if held != null:
		_check(
			absf(
				held.value_of(G2GStats.RUNS_FINISHED)
					- values.get_value(G2GStats.RUNS_FINISHED, 0.0)
			) < 0.001,
			"lifetime finishes equal session finishes, so the link differences",
			"%.0f vs %.0f" % [
				held.value_of(G2GStats.RUNS_FINISHED),
				values.get_value(G2GStats.RUNS_FINISHED, 0.0),
			]
		)

		# A LOWEST stat is an absolute in both systems and must be passed through
		# rather than differenced — differencing a personal best would be meaningless,
		# and dot-achievements' link says so.
		_check(
			absf(
				held.value_of(G2GStats.BEST_TIME)
					- values.get_value(G2GStats.BEST_TIME, 0.0)
			) < 0.001,
			"and a best time is passed through rather than differenced",
			"%.3f vs %.3f" % [
				held.value_of(G2GStats.BEST_TIME),
				values.get_value(G2GStats.BEST_TIME, 0.0),
			]
		)

	# Under Thirty is the trap: a LOWEST stat with an AT_MOST rule is satisfied by a
	# player who has never been recorded, because a missing stat reads as zero. It is
	# guarded by a second rule requiring a finished run — so a player who has never
	# played must NOT have it.
	await progress.begin(&"nobody", "Nobody")
	_check(
		not progress.achievements.is_unlocked("nobody", &"g2g.sub_thirty"),
		"a player who has never run has not finished a course in under thirty seconds"
	)
	await progress.leave(&"nobody")
	_done()
