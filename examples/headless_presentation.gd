extends Node

const G2GParty := preload("../game/g2g_party.gd")
const G2GPresentation := preload("../game/g2g_presentation.gd")
const G2GVote := preload("../game/g2g_vote.gd")
const G2GRig := preload("../game/g2g_rig.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GHud := preload("../game/g2g_hud.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GBindings := preload("../game/g2g_bindings.gd")
const G2GFlashlight := preload("../game/g2g_flashlight.gd")
const G2GMenuPages := preload("../game/ui/g2g_menu_pages.gd")
const G2GClient := preload("../game/g2g_client.gd")

## Settings, audio, effects, the console and the practice session.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]Nearly every check here is about this game refusing something the other four
## accept[/b], because that is what the integration is: the same five addons, and a timer
## server's answer to each of them.
##
## Exits non-zero on any failure.

const CHECKS := 205

var _passed := 0
var _failed := 0
## Checks a section declined to run, counted so the total still adds up to [constant CHECKS].
var _skipped := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: the presentation layer")

	_test_a_runner_is_not_shaken()
	_test_the_sounds_are_the_run()
	_test_the_sounds_follow_the_timer()
	_test_a_run_is_drawn()
	_test_the_landing_is_a_speedometer()
	_test_console_is_prefixed()
	_test_a_party_run_is_tainted()
	await _test_party_over_http()
	_test_chat_box()
	await _test_a_runner_does_not_see_their_own_head()

	_test_every_sound_has_a_voice()
	_test_the_vote_is_heard()
	await _test_blind_and_beacon()
	_test_a_map_credits_its_author()
	_test_every_key_is_the_players()
	_test_the_flashlight_reaches_unshaded_maps()
	_test_settings_reach_the_engine()
	await _test_the_menu_is_a_view_of_the_settings()
	await _test_help_lists_what_it_is_told()
	await _test_a_theme_is_every_screen()
	await _test_the_board_is_a_timer_servers()
	await _test_the_timer_is_the_players_layout()
	await _test_a_confirmed_hit_is_drawn()
	await _test_the_weapon_in_hand_is_named()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed, %d skipped" % [_passed, _failed, _skipped])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed + _skipped != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed + _skipped, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _make() -> G2GPresentation:
	var p := G2GPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	# The client builds the console after its menu; there is no menu here.
	p.build_console()
	# A memory store. A suite that writes to `user://` is one whose result depends on
	# what the last run left there -- which this family already shipped once, as a
	# dedicated suite that began failing on its ninth run.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_a_runner_is_not_shaken() -> void:
	_section("A shaken camera on a surf ramp is a lost run")

	var s := G2GPresentation.schema()
	_check(s.validate().ok, "the schema validates")

	# The disagreement with every other game in the family, and it is a default rather
	# than an absence: a player doing deathmatch on the same server can turn it on.
	_check(
		is_equal_approx(float(s.find(&"shake_scale").default_value), 0.0),
		"camera shake defaults to OFF here, where every other game defaults it to on"
	)
	_check(
		not bool(s.find(&"allow_flashes").default_value),
		"and so do full-screen flashes"
	)
	# fgr-g2g-audio-1: effects are quieter than the stock 1.0, and the wind is cvars.
	_check(float(s.find(&"sfx_volume").default_value) < 1.0, "effect sounds default below full volume")
	_check(s.find(&"snd_wind_min") != null and s.find(&"snd_wind_max") != null
		and s.find(&"snd_wind_full_speed") != null, "the wind curve is three settings")
	var calm := G2GPresentation.wind_level(0.0, 0.3, 1.1, 1500.0)
	var half := G2GPresentation.wind_level(750.0, 0.3, 1.1, 1500.0)
	var full := G2GPresentation.wind_level(9000.0, 0.3, 1.1, 1500.0)
	_check(is_equal_approx(calm, 0.3) and calm < half and half < full and is_equal_approx(full, 1.1),
		"the wind rises with speed and stops at snd_wind_max", "%.2f %.2f %.2f" % [calm, half, full])
	_check(is_equal_approx(G2GPresentation.wind_level(500.0, 0.3, 1.1, 0.0), 1.1),
		"and a full speed of zero is a step, not a division")
	_check(
		s.find(&"shake_scale").max_value > 0.0,
		"while both are still settings, because the same server runs a deathmatch layer"
	)

	var p := _make()
	p.on_run_started(Vector3.ZERO)
	p.watch_movement(false, 900.0, Vector3.ZERO)
	p.watch_movement(true, 900.0, Vector3.ZERO)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"so a landing at speed moves the camera by exactly nothing"
	)

	p.settings.set_value(&"shake_scale", 1.0)
	p.watch_movement(false, 900.0, Vector3.ZERO)
	p.watch_movement(true, 900.0, Vector3.ZERO)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() != Vector3.ZERO,
		"and a player who asked for it gets it"
	)

	# The one that matters for a timer: nothing the effects layer does may cost a tick.
	_check(
		p.fx.config.frame_budget <= 32,
		"the effect budget is small, because a frame here is a tick and a tick is 7.8 ms "
		+ "of somebody's run"
	)
	p.queue_free()
	_done()


# --- 1b ---------------------------------------------------------------------

## The four sounds above, reached from a timer rather than called by hand.
##
## [b]Section 2 called `on_run_started` and friends directly, and so did nothing else.[/b]
## The client never did, so every run on every build started, split and finished in
## silence while this suite reported the sounds present and outranking everything. What
## the client does now is `follow_runs`, so that is what is driven here — through the
## timer manager's own signals, which are what a crossing emits.
func _test_the_sounds_follow_the_timer() -> void:
	_section("The timer's own signals are what make the timer's sounds")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	var timers := DotTimerManager.new()

	p.follow_runs(timers, &"me")
	# Twice, as a client does when it is told who it is and then who it is again. A
	# second connection would play every sound twice.
	p.follow_runs(timers, &"me")
	sink.forget()

	timers.player_started.emit(&"me", DotTimerRun.new())
	_check(sink.count_of(&"timer_start") == 1, "crossing the start line makes the start sound, once")

	timers.player_started.emit(&"someone_else", DotTimerRun.new())
	_check(sink.count_of(&"timer_start") == 1, "and somebody else's start does not")

	timers.player_staged.emit(&"me", 2, 12.5)
	_check(sink.count_of(&"timer_split") == 1, "a stage line makes the split sound")

	timers.player_finished.emit(&"me", DotTimerRun.new())
	_check(sink.count_of(&"timer_finish") == 1, "the end zone makes the finish sound")
	_check(sink.count_of(&"personal_best") == 0, "and not the fanfare, which waits for the record")

	var mine := DotTimerRecord.new()
	mine.player_id = &"me"
	mine.time = 30.0
	var better := DotTimerRecord.new()
	better.player_id = &"me"
	better.time = 20.0

	timers.record_accepted.emit(mine, better, 3)
	_check(sink.count_of(&"personal_best") == 0, "a filed run slower than your best is not a personal best")

	timers.record_accepted.emit(better, mine, 1)
	_check(sink.count_of(&"personal_best") == 1, "a faster one is")

	p.follow_runs(null, &"")
	sink.forget()
	timers.player_started.emit(&"me", DotTimerRun.new())
	_check(sink.count_of(&"timer_start") == 0, "and following nothing hears nothing")

	timers.free()
	p.queue_free()
	_done()


# --- 1c ---------------------------------------------------------------------

