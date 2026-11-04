extends "dedicated_checks.gd"

## The vote, map-menu and mode sections of dedicated.gd, split out for size.


## dot-vote over this server's map catalogue.
##
## [b]This game already had a rock-the-vote and it was not one.[/b]
## `DotMapTimeLimit` counts votes against a fraction and expires the map: a countdown
## and a tally. What a records community runs is a ballot — nominations, seconding, an
## instant runoff, a cooldown, an extend option — and that is dot-vote.
func _test_vote() -> void:
	_section("the vote")

	var module := server.modules.get_module("g2gfast")
	var vote: G2GVote = module.get("vote") if module != null else null

	_check(vote != null, "the vote is up")

	if vote == null:
		return

	_check(vote.source != null and vote.source.is_usable(), "with something to vote for")
	_check(
		vote.director.rules.method == DotVoteRules.Method.INSTANT_RUNOFF,
		"counted by instant runoff rather than plurality"
	)
	_check(
		vote.director.rules.include_extend,
		"and a map can be extended rather than only replaced"
	)

	# `begin_on_apply` off is what stops one play being counted twice. Two entries in
	# the history for one play is a "last five" cooldown that is quietly two or three.
	_check(
		not vote.director.begin_on_apply,
		"the director does not announce a change the host already announces"
	)

	# The ghost is a player in every sense that matters to the game and none that
	# matters to a vote. Counting it would let a one-player server pass a quorum of
	# two, and let it rock the vote on its own.
	game.spawn_ghost()

	var voters := vote._player_count()
	var ghosted := game.players.has(G2GGame.GHOST_ID)

	# [b]The count, not zero.[/b] The first version of this asserted an empty server
	# and the sections above leave players on it — so it failed at "2 voters with 3
	# players", which is the exclusion working. What it has to say is that the ghost
	# is the one player that is not a voter.
	_check(
		voters == game.players.size() - (1 if ghosted else 0),
		"the record ghost is not counted as a voter",
		"%d voters, %d players, ghost %s" % [
			voters, game.players.size(), "up" if ghosted else "absent"
		]
	)

	_test_vote_ballot(vote)
	_test_vote_commands(module)
	_test_status_clock(vote)
	_done()


## The ballot opens, closes, and hands its cues on for the wire.
func _test_vote_ballot(vote: G2GVote) -> void:
	# What the module forwards to the wire as a VOTE event, heard at the vote's edge.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, _runoff: bool) -> void:
		heard.append([String(cue), seconds_left])
	vote.cue_due.connect(probe)

	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(
		opened.ok or opened.error != null,
		"a vote can be asked for and answers either way",
		"" if opened.ok else opened.error.message
	)

	if opened.ok:
		_check(vote.is_voting(), "and the ballot opens")
		vote.director.close_vote()
		_check(not vote.is_voting(), "and closes again")
		_check(
			heard.has([String(G2GVote.CUE_START), 0]) and heard.has([String(G2GVote.CUE_END), 0]),
			"and its start and end cues are handed on for the wire (%s)" % str(heard)
		)

	vote.cue_due.disconnect(probe)


## The console commands and the bridge's RTV request.
func _test_vote_commands(module: Object) -> void:
	# dot-vote's commands, which this game never installed: its own `rtv`, `nominate`,
	# `nextmap` and `timeleft` stood in for four of them and the operator's four did not
	# exist.
	var absent := PackedStringArray()
	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if server.console.find_command(name) == null:
			absent.append(name)
	_check(absent.is_empty(), "dot-vote's commands are on the console", ", ".join(absent))

	# One rock-the-vote. The console `rtv` went to the map session's time limit and `!rtv`
	# in chat to this director — two votes under one name. The director's refusal names
	# its delay; the map session's tally answers "N of M", so the reply says which one ran.
	var session := DotClientSession.new()
	session.peer_id = 4343
	session.userid = 43
	session.display_name = "Rocker"
	var _adopted := server.adopt_session(session)
	var replies: Array[String] = []
	var ctx := session.make_context(
		"rtv", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(line: String) -> void: replies.append(line)
	)
	server.console.execute("rtv", ctx)
	_check(
		replies.size() == 1 and replies[0].contains("rock the vote in"),
		"`!rtv` is the ballot's rock-the-vote, with the ballot's own delay (%s)" % str(replies)
	)
	replies.clear()
	server.console.execute("g2g_rtv", ctx)
	_check(
		replies.size() == 1 and replies[0].contains("rock the vote in"),
		"and so is `g2g_rtv` (%s)" % str(replies)
	)
	var _released := server.release_session(session.peer_id)

	var bridge: Object = module.get("bridge") if module != null else null
	_check(
		bridge != null and (bridge.get("rtv_fn") as Callable).is_valid(),
		"and a client's RTV request goes to the ballot too, not to the map session"
	)
	_check(
		not game.rotation_ends_maps,
		"and the map session's own clock no longer ends a map the vote may have extended"
	)


