extends "g2g_client_base.gd"

## The figure an avatar action plays on: that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: G2GPlayer = null
	if bridge != null and peer_id != 0 and game != null:
		who = game.players.get(StringName("u%d" % bridge.player_for_peer(peer_id)), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.rig.person if who != null and who.rig != null else null


# The load gate

## The screen stays covered, and the local body and the input stay still, until the level is
## built, the local player exists and its camera is current.
##
## [b]Without it the first frames were a half-built world[/b] (a player falling onto a floor still
## arriving, a HUD with nobody to read, a run timer fed through a map change). The gate does not
## stop the simulation itself: [member G2GGame.covered] freezes the tick and the timers,
## [method G2GPlayer.simulate] skips a frozen body, and the keys and netcode sampling check [method _covered].
func _build_gate() -> void:
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	# The rest of the platform stays this client's own: its presentation layer owns the
	# settings and the console, G2GMenuPages the menu, and _grab_mouse the pointer (it has a
	# click-to-play notice). What it takes over is the cover, and telling the server about it.
	platform.use_settings = false
	platform.use_console = false
	platform.capture_pointer = false
	platform.spawned_text = "Joining"
	platform.spawned_fn = func() -> bool:
		return player != null and player.camera != null and player.camera.is_inside_tree()
	# The chat box, console, menu, help and spectating have the keyboard; polled by the
	# platform each frame, so nothing needs forwarding from each of them.
	platform.busy_fn = _input_busy
	add_child(platform)
	gate = platform.gate
	gate.hold(&"map", "Loading the map")
	# The cover blocks input too, so the sampler is still while it is up.
	platform.input_blocked_changed.connect(func(_blocked: bool) -> void: _refresh_suspended())


## dot-workbench over the config: the F9 panel in the editor and debug builds (never in production);
## a window of its own, so a client has no HTTP page.
func _build_workbench() -> void:
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.listen_host_fn = platform.listen_host_fn
	workbench.config = {"enabled": false}
	for set: DotProfileSet in game.config_binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var started := workbench.start()
	if started.ok and workbench.api != null:
		game.config_binder.attach(workbench.api.runtime)
	# This game's menu and console stand in for the platform's (it builds neither itself), only
	# for the call that hooks the window and the `workbench` command up.
	platform.menu = menu
	platform.console = presentation.console if presentation != null else null
	platform.add_workbench(workbench)
	platform.menu = null
	platform.console = null


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote).
func _start_remote_workbench() -> void:
	if _workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = _workbench_remote
	wb.remote_fn = func() -> bool: return true
	var started := wb.start(_profile_runtime)
	DotLog.result("g2g.client", "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.menu = menu
	platform.console = presentation.console if presentation != null else null
	platform.add_workbench(wb)
	platform.menu = null
	platform.console = null


func _say_ready() -> void:
	if _workbench_remote != null:
		_workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


## Releases the map hold once the first level is in, and holds again for each map change.
## Offline the first map is already up (the game loads it inside its own `_ready`); connected
## it arrives with the server's `load`.
func _wire_gate_to_maps() -> void:
	game.maps.changing.connect(
		func(_from: DotMapDef, _to: DotMapDef) -> void: gate.hold(&"map", "Loading the map")
	)
	game.maps.changed.connect(
		func(_map: DotMapDef, _loaded: Node) -> void: gate.release(&"map")
	)
	if game.maps.current != null:
		gate.release(&"map")


## True while the load gate covers the screen: no key, no mouse turn, no run.
func _covered() -> bool:
	return gate != null and not gate.is_open()


# The end of a deathmatch: final killcam, winner reveal, board

## How long the board stays up after the reveal, with nobody holding Tab.
const SUMMARY_BOARD_SEC := 8.0

## The final killcam: records every frame, replays the last kill before the winner reveal.
var killcam: DotKillcamHost = null
var killcam_bodies := G2GKillcamBodies.new()
var winner_reveal: DotWinnerReveal = null

var _end_rows: Array = []
var _end_active: bool = false
var _reveal_hid: Dictionary = {}
var _summary_board_open: bool = false
var _killcam_sec: float = 0.0


func _build_killcam() -> void:
	if DotAddonApi.build_level("dot_replay") >= 6:
		killcam = DotKillcamHost.new()
		killcam_bodies.configure(killcam, game)
		killcam.seconds_fn = func() -> float: return _killcam_sec
		killcam.over.connect(func(_skipped: bool) -> void: _reveal_winner())
		add_child(killcam)
	_build_winner_reveal()
	if _offline:
		G2GClientKillView.solo(self, game)


func _build_winner_reveal() -> void:
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = G2GKillcamBodies.SKIP_ACTIONS
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)
	game.map_ready.connect(func(_map: DotMapDef) -> void: _leave_match_end())


