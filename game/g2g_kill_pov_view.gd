extends CanvasLayer

const KillPov := preload("g2g_kill_pov.gd")
const G2GArsenal := preload("g2g_arsenal.gd")

## The killer's own screen over a replay camera: their crosshair and held weapon, from the recorded aux.

const WEAPON_FONT := 22

var crosshair: DotCrosshair = null
var label: Label = null


func _init() -> void:
	layer = 4


## Draws one frame of the killer's screen; {} ends it.
func present(view: Dictionary) -> void:
	if view.is_empty():
		_end()
		return
	var own: Variant = view.get("crosshair")
	if own is CanvasItem:
		(own as CanvasItem).visible = false
	if crosshair == null:
		_start()
	visible = not view.get("behind", false)
	var aux: PackedFloat32Array = view["aux"]
	crosshair.fov_degrees = view["camera"].fov
	label.text = KillPov.weapon_name(aux[KillPov.WEAPON] if aux.size() > KillPov.WEAPON else 0.0, G2GArsenal.weapon_table())


func _start() -> void:
	crosshair = DotCrosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)
	label = Label.new()
	# Just above the killcam's bottom bar (16% of the height).
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 0.83
	label.anchor_bottom = 0.83
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_right = -40.0
	label.add_theme_font_size_override("font_size", WEAPON_FONT)
	add_child(label)


func _end() -> void:
	for n: Node in [crosshair, label]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	crosshair = null
	label = null


## Puts the killer's screen under [param parent] and makes it [param target]'s `present_fn`; false on a dot-replay without one.
static func mount(parent: Node, target: Object) -> bool:
	if not (&"present_fn" in target):
		return false
	var view := new()
	view.name = "KillerScreen"
	parent.add_child(view)
	target.set(&"present_fn", view.present)
	return true
