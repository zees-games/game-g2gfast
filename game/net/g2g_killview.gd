extends RefCounted

## The kill view's server half over this game: every living eye, respawns held in dot-match's queue.

const CHANNEL := "g2g.killview"

## Most bytes a KILLVIEW body may take: the event body's cap, less its framing.
const BYTES := 15000

var server: DotKillViewServer = null
var _game: Node = null


func _init(game: Node) -> void:
	_game = game
	server = DotKillViewServer.new(game.killview_rules)
	server.tick_rate = game.tick_rate
	server.eyes_fn = _eyes
	server.use_respawn_queue(
		func() -> Variant: return game.combat.match_node.respawns if game.combat != null and game.combat.match_node != null else null,
		func(entity: Variant) -> DotResult: return game.combat.respawn_now(int(entity)))


## Records this tick, and returns [{victim: session id, body}] for the clips that are ready.
func tick(tick_number: int) -> Array:
	var out: Array = []
	var now := float(tick_number) / float(_game.tick_rate)
	server.record(now)
	for ready: Dictionary in server.collect(now, tick_number):
		var victim: StringName = _game.combat.player_id_for(int(ready["victim"]))
		if victim != &"":
			out.append({"player": victim, "body": DotKillViewClip.pack(ready["clip"], ready["info"], BYTES)})
	return out


func note_kill(entry: DotKillFeed.Entry) -> void:
	if not entry.killer_key.is_valid_int() or not entry.victim_key.is_valid_int():
		return
	var killer: Variant = _game.players.get(_game.combat.player_id_for(int(entry.killer_key)))
	var res := server.note_kill(int(entry.killer_key), int(entry.victim_key), float(_game.current_tick()) / float(_game.tick_rate), {
		"killer": String(killer.display_name) if killer != null else "", "weapon": String(entry.cause)})
	if not res.ok:
		DotLog.trace(CHANNEL, "no kill view", {"why": res.error.message})


func skip(player_id: StringName) -> void:
	if _game.combat == null:
		return
	server.skip(_game.combat.entity_for(player_id), _game.current_tick())


func forget(player_id: StringName) -> void:
	if _game.combat == null:
		return
	server.forget(_game.combat.entity_for(player_id))


func _eyes() -> Array:
	var eyes: Array = []
	for id: StringName in _game.players:
		var p = _game.players[id]
		var health: DotHealth = _game.combat.health_of(id)
		if health == null or not health.alive or p.controller == null:
			continue
		var st: DotFpsState = p.controller.state
		var basis := Basis.from_euler(Vector3(deg_to_rad(st.pitch), deg_to_rad(st.yaw), 0.0))
		eyes.append({"id": _game.combat.entity_for(id), "transform": Transform3D(basis, p.eye_position())})
	return eyes
