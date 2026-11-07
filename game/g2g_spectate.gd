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


func _channel() -> String:
	return CHANNEL


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "G2GSpectate needs a game.")

	authoritative = game.authoritative
	tick_rate = game.tick_rate
	chase_distance = 4.0
	chase_height = 1.2
	history_seconds = 4.0

	var res := super.setup()

	if not res.ok:
		# An ERROR, because the server runs on without `!spec` and nothing else says so.
		DotLog.error(CHANNEL, "spectating did not start", {"why": res.error.message})
		return res.wrap("g2gfast spectate")

	if not game.player_removed.is_connected(_on_player_removed):
		game.player_removed.connect(_on_player_removed)

	return DotResult.success(null)


func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	# A timer server is one team by definition, so restricting the camera to "your own
	# side" would restrict it to everybody and mean nothing. It tightens the moment the
	# deathmatch layer is on, where a living player watching a living one is a
	# free wallhack.
	var fighting := game.combat != null and game.combat.enabled

	# [b]Free roam is the family default and follows the cvars, not the deathmatch.[/b]
	# `force_camera` stays 0 and `allow_roaming` stays true here; `mp_forcecamera` and
	# `mp_freeroam` (bound by the module) are the operator's say. What the deathmatch layer
	# tightens is who may spectate at all: `allow_while_alive` is false while fighting, so
	# only the dead can roam.
	r.allow_while_alive = not fighting
	r.cycle_includes_dead = not fighting

	# No death camera on a run. Falling out of a surf map is not a kill and the two
	# seconds a freeze camera holds are two seconds a player wants back to restart.
	r.death_cam_ticks = int(0.75 * float(game.tick_rate)) if fighting else 0
	r.freeze_cam_ticks = int(1.0 * float(game.tick_rate)) if fighting else 0
	return r


func _participants() -> PackedStringArray:
	var ids: Array = game.players.keys()
	# By text: the keys are StringNames, which sort() orders by interning, not by name.
	ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	var out := PackedStringArray()
	for id: Variant in ids:
		out.append(String(id))
	return out


## The side they are actually on. dot-spectate treats 0 as "no team"; a hardcoded 1 made
## everybody a team-mate of everybody. The stack is built before anything can spectate.
func _team_of(key: String) -> int:
	return game.player_stack.team_index_of(key) if game.player_stack != null else 0


func _is_alive(key: String) -> bool:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null:
		return false
	if game.combat == null or not game.combat.enabled:
		# With no deathmatch there is nothing to be dead of, and answering "false" here
		# would make every runner unwatchable.
		return true
	var health := game.combat.health_of(StringName(key))
	return health == null or health.alive


func _pose_of(key: String) -> Transform3D:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	var basis := Basis.from_euler(Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0))
	return Transform3D(basis, player.eye_position())


func _current_tick() -> int:
	return game.current_tick()


func tick(_delta: float) -> void:
	advance_live()


## Watch somebody by id. What `!spec <name>` calls. DEBUG-logged either way: "who was
## watching whom" is the first thing asked about a spectator complaint.
func watch(viewer: String, target: String) -> DotResult:
	return _watched(viewer, super.watch(viewer, target))


func _watched(viewer: String, res: DotResult) -> DotResult:
	if res.ok:
		DotLog.debug(CHANNEL, "spectating", {"viewer": viewer, "target": watching(viewer)})
	else:
		DotLog.debug(CHANNEL, "a spectate request was refused", {"viewer": viewer, "why": res.error.message})
	return res


## Watch whoever is furthest into a run, which is what a player who typed `!spec` with
## no name almost always means. Furthest rather than fastest: "who is nearly finished"
## is the question a spectator is asking.
func watch_best(viewer: StringName) -> DotResult:
	if manager == null:
		return _unset()

	var best := ""
	var best_ticks := -1

	for key in manager.targets_for(String(viewer)):
		var player: G2GPlayer = game.players.get(StringName(key), null)
		if player == null or player.timer == null or player.timer.run == null:
			continue
		if not player.timer.run.is_running():
			continue
		var elapsed := player.timer.run.ticks
		if elapsed > best_ticks:
			best_ticks = elapsed
			best = key

	if best == "":
		return _watched(viewer, next_target(viewer))

	return _watched(viewer, super.watch(viewer, best))


func stop(viewer: String) -> void:
	var was := is_spectating(viewer)
	super.stop(viewer)
	if was:
		DotLog.debug(CHANNEL, "stopped spectating", {"viewer": viewer})


func previous_target(viewer: String) -> DotResult:
	return _watched(viewer, super.previous_target(viewer))


func toggle_roam(viewer: String) -> DotResult:
	var res := super.toggle_roam(viewer)
	if res.ok:
		DotLog.debug(CHANNEL, "free roam toggled", {"viewer": viewer, "roaming": is_roaming(viewer)})
	else:
		DotLog.debug(CHANNEL, "free roam was refused", {"viewer": viewer, "why": res.error.message})
	return res


## Who a viewer is watching, or "".
func target_of(viewer: StringName) -> StringName:
	return StringName(watching(String(viewer)))


func _on_player_removed(id: StringName) -> void:
	left(String(id))
