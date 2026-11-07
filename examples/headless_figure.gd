extends DotGameCheckSuite

## The runner's drawn person (G2GRig's DotHumanoidFigure) against DotClipMetrics: foot slide, floor contact and bone pops at the paces this game moves at,
## with the limits of tools/filmstrip_thresholds.json (the same file the filmstrip clips use).
## Run: godot --headless --path . res://examples/headless_figure.tscn

const G2GConfig := preload("../game/g2g_config.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const THRESHOLDS := "res://tools/filmstrip_thresholds.json"
const SECTIONS := 4
const FPS := 60.0
const RAMP := 0.3
## From this pace the run has a flight phase and no foot stays down long enough to time.
const FLIGHT_PACE := 4.0
const SECONDS := 3.0

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast: figure metrics")
	var top := G2GUnits.to_metres(G2GConfig.new().max_speed)
	for pace: float in [2.0, top * 0.6, top]:
		_section("the figure at %.1f m/s" % pace)
		_pace(pace, "run%.1f" % pace, FPS)
	_section("the figure at top speed, sampled at 15 fps like the filmstrip")
	_pace(top, "run15", 15.0)
	_report_sections(_entered, _completed, SECTIONS)


func _section(title: String) -> void:
	_entered += 1
	print("-- %s" % title)


## Walks a figure from rest up to [param pace] over a ramp, sampling every frame, and checks every metric row.
func _pace(pace: float, clip: String, fps: float) -> void:
	var figure := DotHumanoidFigure.new()
	add_child(figure)
	figure.build(DotHumanoidLook.stock(9), G2GMovement.player_height())
	var metrics := DotClipMetrics.new()
	var dt := 1.0 / fps
	var speed := 0.0
	for i in int(SECONDS * fps):
		speed = minf(pace, speed + pace / RAMP * dt)
		figure.position.z -= speed * dt
		figure.set_motion({"on_floor": true, "vertical": 0.0, "crouched": false, "aim": 0.0})
		figure.animate(speed, dt)
		figure.skeleton().force_update_all_bone_transforms()
		metrics.add(metrics.pose_sample(float(i) * dt, figure.skeleton(), figure.global_position, true))
	var rows := metrics.evaluate(DotClipMetrics.limits_for(THRESHOLDS, clip))
	print(DotClipMetrics.table(clip, rows))
	var judged := 0
	for row in rows:
		# Framing needs a camera; the others are the body's own.
		if row["check"] == "framing":
			continue
		judged += 1
		# A flight-phase run has no foot planted for slide_window_s, so its slide is unmeasurable (skipped), not clean: allowed only there, and floor contact still judges it.
		var unmeasurable: bool = row.get("skip", false) and row["check"] == "foot_slide" and pace >= FLIGHT_PACE
		_check(row["pass"] and (unmeasurable or not row.get("skip", false)), "%s at %s: %s (limit %s)%s" % [row["check"], clip, row["value"], row["limit"], " [skipped: no planted foot in flight]" if unmeasurable else ""], str(row.get("note", "")))
	_check(judged == 3, "three body checks judged at %s" % clip)
	figure.queue_free()
	_completed += 1