## [b]Both gate effects were refused on every run until 2026-09-27[/b], because
## `scenes/fx/` did not exist and dot-fx logs a missing scene at DEBUG. Every check here
## passed throughout: a catalogue validates without its scenes, by design. So this asks
## the two questions that could not pass then -- are the files there, and does a run,
## crossed the way the client crosses one, put nodes in the world at the runner's feet.
func _test_a_run_is_drawn() -> void:
	_section("A start and a finish are drawn where the runner crossed them")

	var missing := G2GPresentation.fx_catalogue().missing_scenes()
	_check(
		missing.is_empty(),
		"every scene the effect catalogue names is present (missing: %s)" % ", ".join(missing)
	)

	# No script and no external resource, so a delivered pack has no path inside the scene
	# to rewrite: `FX_DIR` goes through `G2GPaths.rebase` and that is the only path there is.
	var self_contained := true
	for id in [&"start_gate", &"finish_gate"]:
		var def := G2GPresentation.fx_catalogue().find(id)
		var text := FileAccess.get_file_as_string(def.scene_path) if def != null else ""
		if text.is_empty() or text.contains("ext_resource") or text.contains("script"):
			self_contained = false
	_check(self_contained, "and each is one file, with no script and nothing it loads")

	# And no script of this game loads one of its own files by a bare res:// path: delivered,
	# that names the host project's root. g2g_game.gd's bots layer did (0ae6117), and a
	# delivered server had no bots and stopped building its layers at that line.
	# The host's addons are where they are named, so a load of res://addons/ is not one of these.
	var own := RegEx.create_from_string('load\\("res://(?!addons/)')
	var bare: Array[String] = []
	for path in _scripts_under("res://game"):
		if own.search(FileAccess.get_file_as_string(path)) != null:
			bare.append(path.get_file())
	_check(bare.is_empty(), "no script loads its own files by a bare res:// path (%s)" % ", ".join(bare))

	var p := _make()
	var drawn := {}
	p.fx.spawned.connect(func(id: StringName, node: Node, reason: StringName) -> void:
		drawn[id] = node if node != null else reason
	)
	var timers := DotTimerManager.new()
	p.follow_runs(timers, &"me")

	# Where the client says the feet are, a tick before the line is crossed.
	var feet := Vector3(4.0, 2.0, -7.0)
	p.present(0.016, feet + Vector3(0.0, 1.2, 3.0), Vector3.FORWARD)
	p.watch_movement(true, 400.0, feet)
	timers.player_started.emit(&"me", DotTimerRun.new())

	var start: Variant = drawn.get(&"start_gate")
	_check(
		start is Node3D and (start as Node3D).is_inside_tree(),
		"crossing the start line draws the start gate (%s)" % str(start)
	)
	_check(
		start is Node3D and (start as Node3D).global_position.distance_to(feet) < 0.01,
		"at the runner's feet"
	)
	_check(
		start is Node and (start as Node).find_children("*", "CPUParticles3D").size() > 0,
		"and it is particles, not an empty node"
	)

	drawn.clear()
	timers.player_finished.emit(&"someone_else", DotTimerRun.new())
	_check(drawn.is_empty(), "somebody else's finish draws nothing on this screen (%s)" % str(drawn))

	var end := feet + Vector3(-30.0, -5.0, 12.0)
	p.present(0.016, end + Vector3(0.0, 1.2, 3.0), Vector3.FORWARD)
	p.watch_movement(true, 900.0, end)
	timers.player_finished.emit(&"me", DotTimerRun.new())
	var finish: Variant = drawn.get(&"finish_gate")
	_check(
		finish is Node3D and (finish as Node3D).global_position.distance_to(end) < 0.01,
		"the end zone draws the finish gate where the run ended (%s)" % str(finish)
	)
	_check(
		finish is Node and (finish as Node).find_children("*", "CPUParticles3D").size() > 0,
		"and it is particles too"
	)

	# [b]Drawn where the scene is, not at the world's origin.[/b] dot-fx adds a scene to the
	# tree and THEN sets its transform, and a world-space emitter's first burst goes out
	# from wherever the node was when it entered: the origin. Rendered, the start gate was
	# a ring of green on some other part of the map and the finish half of one. Local
	# coordinates follow the node, and a gate never moves, so nothing is lost by them.
	var world_space := PackedStringArray()
	for node in [start, finish]:
		if not node is Node:
			world_space.append("(not drawn)")
			continue
		for c in (node as Node).find_children("*", "CPUParticles3D", true, false):
			if not (c as CPUParticles3D).local_coords:
				world_space.append("%s/%s" % [(node as Node).name, c.name])
	_check(
		world_space.is_empty(),
		"and every emitter in both follows its node, so the first burst is not at the origin (%s)"
		% ", ".join(world_space)
	)

	p.follow_runs(null, &"")
	timers.free()
	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_the_sounds_are_the_run() -> void:
	_section("Four sounds that are the game, and none of them may be dropped")

	var p := _make()
	var cat := p.audio.catalogue

	for id in [&"timer_start", &"timer_split", &"timer_finish", &"personal_best"]:
		var d := cat.find(id)
		_check(d != null, "there is a sound for '%s'" % id)
		if d != null:
			_check(
				d.priority >= 100,
				"and it outranks everything, because it IS the game (%s)" % id
			)

	var sink := p.audio.sink as DotAudioSinkNull
	sink.forget()
	p.on_run_finished(Vector3.ZERO, false)
	_check(sink.count_of(&"timer_finish") == 1, "finishing makes a noise")
	_check(
		sink.count_of(&"personal_best") == 0,
		"and an ordinary finish is not a personal best"
	)

	sink.forget()
	p.fx.flash_colour.a = 0.0
	p.on_run_finished(Vector3.ZERO, true)
	_check(sink.count_of(&"personal_best") == 1, "a personal best is its own sound")
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and does not tint the screen, because flashes are off here unless asked for"
	)

	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_the_landing_is_a_speedometer() -> void:
	_section("A landing sounds like how fast you were going")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	p.watch_movement(false, 300.0, Vector3.ZERO)
	p.watch_movement(true, 300.0, Vector3.ZERO)
	# Typed explicitly. Indexing a Dictionary yields a Variant, and `var x := <Variant>`
	# is a parse ERROR under these projects' settings -- which makes the SCENE fail to
	# load, and a scene that fails to load HANGS rather than failing, because nothing ever
	# reaches get_tree().quit(). That is in this family's own list of hazards and it cost
	# two timed-out runs here for want of running the check pass first.
	var slow: float = float(sink.played()[sink.played().size() - 1]["pitch"])

	OS.delay_msec(70)
	sink.forget()
	p.watch_movement(false, 1600.0, Vector3.ZERO)
	p.watch_movement(true, 1600.0, Vector3.ZERO)
	var fast: float = float(sink.played()[sink.played().size() - 1]["pitch"])

	_check(
		fast > slow,
		"landing at 1600 is higher than landing at 300 (%.2f against %.2f), which is the "
		% [fast, slow]
		+ "cheapest speedometer there is"
	)

	# Watched rather than listened for: a client that hooked the authority's signal would
	# be silent online and perfectly noisy offline.
	OS.delay_msec(70)
	sink.forget()
	p.watch_movement(true, 900.0, Vector3.ZERO)
	_check(
		sink.count_of(&"land") == 0,
		"and staying on the ground is not a landing, because it is the EDGE that is heard"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_console_is_prefixed() -> void:
	_section("Two consoles whose names mean opposite things")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in G2GPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))

	p.console.submit("sensitivity 4")
	_check(
		is_equal_approx(p.settings.get_float(&"sensitivity"), 4.0),
		"a console line writes the document"
	)
	_check(
		p.settings.schema.find(&"sensitivity").scope == DotSettingsDef.Scope.ACCOUNT,
		"and a runner's sensitivity follows them, because it is months of muscle memory"
	)

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential never reaches the scrollback"
	)

	# The server's console is added with a prefix here and unprefixed everywhere else,
	# because `!s3` means a local navigation on a client and a teleport that ends a run
	# on a server.
	var server_sources := 0
	for src in p.console.sources():
		if src.source_name() == "server":
			server_sources += 1
	_check(
		server_sources == 0,
		"with no server bridged in a client-only process, which is most of them"
	)
	p.queue_free()

	# A server in this process: its console is reached as `server <line>` and nothing else.
	var fake := FakeServer.new()
	DotRegistry.register(&"dot_server", fake)
	var q := _make()
	var _unknown := q.console.submit("s3")
	_check(fake.console.ran.is_empty(),
		"with a server in the process, `s3` does not reach it", str(fake.console.ran))
	var _ran := q.console.submit("server s3")
	_check(fake.console.ran == PackedStringArray(["s3"]),
		"and `server s3` does, without the prefix", str(fake.console.ran))
	DotRegistry.unregister(&"dot_server")
	q.queue_free()
	_done()