## `g2g_status`'s "time left" is the vote's clock, and an extend moves it.
##
## [b]It read the map session's clock after the vote had taken the map's end over[/b], so
## an operator asking how long was left was shown a limit an extend had already moved —
## the same bug the HUD had, one screen over. The check goes through the console, which
## is how an operator reads it, and asserts the session's clock did NOT move while the
## line did: the line moving with the session held still is the line reading the vote.
## Who may change the map from M, on this server's own sessions (2026-10-14: a guest on a
## public server pressed M and changed the map). The sessions stand in for what the listener
## makes for a browser: guests, no permissions, not the host's own player (`local` off).
func _test_map_menu_permissions() -> void:
	_section("M: a guest votes, staff and a lone player change")
	var module := server.modules.get_module("g2gfast")
	var vote: G2GVote = module.get("vote") if module != null else null
	var menu: Object = vote.commands.get("map_menu") if vote != null and vote.commands != null else null
	if menu == null:
		_check(false, "the map menu is installed")
		_done()
		return
	_check(server.playing_sessions().is_empty(), "nobody else is playing as the section starts",
		str(server.playing_sessions().size()))
	var start_map: StringName = game.maps.current.id
	# Each choice below is made past the start-of-map delay, so a rock-the-vote is counted
	# rather than refused for time.
	var guests: Array[DotClientSession] = []
	for i in 2:
		var guest := DotClientSession.new()
		guest.peer_id = 5100 + i
		guest.userid = 510 + i
		guest.display_name = "Guest-%d" % i
		var who := DotGuestIdentity.new()
		who.uid = "guest:map-menu-%d" % i
		guest.identity = who
		var _adopted := server.adopt_session(guest)
		guest.local = false
		guest.state = DotClientSession.State.SPAWNED if i == 0 else DotClientSession.State.CONNECTING
		guests.append(guest)
	var first := guests[0]
	var second := guests[1]

	var choose := func(session: DotClientSession, permissions: PackedStringArray = PackedStringArray()) -> Dictionary:
		var ctx := session.make_context("mapmenu", PackedStringArray(), DotCmdContext.Source.CHAT)
		ctx.permissions = permissions
		var target := &""
		for row: Dictionary in menu.call("rows"):
			if not bool(row.get("current", false)):
				target = StringName(str(row["id"]))
				break
		var before: StringName = game.maps.current.id
		vote.director.clock.elapsed = maxf(vote.director.clock.elapsed, vote.director.rules.rtv_delay_sec + 1.0)
		var result: Dictionary = await menu.call("choose", ctx, target)
		return {"result": result, "changed": game.maps.current.id != before, "target": target}

	# Alone, with the owner's sv_map_menu_alone off: a vote of one is no vote.
	_run_command("sv_map_menu_alone 0")
	var alone_off: Dictionary = await choose.call(first)
	_check(not alone_off["changed"] and str(alone_off["result"].get("text", "")).contains("needs a vote of the players here")
		and not vote.director.is_voting(),
		"one guest, sv_map_menu_alone 0: their M choice does not change the map, and says it needs a vote",
		str(alone_off["result"].get("text", "")))

	# Alone with it on (the default): nobody to ask, nobody harmed.
	_run_command("sv_map_menu_alone 1")
	var alone_on: Dictionary = await choose.call(first)
	_check(alone_on["changed"] and str(alone_on["result"].get("how", "")) == "changed",
		"one guest, sv_map_menu_alone 1: their M choice changes the map", str(alone_on["result"].get("text", "")))

	# A second human: a vote again, whatever sv_map_menu_alone says.
	second.state = DotClientSession.State.SPAWNED
	var two: Dictionary = await choose.call(first)
	_check(not two["changed"] and str(two["result"].get("how", "")) == "voted" and not vote.director.is_voting(),
		"two guests, sv_map_menu_alone 1: the M choice is a nomination and a rock, not a change",
		str(two["result"].get("text", "")))
	var _withdrawn := vote.director.clock.unrock(&"u510")
	_run_command("sv_map_menu_alone 0")
	var two_off: Dictionary = await choose.call(first)
	_check(not two_off["changed"], "two guests, sv_map_menu_alone 0: no change either", str(two_off["result"].get("text", "")))
	_withdrawn = vote.director.clock.unrock(&"u510")

	# The older client's own map list asks the same question through the bridge.
	var bridge: Object = module.get("bridge")
	var may: Callable = bridge.get("may_change_map_fn") if bridge != null else Callable()
	_check(may.is_valid() and not bool(may.call(first.userid)), "the older client's map list refuses the same guest")

	# Staff change it with others here, by the owner's flag.
	var staff: Dictionary = await choose.call(second, PackedStringArray(["generic"]))
	_check(staff["changed"] and str(staff["result"].get("how", "")) == "changed",
		"staff (generic) change the map from M with two players here", str(staff["result"].get("text", "")))

	# Fail closed: an emptied flag is staff, not anybody.
	_run_command("sv_map_menu_flag \"\"")
	var emptied: Dictionary = await choose.call(first)
	_check(not emptied["changed"] and str(menu.call("required_flag")) == "generic",
		"an emptied sv_map_menu_flag is staff only, not anybody", str(emptied["result"].get("text", "")))
	_withdrawn = vote.director.clock.unrock(&"u510")

	# The host's own player (a session with no transport) owns the server.
	first.local = true
	var host: Dictionary = await choose.call(first)
	_check(host["changed"], "the host's own player changes the map with others here", str(host["result"].get("text", "")))

	_run_command("sv_map_menu_flag generic")
	_run_command("sv_map_menu_alone 1")
	for guest in guests:
		var _released := server.release_session(guest.peer_id)
	# Back on the map the sections after this one stand on: the rows this picked from depend on
	# which map packs are linked, and a course with its start somewhere else fails them.
	if game.maps.current.id != start_map:
		var _back: DotResult = await game.change_map(start_map)
	_done()


