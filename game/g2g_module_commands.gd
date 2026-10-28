extends DotModule

const G2GPaths := preload("g2g_paths.gd")

const G2GCamera := preload("g2g_camera.gd")
const G2GCombat := preload("g2g_combat.gd")
const G2GConfig := preload("g2g_config.gd")
const G2GGame := preload("g2g_game.gd")
const G2GMapConfig := preload("g2g_map_config.gd")
const G2GHunters := preload("g2g_hunters.gd")
const G2GIdentity := preload("g2g_identity.gd")
const G2GModTools := preload("g2g_mod_tools.gd")
const G2GNetBridge := preload("net/g2g_net_bridge.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GProps := preload("g2g_props.gd")
const G2GQuery := preload("g2g_query.gd")
const G2GServices := preload("g2g_services.gd")
const G2GStats := preload("g2g_stats.gd")
const G2GUnits := preload("g2g_units.gd")
const G2GVote := preload("g2g_vote.gd")

## Binds a [G2GGame] to a [DotServer]: the movement cvars, and the commands.
## The cvars keep the names and units operators know ([code]sv_airaccelerate[/code], [code]sv_gravity[/code]...).
## Each writes the [G2GConfig] and rebuilds every player's movement, abandoning their runs; [code]sv_tickrate[/code] is dot-server's own.

const CHANNEL := "g2g.module"

## The drawn map ballot's notice topic. The client shell draws one menu per topic, and a
## server running several games sends its own `game_ballot` beside this one.
const MAP_BALLOT_TOPIC := &"map_ballot"

var game: G2GGame = null
## Per-map movement settings, built on the first map.
var map_config: DotGameMapConfig = null
var net: DotNetManager = null
var bridge: G2GNetBridge = null

## Chat, voice and moderation. See [G2GServices].
var services: G2GServices = null

## Where the services keep punishments; empty is dot-moderation's default `user://moderation.json`.
## Static, because dot-server constructs the module inside `load_module`, so no host can set a field first.
## `examples/dedicated.tscn` points it at a directory of its own.
static var punishments_file: String = ""

## The live tools' commands. See [method _build_services].
var mod_commands: DotModToolCommands = null

## Content, profiles, avatars and admission. See [G2GIdentity].
var identity: G2GIdentity = null

## The ballot. What replaces the rock-the-vote this game shipped with.
var vote: G2GVote = null
var _painters: Dictionary = {}
var _tick: int = 0

## How many bots: dot-server's `bot_quota`, `bot_quota_mode`, `bot_quota_empty`. See
## [method _keep_bots].
var _quota: DotBotQuota = null
var _joined: Dictionary = {}

const SNAPSHOT_RATE := 32

## Config fields that already have a hand-written cvar above (field -> cvar). The binder leaves
## these cvars alone; a workbench or file edit is pushed through the cvar so its handler runs.
const HAND_CVARS := {
	"auto_bhop": "sv_autobunnyhopping", "enable_bunnyhopping": "sv_enablebunnyhopping",
	"air_accelerate": "sv_airaccelerate", "accelerate": "sv_accelerate", "gravity": "sv_gravity",
	"friction": "sv_friction", "stop_speed": "sv_stopspeed", "max_speed": "sv_maxspeed",
	"max_velocity": "sv_maxvelocity", "air_wish_cap": "sv_airwishcap", "step_size": "sv_stepsize",
	"edge_friction": "sv_edgefriction", "jump_buffer": "sv_jumpbuffer", "crest_launch": "sv_crestlaunch",
	"show_replay_bot": "sv_replay_bot", "allow_thirdperson": "sv_allow_thirdperson",
	"flashlight": "sv_flashlight", "stagger_snapshots": "sv_stagger_snapshots",
	"spectator_list": "sv_spec_list", "map_content_owner": "sv_map_content_owner",
	"content_maps": "sv_content_maps", "map_rotation_file": "sv_map_rotation_file",
	"map_sync_seconds": "sv_map_sync_timeout", "deathmatch": "sv_deathmatch",
	"killcam_seconds": "mp_killcam_time", "hunters": "sv_hunters", "placeable_props": "sv_props",
}

## dot-team's block rules (`mp_teamblock`, `!block`, `!noblock`); null without dot-team.
var noblock: DotGameNoblock = null
## dot-workbench: the F9 panel in debug builds, the loopback page when `workbench.enabled`.
var workbench: DotGameWorkbench = null
## Carries the workbench's profile runtime (rows down) over this manager; null without a workbench.
var profile_link: DotNetProfileLink = null
## The noblock half and the workbench runtime, made before the netcode so the profile link can bind to it.
var _noblock_made: DotResult = null
var _wb_runtime: DotProfileRuntime = null


func _player_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


## The key this seat's records are filed under: the account's uid (a guest's is per device), never the
## session's userid, a server-local counter that restarts at 1. Empty without an identity, then the
## userid is the key, which [method G2GGame.is_legacy_key] reads as unranked.
func _record_key_for(session: DotClientSession) -> StringName:
	var uid := session.uid()
	if uid == "":
		log_warn("a session has no identity; its runs are not ranked", {"userid": session.userid})
		return &""
	return StringName(uid)


func _caller_id(ctx: DotCmdContext) -> StringName:
	return _player_id(ctx.session) if ctx.session != null else &""


func _caller(ctx: DotCmdContext) -> G2GPlayer:
	var found: Variant = game.players.get(_caller_id(ctx))
	return found if found is G2GPlayer else null


# Commands

func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(game.describe_lines())


func _cmd_restart(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can restart.")
		return
	game.spawn_player(id)
	ctx.reply("Back at the start.")


## `!s <n>` / `!stage <n>` to a stage's own spot, and `!rs` (or either with no number)
## back to the start of the stage the player is in. Either stops the run.
func _cmd_stage(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can go to a stage.")
		return
	var res: DotResult
	if ctx.args.is_empty():
		res = game.restart_stage(id)
	elif not ctx.args[0].is_valid_int():
		ctx.reply("Usage: !s <stage number>")
		return
	else:
		res = game.request_stage(id, ctx.args[0].to_int())
	if not res.ok:
		ctx.reply_error(res)
		return
	ctx.reply("Stage %d. The run is stopped." % int((res.value as DotTimerZone).number))


func _cmd_style(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Styles:"])
		for style in game.timers.styles_in_order():
			lines.append("  %-16s %-4s %s" % [String(style.id), style.short_name,
				"unranked" if not style.ranked else "x%.2f points" % style.points_multiplier])
		ctx.reply_lines(lines)
		return
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can switch style.")
		return
	if not game.set_player_style(id, StringName(ctx.args[0])):
		ctx.reply("No such style: %s" % ctx.args[0])
		return
	ctx.reply("Style: %s" % ctx.args[0])


func _cmd_track(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can switch track.")
		return
	var track := DotTimerTrack.parse(" ".join(Array(ctx.args)))
	if track < 0:
		ctx.reply("No such track: %s" % " ".join(Array(ctx.args)))
		return
	game.timers.set_player_track(game.record_key(id), track)
	game.spawn_player(id)
	ctx.reply("Track: %s" % DotTimerTrack.name_of(track))


func _cmd_top(ctx: DotCmdContext) -> void:
	if game.maps.current == null or game.timers.store == null:
		ctx.reply("No records here.")
		return
	var timer := game.timers.timer_for(game.record_key(_caller_id(ctx)))
	var track := timer.track if timer != null else DotTimerTrack.MAIN
	var style: StringName = timer.style.id if timer != null and timer.style != null else &"normal"
	var listed: DotResult = await game.timers.store.top(game.maps.current.id, track, style, 10)
	if not listed.ok:
		ctx.reply_error(listed)
		return
	var rows: Array = listed.value
	if rows.is_empty():
		ctx.reply("Nobody has finished %s on %s yet." % [String(game.maps.current.id), String(style)])
		return
	var lines := PackedStringArray()
	var rank := 1
	for i in range(rows.size()):
		var record: DotTimerRecord = rows[i]
		# Ties share a place, as the store ranks them.
		if i > 0 and record.time > (rows[i - 1] as DotTimerRecord).time:
			rank = i + 1
		lines.append("  %2d. %-20s %s%s" % [
			rank, record.player_name, record.formatted_time(),
			"" if i == 0 else "  +" + DotTimerRun.format_time(record.time - (rows[0] as DotTimerRecord).time),
		])
	ctx.reply_lines(lines)


# Records

## The board the caller is on: this map, their track and style.
func _board_of(ctx: DotCmdContext) -> Dictionary:
	var timer := game.timers.timer_for(game.record_key(_caller_id(ctx)))
	return {
		"map": game.maps.current.id if game.maps.current != null else &"",
		"track": timer.track if timer != null else DotTimerTrack.MAIN,
		"style": timer.run.style_id if timer != null else &"normal",
	}


func _no_records(ctx: DotCmdContext) -> bool:
	if game.maps.current == null or game.timers.store == null:
		ctx.reply("No records here.")
		return true
	return false


## A player on this server by part of their name, or by id. The caller when empty.
func _find_player(ctx: DotCmdContext, text: String) -> Dictionary:
	if text.strip_edges() == "":
		var me := _caller(ctx)
		return {"id": game.record_key(_caller_id(ctx)), "name": me.display_name if me != null else String(_caller_id(ctx))}
	var wanted := text.strip_edges().to_lower()
	for id in game.players:
		var p: G2GPlayer = game.players[id]
		if p.display_name.to_lower().contains(wanted) or String(id) == text.strip_edges():
			return {"id": game.record_key(id), "name": p.display_name}
	return {"id": StringName(text.strip_edges()), "name": text.strip_edges()}


func _cmd_pb(ctx: DotCmdContext) -> void:
	if _no_records(ctx):
		return
	var who := _find_player(ctx, " ".join(Array(ctx.args)))
	var board := _board_of(ctx)
	var best: DotResult = await game.timers.store.best_for(board["map"], board["track"], board["style"], who["id"])
	if not best.ok:
		ctx.reply_error(best)
		return
	if best.value == null:
		ctx.reply("%s has no time on %s (%s)." % [who["name"], String(board["map"]), DotTimerTrack.name_of(board["track"])])
		return
	var record: DotTimerRecord = best.value
	var rank: DotResult = await game.timers.store.rank_of(board["map"], board["track"], board["style"], who["id"])
	var total: DotResult = await game.timers.store.count_on(board["map"], board["track"], board["style"])
	ctx.reply("%s: %s — rank %d / %d, %d finishes, %.1f points" % [
		who["name"], record.formatted_time(), int(rank.value), int(total.value), record.completions, record.points,
	])


func _cmd_rank(ctx: DotCmdContext) -> void:
	if game.timers.store == null:
		ctx.reply("No records here.")
		return
	var who := _find_player(ctx, " ".join(Array(ctx.args)))
	var standing: DotResult = await game.timers.store.player_rank(who["id"])
	if not standing.ok:
		ctx.reply_error(standing)
		return
	var info: Dictionary = standing.value
	if int(info["rank"]) <= 0:
		ctx.reply("%s is not ranked yet: finish a map to be." % who["name"])
		return
	var title: Dictionary = await game.timers.title_for(who["id"])
	ctx.reply("%s: rank %d / %d with %.1f points%s" % [
		who["name"], int(info["rank"]), int(info["total"]), float(info["points"]),
		(" — " + str(title["title"])) if title.has("title") else "",
	])


func _cmd_players(ctx: DotCmdContext) -> void:
	var page := maxi(ctx.args[0].to_int(), 1) if not ctx.args.is_empty() and ctx.args[0].is_valid_int() else 1
	var listed: DotResult = await game.timers.top_players(10, (page - 1) * 10)
	if not listed.ok:
		ctx.reply_error(listed)
		return
	var rows: Array = listed.value
	if rows.is_empty():
		ctx.reply("Nobody is ranked yet." if page == 1 else "No page %d." % page)
		return
	var lines := PackedStringArray()
	for row in rows:
		lines.append("  %3d. %-20s %8.1f  %s" % [int(row["rank"]), str(row["name"]), float(row["points"]), str((row["title"] as Dictionary).get("title", ""))])
	ctx.reply_lines(lines)


func _cmd_recent(ctx: DotCmdContext) -> void:
	var listed: DotResult = await game.timers.recent_records(10)
	if not listed.ok:
		ctx.reply_error(listed)
		return
	var rows: Array = listed.value
	if rows.is_empty():
		ctx.reply("No records yet.")
		return
	var lines := PackedStringArray()
	for entry in rows:
		var r: DotTimerRecord = entry["record"]
		var before := float(entry["previous_record_time"])
		lines.append("  %-18s %-20s %s%s  %s" % [
			String(r.map_id), r.player_name, r.formatted_time(),
			("  (-%s)" % DotTimerRun.format_time(before - r.time)) if before > 0.0 and before > r.time else "",
			"%s%s" % [DotTimerTrack.short_name_of(r.track), "" if r.style_id == &"normal" else " " + String(r.style_id)],
		])
	ctx.reply_lines(lines)


func _cmd_profile(ctx: DotCmdContext) -> void:
	var who := _find_player(ctx, " ".join(Array(ctx.args)))
	var profile: DotResult = await game.timers.profile(who["id"])
	if not profile.ok:
		ctx.reply_error(profile)
		return
	var p: Dictionary = profile.value
	var info: Variant = p["info"]
	var hours := float((info as Dictionary).get("playtime", 0.0)) / 3600.0 if info is Dictionary else 0.0
	ctx.reply_lines(PackedStringArray([
		"%s — %s" % [who["name"], str((p["title"] as Dictionary).get("title", "Unranked"))],
		"  rank       %s" % ("%d / %d" % [int(p["rank"]), int(p["ranked_players"])] if int(p["rank"]) > 0 else "-"),
		"  points     %.1f" % float(p["points"]),
		"  maps       %d / %d finished, %d bonuses" % [int(p["maps_done"]), int(p["maps_total"]), int(p["bonuses_done"])],
		"  records    %d held" % int(p["record_holds"]),
		"  played     %.1f h" % hours,
	]))


func _cmd_maps_done(ctx: DotCmdContext) -> void:
	var board := _board_of(ctx)
	var done: DotResult = await game.timers.maps_done(_caller_id(ctx), board["style"])
	if not done.ok:
		ctx.reply_error(done)
		return
	var rows: Array = done.value
	if rows.is_empty():
		ctx.reply("You have not finished any map on %s yet." % String(board["style"]))
		return
	var lines := PackedStringArray(["Finished on %s (%d):" % [String(board["style"]), rows.size()]])
	for record in rows:
		lines.append("  %-24s %s" % [String((record as DotTimerRecord).map_id), (record as DotTimerRecord).formatted_time()])
	ctx.reply_lines(lines)


func _cmd_maps_left(ctx: DotCmdContext) -> void:
	var board := _board_of(ctx)
	var left: DotResult = await game.timers.maps_left(_caller_id(ctx), board["style"])
	if not left.ok:
		ctx.reply_error(left)
		return
	var rows: Array = left.value
	if rows.is_empty():
		ctx.reply("Nothing left on %s. Every map this server knows is done." % String(board["style"]))
		return
	var lines := PackedStringArray(["Not yet finished on %s (%d):" % [String(board["style"]), rows.size()]])
	for info in rows:
		lines.append("  %-24s tier %d" % [str(info["map"]), int(info.get("tier", 1))])
	ctx.reply_lines(lines)


func _cmd_sections(ctx: DotCmdContext) -> void:
	if _no_records(ctx):
		return
	var board := _board_of(ctx)
	var listed: DotResult = await game.timers.section_records(board["track"], board["style"])
	if not listed.ok:
		ctx.reply_error(listed)
		return
	var rows: Array = listed.value
	if rows.is_empty():
		ctx.reply("%s has no stages on this track." % String(board["map"]))
		return
	var lines := PackedStringArray()
	for i in range(rows.size()):
		var r: Variant = rows[i]
		lines.append("  stage %d  %s" % [i + 1, ("%s  %s" % [(r as DotTimerRecord).formatted_time(), (r as DotTimerRecord).player_name]) if r is DotTimerRecord else "-"])
	ctx.reply_lines(lines)


func _cmd_progress(ctx: DotCmdContext) -> void:
	if _no_records(ctx):
		return
	var board := _board_of(ctx)
	var progress: DotResult = await game.timers.store.progress_for(_caller_id(ctx), board["map"], board["track"], board["style"])
	if not progress.ok or progress.value == null:
		ctx.reply("No attempts here yet.")
		return
	var p: Dictionary = progress.value
	ctx.reply("%d attempts, %d finishes, %s spent running%s" % [
		int(p["attempts"]), int(p["completions"]), DotTimerRun.format_time(float(p["time_spent"])),
		(", first finish after %s" % DotTimerRun.format_time(float(p["time_to_first"]))) if float(p["time_to_first"]) >= 0.0 else "",
	])


func _cmd_tier(ctx: DotCmdContext) -> void:
	if game.maps.current == null:
		ctx.reply("No map.")
		return
	ctx.reply("%s is tier %d." % [String(game.maps.current.id), game.timers.map_tier()])


func _cmd_set_tier(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty() or not ctx.args[0].is_valid_int():
		ctx.reply("Usage: g2g_settier <1-10>")
		return
	var res: DotResult = await game.timers.set_map_tier(ctx.args[0].to_int())
	if not res.ok:
		ctx.reply_error(res)
		return
	ctx.reply("Tier %d. %d records re-scored." % [ctx.args[0].to_int(), int(res.value)])


func _cmd_end(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can go to the end.")
		return
	var res := game.timers.request_end(game.record_key(id))
	if not res.ok:
		ctx.reply_error(res)
		return
	var zone: DotTimerZone = res.value
	(game.players[id] as G2GPlayer).teleport(zone.centre(), 0.0)
	ctx.reply("At the end. The run is stopped.")


func _cmd_pause(ctx: DotCmdContext) -> void:
	var res := game.timers.pause_player(game.record_key(_caller_id(ctx)))
	ctx.reply("Paused." if res.ok else res.error.message)


func _cmd_unpause(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	var res := game.timers.resume_player(game.record_key(id))
	if not res.ok:
		ctx.reply(res.error.message)
		return
	var player: G2GPlayer = game.players.get(id)
	if player != null:
		player.teleport((res.value as Dictionary)["position"], player.controller.state.yaw)
	ctx.reply("Resumed.")


func _cmd_restore(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	var res := game.timers.restore_player(game.record_key(id))
	if not res.ok:
		ctx.reply(res.error.message)
		return
	var player: G2GPlayer = game.players.get(id)
	if player != null:
		player.teleport((res.value as Dictionary)["position"], player.controller.state.yaw)
	ctx.reply("Your run is back, paused where you left it. !unpause to carry on.")


func _cmd_auto_restart(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	var player := game.timers.player(game.record_key(id))
	if player == null:
		ctx.reply("Only a player can do that.")
		return
	game.timers.set_auto_restart(game.record_key(id), not player.auto_restart)
	ctx.reply("Auto-restart %s." % ("on" if player.auto_restart else "off"))


func _cmd_delete_record(ctx: DotCmdContext) -> void:
	if _no_records(ctx):
		return
	if ctx.args.is_empty():
		ctx.reply("Usage: g2g_deleterecord <name or id> [track] [style]")
		return
	var who := _find_player(ctx, ctx.args[0])
	var board := _board_of(ctx)
	var track: int = board["track"]
	if ctx.args.size() > 1:
		track = DotTimerTrack.parse(ctx.args[1])
	var style: StringName = StringName(ctx.args[2]) if ctx.args.size() > 2 else board["style"]
	# Through the manager, which re-scores the board and re-totals the player whose
	# record went. The store's own `remove` deletes the row and nothing else, which left
	# that player's points still counting it.
	var removed: DotResult = await game.timers.remove_record(board["map"], track, style, who["id"])
	if not removed.ok:
		ctx.reply_error(removed)
		return
	if not bool(removed.value):
		ctx.reply("%s has no time there." % who["name"])
		return
	DotLog.info(CHANNEL, "record removed by an admin", {"player": String(who["id"]), "map": String(board["map"]), "track": track, "style": String(style)})
	ctx.reply("Removed %s's time; the board is re-scored." % who["name"])


func _cmd_wipe_player(ctx: DotCmdContext) -> void:
	if game.timers.store == null or ctx.args.is_empty():
		ctx.reply("Usage: g2g_wipeplayer <player id>")
		return
	var id := StringName(ctx.args[0])
	# Every map they were on is re-scored, not only this one: a wiped record holder's time
	# was the scale everybody else's points on those maps were measured against.
	var wiped: DotResult = await game.timers.wipe_player(id)
	if not wiped.ok:
		ctx.reply_error(wiped)
		return
	DotLog.info(CHANNEL, "player wiped by an admin", {"player": String(id), "records": int(wiped.value)})
	ctx.reply("Removed %d records of %s." % [int(wiped.value), String(id)])


func _cmd_rescore(ctx: DotCmdContext) -> void:
	if _no_records(ctx):
		return
	var res: DotResult = await game.timers.rescore_map(game.maps.current.id)
	ctx.reply("%d records re-scored." % int(res.value) if res.ok else res.error.message)


func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Maps:"])
		for map in game.maps.catalogue.maps:
			lines.append("  %-24s tier %d  %s" % [String(map.id), map.tier, String(map.kind)])
		ctx.reply_lines(lines)
		return
	var found := game.maps.catalogue.search(ctx.args[0])
	if found.size() != 1:
		ctx.reply("No map matches '%s'." % ctx.args[0] if found.is_empty() else "Which one?")
		return
	ctx.reply("Changing to %s." % found[0].label())
	var changed: DotResult = await game.change_map(found[0].id)
	if not changed.ok:
		ctx.reply_error(changed)


## Re-read the map directory on a running server, so an operator can drop a map in without a restart that kicks everybody.
func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var change := game.rescan_maps()
	var added: Array = change["added"]
	var removed: Array = change["removed"]
	var lines := PackedStringArray([
		"%d maps (%d added, %d removed)" % [change["total"], added.size(), removed.size()]
	])
	for id: StringName in added:
		lines.append("  + %s" % String(id))
	for id: StringName in removed:
		lines.append("  - %s" % String(id))
	# Naming the map still being played is the one thing an operator needs told: it
	# keeps running, deliberately, and will not be chosen again.
	if game.maps.current != null and not game.maps.catalogue.has(game.maps.current.id):
		lines.append("  %s is still being played and is no longer on disk"
			% String(game.maps.current.id))
	ctx.reply_lines(lines)


func _cmd_rtv(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if id == &"":
		ctx.reply("Only a player can rock the vote.")
		return
	# `g2g_rtv` with a ballot is the ballot's rock-the-vote, the same one `rtv` is.
	if vote != null:
		var res := vote.rock_the_vote(id)
		ctx.reply("Rocked the vote." if res.ok else res.error.message)
		return
	if game.rock_the_vote(id):
		ctx.reply("The vote passed.")
	else:
		ctx.reply("%d of %d." % [game.maps.time_limit.rtv_votes(),
			game.maps.time_limit.rtv_needed(game.players.size())])

