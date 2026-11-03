extends Node3D

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const ReplayFollow := preload("replay_follow.gd")

## Drives the real movement along a map's recorded run (`maps/routes/<id>.replay`) and
## says whether it finished, or where it left the line. See replay_follow.gd.
##
##     godot --headless --fixed-fps 128 --path . tools/follow_replay.tscn -- bhop_grove
##     godot --headless --fixed-fps 128 --path . tools/follow_replay.tscn -- bhop_grove 200 some.replay
##
## The second argument is seconds (default 1.2 times the recorded run); the third a replay
## file to follow instead of the map's own -- a person's record from the server's records
## directory, before it is copied in beside the route.

var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0] if args.size() > 0 else "bhop_grove")
	var why: Array = []
	var replay: DotTimerReplay = null
	if args.size() > 2:
		var parsed := DotTimerReplay.load_from(args[2])
		if parsed.ok:
			replay = parsed.value
		else:
			why.append(parsed.error.message)
	else:
		replay = ReplayFollow.load_for(id, why)
	if replay == null:
		print("[follow] %s: %s" % [id, why[0]])
		get_tree().quit(1)
		return
	var seconds := float(args[1]) if args.size() > 1 else replay.duration() * 1.2

	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = id
	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(240):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	if game.maps == null or game.maps.current == null or game.maps.current.id != id:
		print("[follow] %s did not load" % id)
		get_tree().quit(1)
		return
	var bot := game.add_player(&"bot", "Bot", true)
	bot.sampler = null
	await get_tree().physics_frame

	print("[follow] %s: %d frames at %d Hz by %s, run %.2f s" % [
		id, replay.frames.size(), replay.tick_rate, replay.player_name, replay.time])
	if game.mechanics != null:
		game.mechanics.blocks.clear()  # the recording is a route bot's run, which a sinking block would put back
	var result: Dictionary = await ReplayFollow.drive(game, bot, replay, seconds)
	print("[follow] %s: %s" % [id, ReplayFollow.summary(result)])
	get_tree().quit(0 if float(result["finished"]) >= 0.0 else 2)