## The deathmatch ended: the final killcam if there is a kill to show, then the winner.
func _match_over(killcam_sec: float, rows: Array) -> void:
	_end_rows = rows
	_end_active = true
	_killcam_sec = killcam_sec
	if killcam == null:
		_reveal_winner()
	elif killcam.match_ended():
		DotLog.debug("g2g.client", "the winner waits for the final killcam")


## The top three on a podium, after the killcam and before the board.
func _reveal_winner() -> void:
	if not _end_active:
		return
	var entries: Array = []
	for row: Dictionary in _end_rows:
		var kills := int(row.get("kills", 0))
		var deaths := int(row.get("deaths", 0))
		entries.append({"name": str(row.get("name", "")), "score": "%d %s  %d %s" % [
			kills, "kill" if kills == 1 else "kills", deaths, "death" if deaths == 1 else "deaths"]})
	winner_reveal.reduced_motion = presentation != null and presentation.settings != null \
		and presentation.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "WINNER", "hint": "Jump to skip"})
	if not shown.ok:
		_end_active = false
		_open_summary_board()
		return
	if hud != null:
		_reveal_hid[hud] = hud.visible
		hud.visible = false


func _on_reveal_finished(_skipped: bool) -> void:
	for n: Variant in _reveal_hid:
		if is_instance_valid(n):
			(n as CanvasItem).visible = _reveal_hid[n]
	_reveal_hid.clear()
	if _end_active:
		_end_active = false
		_open_summary_board()


func _open_summary_board() -> void:
	if menu == null or menu.any_open():
		return
	menu.scoreboard.open()
	_summary_board_open = true
	await get_tree().create_timer(SUMMARY_BOARD_SEC).timeout
	if _summary_board_open and menu != null:
		_summary_board_open = false
		menu.scoreboard.close()


## A new match or map began: whatever of the end is still up goes.
func _leave_match_end() -> void:
	if not _end_active and not _summary_board_open:
		return
	_end_active = false
	if killcam != null:
		killcam.skip()
	if winner_reveal != null:
		winner_reveal.skip()
	if _summary_board_open and menu != null:
		_summary_board_open = false
		menu.scoreboard.close()


# Dead bodies