func _test_status_clock(vote: G2GVote) -> void:
	var rules := vote.director.rules
	var clock := vote.director.clock
	var was_duration := rules.duration_sec
	var was_trigger := rules.trigger
	var was_max_extends := rules.max_extends

	# A known clock, so the numbers mean something whatever the config shipped.
	rules.duration_sec = 600.0
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.max_extends = 0
	clock.start()

	var session_before := game.maps.time_limit.formatted_remaining()
	var before := _status_seconds(_run_command("g2g_status"))
	_check(
		absf(before - clock.remaining) <= 1.0,
		"`g2g_status` reports the vote's time left (%d s, the vote's is %.0f s)" % [
			before, clock.remaining
		]
	)

	_check(clock.extend(), "the vote extends the map")
	var after := _status_seconds(_run_command("g2g_status"))
	_check(
		after - before == int(rules.extend_seconds)
			and game.maps.time_limit.formatted_remaining() == session_before,
		"and the status line moves by the extension while the map session's clock does not "
			+ "(%d s -> %d s, extended by %.0f)" % [before, after, rules.extend_seconds],
		"the line is reading the map session's clock, which nothing extends"
	)

	# `trigger: rtv_only` with no limit, which is what the deployment runs.
	rules.duration_sec = 0.0
	rules.trigger = DotVoteRules.Trigger.RTV_ONLY
	clock.start()
	var status := _run_command("g2g_status")
	_check(
		_said(status, "time left    no limit"),
		"a vote with no clock is reported as no limit, not as the session's (%s)" % _status_line(status)
	)

	rules.duration_sec = was_duration
	rules.trigger = was_trigger
	rules.max_extends = was_max_extends
	clock.start()


func _status_line(lines: PackedStringArray) -> String:
	for line in lines:
		if line.begins_with("time left"):
			return line
	return ""


## Seconds on `g2g_status`'s time-left line, or -1 when it is not an m:ss.
func _status_seconds(lines: PackedStringArray) -> int:
	var parts := _status_line(lines).trim_prefix("time left").strip_edges().split(" ")[0].split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	return int(parts[0]) * 60 + int(parts[1])


