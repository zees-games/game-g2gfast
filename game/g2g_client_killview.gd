extends Node

const G2GArsenal := preload("g2g_arsenal.gd")
const G2GRig := preload("g2g_rig.gd")
const G2GKillView := preload("net/g2g_killview.gd")

## The client half of the shared kill view (dot-replay): the killer's view replayed to the victim.
## Kept out of G2GClient, which is at its size baseline.

var view: DotKillViewClient = null
var _client: Node = null
var _game: Node = null
var _solo: G2GKillView = null


## A solo game's kill view, under [param client].
static func solo(client: Node, game: Node) -> void:
	var node := new()
	node.name = "SoloKillView"
	client.add_child(node)
	node.attach(client, null, game)


## [param client] is the G2GClient; the view hides its HUD, and yields to its final killcam.
## A null [param bridge] is a solo game: this process records and replays its own kills.
func attach(client: Node, bridge: Node, game: Node) -> void:
	_client = client
	_game = game
	view = DotKillViewClient.new()
	view.name = "KillView"
	add_child(view)
	view.setup(game.killview_rules)
	view.hide_fn = func() -> Array: return [client.hud]
	view.stage = client.get("killcam")
	# The victim is the local body, on a layer their own camera culls; the replay camera copies that mask.
	view.kv.view.connect(func(_x: Transform3D, _f: float, _c: Vector2, _h: bool) -> void:
		view.camera.cull_mask |= 1 << (G2GRig.LAYER_LOCAL_BODY - 1))
	if bridge == null:
		_attach_solo()
		return
	view.respawn_requested.connect(func() -> void: bridge.ask_respawn())
	bridge.killview_received.connect(_on_clip)
	var link: Object = DotRegistry.get_service(&"dot_client_link")
	if link != null:
		var _following: bool = game.killview_rules.follow_cvars(link)


func _attach_solo() -> void:
	if _game.combat == null:
		return
	_solo = G2GKillView.new(_game)
	_game.combat.player_killed.connect(_solo.note_kill)
	view.respawn_requested.connect(func() -> void:
		if _client.player != null:
			_solo.skip(_client.player.player_id))


func _physics_process(_delta: float) -> void:
	if _solo == null or not _game.killview_rules.enabled:
		return
	var tick: int = _game.current_tick()
	var now := float(tick) / float(_game.tick_rate)
	_solo.server.record(now)
	for ready: Dictionary in _solo.server.collect(now, tick):
		if _client.player != null and int(ready["victim"]) == _game.entities.id_for_key(_client.player.player_id):
			_on_clip(ready["clip"], ready["info"])


func _on_clip(clip: Dictionary, info: Dictionary) -> void:
	var killcam: Variant = _client.killcam
	if killcam != null and killcam.is_playing():
		return
	var player: Variant = _client.player
	var shown := info.merged({})
	var bodies: Variant = _client.killcam_bodies
	shown["victim_id"] = bodies.id_for(_game, player.player_id) if player != null else 0
	# The clip names the killer by the server's entity id; the stage records local ids.
	var key := StringName(String(info.get("killer_key", "")))
	var staged := clip
	if key != &"":
		staged = clip.merged({"killer": bodies.id_for(_game, key)}, true)
	var weapon := String(info.get("weapon", ""))
	var def: DotWeaponDef = G2GArsenal.weapon_catalogue().get_def(StringName(weapon)) if weapon != "" else null
	shown["weapon"] = def.display_name if def != null and def.display_name != "" else weapon.capitalize()
	var _started := view.play(staged, shown)
