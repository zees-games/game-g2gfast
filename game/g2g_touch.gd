extends Node

## Touch controls on a phone or tablet: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's
## own [DotFpsTouchSampler]. Nothing shows on a desktop; the server's `sv_mobile_*` cvars bound the rest.
## See docs/touch.md.

const CHANNEL := "g2g.touch"

## Jump and crouch hold their command bits on the sampler, so a run sees a thumb exactly as it sees Space and Ctrl.
const RESTART := &"restart"
## Held while a finger is on it; the client reads it where it reads the mouse button (see G2GClientNetcode.fire_wanted).
const FIRE := &"fire"

var controls: DotMobileControls = null
var menu_button: Button = null

## () -> DotFpsSampler: the sampler the keys drive now (the player's own offline, the netcode's online).
var sampler_fn: Callable = Callable()
## () -> bool: a menu, the console, the load gate or spectating has the screen.
var busy_fn: Callable = Callable()


## Builds the overlay under [param host] (the client), above its HUD. [param on_restart] and [param on_menu] are what R
## and Escape do.
func build(host: Node, rules: DotMobileRules, on_restart: Callable, on_menu: Callable) -> void:
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.rules = rules
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	controls.button_pressed.connect(func(id: StringName) -> void:
		if id == RESTART and on_restart.is_valid():
			on_restart.call())
	menu_button = Button.new()
	menu_button.name = "TouchMenu"
	menu_button.text = "MENU"
	menu_button.focus_mode = Control.FOCUS_NONE
	menu_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	menu_button.position = Vector2(-96, 12)
	menu_button.custom_minimum_size = Vector2(84, 40)
	menu_button.pressed.connect(func() -> void:
		if on_menu.is_valid():
			on_menu.call())
	# The menu button is a plain Button; the overlay leaves its touches to the GUI.
	controls.ignore_fn = func(at: Vector2) -> bool:
		return menu_button.visible and menu_button.get_global_rect().has_point(at)
	host.add_child(controls)
	controls.add_child(menu_button)
	sync()


## The buttons a runner needs, offsets from the bottom-right corner.
static func layout() -> Array[Dictionary]:
	return [
		{"id": &"jump", "label": "JUMP", "offset": Vector2(70, 60), "radius": 56.0, "hold": DotFpsCommand.BUTTON_JUMP},
		{"id": &"crouch", "label": "DUCK", "offset": Vector2(190, 40), "radius": 42.0, "hold": DotFpsCommand.BUTTON_CROUCH},
		{"id": FIRE, "label": "FIRE", "offset": Vector2(300, 80), "radius": 52.0},
		{"id": RESTART, "label": "R", "offset": Vector2(60, 200), "radius": 32.0},
	]


## Whether a finger is on FIRE.
func fire_held() -> bool:
	return controls != null and controls.is_held(FIRE)


## Follows the active sampler and pauses while anything else has the screen. Called every frame by the client.
func sync() -> void:
	if controls == null:
		return
	var sampler: DotFpsSampler = sampler_fn.call() if sampler_fn.is_valid() else null
	if sampler != null and sampler != controls.sampler:
		controls.setup(sampler, layout())
	controls.paused = busy_fn.is_valid() and bool(busy_fn.call())
	menu_button.visible = controls.touch


## True when the event is the overlay's: a touch it forwards, or the mouse Godot emulates from that touch, which
## would otherwise turn the view a second time once the pointer is captured.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


## Whether the overlay is up: a touch device and the server allows it.
func active() -> bool:
	return controls != null and controls.touch


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}