## The three modes, and the cvars that flip them.
##
## [b]Each layer is built whether or not it is enabled, and the cvar flips it.[/b] A
## layer constructed on the cvar instead would be constructed under live players,
## which is where the interesting failures are — and it would have to be torn down
## again on the way back.
func _test_modes() -> void:
	_section("deathmatch, hunters and blocks")

	_check(game.combat != null, "the deathmatch layer is built")
	_check(game.hunters != null, "the hunters are built")
	_check(game.props != null, "the blocks are built")

	for name in ["sv_deathmatch", "sv_hunters", "sv_props"]:
		_check(server.console.find_cvar(name) != null, "%s is a cvar" % name)

	if game.combat != null:
		_check(game.combat.enabled, "deathmatch starts on, because the config said so")

		_run_command("sv_deathmatch 0")
		_check(not game.combat.enabled, "and sv_deathmatch 0 turns it off live")

		_run_command("sv_deathmatch 1")
		_check(game.combat.enabled, "and back on again")

		# The match must not carry a time limit of its own. The MAP's clock ends the
		# map; a second clock underneath it that ends the match is two authorities
		# over one question, and dot-vote's director already owns the first.
		_check(
			game.combat.match_node.rules.time_limit_sec == 0.0,
			"the match has no clock of its own"
		)

		# A run and a fight at the same time. The layer adds hitboxes, health and an
		# arsenal and takes nothing away — a player who never presses fire plays
		# exactly the game they played before.
		var runner := game.add_player(&"u4242", "Runner")
		_check(runner != null, "a player joins")

		if runner != null:
			var entity := _modes_ids(runner)
			_modes_hit_and_fall(runner, entity)
			_modes_killview(entity)
			_modes_fire()
			_modes_hunter_kill(runner)
			game.remove_player(&"u4242")

	DedicatedWorld.new(self, game).run()
	_done()


## The id round trip and the combat handle of one joined player; returns the entity id.
func _modes_ids(runner: G2GPlayer) -> int:
	_check(
		game.combat.health_of(&"u4242") != null,
		"and is shootable in deathmatch"
	)
	_check(
		runner.timer != null,
		"and still has a timer, because the run is the point"
	)

	# The id round trip, in one assertion, because the two ends of one
	# serialisation are exactly as capable of never meeting as the two ends
	# of a wire -- and these two used to be a formula and its inverse.
	var entity := game.combat.entity_for(&"u4242")

	_check(entity != 0, "and an entity id from the table (%d)" % entity)
	_check(
		DotEntity.is_kind(entity, DotEntity.KIND_PLAYER),
		"which says it names a player, without a range check",
		DotEntity.describe_id(entity)
	)
	_check(
		game.combat.player_id_for(entity) == &"u4242",
		"and turns back into the player it came from"
	)
	# The conflation the table removed: the account number and the combat
	# handle used to be the same integer, so a loadout's filename and a
	# session lookup were quietly riding on a runtime id.
	_check(
		G2GCombat.userid_of(&"u4242") == 4242,
		"the userid is still parsed out of the name, unchanged"
	)
	_check(
		entity != 4242,
		"and is no longer what the entity id happens to be"
	)
	return entity