## Stands in for a dot-server in this process: all the kit asks of one is a `console`.
class FakeServer extends RefCounted:
	var console := FakeConsole.new()


class FakeConsole extends RefCounted:
	var ran := PackedStringArray()

	func execute(line: String) -> DotResult:
		ran.append(line)
		return DotResult.success("")

	func command_names() -> PackedStringArray:
		return PackedStringArray(["s3", "quit"])


# --- 5 ----------------------------------------------------------------------

func _test_a_party_run_is_tainted() -> void:
	_section("A run nobody can vouch for is not a record")

	DotP2PSignallerLoopback.reset_all()

	var party := G2GParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"a practice session is sandboxed"
	)
	_check(
		not party.session.config.migrate_host,
		"and does not migrate, because a time made of two machines' clocks is worse than "
		+ "no time at all"
	)

	var run := DotTimerRun.new()
	_check(party.ranked(), "an ordinary session is ranked")
	_check(not party.taint_if_unranked(run), "so a run in it is untouched")
	_check(not run.tainted, "and stays clean")

	party.session._state = &"hosting"
	_check(not party.ranked(), "a live peer-to-peer session is not")
	_check(party.taint_if_unranked(run), "and a run started in it is tainted")
	_check(
		run.tainted,
		"using the field dot-timer has had since it was written, whose first caller was "
		+ "this game's effects layer for exactly the same reason"
	)

	# Tainted rather than refused: a run you cannot compare is still a run worth doing,
	# which is the choice this game already made about movement effects.
	_check(
		party.describe_lines().size() > 1,
		"and it says so when asked, rather than refusing the session outright"
	)

	party.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_chat_box() -> void:
	_section("A runner who can be talked to and can talk back")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)
	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# [b]The one that costs a run.[/b] A client that keeps reading movement while somebody
	# types strafes them off a ramp, and on a timer server that is minutes of work gone.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a strafe")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	# A join notice is a name and NO text (dot-chat's `_presence`). Drawn as name and text
	# it was a bare "Guest 435:" in the box, which read as a chat command echoed with its
	# text stripped. The client is never added to the tree; only `_on_said` is used, fed
	# exactly what the extras' `message_received` handler hands it.
	var extras_script := preload("../game/g2g_client_extras.gd")
	var join := DotChatMessage.make(DotChatMessage.Kind.JOIN, &"all", "k2", "Guest 435", "")
	var said_client := G2GClient.new()
	said_client.presentation = p
	said_client._on_said(extras_script.speaker_of(join), extras_script.text_of(join), join.kind_name())
	var said_rows := window.history()
	var said_line := ""
	for part in (said_rows[said_rows.size() - 1] if not said_rows.is_empty() else []):
		said_line += str((part as Dictionary).get("text", ""))
	_check(
		said_line.contains("Guest 435 joined") and not said_line.contains(":"),
		"a join notice is drawn as a sentence, not as a bare name",
		"'%s'" % said_line
	)
	said_client.free()

	_done()


# --- Harness ---------------------------------------------------------------

## The one bug in this file's history that no assertion in it could have caught, and
## the reason it is now an assertion.
##
## [G2GRig] puts a player's body on two visibility layers so the OWNER'S first-person
## camera can cull it while every other camera still draws it — that is what
## [member G2GCamera.first]'s cull mask is for, and the third-person path depends on
## the same two layers. It set both layers unconditionally, so the culled layer was
## never the only one and the first-person camera drew its own player's avatar at
## point-blank range. The bottom third of the screen was the inside of the player's
## own head, in every frame, on every map.
##
## Every number in the game was right: the cull mask, the layer constant, the
## third-person view, and the `visible_to_owner` flag, which arrived correctly and was
## then used for nothing. It was found in a screen recording, which is where an
## interface bug is always found. What it costs to check here is one bitwise AND.
func _test_a_runner_does_not_see_their_own_head() -> void:
	_section("A first-person runner is culled out of their own camera")

	var camera := G2GCamera.new()
	add_child(camera)
	await get_tree().process_frame

	var fp_mask: int = camera.first.cull_mask
	var tp_mask: int = camera.third.cull_mask

	_check(
		fp_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1)) == 0,
		"the first-person camera culls the local-body layer",
		"mask 0x%05X" % fp_mask
	)
	_check(
		tp_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1)) != 0,
		"and the third-person camera does not",
		"mask 0x%05X" % tp_mask
	)

	var rig := G2GRig.new()
	add_child(rig)
	await get_tree().process_frame

	# Stand-ins for whatever avatar is loaded: the rule is about the layers, not about
	# which mesh happens to be mounted.
	for mount in [rig.body_mount, rig.head_mount]:
		var mesh := MeshInstance3D.new()
		mesh.mesh = SphereMesh.new()
		mount.add_child(mesh)

	rig.visible_to_owner = false
	await get_tree().process_frame

	var hidden := _drawn_by(rig, fp_mask)
	_check(
		hidden == 0,
		"a rig its owner must not see is drawn by none of their first-person camera",
		"%d visuals still drawn" % hidden
	)
	_check(
		_drawn_by(rig, tp_mask) > 0,
		"and is still drawn by every other camera, so other players can see them"
	)

	rig.visible_to_owner = true
	await get_tree().process_frame

	_check(
		_drawn_by(rig, fp_mask) > 0,
		"and in third person the owner sees it again"
	)

	# `show_own_body`: the third state, and the whole point of it is that it is NOT
	# "first person with the cull turned off". The head mount is AT the eye, so a
	# switch that showed the whole rig would put the camera inside a 40 cm cube and
	# reproduce the bug this section is named after — on purpose, from a setting.
	rig.owner_sees_head = false
	await get_tree().process_frame

	_check(
		_drawn_by(rig.body_mount, fp_mask) > 0,
		"with show_own_body on, the owner's first-person camera draws their body"
	)
	_check(
		_drawn_by(rig.head_mount, fp_mask) == 0,
		"and never their head, which is the mount the camera is inside"
	)
	_check(
		_drawn_by(rig.head_mount, tp_mask) > 0,
		"while everybody else still sees the whole of them"
	)

	rig.owner_sees_head = true

	remove_child(rig)
	rig.queue_free()
	remove_child(camera)
	camera.queue_free()

	_completed += 1


## How many of [param node]'s visuals a camera with [param mask] would draw.
func _drawn_by(node: Node, mask: int) -> int:
	var count := 0

	if node is VisualInstance3D and (node as VisualInstance3D).layers & mask != 0:
		count += 1

	for child in node.get_children():
		count += _drawn_by(child, mask)

	return count


