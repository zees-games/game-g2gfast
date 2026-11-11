extends "headless_presentation_menu.gd"

## The party, chat, rig and voice sections of headless_presentation.


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
	# the HUD's own or zero, which is the bug game-fatal-contact's first rendered frame showed.
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


## `[p2p-await-games]`: a practice session over the HTTP rendezvous, host and join, each
## awaited end to end — through `G2GParty`, `DotP2PSession` and `DotP2PSignallerHttp` to
## a socket and back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link in the chain that dropped its `await` hands its caller null or returns before
## the stub has answered, and either fails here.
##
## Differs from the other games' copy in one rule: a run started in a session that met over a
## real rendezvous is tainted, because that is the path a real practice session takes.
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
