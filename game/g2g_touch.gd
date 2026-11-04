class_name G2GTouch
extends RefCounted

## The on-screen buttons a phone needs for a run: jump, duck, restart, the two checkpoint keys, next style, the
## held scoreboard and chat. Look and move are [DotFpsTouchSampler]'s; [member ignore_fn] keeps a button's finger off the stick.

const JUMP := &"jump"
const DUCK := &"duck"
const RESTART := &"restart"
const SAVE := &"save"
const LOAD := &"load"
const STYLE := &"style"
const BOARD := &"board"
const CHAT := &"chat"

## Asked with a screen position by every touch sampler; set by the client that builds the buttons.
static var ignore_fn: Callable = Callable()

## Offsets are from the bottom-right corner towards the middle; two columns so the clock keeps the left, small enough for a 375 px tall screen.
static func layout() -> Array[Dictionary]:
	return [
		{"id": JUMP, "label": "JUMP", "offset": Vector2(56, 56), "radius": 44.0},
		{"id": RESTART, "label": "R", "offset": Vector2(56, 142), "radius": 28.0},
		{"id": CHAT, "label": "CHAT", "offset": Vector2(56, 200), "radius": 24.0},
		{"id": BOARD, "label": "TAB", "offset": Vector2(56, 252), "radius": 24.0},
		{"id": DUCK, "label": "DUCK", "offset": Vector2(134, 46), "radius": 30.0},
		{"id": LOAD, "label": "LOAD", "offset": Vector2(134, 112), "radius": 28.0},
		{"id": SAVE, "label": "SAVE", "offset": Vector2(134, 176), "radius": 28.0},
		{"id": STYLE, "label": "STYLE", "offset": Vector2(134, 232), "radius": 24.0},
	]


## A touch sampler where a phone is (it still reads keys), the keyboard one otherwise, with the actions registered.
static func make_sampler(tunables: DotFpsTunables) -> DotFpsSampler:
	var sampler: DotFpsSampler
	if DotPlatform.has_touch():
		var touch := DotFpsTouchSampler.new(tunables)
		touch.ignore_fn = _ignores
		sampler = touch
	else:
		sampler = DotFpsSampler.new(tunables)
	DotFpsSampler.register_default_actions(sampler)
	return sampler


static func _ignores(position: Vector2) -> bool:
	return ignore_fn.is_valid() and bool(ignore_fn.call(position))


## Jump or duck on a sampler: a press is refused while [param covered], a release always lands. Returns whether it reached a sampler; a null, freed or non-touch sampler is a no-op.
static func hold_button(id: StringName, down: bool, covered: bool, sampler: Variant) -> bool:
	if down and covered:
		return false
	if sampler == null or not is_instance_valid(sampler) or not sampler is DotFpsTouchSampler:
		return false
	var bit := DotFpsCommand.BUTTON_JUMP if id == JUMP else DotFpsCommand.BUTTON_CROUCH
	(sampler as DotFpsTouchSampler).hold(bit, down)
	return true