## A hit on yourself and on somebody else, then a kill: how the body falls and the return.
func _modes_hit_and_fall(runner: G2GPlayer, entity: int) -> void:
	# The shooter's hit feedback is what the authority applied, never a refusal.
	# A second player, hit by the first: a refused hit (spawn protection) or one
	# on yourself is no hit, and an applied one says who fired, at whom, how much.
	var target := game.add_player(&"u4343", "Target")
	var heard: Array = []
	var on_hit := func(by: StringName, victim: int, amount: float, _point: Vector3, _killed: bool, _head: bool) -> void:
		heard.append([by, victim, amount])
	game.combat.hit_landed.connect(on_hit)
	var bullet := game.combat.manager.damage_type(G2GArsenal.DAMAGE_BULLET)
	var victim_entity := game.combat.entity_for(&"u4343")
	game.combat.manager.apply_damage(DotDamage.make(entity, entity, 10.0, bullet))
	var self_heard := heard.size()
	var hit := DotDamage.make(entity, victim_entity, 25.0, bullet)
	game.combat.manager.apply_damage(hit)
	game.combat.hit_landed.disconnect(on_hit)
	_check(self_heard == 0, "a hit on yourself is no hit marker", str(heard))
	_check(
		not hit.refused and heard.size() == 1 and heard[0][0] == &"u4242"
			and heard[0][1] == victim_entity and absf(float(heard[0][2]) - hit.health_lost) < 0.01,
		"and an applied hit on somebody else says who fired, at whom and how much",
		"refused=%s heard=%s" % [hit.refused, str(heard)]
	)

	# --- How a dead body falls: picked here, from the server's own weights ---
	#
	# Armed by turning the cvar binding off in the module (the replicated check fails
	# and the pick stays a draw over the stock weights) and by deciding nothing in
	# `_on_entity_killed` (the death is null).
	var weights := server.console.find_cvar("sv_ragdoll_reactions")
	_check(weights != null and weights.has_flag(DotConVar.FLAG_REPLICATED)
			and server.console.find_cvar("sv_ragdoll") != null,
		"the sv_ragdoll* set is bound, replicated, because the clients draw the bodies")
	var _only := _run_command("sv_ragdoll_reactions limp=0,crumple=0,face_plant=1")
	var fatal := DotDamage.make(entity, victim_entity, 500.0, bullet)
	fatal.tick = game.current_tick()
	game.combat.manager.apply_damage(fatal)
	var fallen: G2GPlayer = game.players.get(&"u4343")
	var away := Vector3.ZERO
	if fallen != null:
		away = fallen.controller.state.position - runner.controller.state.position
		away.y = 0.0
	_check(fallen != null and fallen.death != null
			and fallen.death.reaction == DotPlayerDeathReactions.FACE_PLANT,
		"a kill picks the body's fall on the server, from sv_ragdoll_reactions",
		str(fallen.death.describe()) if fallen != null and fallen.death != null else "no death")
	_check(fallen != null and fallen.death != null
			and (away.length() < 0.01 or fallen.death.direction.dot(away.normalized()) > 0.9),
		"pushed away from the shooter")
	var _stock := _run_command("sv_ragdoll_reactions limp=4,headshot_launch=6,power_launch=8,face_plant=1.5,crumple=2.5")
	var back: Array[StringName] = []
	var on_back := func(id: StringName) -> void: back.append(id)
	game.combat.player_respawned.connect(on_back)
	for _respawn in range(game.tick_rate + game.tick_rate / 4):
		game.tick_once(game.current_tick() + 1)
	game.combat.player_respawned.disconnect(on_back)
	_check(back.has(&"u4343"), "and the dead player's return is announced, for the clients to draw them again", str(back))

	if target != null:
		game.remove_player(&"u4343")


## The server kill view clip names its killer by key.
func _modes_killview(entity: int) -> void:
	var bullet := game.combat.manager.damage_type(G2GArsenal.DAMAGE_BULLET)
	# The server's own kill view clip names its killer by key, for a client that numbers no entity.
	var kv_bridge: Object = server.modules.get_module("g2gfast").get("bridge")
	var kv: Object = kv_bridge.get("killview") if kv_bridge != null else null
	var prey := game.add_player(&"u4444", "Prey")
	game.killview_rules.enabled = true
	var kv_base: int = game.current_tick()
	var kv_clips: Array = []
	for kv_tick in range(kv_base - 60, kv_base + 60):
		if kv_tick == kv_base:
			game.combat.manager.apply_damage(DotDamage.make(entity, game.combat.entity_for(&"u4444"), 500.0, bullet))
		if kv != null:
			kv_clips.append_array(kv.tick(kv_tick))
	var kv_info := {}
	for clip: Dictionary in kv_clips:
		var kv_read := DotKillViewClip.unpack(clip["body"])
		if bool(kv_read["ok"]):
			kv_info = kv_read["info"]
	_check(prey != null and kv_clips.size() == 1 and kv_info.get("killer_key", "") == "u4242",
		"a real kill's clip carries the killer's key, emitted by the server", str(kv_info))
	game.killview_rules.enabled = false
	game.remove_player(&"u4444")