func _test_every_sound_has_a_voice() -> void:
	# This game shipped a complete catalogue pointing at files nobody has produced, and
	# was therefore silent while every check about its audio passed. The two directions
	# below are the ones that go wrong without erroring: an id with no recipe is one sound
	# that stays silent for ever, and a recipe naming an id the catalogue does not have is
	# a decision that reaches nothing. Neither is visible from any assertion about the
	# catalogue on its own -- and a headless run cannot hear the result, so this is as
	# close as an assertion gets. game-arena/tools/audio_probe.sh is the other half.
	_section("Every sound this game declares has a noise to make")

	var cat := G2GPresentation.sound_catalogue()
	var recipes := G2GPresentation.sound_recipes()

	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		if not recipes.has(id) and not DotAudioStock.ids().has(id):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice",
		"silent for ever: %s" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there", str(stray))

	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"land") and bank.has("res://audio/land.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"jump"] as AudioStreamWAV).data
			!= (bank[&"land"] as AudioStreamWAV).data
		),
		"and jump does not sound like land",
		"a jump and a landing are the rhythm a runner keeps time by, and two that sounded alike would be worse than silence"
	)

	_done()


func _test_the_vote_is_heard() -> void:
	_section("The map vote is heard, and under the run")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	# G2GVote's constants are the one copy: its rules name them and this catalogue
	# defines them, so a cue the server sends and the client lacks cannot be a typo.
	var named: Array[StringName] = [
		G2GVote.CUE_START, G2GVote.CUE_END, G2GVote.CUE_WARNING, G2GVote.CUE_COUNT
	]
	var missing: Array[String] = []
	for id in named:
		var d := p.audio.catalogue.find(id)
		if d == null or d.priority >= 100:
			missing.append(String(id))
	_check(
		missing.is_empty(),
		"every vote cue is in the catalogue, below the timer's four (%s)" % str(missing)
	)

	sink.forget()
	_check(p.on_vote_cue(G2GVote.CUE_START) != 0, "a ballot opening plays")
	p.on_vote_cue(&"")
	p.on_vote_cue(&"not_in_this_build")
	_check(
		sink.count_of(G2GVote.CUE_START) == 1 and sink.count_of(&"not_in_this_build") == 0,
		"once, and an empty or unknown cue is silence"
	)

	p.queue_free()
	_done()


## What an administrator's blind and beacon look and sound like on a client: the HUD's
## overlay and the marker, driven off the two flags exactly as a snapshot leaves them.
## Who is TOLD is `headless_net`'s; what the server decides is `dedicated`'s; what it looks
## like to a person is `tools/screenshot_hud.sh`'s `hud_beacon` and `hud_blind`.
func _test_blind_and_beacon() -> void:
	_section("A blind is the owner's screen, and a beacon is everybody's")

	var config := G2GConfig.new()
	config.records_directory = ""
	config.initial_map = &"bhop_g2g_intro"
	var game := G2GGame.new()
	game.name = "BeaconGame"
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	var ada: G2GPlayer = game.add_player(&"u1", "Ada")
	var bea: G2GPlayer = game.add_player(&"u2", "Bea")

	var hud := G2GHud.new()
	add_child(hud)
	hud.bind(game, &"u1")

	_check(
		hud.blind_overlay != null and hud.blind_overlay.get_index() == 0,
		"the blind is the HUD's first child, so every widget draws over it"
	)

	# The chat box beside the timer's plate, at the 1280 x 720 a client draws: a 460-wide box
	# from 16 wrapped its lines over "0 u/s" (the plate's left edge is near 426).
	hud.timer_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud.timer_hud.position = Vector2.ZERO
	hud.timer_hud.size = Vector2(1280.0, 720.0)
	# One HUD frame, so the plate carries what a client's does: speed, style and stats.
	hud._process(1.0 / 60.0)
	hud.timer_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud.timer_hud.position = Vector2.ZERO
	hud.timer_hud.size = Vector2(1280.0, 720.0)
	var plate := hud.timer_rect()
	var box := _make()
	var fitted := G2GPresentation.chat_width_beside(plate, box.chat_window, 720.0)
	_check(
		plate.size.x > 0.0 and box.chat_window.margin_left + fitted <= plate.position.x,
		"a full chat log stays left of the timer's plate (%.0f wide at x %.0f)" % [plate.size.x, plate.position.x],
		"box ends at %.0f, plate %s" % [box.chat_window.margin_left + fitted, plate]
	)
	box.queue_free()

	ada.blinded = true
	hud.present_blind(G2GHud.BLIND_FADE_SEC * 0.5)
	var halfway := hud.blind_overlay.modulate.a
	hud.present_blind(G2GHud.BLIND_FADE_SEC)
	_check(
		halfway > 0.2 and halfway < 0.8 and is_equal_approx(hud.blind_overlay.modulate.a, 1.0),
		"a blind fades down over a quarter of a second rather than cutting (%.2f halfway)" % halfway
	)

	# Measured against the VIEWPORT, not the HUD. At 64 x 64 headless this cannot say
	# anything about a real window's layout; it can say the rect is the viewport's and not
	# the HUD's own or zero, which is the bug game-arena's first rendered frame showed.
	var covered := hud.blind_overlay.get_global_rect()
	var viewport := hud.get_viewport_rect()
	_check(
		covered.encloses(viewport) and viewport.size.x > 0.0,
		"and it covers the whole viewport", "%s against %s" % [covered, viewport]
	)

	# The HUD follows Ada; Bea's blind is not this screen's business.
	ada.blinded = false
	bea.blinded = true
	hud.present_blind(1.0)
	_check(not hud.blind_overlay.visible, "somebody else's blind leaves this screen alone, and a lifted one lifts")

	# The beacon: built from the flag, pinging on a period rather than on a frame.
	var pings: Array[Vector3] = []
	bea.beacon_pulsed.connect(func(at: Vector3) -> void: pings.append(at))
	bea.beacon = true
	for _i in range(120):
		bea.present(1.0 / 60.0)
	_check(bea.beacon_marker != null, "a beaconed player grows a marker")
	_check(
		pings.size() == 2 or pings.size() == 3,
		"which pings once as it comes on and once a second after, not once a frame (%d in two seconds)" % pings.size()
	)
	_check(bea.beacon_marker.column_shown(), "with the column through walls, on somebody else")

	var own := game.add_player(&"u3", "Cy", true)
	own.sampler = null
	own.beacon = true
	own.present(1.0 / 60.0)
	_check(
		own.beacon_marker != null and not own.beacon_marker.column_shown(),
		"and without it on your own, where the camera would be inside it"
	)

	bea.beacon = false
	bea.present(1.0 / 60.0)
	_check(bea.beacon_marker == null, "turning it off takes the marker away")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	var def := p.audio.catalogue.find(G2GPresentation.BEACON_SOUND)
	_check(
		def != null and def.kind == DotAudioDef.Kind.POSITIONAL_3D and def.priority < 50,
		"the ping is positional, and below every sound the run is made of"
	)
	sink.forget()
	_check(
		p.on_beacon(Vector3(3.0, 0.0, 4.0)) != 0 and sink.count_of(G2GPresentation.BEACON_SOUND) == 1,
		"and a ripple plays it"
	)

	p.queue_free()
	hud.queue_free()
	game.queue_free()
	_done()