## The yard the dead lie in, the presentation's sound, and the solo game's own deaths. Built
## once; emptied on a map change (a body on the old map's floor would hang in the new one's
## air). Connected, the deaths arrive as DEATH and ALIVE through the bridge instead.
func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = func(id: StringName, at: Vector3, volume: float) -> void:
		if presentation != null:
			var _played := presentation.on_body(id, at, volume)
	add_child(ragdolls)

	game.map_ready.connect(func(_map: DotMapDef) -> void:
		ragdolls.clear()
		for id: StringName in game.players:
			rise(id)
	)

	# Solo, the world is this process's and there is no DEATH message: the death the combat
	# layer decided is on the player.
	if game.combat != null:
		game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
			var id := game.combat.player_id_for(entry.victim_key.to_int())
			var who: G2GPlayer = game.players.get(id)
			var _fell := fall(id, who.death if who != null else null)
		)
		game.combat.player_respawned.connect(rise)
		# The deagle and the knife are heard (dot-audio's weapon stock).
		game.combat.weapon_used.connect(func(_id: StringName, weapon: StringName, at: Vector3) -> void:
			var cam: Camera3D = player.camera.active() if player != null and player.camera != null else null
			presentation.on_weapon_used(weapon, at, cam.global_position if cam != null else at))
		game.combat.weapon_dry.connect(func(_id: StringName, at: Vector3) -> void:
			presentation.on_weapon_dry(at))
		game.combat.weapon_equipped.connect(func(id: StringName, _weapon: StringName, at: Vector3) -> void:
			if player != null and id == player.player_id:
				presentation.on_weapon_equipped(at))
		game.combat.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
			if killcam != null:
				killcam.note_kill(entry.killer_key.to_int(), entry.victim_key.to_int(), entry.cause, entry.headshot)
		)
		if game.combat.match_node != null:
			# Deferred: the last kill ends the match from inside its own report, before the kill
			# reaches the killcam.
			game.combat.match_node.match_ended.connect(func(_winner: int, _outcome: int) -> void:
				_match_over.call_deferred(game.config.killcam_seconds, game.combat.podium_rows())
			)


## [param id]'s body falls the way the server picked ([param death]; null is a plain drop),
## copied from the rig this client draws, which stays hidden until [method rise]. Null when
## the server's style hides bodies, or nobody here draws that body: a player the client is
## hiding, or this client's own in first person (the camera is inside its head).
func fall(id: StringName, death: DotPlayerDeath) -> DotPlayerRagdoll:
	if killcam != null:
		killcam_bodies.set_alive(id, false)
	var who: G2GPlayer = game.players.get(id) if game != null else null
	if who == null or ragdolls == null or who.rig == null or not who.rig.is_inside_tree():
		return null
	if not who.visible or (who == player and not who.rig.visible_to_owner):
		return null
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	return ragdolls.spawn(who.rig, death if death != null else DotPlayerDeath.new(), velocity)


## [param id] is alive again: the rig a fall hid is drawn again where they now stand.
func rise(id: StringName) -> void:
	if killcam != null:
		killcam_bodies.set_alive(id, true)
	_leave_match_end()
	var who: G2GPlayer = game.players.get(id) if game != null else null
	if who != null and who.rig != null:
		who.rig.visible = true


## Lists what the browser found, on the HUD. What `!servers` and F3 both call.
##
## [b]A chat command rather than a screen, and game-arena has a screen.[/b] That game
## has a [DotScreenStack]; this client has a HUD and a keyboard, and the genre's answer
## to "show me the servers" is a chat trigger, because that is what a bhop player's
## fingers already do. The list model, the sources, the filters and the favourites are
## the same addon doing the same work either way.
func show_servers() -> void:
	if servers == null or hud == null:
		return

	hud.notice("Looking for servers…")

	var found: DotResult = await servers.refresh()

	if not found.ok:
		hud.notice(found.error.message)
		return

	for line in servers.lines():
		hud.notice(line)


## Hides and captures the cursor, or arranges for a click to do it.
##
## [b]A browser will not hide the cursor because a scene asked it to.[/b] Pointer lock needs a
## real click and `_ready()` never has one; the request is refused SILENTLY (`Input.mouse_mode`
## reads CAPTURED, the cursor stays), so the mouse leaves the window mid-run.
## Desktop captures immediately.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true
	_say_click_to_play()


## Tells the player the one thing they have to do, once there is a HUD to say it on.
##
## `_ready()` builds the HUD only on the offline path; a networked client gets one when
## the server says who it is, which is several hundred milliseconds later. Saying it in
## both places rather than once is why this is a function.
func _say_click_to_play() -> void:
	if _awaiting_click and hud != null:
		hud.notice("Click to play")


