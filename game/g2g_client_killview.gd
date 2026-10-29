extends Node

const G2GArsenal := preload("g2g_arsenal.gd")

## The client half of the shared kill view (dot-replay): the killer's view replayed to the victim.
## Kept out of G2GClient, which is at its size baseline.

var view: DotKillViewClient = null
var _client: Node = null
var _game: Node = null


## [param client] is the G2GClient; the view hides its HUD, and yields to its final killcam.
func attach(client: Node, bridge: Node, game: Node) -> void:
	_client = client
	_game = game
	view = DotKillViewClient.new()
	view.name = "KillView"
	add_child(view)
	view.setup(game.killview_rules)
	view.hide_fn = func() -> Array: return [client.hud]
	view.respawn_requested.connect(func() -> void: bridge.ask_respawn())
	bridge.killview_received.connect(_on_clip)
	var link: Object = DotRegistry.get_service(&"dot_client_link")
	if link != null:
		var _following: bool = game.killview_rules.follow_cvars(link)


func _on_clip(clip: Dictionary, info: Dictionary) -> void:
	var killcam: Variant = _client.killcam
	if killcam != null and killcam.is_playing():
		return
	var player: Variant = _client.player
	var shown := info.duplicate()
	shown["victim_id"] = _game.combat.entity_for(player.player_id) if player != null else 0
	var weapon := String(info.get("weapon", ""))
	var def: DotWeaponDef = G2GArsenal.weapon_catalogue().get_def(StringName(weapon)) if weapon != "" else null
	shown["weapon"] = def.display_name if def != null and def.display_name != "" else weapon.capitalize()
	var _started := view.play(clip, shown)