# --- 5b ---------------------------------------------------------------------

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] The other party check here uses the loopback signaller,
## which answers inside the call — and a coroutine that never suspends is
## indistinguishable from a function, so a caller that forgot `await` passes against it.
## A rendezvous that answers frames later is the shape the real one has.
##
## Ported from game-playground's headless_presentation (d4ff040) by way of game-arena's
## (1c64940), on ports 38900-38960, clear of playground's 38700-38760 and arena's
## 38800-38860, so the three suites can run at the same time.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## The ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(38900, 38960):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open.duplicate():
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## `[p2p-await-games]`: a practice session over the HTTP rendezvous, host and join, each
## awaited end to end — through `G2GParty`, `DotP2PSession` and `DotP2PSignallerHttp` to
## a socket and back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link in the chain that dropped its `await` hands its caller null or returns before
## the stub has answered, and either fails here.
##
## [b]What differs from playground's copy.[/b] g2gfast's party is `Trust.SANDBOXED` with
## migration off, as arena's is. dot-peer-to-peer's session does not branch on trust when
## it signals, so every assertion playground makes applies here unchanged; the one thing
## added is this game's own rule, that a run started in a session which met over a real
## rendezvous is tainted, because that is the path a real practice session takes.
func _test_party_over_http() -> void:
	_section("A practice session that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := G2GParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := G2GParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is DotP2PSignallerHttp
			and bob.session.signaller is DotP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(code: String) -> void: opened.append(code))

	var before := Engine.get_process_frames()
	var hosted: DotResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and DotP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.active() and ada.session.is_host() and opened == [code],
		"the session is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])
	var run := DotTimerRun.new()
	_check(not ada.ranked() and ada.taint_if_unranked(run) and run.tainted,
		"and a run started in a session that met over a real rendezvous is tainted too")

	before = Engine.get_process_frames()
	var joined: DotResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.session.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.session.lobby.member_ids())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := G2GParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: DotResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and not carol.active(),
		"and a rendezvous that refuses leaves the session closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
	_done()



 # --- Harness ---------------------------------------------------------------


# --- 13 ---------------------------------------------------------------------

## `[credit-1]`: an imported map is somebody else's work, and the line a map change puts
## on screen names them. Asserted on the catalogue's own defs rather than on a made-up
## one, so a zones file that loses its author fails here and not only in a review.
func _test_a_map_credits_its_author() -> void:
	_section("A map change names the map's author")

	var bare := DotMapDef.new()
	bare.id = &"bhop_g2g_intro"
	_check(G2GHud.now_playing_text(bare) == "Now playing bhop_g2g_intro",
		"a hand-built map with no author reads as it always did", G2GHud.now_playing_text(bare))

	var defs: Array[DotMapDef] = G2GMapCatalogue.scan()
	var imported := defs.filter(func(m: DotMapDef) -> bool:
		return FileAccess.file_exists("res://maps/imported/%s/%s.json" % [m.id, m.id]))
	# [b]A clean checkout has nothing to ask[/b], and CI is one: `maps/imported/` is
	# gitignored, and an imported map's author lives only in its manifest there. The
	# zones files in maps/zones/ are tracked but the catalogue does not read authors from
	# them, so there is no tracked stand-in to assert on. Skip, as headless_imported does,
	# and count the skips so a section that aborts still shows in the total.
	if imported.is_empty():
		_skip(3, "no imported maps on this checkout, so no author to ask (maps/imported/ is gitignored)")
		_done()
		return
	var uncredited := imported.filter(func(m: Variant) -> bool: return G2GMapCatalogue.credit(m as DotMapDef).is_empty())
	_check(imported.size() > 0, "the catalogue holds imported maps to ask", "%d defs" % defs.size())
	_check(uncredited.is_empty(), "and every one of them has an author to name",
		", ".join(uncredited.map(func(m: Variant) -> String: return String((m as DotMapDef).id))))

	var mesa: DotMapDef = null
	for m: Variant in imported:
		if (m as DotMapDef).id == &"surf_mesa":
			mesa = m
	_check(mesa != null and G2GHud.now_playing_text(mesa).ends_with(", by Arblarg"),
		"so surf_mesa's line credits Arblarg",
		G2GHud.now_playing_text(mesa) if mesa != null else "no surf_mesa")
	_done()



# --- Keys, the flashlight and the menus --------------------------------------------

func _test_every_key_is_the_players() -> void:
	_section("Every key the client reads is a setting the player can move")

	var p := _make()

	var bound := 0
	for row in G2GBindings.ROWS:
		# Jump also has the wheel's two extra rows (Space stays the first).
		var events := 3 if row["action"] == &"dot_fps_jump" else 1
		if InputMap.action_get_events(row["action"]).size() == events \
				and DotInputBinding.describe_action(row["action"]).begins_with(str(row["default"])):
			bound += 1
	_check(bound == G2GBindings.ROWS.size(),
		"every action is on its default and on one key only (%d of %d)" % [bound, G2GBindings.ROWS.size()])

	var declared := 0
	for row in G2GBindings.ROWS:
		var def := p.settings.schema.find(row["setting"])
		if def != null and def.kind == DotSettingsDef.Kind.BINDING:
			declared += 1
	_check(declared == G2GBindings.ROWS.size(), "and every one is a binding in the settings document")

	var clash := ""
	for row in G2GBindings.ROWS:
		var other := p.bindings.row_using(str(row["default"]), row["setting"], p.settings)
		if not other.is_empty():
			clash = "%s and %s" % [row["label"], other["label"]]
	_check(clash == "", "no two defaults share a key", clash)

	_check(DotInputBinding.describe_action(&"dot_fps_crouch") == "Ctrl",
		"Duck is Ctrl, the genre's, and the text form of it round-trips")

	p.settings.set_value(&"bind_flashlight", "G")
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "G"
		and InputMap.action_get_events(&"g2g_flashlight").size() == 1,
		"rebinding moves the action, and leaves one key rather than two")

	p.settings.set_value(&"bind_flashlight", "Qwerty")
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "F",
		"a binding that names no key falls back to the default rather than unbinding")

	var escape := false
	for row in G2GBindings.ROWS:
		if str(row["default"]) == "Escape":
			escape = true
	_check(not escape, "and nothing is on Escape, which is the menu and the browser's own")
	_check(DotInputBinding.describe_action(&"g2g_scoreboard") == "Tab"
		and DotInputBinding.describe_action(&"g2g_style_next") == "N",
		"Tab holds the scoreboard, as in every game here, and the next style is N")

	# A document from before stores "Tab" for the next style, because a document stores
	# defaults too; keeping it would put two actions on one key.
	var step: Callable = G2GPresentation.migrations()[2]
	_check(not (step.call({"bind_style_next": "Tab"}) as Dictionary).has("bind_style_next")
		and str((step.call({"bind_style_next": "G"}) as Dictionary)["bind_style_next"]) == "G",
		"a stored Tab for the next style is dropped, and a key somebody chose is kept")

	p.settings.reset_value(&"bind_flashlight")
	_done()