## Follows a player: the camera, the HUD, and everything the keys act on.
##
## [b]The id arrives one message before the player does.[/b] `HELLO` says who you are and
## `JOIN` is what creates you — `G2GNetBridge._apply_join` calls `game.add_player` — so a
## networked client that resolved [member player] here and never again held null for the
## whole session. Nothing errored: the HUD binds by id and worked, movement is polled
## from the [InputMap] by `DotFpsSampler.sample` and worked, and the camera follows the
## entity rather than this reference. What did not work was every line below the
## `player == null` guard in [method _unhandled_input] — which is mouse look, F5, Tab, R,
## C, V and M. **The whole keyboard and the whole mouse, on a client that otherwise
## looked fine.**
##
## `headless_net` never instantiates this class — it drives two bridges directly — so
## nothing in the suite had ever been through this path.
func _watch(id: StringName) -> void:
	_watch_id = id
	_adopt(game.players.get(id))

	if hud == null:
		hud = G2GHud.new()
		hud.name = "Hud"
		add_child(hud)
		_follow_hud()
	hud.bind(game, id)
	# The server's time left, which may well have arrived before there was a HUD: HELLO
	# and the admit's CLOCK come together, and JOIN is what makes the player watched.
	if bridge != null:
		hud.clock_view = bridge.clock_view
	# Likewise the standing: kept from whenever it came, so a HUD made after it still
	# shows the best and the record.
	if not _standing.is_empty():
		hud.apply_standing(_standing)
	if not _stage_reference.is_empty():
		hud.apply_stage_reference(_stage_reference)
	apply_client_settings()
	_say_click_to_play()

	# By id, like the HUD, and for the same reason: HELLO names us before JOIN makes us.
	if presentation != null:
		presentation.follow_runs(game.timers, id)


## The player we are waiting for has been created. Fires for every player; ours is one.
func _on_player_added(added: G2GPlayer) -> void:
	_hear_beacon(added)

	if player == null and added != null and added.player_id == _watch_id:
		_adopt(added)


## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## Every player reaches this, because every player on a client — offline, the local one
## and a ghost; online, everybody the server sends — is made by `G2GGame.add_player`,
## which emits `player_added` after this client has connected to it. Guarded anyway,
## because a second connection would be every ping played twice.
##
## Bound to the body, so a ping can be left unplayed for a player [method _hidden] is
## hiding — a beacon you cannot see should not be one you can hear either. The guard is a
## dictionary rather than `is_connected`, because a bound callable is a new [Callable] and
## would never compare equal to the one already connected.
func _hear_beacon(body: G2GPlayer) -> void:
	if body == null or _beacons_heard.has(body.get_instance_id()):
		return

	_beacons_heard[body.get_instance_id()] = true
	body.beacon_pulsed.connect(_on_beacon_pulsed.bind(body))


func _on_beacon_pulsed(at: Vector3, body: G2GPlayer) -> void:
	if presentation != null and not _hidden(body):
		var _voice := presentation.on_beacon(at)


func _adopt(candidate: G2GPlayer) -> void:
	if candidate == null:
		return

	player = candidate
	gate.freeze(player)

	# The sampler turns the view at the rate this player's style says, and until there
	# is a player to ask it is on the game's own tunables. Done here rather than in
	# `_on_hello` for the same reason as everything else in this function: at hello
	# there is nobody to ask.
	if _sampler != null:
		_sampler.tunables = player.controller.tunables

	# The settings that live on the PLAYER rather than on the presentation layer, and
	# for the same reason the sampler is here: `apply_all()` ran during `setup()`, when
	# there was nobody to apply them to. A networked client reaches this function a
	# JOIN after that, and again every time the server hands it a new player.
	if presentation != null:
		presentation.apply_own_body()

	apply_client_settings()
	_apply_rules_to_player()
	_restore_style()
	# A new player has a new sampler (offline), and it has to start the way the old one
	# was left: a chat box open across a respawn or a map change is still open.
	_refresh_suspended()


