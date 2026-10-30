extends RefCounted

## Re-emits dot-stats' `recorded` with the record key, so the achievement link keeps the account's
## key while the stats report is filed under the stable stats key.

signal recorded(player_id: StringName, stat_id: StringName, value: float)

## stats key -> record key; a key not listed passes through.
var record_of: Dictionary = {}


func follow(source: Object) -> void:
	source.connect("recorded", _on_recorded)


func _on_recorded(player_id: StringName, stat_id: StringName, value: float) -> void:
	recorded.emit(record_of.get(player_id, player_id), stat_id, value)
