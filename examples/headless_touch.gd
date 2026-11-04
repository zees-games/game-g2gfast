extends DotGameCheckSuite

## The touch layout: eight buttons that fit a phone without overlapping, the sampler a touch device gets, and a finger on a button kept off the look stick.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 21


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: touch buttons")
	var layout := G2GTouch.layout()
	var ids: Array[StringName] = []
	for b: Dictionary in layout:
		ids.append(b["id"])
	var wanted: Array[StringName] = [G2GTouch.JUMP, G2GTouch.DUCK, G2GTouch.RESTART, G2GTouch.SAVE, G2GTouch.LOAD, G2GTouch.STYLE, G2GTouch.BOARD, G2GTouch.CHAT]
	ids.sort()
	wanted.sort()
	_check(ids == wanted, "jump, duck, restart, checkpoints, style, board and chat are on the layout")

	DotPlatform.touch_override = 0
	var sampler := G2GTouch.make_sampler(DotFpsTunables.new())
	_check(not sampler is DotFpsTouchSampler, "no touch: the plain sampler")
	DotPlatform.touch_override = 1
	sampler = G2GTouch.make_sampler(DotFpsTunables.new())
	_check(sampler is DotFpsTouchSampler, "touch: the touch sampler")

	for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
		var buttons := DotTouchButtons.new()
		buttons.size = size
		buttons.set_buttons(layout)
		add_child(buttons)
		_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "the cluster fits %dx%d" % [size.x, size.y], str(buttons.footprint()))
		var clash := ""
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
				if gap < 4.0:
					clash = "%s and %s" % [ids[i], ids[j]]
		_check(clash == "", "no two buttons overlap at %dx%d" % [size.x, size.y], clash)
		if size.x == 844.0:
			var jump_pos := buttons.centre_of(G2GTouch.JUMP)
			_check(buttons.contains_point(jump_pos), "a point on jump is the button's")
			_check(not buttons.contains_point(Vector2(100, 100)), "a point on the left half is the look stick's")
			G2GTouch.ignore_fn = buttons.contains_point
			var made := G2GTouch.make_sampler(DotFpsTunables.new()) as DotFpsTouchSampler
			_check(made.ignore_fn.is_valid() and made.ignore_fn.call(jump_pos), "the sampler ignores a finger on a button")
		buttons.free()
	G2GTouch.ignore_fn = Callable()
	sampler = null

	DotPlatform.touch_override = 0
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1

	var jump := DotFpsCommand.BUTTON_JUMP
	var held := DotFpsTouchSampler.new(DotFpsTunables.new())
	_check(G2GTouch.hold_button(G2GTouch.JUMP, true, false, held) and _bits(held) & jump != 0, "uncovered: a press holds jump")
	_check(G2GTouch.hold_button(G2GTouch.JUMP, false, true, held) and _bits(held) & jump == 0, "covered: the release still lands")
	_check(not G2GTouch.hold_button(G2GTouch.DUCK, true, true, held) and _bits(held) & DotFpsCommand.BUTTON_CROUCH == 0, "covered: a press is refused")
	G2GTouch.hold_button(G2GTouch.DUCK, true, false, held)
	_check(_bits(held) & DotFpsCommand.BUTTON_CROUCH != 0, "uncovered: a press holds duck")
	G2GTouch.hold_button(G2GTouch.DUCK, false, false, held)
	_check(_bits(held) & DotFpsCommand.BUTTON_CROUCH == 0, "the release lets go of duck")
	_check(not G2GTouch.hold_button(G2GTouch.JUMP, false, false, null), "no sampler: a release is a no-op")
	_check(not G2GTouch.hold_button(G2GTouch.JUMP, false, false, DotFpsSampler.new(DotFpsTunables.new())), "a plain sampler: a release is a no-op")
	var gone := Node.new()
	gone.free()
	_check(not G2GTouch.hold_button(G2GTouch.JUMP, false, false, gone), "a freed sampler: no error, no hold")
	_report(CHECKS)


func _bits(sampler: DotFpsTouchSampler) -> int:
	return sampler.sample(0.0).buttons