func _test_the_flashlight_reaches_unshaded_maps() -> void:
	_section("A flashlight lights the maps that ignore every light")

	var code_ok := 0
	for path in ["res://game/g2g_bsp_lightmapped.gdshader", "res://game/g2g_bsp_translucent.gdshader"]:
		var text := FileAccess.get_file_as_string(path)
		if text.contains("uniform sampler2D flashlight_tex : hint_default_black") \
				and text.contains("flashlight(world, normal)"):
			code_ok += 1
	_check(code_ok == 2, "both imported-map shaders compute the cone, off by default (%d of 2)" % code_ok,
		"an unshaded surface ignores a SpotLight3D, so the shader is the only way to light one")

	var light := G2GFlashlight.new()
	add_child(light)
	var shader := load("res://game/g2g_bsp_lightmapped.gdshader") as Shader
	_check(shader != null and shader.get_default_texture_parameter(G2GFlashlight.SHADER_PARAMETER) == light._texture,
		"it hands the shader its parameters as the shader's own default, never per material")
	_check(light._image.get_pixel(0, 0).a == 0.0, "and starts off")

	_check(light.set_on(true) and light.on and light.spot.visible, "F switches it on, spotlight and all")
	light.present(1.0 / 60.0, Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0)))
	var at := light._image.get_pixel(0, 0)
	var aim := light._image.get_pixel(1, 0)
	var off_eye := Vector3(at.r, at.g, at.b).distance_to(Vector3(1.0, 2.0, 3.0))
	_check(at.a == 1.0 and off_eye < 0.25, "it is carried at the eye, a hand's width off it (%.2f m)" % off_eye)
	_check(Vector3(aim.r, aim.g, aim.b).distance_to(Vector3.FORWARD) < 0.001, "and points where the eye does")

	light.allowed = false
	_check(not light.on and light._image.get_pixel(0, 0).a == 0.0,
		"sv_flashlight 0 switches it off, on every surface")
	_check(not light.set_on(true), "and keeps it off")

	remove_child(light)
	light.free()
	_check(shader.get_default_texture_parameter(G2GFlashlight.SHADER_PARAMETER) == null,
		"and a client that goes away takes its texture back off the shader")
	_done()


func _test_settings_reach_the_engine() -> void:
	_section("A setting in the menu is a setting that does something")

	var p := _make()
	_check(Engine.max_fps == 0, "the frame rate is unlimited by default")
	p.settings.set_value(&"fps_max", 144)
	_check(Engine.max_fps == 144, "and capping it caps the engine")
	p.settings.set_value(&"fps_max", 0)

	p.settings.set_value(&"ui_volume", 0.3)
	_check(is_equal_approx(p.audio.mixer.ui, 0.3), "the timer's volume is the UI bus's")

	_check(p.settings.get_int(&"field_of_view", 0) == 90,
		"the field of view starts at 90, the genre's fov_desired, rather than 110")
	_check(not p.settings.get_bool(&"hide_others", true) and not p.settings.get_bool(&"vsync", true),
		"other players are shown and V-Sync is off until somebody says otherwise")

	# Every document on disk stores 110, the old default that nothing read.
	var step: Callable = G2GPresentation.migrations()[1]
	_check(not (step.call({"field_of_view": 110, "sensitivity": 3.0}) as Dictionary).has("field_of_view"),
		"a stored 110 from before the camera read it is dropped, so the player gets 90")
	_check(int((step.call({"field_of_view": 100}) as Dictionary)["field_of_view"]) == 100,
		"and any other value is somebody's choice, and kept")
	_done()


## A client with the methods the menu's pages ask. Nothing in it decides anything.
class FakeHost:
	extends Node
	var style: StringName = &"normal"
	var light := false
	var third := false
	var preset: StringName = &""
	var edited := 0

	func menu_styles() -> Array:
		return [{"id": &"normal", "name": "Normal"}, {"id": &"sideways", "name": "Sideways"}]

	func menu_style() -> StringName:
		return style

	func menu_choose_style(id: StringName) -> void:
		style = id

	func menu_flashlight_allowed() -> bool:
		return true

	func menu_flashlight_on() -> bool:
		return light

	func menu_set_flashlight(on: bool) -> void:
		light = on

	func menu_third_person_allowed() -> bool:
		return false

	func menu_third_person_on() -> bool:
		return third

	func menu_set_third_person(on: bool) -> void:
		third = on

	func menu_layout_presets() -> Array:
		return [[&"minimal", "Minimal"]]

	func menu_apply_layout_preset(id: StringName) -> void:
		preset = id

	func menu_edit_layout() -> void:
		edited += 1

	func menu_where() -> String:
		return "surf_test  ·  offline"

	func menu_leave_label() -> String:
		return "Quit game"


## The real menu as the client builds it: dot-menu's, with this game's keys and pages.
func _menu_for(p: G2GPresentation, host: Node) -> DotMenu:
	var menu := DotMenu.new()
	menu.settings = p.settings
	menu.bindings = p.bindings
	menu.config = DotMenuConfig.new()
	menu.config.escape_grace_ms = 0
	menu.manage_pointer = false
	menu.help_action = &"g2g_help"
	menu.theme_action = &"g2g_theme_next"
	menu.scoreboard_action = &"g2g_scoreboard"
	add_child(menu)
	var _set := menu.setup()
	G2GMenuPages.install(menu, host)
	return menu


func _live(root: Node, type: String) -> Array:
	return root.find_children("*", type, true, false).filter(
		func(n: Node) -> bool: return n.is_inside_tree() and not n.is_queued_for_deletion())


func _row(menu: DotMenu, id: String) -> Node:
	return menu.screen.find_child("Row_%s" % id, true, false)


func _test_the_menu_is_a_view_of_the_settings() -> void:
	_section("The Escape menu writes the settings and keeps no copy of them")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame

	var order: Array = menu.screen.visible_pages().map(func(page: DotMenuPage) -> StringName: return page.id)
	# dot-menu may append its own optional `advanced` page (the connection overlay) after
	# this game's six; it is the addon's, not a reordering of ours, so both shapes pass and
	# anything else -- a page missing, moved or added elsewhere -- does not.
	var ours: Array = [&"general", &"hud", &"gameplay", &"video", &"audio", &"controls"]
	_check(order == ours or order == ours + [&"advanced"],
		"six pages, in this game's order, then dot-menu's optional advanced page if it has one", str(order))

	menu.open(&"general")
	await get_tree().process_frame
	_check(menu.is_open() and menu.screen.visible, "it opens")
	var switches := _live(menu.screen, "DotMenuSwitch")
	# dot-menu adds its Scoreboard section (one switch per hideable column) to General.
	var board_switches := menu.scoreboard_column_rows().size()
	_check(switches.size() == 7 + board_switches, "the General page has a switch per HUD setting, zones and the counter included, plus dot-menu's scoreboard columns (%d)" % switches.size())

	(_row(menu, "show_speed") as Button).button_pressed = false
	_check(not p.settings.get_bool(&"show_speed", true), "flipping one writes the setting it shows")

	p.settings.set_value(&"show_speed", true)
	menu.open(&"general")
	await get_tree().process_frame
	_check((_row(menu, "show_speed") as Button).button_pressed,
		"and a change made elsewhere (the console) is what it shows next time")

	menu.open(&"gameplay")
	await get_tree().process_frame
	var pick := _row(menu, "style").find_children("*", "OptionButton", true, false)
	var styles: OptionButton = pick[0] if not pick.is_empty() else _row(menu, "style") as OptionButton
	_check(styles != null and styles.item_count == 2, "the style list is the host's, not one the menu keeps")
	if styles != null:
		styles.select(1)
		styles.item_selected.emit(1)
	_check(host.style == &"sideways", "and choosing one asks the host for it")
	_check((_row(menu, "third_person") as Button).disabled,
		"a server that keeps everybody in first person greys the switch out, and says why")
	(_row(menu, "flashlight") as Button).button_pressed = true
	_check(host.light, "the flashlight is the host's, never a stored setting")

	menu.open(&"controls")
	await get_tree().process_frame
	var keys := _live(menu.screen, "DotMenuKeyButton")
	_check(keys.size() == G2GBindings.ROWS.size() + 2, "the Controls page has a key per action (plus the wheel's two) (%d)" % keys.size())

	# Flashlight onto R: R was Restart, so Restart gets F rather than nothing.
	var _r := p.bindings.rebind(p.bindings.row_for_action(&"g2g_flashlight"), "R", p.settings)
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "R"
		and DotInputBinding.describe_action(&"g2g_restart") == "F",
		"binding a key that is taken swaps the two, so nothing is left unbound")
	p.bindings.reset_all(p.settings)
	_check(DotInputBinding.describe_action(&"g2g_flashlight") == "F"
		and DotInputBinding.describe_action(&"g2g_restart") == "R",
		"and Reset puts every key back")

	var changes: Array = []
	menu.overlays_changed.connect(func(open: bool) -> void: changes.append(open))
	menu.close()
	_check(not menu.screen.visible and changes == [false], "it closes, and says so, so the client can take the mouse back")

	menu.queue_free()
	host.queue_free()
	_done()


