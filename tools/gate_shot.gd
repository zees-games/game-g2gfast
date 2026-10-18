extends SceneTree

## Renders the real offline client's first frames, to see what the load gate covers.
##
##     xvfb-run -a godot --path . --resolution 1280x720 --script tools/gate_shot.gd
##
## Saves screenshots/gate_<n>.png on a few chosen frames and prints, per frame, whether the
## gate is open, the local body's height and how many ticks its timer has been fed. Not --headless:
## that renders nothing.

var _client: Node = null
var _frame := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_client = (load("res://game/g2g.tscn") as PackedScene).instantiate()
	_client.force_offline = true
	root.add_child(_client)


func _process(_delta: float) -> bool:
	_frame += 1
	var p = _client.player
	var gate: DotLoadGate = _client.gate
	var y: float = p.global_position.y if p != null else NAN
	var ticks: int = 0
	if p != null and p.timer != null:
		ticks = p.timer.ticks_processed
	print("f%d open=%s settling=%s y=%.2f timer_ticks=%d" % [_frame, gate.is_open(), gate.is_settling(), y, ticks])
	if _frame in [2, 20, 60, 140, 200]:
		root.get_texture().get_image().save_png("res://screenshots/gate_%03d.png" % _frame)
	return _frame >= 220
