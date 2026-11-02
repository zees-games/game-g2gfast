extends DotGameNetchaosClient

## g2gfast's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient). No weapons: the pilot only runs, strafes and jumps.


func _configure() -> void:
	client_scene = "res://game/g2g.tscn"


func _roster() -> Array:
	var game = _client.get("game") if _client != null else null
	return game.players.values() if game != null else []