func _test_help_lists_what_it_is_told() -> void:
	_section("The help screen lists the player's keys and the server's commands")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame

	var texts := func() -> PackedStringArray:
		var out := PackedStringArray()
		for n in _live(menu.help, "Label"):
			out.append((n as Label).text)
		return out

	menu.help.show_browser_tips = false
	menu.open_help([["spec", "Watch somebody"], ["wr", "Fastest times here"]], true)
	await get_tree().process_frame
	var shown: PackedStringArray = texts.call()
	_check(menu.help.visible and shown.has("!spec") and shown.has("!wr"), "online, it lists the commands the server sent")
	_check(shown.has("Flashlight") and shown.has(p.bindings.key_for(&"g2g_flashlight")) and shown.has("Scoreboard (hold)"),
		"and every key, as it is bound now")
	_check(not shown.has("Ctrl + W"), "the browser's tips are for a browser, and this is not one")

	menu.help.close()
	menu.open_help(null, false)
	await get_tree().process_frame
	shown = texts.call()
	_check(not shown.has("!spec"), "offline there is no server, so no commands are offered")
	menu.help.close()

	# The family's rule since the first play test: H is help, nothing else is on H, the help
	# says what the game is, and the Escape menu has Help & commands and Leave.
	_check(p.bindings.key_for(&"g2g_help") == "H" and p.bindings.defaults_on("H").size() == 1
		and p.bindings.key_for(DotMenuBindings.MAPS_ACTION) == "M" and p.bindings.defaults_on("M").size() == 1,
		"help is on H and the map menu on M, and nothing else in the table is on either",
		str(p.bindings.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(menu.handle_event(h) and menu.help.is_open(), "H opens the help screen")
	await get_tree().process_frame
	_check(menu.help.about != "" and texts.call().has("How to play g2g fast") and texts.call().has("RUNS"),
		"which says what the game is before the keys")
	menu.help.close()
	menu.open()
	var leave := menu.screen.find_child("Action_leave", true, false) as Button
	_check(menu.screen.find_child("Action_help", true, false) != null, "the Escape menu has Help & commands")
	_check(leave != null and leave.visible, "and Leave")
	menu.close()

	menu.queue_free()
	host.queue_free()
	_done()


func _test_a_theme_is_every_screen() -> void:
	_section("A theme reaches the menus and the HUD, and switches while they are open")

	var s := G2GPresentation.schema()
	var themes := DotMenuThemes.stock()
	_check(themes.size() == 7 and s.find(&"ui_theme") != null
		and StringName(str(s.find(&"ui_theme").default_value)) == &"midnight",
		"seven themes, offered by a setting whose default is the palette the menus always had")
	var row := G2GBindings.make().row_for_action(&"g2g_theme_next")
	_check(not row.is_empty() and str(row["default"]) == "P", "and a key that cycles them, P unless rebound")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame
	menu.open(&"hud")
	await get_tree().process_frame

	var seen: Array = []
	menu.theme_changed.connect(func(palette: DotMenuPalette) -> void: seen.append(palette))
	p.settings.set_value(&"ui_theme", &"ember")
	await get_tree().process_frame
	var resume := menu.screen.find_child("Resume", true, false) as Button
	var fill := (resume.get_theme_stylebox(&"normal") as StyleBoxFlat).bg_color if resume != null else Color.BLACK
	var ember := themes.named(&"ember")
	_check(fill == ember.accent_deep, "a menu open when the theme changes is rebuilt in it",
		"%s against %s" % [fill, ember.accent_deep])
	_check(menu.is_open() and menu.screen.current_page() == &"hud", "on the page it was showing, still open")

	var hud := G2GHud.new()
	add_child(hud)
	hud.apply_theme(seen[0] if not seen.is_empty() else null)
	_check(hud.timer_hud.panel_colour == ember.hud_plate and hud.timer_hud.neutral_colour == ember.hud_text,
		"and the clock's plate and text are the theme's")
	menu.follow_hud(hud, null, false)
	_check(hud.hit_marker.colour(&"plate") == ember.hud_plate and hud.damage_numbers.colour(&"text") == ember.hud_text,
		"and dot-ui's pieces on it (the hit marker, the damage numbers) are in the theme too")

	p.settings.set_value(&"ui_theme", &"midnight")
	menu.queue_free()
	hud.queue_free()
	host.queue_free()
	_done()


func _test_the_board_is_a_timer_servers() -> void:
	_section("Tab holds a board of styles, best times and ranks")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	var client := G2GClient.new()
	client.menu = menu
	client.call("_wire_scoreboard")
	await get_tree().process_frame

	var board := menu.scoreboard
	board.source = func() -> Dictionary:
		return {"server": {"name": "g2g test", "map": "surf_test", "players": 3, "max": 24}, "you": 7,
			"players": [
				{"id": 5, "name": "Ada", "style": "Normal", "best": 61.234, "rank": 2, "of": 9, "seconds": 300, "ping": 40},
				{"id": 6, "name": "Bea", "style": "Sideways", "best": 58.5, "rank": 1, "of": 9, "seconds": 1200, "ping": 90},
				{"id": 7, "name": "Cy", "style": "Normal", "best": -1.0, "rank": 0, "seconds": 20, "ping": 15},
			]}
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.keycode = KEY_TAB
	tab.pressed = true
	_check(menu.handle_event(tab) and board.is_open(), "Tab held puts it up")
	await get_tree().process_frame
	var order: Array = board.rows().map(func(r: Dictionary) -> String: return str(r["name"]))
	_check(order == ["Bea", "Ada", "Cy"], "fastest first, and nobody with a time after everybody with one", str(order))
	var texts: Array = _live(board, "Label").map(func(l: Node) -> String: return (l as Label).text)
	_check(texts.has("0:58.500") or texts.any(func(t: String) -> bool: return t.contains("58.5")),
		"a best time is drawn as a time", str(texts))
	_check(texts.has("1 / 9") and texts.has("—"), "a rank out of how many, and a dash for no time")
	_check(not menu.any_open(), "and it is not a menu: the runner keeps moving")
	tab.pressed = false
	var _up := menu.handle_event(tab)
	_check(not board.is_open(), "letting go puts it away")

	client.free()
	menu.queue_free()
	host.queue_free()
	_done()


func _test_the_timer_is_the_players_layout() -> void:
	_section("The timer's lines and where everything goes are the player's")

	var hud := G2GHud.new()
	add_child(hud)
	await get_tree().process_frame
	if hud.size.x <= 0.0:
		hud.size = Vector2(1600, 900)

	hud.apply_layout({
		"show_stats": false, "show_track": false, "size": 40, "comparison": "wr",
		"position": "top_left", "compact": false,
	})
	var t := hud.timer_hud
	_check(not t.show_stats and not t.show_track and t.show_time and t.clock_size == 40
		and t.comparison == DotTimerHud.Comparison.WORLD_RECORD and not t.compact,
		"every timer line is the timer's own switch, so an off line closes up rather than leaving a gap")
	hud.place()
	_check(t.corner == DotTimerHud.Placement.TOP_LEFT, "and the block goes where the player put it")

	_check(G2GHud.positions_from_text("not json").is_empty() and G2GHud.positions_from_text("").is_empty(),
		"a positions setting that is not a layout is the default layout")
	var read := G2GHud.positions_from_text('{"timer":[0.25,0.5],"bogus":[1,1],"keys":[2,-1]}')
	_check(read.size() == 2 and read[&"timer"] == Vector2(0.25, 0.5) and read[&"keys"] == Vector2(1, 0),
		"unknown pieces are dropped and a piece off the screen is put back on it", str(read))
	_check(G2GHud.positions_from_text(G2GHud.positions_to_text(read)) == read, "and it round-trips")

	hud.move_element(&"timer", Vector2(300, 200))
	var clock := hud.element_rect(&"timer")
	_check(clock.get_center().distance_to(Vector2(300, 200)) < 1.0,
		"a dragged clock is drawn where it was dropped, with or without a run on it", str(clock))
	var keys := hud.element_rect(&"keys")
	_check(keys.position.y >= clock.end.y - 0.5 and absf(keys.get_center().x - clock.get_center().x) < 1.0,
		"and the keys follow it, centred underneath", "%s under %s" % [keys, clock])
	hud.reset_element(&"timer")
	hud.place()
	_check(not hud.positions.has(&"timer") and t.corner == DotTimerHud.Placement.TOP_LEFT,
		"putting it back is the layout's place again")

	hud.set_spectators(PackedStringArray(["Ada", "Bea"]))
	hud.place()
	var listed := hud.find_child("Spectators", true, false) as Control
	_check(listed != null and listed.visible and hud.element_rect(&"spectators").size.x > 0.0,
		"who is spectating is drawn when somebody is")
	hud.apply_layout({"show_spectators": false})
	_check(listed != null and not listed.visible, "and not when the player turned it off")

	hud.set_spectating(&"u8", "Bea")
	_check(hud.shown_id() == &"u8", "while spectating, the clock is the watched player's")
	hud.set_spectating(&"")
	_check(hud.shown_id() == hud.player_id, "and back to your own when you stop")

	var editor := DotMenuLayoutEditor.new()
	editor.target = hud
	editor.pieces = G2GClient.HUD_PIECES
	add_child(editor)
	var saved: Array[String] = ["unset"]
	editor.saved.connect(func(text: String) -> void: saved[0] = text)
	var status := hud.element_rect(&"status")
	editor.drag(&"status", status.get_center(), Vector2(400, 500))
	_check(hud.element_rect(&"status").get_center().distance_to(Vector2(400, 500)) < 1.0
		and saved[0].contains("status"),
		"the editor moves a piece and saves where it went", saved[0])
	_check(G2GHud.positions_from_text(saved[0]).has(&"status"),
		"in the shape the HUD reads back")
	_check(editor.piece_at(Vector2(400, 500)) == &"status", "and the piece is picked up where it is drawn")
	editor.reset_all()
	_check(saved[0] == "" and hud.positions.is_empty(), "Reset all is the default layout, saved as nothing")

	var p := _make()
	var host := FakeHost.new()
	add_child(host)
	var menu := _menu_for(p, host)
	await get_tree().process_frame
	menu.open(&"hud")
	await get_tree().process_frame
	var switches := _live(menu.screen, "DotMenuSwitch")
	_check(switches.size() == 8, "the HUD page has a switch per timer line and piece (%d)" % switches.size())
	(_row(menu, "timer_show_stats") as Button).button_pressed = false
	_check(not p.settings.get_bool(&"timer_show_stats", true), "and flipping one writes its setting")
	(_row(menu, "arrange") as Button).pressed.emit()
	_check(host.edited == 1, "and Move HUD elements asks the client to open the editor")

	menu.queue_free()
	host.queue_free()
	editor.queue_free()
	hud.queue_free()
	_done()


## Hit feedback on a combat map, from dot-ui: the marker and the number come from a hit the
## authority applied (`confirm_hit`), and nothing is drawn before one.
func _test_a_confirmed_hit_is_drawn() -> void:
	_section("A hit the server confirmed is drawn, and nothing before it")

	var hud := G2GHud.new()
	add_child(hud)
	await get_tree().process_frame

	_check(hud.hit_marker != null and hud.damage_numbers != null,
		"the HUD carries dot-ui's hit marker and damage numbers")
	_check(hud.hit_marker.alpha() == 0.0 and hud.damage_numbers.texts().is_empty(),
		"and neither draws anything until a hit lands", str(hud.hit_marker.describe()))
	hud.confirm_hit(7, 27.0, Vector3(0.0, 1.0, -4.0), false, true)
	_check(hud.hit_marker.alpha() > 0.0, "a confirmed hit flashes the marker", str(hud.hit_marker.describe()))
	_check(hud.damage_numbers.texts().size() == 1 and hud.damage_numbers.texts()[0].contains("27"),
		"and puts its number up", str(hud.damage_numbers.texts()))
	hud.queue_free()
	_done()


## The ammunition counter on an offline deathmatch: the combat layer writes the weapon in
## hand onto the player and the HUD names it, with no count (both weapons are endless). Armed
## by dropping `_note_held` (the first check fails) and by showing the count (the last does).
## Connected, the same field arrives by `net_weapon`: `headless_net`'s blind-and-beacon section.
func _test_the_weapon_in_hand_is_named() -> void:
	_section("The weapon in hand is named on a deathmatch, and nothing on a timer server")

	var config := G2GConfig.new()
	config.records_directory = ""
	config.initial_map = &"bhop_g2g_intro"
	config.deathmatch = true
	var game := G2GGame.new()
	game.name = "AmmoGame"
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	var ada: G2GPlayer = game.add_player(&"u1", "Ada")
	var hud := G2GHud.new()
	hud.size = Vector2(1280.0, 720.0)
	add_child(hud)
	hud.bind(game, &"u1")
	for _i in range(60):
		await get_tree().physics_frame
		if ada.held_weapon != &"":
			break

	_check(ada.held_weapon in [&"knife", &"deagle"], "the combat layer puts a weapon in hand", str(ada.held_weapon))
	hud._process(1.0 / 60.0)
	_check(hud.ammo.weapon_name == String(ada.held_weapon).capitalize() and hud.ammo.count_text() == "",
		"and the counter names it with no count, because it has no magazine", str(hud.ammo.describe()))
	_check(hud.ammo.footprint().size != Vector2.ZERO
			and not hud.ammo.get_global_rect().intersects(hud.element_rect(&"timer")),
		"drawn bottom right, clear of the clock", "%s / %s" % [hud.ammo.get_global_rect(), hud.element_rect(&"timer")])

	game.combat.enabled = false
	for _i in range(4):
		await get_tree().physics_frame
	hud._process(1.0 / 60.0)
	_check(ada.held_weapon == &"" and hud.ammo.weapon_name == "",
		"with deathmatch off the hand is empty and the counter draws nothing", str(hud.ammo.describe()))

	hud.show_weapon(null)
	_check(hud.ammo.footprint() == Rect2(), "and watching somebody else shows nothing")

	hud.queue_free()
	game.queue_free()
	_done()


## Every .gd file under [param dir], recursively.
func _scripts_under(dir: String) -> Array[String]:
	var out: Array[String] = []
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_scripts_under(dir.path_join(sub)))
	return out


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _skip(count: int, why: String) -> void:
	_skipped += count
	print("  skip  %d check(s): %s" % [count, why])


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition
