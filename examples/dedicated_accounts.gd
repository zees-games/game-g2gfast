extends RefCounted

const G2GGame := preload("../game/g2g_game.gd")
const G2GPlayer := preload("../game/g2g_player.gd")

## The account-keyed records section of `dedicated.gd`, run against the suite's own server and game.

var s: DotGameCheckSuite
var server: DotServer
var game: G2GGame


func _init(suite: DotGameCheckSuite, srv: DotServer, g: G2GGame) -> void:
	s = suite
	server = srv
	game = g


static func finished_copy(run: DotTimerRun) -> DotTimerRun:
	var copy := DotTimerRun.make(run.track, run.style_id, 0.01)
	copy.begin(0.0)
	copy.tainted = run.tainted
	copy.used_checkpoints = run.used_checkpoints
	for _i in range(6000):
		copy.advance(1.0)
	copy.finish(0.0)
	return copy


## [b]A record belongs to the account, not to the connection.[/b] dot-server's userid is a
## server-local counter: the same account reconnecting is a new number, and a restarted
## server hands the old numbers to strangers. Records, boards and the Tab board's Best were
## keyed by `u<userid>`, so a returning runner was a second row with no Best, and a new
## player could inherit an old runner's time. Armed by making `_record_key_for` return
## `&""` (the key falls back to `u<userid>`): both halves fail.
func run() -> void:
	s._section("records follow the account, not the connection")

	var map_id: StringName = game.maps.current.id
	var store := game.timers.store

	# No socket stands behind these peers: swallow what the bridge would send them rather
	# than have the engine report an RPC to a peer that does not exist.
	var bridge: Object = server.modules.get_module("g2gfast").get("bridge")
	var link: Object = bridge.get("link")
	var kept_loopback: Callable = link.get("loopback")
	link.set("loopback", func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass)

	var join := func(peer: int, userid: int, uid: String, name: String) -> DotClientSession:
		var session := DotClientSession.new()
		session.peer_id = peer
		session.userid = userid
		session.display_name = name
		var who := DotGuestIdentity.new()
		who.uid = uid
		session.identity = who
		var _adopted := server.adopt_session(session)
		# What dot-server fires when a client finishes joining; the module seats the player.
		server.events.fire("client_spawn", {"userid": userid, "name": name})
		for _i in range(4):
			await s.get_tree().physics_frame
		return session

	var leave := func(session: DotClientSession) -> void:
		server.client_disconnected.emit(session, "test")
		var _released := server.release_session(session.peer_id)

	var settle := func() -> void:
		for _i in range(8):
			await s.get_tree().physics_frame

	# Alice connects, finishes a run, goes.
	var first: DotClientSession = await join.call(9201, 8801, "acct:alice", "Alice")
	var player: G2GPlayer = game.players.get(&"u8801")
	s._check(player != null, "an account connects as u<userid> in the match", str(game.players.keys()))
	if player == null:
		s._done()
		return
	s._check(game.record_key(&"u8801") == &"acct:alice", "and is filed under its account uid, not the userid")
	s._check(player.timer == game.timers.timer_for(&"acct:alice"), "the timer manager knows it by the account")

	var run := finished_copy(player.timer.run)
	for stage in range(1, game.timers.stage_count(run.track) + 1):
		run.splits[stage] = float(stage)
	var why: Array = []
	game.run_filed.connect(func(_id: StringName, _r: DotTimerRun, _rank: int, reason: String) -> void: why.append(reason))
	player.timer.run_finished.emit(run)
	await settle.call()
	var mine: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"acct:alice")
	s._check(mine.ok and mine.value is DotTimerRecord, "the finish is on the board under the account", str(why))
	var by_number: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"u8801")
	s._check(by_number.ok and by_number.value == null, "and nothing is filed under the userid")
	await game.refresh_standing(&"u8801")
	s._check(float(game.board_fields(&"u8801")["best"]) > 0.0, "the Tab board shows the Best")

	leave.call(first)
	await settle.call()
	s._check(not game.players.has(&"u8801"), "the player leaves")

	# Alice reconnects: a new userid, the same account.
	var again: DotClientSession = await join.call(9202, 8802, "acct:alice", "Alice")
	await game.refresh_standing(&"u8802")
	s._check(game.players.has(&"u8802") and game.record_key(&"u8802") == &"acct:alice",
		"the reconnect is a new userid on the same account")
	s._check(float(game.board_fields(&"u8802")["best"]) > 0.0 and int(game.board_fields(&"u8802")["rank"]) == 1,
		"and the Tab board shows the Best and rank it had, not a dash", str(game.board_fields(&"u8802")))
	var rows: DotResult = await store.top(map_id, DotTimerTrack.MAIN, &"normal", 20)
	s._check(rows.ok and (rows.value as Array).size() == 1, "the records board has one row for the account",
		str((rows.value as Array).size()) if rows.ok else str(rows.error))
	var fastest: DotResult = await game.boards.page_async(&"fastest", {
		"map": String(map_id), "track": str(DotTimerTrack.MAIN), "style": "normal",
	})
	var entries: Array = fastest.value if fastest.ok and fastest.value is Array else []
	s._check(fastest.ok and entries.size() == 1 and (entries[0] as DotLeaderboardEntry).player_id == &"acct:alice",
		"and so does the leaderboard", str(fastest.value) if fastest.ok else str(fastest.error))

	# The server restarts: userids start again, and the number Alice had goes to a stranger.
	leave.call(again)
	await settle.call()
	var stranger: DotClientSession = await join.call(9203, 8801, "acct:bob", "Bob")
	await game.refresh_standing(&"u8801")
	var none: DotResult = await store.best_for(map_id, DotTimerTrack.MAIN, &"normal", &"acct:bob")
	s._check(none.ok and none.value == null, "a stranger who draws an earlier userid has no record")
	s._check(float(game.board_fields(&"u8801")["best"]) < 0.0 and int(game.board_fields(&"u8801")["rank"]) == 0,
		"and the Tab board gives them no Best and no rank", str(game.board_fields(&"u8801")))
	leave.call(stranger)
	await settle.call()

	# Rows written before the change are retired, not ranked and not deleted.
	var old := DotTimerRecord.new()
	old.map_id = map_id
	old.track = DotTimerTrack.MAIN
	old.style_id = &"normal"
	old.player_id = &"u12"
	old.player_name = "Old"
	old.time = 31.0
	var _put: DotResult = await store.put(old)
	s._check(G2GGame.is_legacy_key(&"u12") and not G2GGame.is_legacy_key(&"acct:alice") and not G2GGame.is_legacy_key(&"local")
		and not G2GGame.is_legacy_key(&"user"), "a session-number key is recognised by its shape and an account's is not")
	var moved := await game.retire_legacy_records()
	var after: DotResult = await store.top(map_id, DotTimerTrack.MAIN, &"normal", 20)
	var left_ids: Array = []
	for row in (after.value as Array):
		left_ids.append((row as DotTimerRecord).player_id)
	s._check(moved == 1 and not left_ids.has(&"u12") and left_ids.has(&"acct:alice"),
		"a u<N> row leaves the board and the account's stays", str(left_ids))
	var base := game.config.records_directory.strip_edges()
	var archive := (base if base != "" else "user://").path_join("legacy_records.jsonl")
	s._check(FileAccess.file_exists(archive) and FileAccess.get_file_as_string(archive).contains("\"u12\""),
		"and is kept in legacy_records.jsonl, not deleted", archive)
	s._check(await game.retire_legacy_records() == 0, "and retiring is idempotent")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(archive))
	link.set("loopback", kept_loopback)
	s._done()