## The bridge's signals about the world: deaths, shots, the server's rules, the clock and the vote.
func _wire_bridge_world() -> void:
	# Every death on the server, a hunter's swipe included, and every return to a start.
	bridge.death_received.connect(func(id: StringName, death: DotPlayerDeath) -> void:
		var _fell := fall(id, death)
	)
	bridge.alive_received.connect(rise)
	bridge.kill_received.connect(func(killer: StringName, victim: StringName, weapon: String, head: bool) -> void:
		if killcam != null:
			killcam.note_kill(killcam_bodies.id_for(game, killer), killcam_bodies.id_for(game, victim), weapon, head)
	)
	bridge.match_end_received.connect(_match_over)
	# Everybody else's shots: the local player's own is predicted by the combat layer here.
	bridge.shot_received.connect(func(who: StringName, weapon: StringName, at: Vector3) -> void:
		if player != null and who == player.player_id:
			return
		var cam: Camera3D = player.camera.active() if player != null and player.camera != null else null
		presentation.on_weapon_used(weapon, at, cam.global_position if cam != null else at)
	)
	# The server's sv_ragdoll* set: this end draws the bodies. An older shell's link cannot
	# say, and the rules keep their defaults.
	if link != null:
		var _bodies := game.ragdoll_rules.follow_cvars(link)
		var _weapons := game.weapon_layer.rules.follow_cvars(link)
		# The server's mp_forceview: this end places its own camera (G2GGame keeps every
		# camera under it).
		var _view := game.view_rules.follow_cvars(link)
		# mp_teamblock, mp_enemyblock and the `!block` requests, followed so this end predicts
		# against the same pairs. Needs dot-team; without it players are not blocked at all.
		var blocked := platform.add_noblock(game, Callable(game, "block_side"))
		if not blocked.ok:
			DotLog.result("g2g.client", "the block rules", blocked)
		# mp_forcecamera, mp_freeroam and mp_freeroam_speed: whether the free camera is
		# offered, and how fast it flies.
		if game.spectate != null and game.spectate.manager != null:
			var _roam := game.spectate.manager.rules.follow_cvars(link)
			game.spectate.manager.rules.rules_changed.connect(_refresh_spectator_hud)
	# The map's time left, from the server's vote. The bridge holds it; the HUD draws it.
	bridge.clock_received.connect(func(_state: Dictionary) -> void:
		if hud != null:
			hud.clock_view = bridge.clock_view
	)
	# The map vote's cue and countdown. The ballot itself arrives as chat; this is what
	# chat cannot carry.
	bridge.vote_received.connect(func(info: Dictionary) -> void:
		var seconds_left := int(info.get("seconds_left", 0))
		if seconds_left > 0 and hud != null:
			hud.notice("%s in %d…" % [
				"Runoff" if bool(info.get("runoff", false)) else "Map vote", seconds_left
			])
		if presentation != null:
			presentation.on_vote_cue(StringName(str(info.get("cue", ""))))
	)

# Chat

## Joins the chat box to the two things it needs: a way out, and a way to stop the runner.
##
## [b]The sampler is the half that is easy to forget, and on a timer server it is the
## expensive one.[/b] `swallows_input` keeps typed keys out of `_unhandled_input`, but
## movement here is POLLED — `DotFpsSampler.sample` reads the device every physics frame
## and does not care what consumed an event. Without `suspended`, typing during a run
## strafes the player off a ramp and ends it.
func _wire_chat_window() -> void:
	var window: DotChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)

	window.opened.connect(func(_channel: StringName) -> void: _refresh_suspended())
	window.closed.connect(func() -> void: _refresh_suspended())


## What a player typed, on its way to the server.
##
## Nothing is filtered here: the server decides what a line may contain and its answer is
## the only one that counts.
func _on_chat_submitted(text: String, channel: StringName) -> void:
	if _offline:
		# Offline there is no server to decide anything, so the line goes straight to the
		# log. Saying nothing would read as a chat box that does not work.
		if presentation != null and presentation.chat_window != null:
			presentation.chat_window.add_said("You", text, Color(0.62, 0.78, 1.0))
		return

	if link != null and link.has_method("send_chat"):
		link.send_chat(text, channel == &"team")


