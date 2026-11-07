extends DotSpectatorHost

const G2GGame := preload("g2g_game.gd")
const G2GPlayer := preload("g2g_player.gd")

## Watching somebody run: [DotSpectatorHost] with this game's numbers.
##
## [b]This is not the same feature it is in a deathmatch.[/b] On a timer server a record is set by somebody, once, and
## everybody else wants to watch it being set: `!spec ada`. Two consequences, both settings:
##
## - [b]Anybody may watch anybody.[/b] There are no sides here. `force_camera` is 0 unless the deathmatch layer is on,
##   where an alive player watching a live one is a free wallhack.
## - [b]A live player may watch too.[/b] Somebody in the start zone deciding whether to run is not dead.
##
## [codeblock]
## var spectate := G2GSpectate.new()
## spectate.game = game
## add_child(spectate)
## spectate.setup()
## spectate.watch(&"ada", &"bob")
## [/codeblock]

const CHANNEL := "g2g.spectate"

var game: G2GGame = null


func _init() -> void:
	chase_distance = 4.0
	chase_height = 1.2
	history_seconds = 4.0


func _channel() -> String:
	return CHANNEL


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "G2GSpectate needs a game.")
	authoritative = game.authoritative
	tick_rate = game.tick_rate
	var res := super.setup()
	if not res.ok:
		# An ERROR, because the server runs on without `!spec` and nothing else says so.
		DotLog.error(CHANNEL, "spectating did not start", {"why": res.error.message})
		return res.wrap("g2gfast spectate")
	if not game.player_removed.is_connected(_on_player_removed):
		game.player_removed.connect(_on_player_removed)
	return res


## A timer server is one team, so "your own side" would mean everybody; the deathmatch layer is where it tightens.
## Free roam follows `mp_forcecamera` and `mp_freeroam`, which the module binds: hard-coding it here would be
## overwritten by the cvar's default.
func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	var fighting := game.combat != null and game.combat.enabled
	r.allow_while_alive = not fighting
	r.cycle_includes_dead = not fighting
	# No death camera on a run: falling off a surf map is not a kill, and the seconds are a restart.
	r.death_cam_ticks = int(0.75 * float(game.tick_rate)) if fighting else 0
	r.freeze_cam_ticks = int(1.0 * float(game.tick_rate)) if fighting else 0
	return r


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = game.players.keys()
	# By text: StringNames sort by interning, not by name.
	ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for id: Variant in ids:
		out.append(String(id))
	return out


## The side they are on, not a constant. dot-spectate treats team 0 as "no team", and the stack does not exist until
## the game is built, so 0 is the honest answer before that.
func _team_of(key: String) -> int:
	return game.player_stack.team_index_of(key) if game.player_stack != null else 0


func _is_alive(key: String) -> bool:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null:
		return false
	if game.combat == null or not game.combat.enabled:
		# Nothing to be dead of, and "false" would make every runner unwatchable.
		return true
	var health := game.combat.health_of(StringName(key))
	return health == null or health.alive


func _pose_of(key: String) -> Transform3D:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	var pose := eye_pose(Vector3.ZERO, state.pitch, state.yaw)
	pose.origin = player.eye_position()
	return pose


func _current_tick() -> int:
	return game.current_tick()


func tick(_delta: float) -> void:
	advance_live()


func watch(viewer: String, target: String) -> DotResult:
	return _watched(viewer, super.watch(viewer, target))


func previous_target(viewer: String) -> DotResult:
	return _watched(viewer, super.previous_target(viewer))


## DEBUG either way: a refused `!spec` is the player's answer in chat, but "who was watching whom" is the first thing
## asked about a spectator complaint.
func _watched(viewer: String, res: DotResult) -> DotResult:
	if res.ok:
		DotLog.debug(CHANNEL, "spectating", {"viewer": viewer, "target": target_of(viewer)})
	else:
		DotLog.debug(CHANNEL, "a spectate request was refused", {"viewer": viewer, "why": res.error.message})
	return res


## Watch whoever is furthest into a run, which is what `!spec` with no name almost always means. Furthest rather than
## fastest: "who is nearly finished" is the question a spectator is asking.
func watch_best(viewer: String) -> DotResult:
	if manager == null:
		return _unset()
	var best := ""
	var best_ticks := -1
	for key in manager.targets_for(viewer):
		var player: G2GPlayer = game.players.get(StringName(key), null)
		if player == null or player.timer == null or player.timer.run == null or not player.timer.run.is_running():
			continue
		if player.timer.run.ticks > best_ticks:
			best_ticks = player.timer.run.ticks
			best = key
	if best == "":
		return _watched(viewer, manager.next_target(viewer))
	return _watched(viewer, manager.watch(viewer, best))


## Who a viewer is watching, or "".
func target_of(viewer: String) -> StringName:
	return StringName(watching(viewer))



func _on_player_removed(id: StringName) -> void:
	left(String(id))
