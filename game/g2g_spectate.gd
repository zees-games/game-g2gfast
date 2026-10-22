extends Node

const G2GGame := preload("g2g_game.gd")
const G2GPlayer := preload("g2g_player.gd")

## Watching somebody run.
##
## [b]This is not the same feature it is in a deathmatch.[/b] In an arena, spectating is
## what a dead player does for three seconds. On a timer server it is the point: a
## record is set by somebody, once, and everybody else on the server wants to watch it
## being set. `!spec ada` is a command bhop and surf servers have had for fifteen years,
## and this game shipped without it.
##
## Two consequences follow from that, and both are settings:
##
## - **Anybody may watch anybody.** There are no sides here. `force_camera` is 0 unless
##   the deathmatch layer is on, where an alive player watching a live one is a
##   free wallhack and the policy tightens to the usual one.
## - **A live player may watch too.** Somebody standing in the start zone deciding
##   whether to run is not dead, and refusing them the camera because they are alive is
##   the rule from a game this is not.
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

var manager: DotSpectatorManager = null


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "G2GSpectate needs a game.")

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = game.authoritative
	manager.rules = _rules()
	manager.participants_fn = _participants
	# The side they are actually on, not a constant.
	#
	# dot-spectate keys teams by [code]int[/code] and treats 0 as "no team". A hardcoded
	# 1 made everybody — including somebody on the spectator side — a team-mate of
	# everybody, which is what `force_camera` reads as permission to watch. The stack is
	# built before anything can spectate, and 0 is the honest answer while it is not.
	manager.team_fn = func(key: String) -> int:
		return game.player_stack.team_index_of(key) if game.player_stack != null else 0
	manager.alive_fn = _alive
	manager.pose_fn = _pose_of
	add_child(manager)

	var res := manager.setup()
	if not res.ok:
		# An ERROR, because the server runs on without `!spec` and nothing else says so.
		DotLog.error(CHANNEL, "spectating did not start", {"why": res.error.message})
		return res.wrap("g2gfast spectate")

	if not game.player_removed.is_connected(_on_player_removed):
		game.player_removed.connect(_on_player_removed)

	return DotResult.success(null)


func _rules() -> DotSpectatorRules:
	var rules := DotSpectatorRules.new()

	# A timer server is one team by definition, so restricting the camera to "your own
	# side" would restrict it to everybody and mean nothing. It tightens the moment the
	# deathmatch layer is on, where a living player watching a living one is a
	# free wallhack.
	var fighting := game.combat != null and game.combat.enabled
	#
	# [b]Free roam is the family default and follows the cvars, not the deathmatch.[/b]
	# `force_camera` stays 0 and `allow_roaming` stays true here; `mp_forcecamera` and
	# `mp_freeroam` (bound by the module) are the operator's say. What the deathmatch layer
	# tightens is who may spectate at all: `allow_while_alive` is false while fighting, so
	# only the dead can roam, and an operator who wants the dead held to their own side
	# sets `mp_forcecamera 1`. A hard-coded tightening here would be overwritten by the
	# cvar's default the moment the module bound it, and say nothing about it.
	rules.allow_while_alive = not fighting
	rules.cycle_includes_dead = not fighting

	# No death camera on a run. Falling out of a surf map is not a kill and the two
	# seconds a freeze camera holds are two seconds a player wants back to restart.
	rules.death_cam_ticks = int(0.75 * float(game.tick_rate)) if fighting else 0
	rules.freeze_cam_ticks = int(1.0 * float(game.tick_rate)) if fighting else 0

	rules.chase_distance = 4.0
	rules.chase_height = 1.2
	rules.history_ticks = 4 * game.tick_rate
	return rules


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = game.players.keys()
	# By text: the keys are StringNames, which sort() orders by interning, not by name.
	ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for id: Variant in ids:
		out.append(String(id))
	return out


func _alive(key: String) -> bool:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null:
		return false
	if game.combat == null or not game.combat.enabled:
		# With no deathmatch there is nothing to be dead of, and answering "false" here
		# would make every runner unwatchable — the exact feature this layer is for.
		return true
	var health := game.combat.health_of(StringName(key))
	return health == null or health.alive


func _pose_of(key: String) -> Transform3D:
	var player: G2GPlayer = game.players.get(StringName(key), null)
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0)
	)
	return Transform3D(basis, player.eye_position())


func tick(_delta: float) -> void:
	if manager != null:
		manager.advance(game.current_tick())


## Watch somebody by id. What `!spec <name>` calls.
func watch(viewer: StringName, target: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return _watched(viewer, manager.watch(String(viewer), String(target)))


## Logs what a watch request decided. DEBUG either way: a refused `!spec` is the player's
## answer in chat, not something an operator acts on, but "who was watching whom" is the
## first thing asked about a spectator complaint.
func _watched(viewer: StringName, res: DotResult) -> DotResult:
	if res.ok:
		DotLog.debug(CHANNEL, "spectating", {"viewer": String(viewer), "target": String(target_of(viewer))})
	else:
		DotLog.debug(CHANNEL, "a spectate request was refused", {"viewer": String(viewer), "why": res.error.message})
	return res


## Watch whoever is furthest into a run, which is what a player who typed `!spec` with
## no name almost always means.
##
## [b]Furthest rather than fastest.[/b] A player two seconds into a personal best is
## less interesting than one three quarters of the way through anything, and "who is
## nearly finished" is the question a spectator is asking.
func watch_best(viewer: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")

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
		return _watched(viewer, manager.next_target(String(viewer)))

	return _watched(viewer, manager.watch(String(viewer), best))


func stop(viewer: StringName) -> void:
	if manager != null:
		var was := manager.is_spectating(String(viewer))
		manager.stop(String(viewer))
		if was:
			DotLog.debug(CHANNEL, "stopped spectating", {"viewer": String(viewer)})


func is_spectating(viewer: StringName) -> bool:
	return manager != null and manager.is_spectating(String(viewer))


func camera_for(viewer: StringName) -> Transform3D:
	return manager.camera_of(String(viewer)) if manager != null \
		else Transform3D.IDENTITY


func next_target(viewer: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.next_target(String(viewer))


## The player before the one being watched, round the end. Left click.
func previous_target(viewer: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return _watched(viewer, manager.previous_target(String(viewer)))


## The free-roam key and `!spec free`: into a free camera, or back onto a player. Refused
## (roaming off, or `mp_forcecamera` set) comes back as a failed result for a notice.
func toggle_roam(viewer: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	var res := manager.toggle_roam(String(viewer))
	if res.ok:
		DotLog.debug(CHANNEL, "free roam toggled", {"viewer": String(viewer), "roaming": is_roaming(viewer)})
	else:
		DotLog.debug(CHANNEL, "free roam was refused", {"viewer": String(viewer), "why": res.error.message})
	return res


func is_roaming(viewer: StringName) -> bool:
	return manager != null and manager.view(String(viewer)).mode == DotSpectatorView.Mode.ROAMING


## Whether the key and the hint should be offered to [param viewer].
func can_roam(viewer: StringName) -> bool:
	return manager != null and manager.can_roam(String(viewer))


## Who a viewer is watching, or "".
func target_of(viewer: StringName) -> StringName:
	if manager == null:
		return &""
	return StringName(manager.view(String(viewer)).target)


func _on_player_removed(id: StringName) -> void:
	if manager != null:
		manager.on_leave(String(id))


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])
	return manager.describe_lines()