## A line somebody said, in the chat box, with the name drawn apart from the text.
func _on_said(speaker: String, text: String, kind: String) -> void:
	# The server's own lines (a vote, a record, a map change) go on the HUD's centre notice
	# only when there is no box to read them in. Every line used to, which put whatever
	# anybody typed over the timer; then every system line did, so a vote was written three
	# times (notice, box, and the drawn ballot). The box draws even when a relay hides its
	# entry field, so it is always the place. hungario 5bfb319 and playground 532b7ca agree.
	if kind == "system" and hud != null and (presentation == null or presentation.chat_window == null):
		hud.notice(text)

	if presentation == null or presentation.chat_window == null:
		return

	var speaker_colour := Color(0.55, 0.85, 0.60) if kind == "team" else Color(0.62, 0.78, 1.0)

	if speaker == "":
		presentation.chat_window.add_text(text, Color(0.80, 0.82, 0.86))
		return

	presentation.chat_window.add_said(speaker, text, speaker_colour)


func _on_hello(player_id: int) -> void:
	_watch(StringName("u%d" % player_id))
	# The server dressed us from dot-platform's admission if it could; a launcher
	# that resolved one locally through DotAvatarManager sets [member avatar] and it
	# goes up now, to be conformed against the server's schema like any other.
	if avatar != null and bridge != null:
		bridge.publish_avatar(avatar)


## The server moved to a map this client will not or cannot load.
##
## [b]Leaves, rather than staying.[/b] The server keeps simulating this player on the map
## it announced, so staying is a player whose every tick is corrected into geometry their
## screen does not have — and the server cannot know to do anything about it, because
## dot-map keeps a refusal silent on purpose. The client is the one end that knows, so it
## is the one that acts, with the reason on the way out rather than a connection that
## simply goes strange.
func _on_map_refused(map_id: StringName, reason: String) -> void:
	var text := "Cannot follow the server to %s: %s" % [String(map_id), reason]
	if hud != null:
		hud.notice(text)
	if link != null and link.has_method("disconnect_from_server"):
		link.call("disconnect_from_server", text)


func _physics_process(delta: float) -> void:
	if _offline or net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)
	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if net.clock.is_synced():
			# The clock above has advanced; only the sampling waits, so the mouse does not pile
			# up a turn behind the cover and the server sees an idle body until it lifts.
			var command: DotFpsCommand = DotFpsCommand.new() if _covered() else _sampler.sample(delta)
			bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), command)


## The shared cover instead of a grey world while the server is on a map this client is not on.
## Edge-triggered: a hold re-closes the gate and restarts its settle.
func _cover_transit(text: String) -> void:
	if text == _transit_text or gate == null:
		return
	_transit_text = text
	if text == "":
		gate.release(&"transit")
	else:
		gate.hold(&"transit", text)


## Hands the local player this frame's view, the mouse motion of THIS frame folded in,
## so a frame on which no tick ran still turns. See [member G2GPlayer.view_now].
##
## By name, with the state's angles as the fallback: a pack runs on whatever
## dot-player-controller the client shell carries, and a shell older than `look_now`
## draws exactly what it drew before.
func _fold_look() -> void:
	if player == null:
		return
	var sampler := _active_sampler()
	if sampler == null or not sampler.has_method(&"look_now") or is_spectating():
		player.view_now = null
		return
	player.view_now = sampler.call(&"look_now")


## Hands the local player what is left of its prediction corrections, so the eye eases
## across one rather than jumping with it. See [member G2GPlayer.drawn_offset].
func _fold_correction() -> void:
	if player == null:
		return
	player.drawn_offset = Vector3.ZERO
	if _offline or net == null or net.predictor == null or bridge == null:
		return
	var mine := bridge.behaviour_for(bridge.local_player_id)
	if mine != null and mine.identity != null and mine.player == player:
		player.drawn_offset = net.predictor.visual_offset(mine.identity.net_id)


