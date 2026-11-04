extends "headless_presentation_chat.gd"

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

const CHECKS := 223
const SECTIONS := 25


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
	_test_the_weapons_are_heard()
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

	print("%d checks skipped" % _skipped)
	_report_sections(_entered, _completed, SECTIONS, CHECKS - _skipped)


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
	_check(s.find(&"ambience_volume") != null and is_zero_approx(float(s.find(&"ambience_volume").default_value)),
		"the wind and birdsong bed is off by default, and still a setting")
	_check(DotMenuStock.audio_page().sections.any(func(sec) -> bool: return sec.rows.any(func(r) -> bool: return r.key == &"ambience_volume")),
		"and the Audio page has its slider")
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

func _test_the_weapons_are_heard() -> void:
	_section("The deagle and the knife play dot-audio's stock recordings")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	_check(p.audio.catalogue.has(&"weapon_magnum_fire"), "the game's catalogue carries the weapon stock (DotAudioStock.add_to)")
	var stock_problems := DotWeaponSound.check_stock()
	_check(stock_problems.is_empty(), "every weapon class resolves a non-silent, unclipped stock voice (%s)" % ", ".join(stock_problems))
	var def: DotAudioDef = p.audio.catalogue.find(&"weapon_magnum_fire")
	_check(def != null and def.variants.size() >= 4 and ResourceLoader.exists(def.variants[0]), "and its deagle report has real variant files")

	sink.forget()
	p.on_weapon_used(&"deagle", Vector3.ZERO, Vector3.ZERO)
	_check(sink.count_of(&"weapon_magnum_fire") == 1, "a deagle shot plays the magnum report")
	p.on_weapon_used(&"deagle", Vector3(200.0, 0.0, 0.0), Vector3.ZERO)
	_check(sink.count_of(&"weapon_magnum_far") == 1, "and a far one plays the distant recording")
	p.on_weapon_used(&"knife", Vector3.ZERO, Vector3.ZERO)
	_check(sink.count_of(&"weapon_swing") == 1, "a knife plays a swing")
	p.on_weapon_dry(Vector3.ZERO)
	_check(sink.count_of(&"weapon_dry") == 1, "the trigger on nothing clicks")
	p.on_weapon_equipped(Vector3.ZERO)
	_check(sink.count_of(&"weapon_equip") == 1, "a weapon coming up is heard")
	p.on_weapon_used(&"nothing", Vector3.ZERO, Vector3.ZERO)
	_check(sink.played().size() == 5, "and an unknown weapon plays nothing")

	sink.forget()
	p.on_weapon_used(&"deagle", Vector3.ZERO, Vector3.ZERO)
	p.present(0.2, Vector3.ZERO, Vector3.FORWARD)
	_check(sink.count_of(&"weapon_magnum_far") == 0, "outdoors a deagle shot has no room tail")
	p.shot_roof.feed(true)
	p.shot_roof.feed(true)
	_check(p.shot_roof.roofed, "two rays under a ceiling roof the listener")
	sink.forget()
	p.on_weapon_used(&"deagle", Vector3.ZERO, Vector3.ZERO)
	p.present(0.01, Vector3.ZERO, Vector3.FORWARD)
	_check(sink.count_of(&"weapon_magnum_far") == 0, "indoors the tail waits out its delay")
	p.present(0.2, Vector3.ZERO, Vector3.FORWARD)
	_check(sink.count_of(&"weapon_magnum_far") == 1, "and then the deagle's distant recording follows the report")

	p.queue_free()
	_done()


func _test_console_is_prefixed() -> void:
	_section("Two consoles whose names mean opposite things")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in G2GPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))
	_check(p.console.all_names().has("cl_weapon_icons") and p.console.all_names().has("cl_weapon_icon_profile"),
		"the weapon icon cvars are at the console")

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