## The ghost is unarmed, and holding the trigger fires at the weapon's rate.
func _modes_fire() -> void:
	# The ghost is deliberately not armed: it is a replay, it cannot be hurt,
	# and registering it would put a name on the scoreboard that never dies
	# and never leaves.
	_check(
		game.combat.health_of(G2GGame.GHOST_ID) == null,
		"the record ghost is not on the scoreboard"
	)

	# The trigger is a bit on `G2GNetCommand`, replayed with that tick's movement, not a request.
	var arsenal_before := game.combat._kit[&"u4242"]["arsenal"] as DotWeaponArsenal
	_check(
		arsenal_before.slots().size() >= 1,
		"an armed player has something to shoot with",
		"%d slots" % arsenal_before.slots().size()
	)

	# A hand-out into a disabled arsenal (a freeze) still holds the sidearm, as a bot never presses a slot key.
	arsenal_before.disabled = true
	game.combat._give_default(arsenal_before)
	_check(arsenal_before.current_slot() == 2, "a default kit given while disabled holds the sidearm, not the knife", str(arsenal_before.current_slot()))
	arsenal_before.disabled = false

	# Release the trigger until the semi-automatic deagle has deployed: a press during
	# a switch must not fire.
	# Once a tick: a command is consumed by the tick that reads it.
	var idle := DotWeaponCommand.new()

	# `tick_once`, not `combat.tick`: dot-weapon durations are measured in ticks.
	for _deploy in range(game.tick_rate):
		game.combat.set_fire_command(&"u4242", idle)
		game.tick_once(game.current_tick() + 1)

	var fire := DotWeaponCommand.new()
	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

	# An Array: a lambda captures locals by value.
	var shots: Array[DotShot] = []
	game.combat.manager.shot_resolved.connect(
		func(shot: DotShot) -> void: shots.append(shot)
	)

	# Enough ticks for the deagle's 160 rpm to come round. A weapon that fired
	# on the first tick would be a weapon with no rate of fire.
	for _step in range(game.tick_rate):
		game.combat.set_fire_command(&"u4242", fire)
		game.tick_once(game.current_tick() + 1)

	_check(
		shots.size() > 0,
		"and holding the trigger fires it",
		"%d shots" % shots.size()
	)

	# The rate of fire is real: 160 rpm over one second is under three shots,
	# and a trigger read as "fire every tick" would be a hundred.
	_check(
		shots.size() < 10,
		"at its rate of fire rather than once a tick",
		"%d shots in a second" % shots.size()
	)
	_modes_fire_starved(fire)


## A tick whose input never arrived is not the last trigger again.
func _modes_fire_starved(fire: DotWeaponCommand) -> void:
	# dot-net skips `_net_apply_input` for a starved tick, so a command left on
	# the player would be replayed for as long as packets are lost — the held
	# trigger `G2GPlayerNet.last_attack` says does not survive a hiccup.
	game.combat.set_fire_command(&"u4242", fire)
	game.tick_once(game.current_tick() + 1)
	game.tick_once(game.current_tick() + 1)
	var shooter: G2GPlayer = game.players.get(&"u4242")
	_check(
		shooter != null and not shooter.has_meta("g2g_fire"),
		"and a trigger is read once, so a lost packet is not a held trigger"
	)


## A hunter's kill is a death like any other.
func _modes_hunter_kill(runner: G2GPlayer) -> void:
	# A hunter's kill is world damage through the same combat layer, so it is a death
	# like any other: the body falls away from the hunter that swiped.
	if game.hunters != null:
		var at := runner.controller.state.position + Vector3(3.0, 0.0, 0.0)
		var hunter := game.hunters.spawn_one(&"g2g_stalker", at)
		if hunter != null:
			game.hunters.hunter_attack(hunter, &"u4242", 1000.0)
			game.hunters.spawner.remove(hunter.instance_id, DotNpcSpawner.REASON_ADMIN)
		_check(hunter != null and runner.death != null and runner.death.direction.x < -0.9,
			"a hunter's kill falls too, away from the hunter",
			str(runner.death.describe()) if runner.death != null else "no death")


## dot-browser asking a real [DotServer] — which nothing in this family had done.
##
## [b]This is the seam the family's own notes name.[/b] dot-server has answered A2S and
## its own richer protocol since it was written; dot-browser's suite queries a DQP
## server over a real loopback socket. Neither had ever met the other.
##
## What this game contributes that a bare `DotGameDescriptor` cannot is `G2GQuery`'s
## section: the map, the tick rate, the styles, the world record, and — since the
## modes were added — whether deathmatch and the hunters are on. A player filtering a
## list for "surf DM" is filtering for exactly that.