## Hands the local player's controller the clock its ticks are counted on, so its
## `render_state` draws at `DotNetClock.render_alpha` (dot-net) rather than the engine's
## physics fraction: the clock stretches and shrinks its ticks while it settles on the
## server, a physics frame now and then runs no tick or two, and drawn at the engine's
## fraction the eye stood still on one frame and moved double on the next.
## `headless_feel`'s *a clock slip* section measures it beside its control.
##
## By name both ways: `set` on a shell's older `DotFpsController` is a no-op, and the
## controller asks the clock for `render_alpha` by name, so a shell older than either draws
## exactly as before. Null offline, where every physics frame is one tick.
func _fold_clock() -> void:
	if player == null or player.controller == null:
		return
	var connected := not _offline and net != null and net.is_running() and net.clock != null
	player.controller.set(&"render_clock", net.clock if connected else null)


## Mouse motion while roaming, as radians for [DotSpectatorFreeCam.look]: x turns the view
## left for positive (so mouse right is negative), y up for positive (mouse down is negative).
func _roam_mouse(motion: InputEventMouseMotion) -> void:
	var sampler := _active_sampler()
	var degrees := sampler.tunables.mouse_sensitivity if sampler != null and sampler.tunables != null else 0.12
	var invert := -1.0 if sampler != null and sampler.tunables != null and sampler.tunables.invert_look_y else 1.0
	_roam_look += Vector2(-motion.relative.x, -motion.relative.y * invert) * deg_to_rad(degrees)


## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
##
## [b]Only while the cursor is actually captured.[/b] KEY_ESCAPE releases it, and on the
## web [member _awaiting_click] leaves it released before the first click too — in both
## of those states the pointer is a pointer, so spending its motion on the view turns
## the player away from the "click to play" notice they are being asked to click.
## `game-arena` guarded this from the start; this file and `game-playground` did not.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested here.[/b] The dummy display server pins the
## mode to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so a suite
## can neither put a client into the state a player plays in nor out of it — which is
## why arena's identical guard has never been exercised by anything.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Whether a click may take the pointer back: not while a modal holds it through [method DotGameClient.hold_pointer] (or a `dot_pointer_modal` node). Spectating is exempt because it is also "busy" to the platform and still needs the click.
func click_may_capture() -> bool:
	return platform == null or is_spectating() or not platform.is_input_blocked()


## R. Once: back to the start of the stage you are in (or of the track, when you are in
## none). Twice inside [constant DOUBLE_TAP_MSEC]: back to the main start zone, from a bonus
## too. See [method G2GGame.restart] for what each means.
##
## [b]The first press acts at once rather than waiting to see whether a second comes.[/b]
## Waiting would put a third of a second of nothing between every R and the restart, on the
## key a runner presses more than any other; and the second press only ever widens what the
## first did, so having acted early costs nothing.
func _restart_key(now_msec: int = -1) -> int:
	var now := now_msec if now_msec >= 0 else Time.get_ticks_msec()
	var mode := G2GEvents.RESTART_MAIN if now - _last_restart_msec <= DOUBLE_TAP_MSEC \
		else G2GEvents.RESTART_STAGE
	# A double tap is spent: a third press starts counting again rather than being a
	# second double tap.
	_last_restart_msec = now if mode == G2GEvents.RESTART_STAGE else -100000

	if _offline:
		var _restarted := game.restart(&"local", mode)
		if hud != null:
			hud.refresh_stage_reference()
	elif bridge != null:
		bridge.ask_restart(mode)
	return mode


# Themes and the HUD's layout

## The theme the menu just changed to, onto the HUD and the zone editor. The menus restyle
## themselves (dot-menu rebuilds them rather than recolouring, for the reason its CLAUDE.md
## gives); this is the half that is this game's.
## dot-ui's pieces on the HUD (the hit marker, the damage numbers) in the menu's theme too,
## live: the menu sets the theme on the HUD's root (dot-menu's `follow_hud`, by name for a
## shell older than it). Not scaled by the HUD size setting: this HUD is laid out by the
## player's own zone editor (`hud_positions`), in the frame's pixels. Whichever of the HUD and
## the menu comes second calls it.
func _follow_hud() -> void:
	if hud != null and menu != null and menu.has_method(&"follow_hud"):
		menu.call(&"follow_hud", hud, null, false)
