extends SceneTree

const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GHud := preload("../game/g2g_hud.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GPresentation := preload("../game/g2g_presentation.gd")

## Renders this game's HUD to `screenshots/` so a person can look at it.
##
## [b]This was the only game in the family with no way to look at its own interface.[/b]
## `tools/bsp_preview.sh` renders MAPS and has since it was written; the HUD — the clock,
## the speed, the key display, the stage line, the crosshair — had nothing, and a timer
## HUD is the one surface in this repository a player stares at for an entire run. Four
## of the bugs in this family's list were found by looking at a picture, and two of them
## were a Control laid out inside nothing while every property on it read correctly.
##
## Three frames, because the states differ in the ways that go wrong:
##
## [codeblock]
## hud_run        mid-run, keys down, a stage reference to compare against
## hud_practice   the same run after a checkpoint — PRACTICE has to appear
## hud_notice     a filed time over the top, which is the widest text the HUD draws
## hud_clock      the time left as a server's vote describes it, after an extend
## hud_no_clock   a server whose vote has no clock: no time left drawn at all
## hud_beacon     an admin's beacon on another runner four metres ahead: ring, column
## hud_hit        a confirmed headshot on that runner, and the deagle named bottom right
## hud_blind      the same view after an admin's blind: black, with the HUD still on it
## [/codeblock]
##
## [b]`--fx` renders the two gate effects instead[/b] (`tools/screenshot_hud.sh --fx`):
## `g2gfast_fx_start` and `g2gfast_fx_finish`, each drawn by the real presentation layer's
## `on_run_started` / `on_run_finished` at a point on the floor three metres in
## front of the camera, and `g2gfast_fx_both` with the two side by side. The particles are
## slowed to a tenth of real speed and captured at a fixed point in the effect's own time,
## because a software renderer under xvfb is slower than the effect and a capture on the
## Nth frame would be a different moment of it on every machine. `--debug` prints where each
## emitter's particles are at the capture, which is how the origin bug in `scenes/fx/` showed.
##
## Run through `tools/screenshot_hud.sh`. [b]Not `--headless`[/b]: that gives a null
## renderer, a 64 x 64 viewport, and every frame it saves is empty — which is worse than
## no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"

## Frames to let the layout settle before the capture. The HUD reads the player's state
## in `_process`, so a capture on the first frame catches labels that have never been
## filled in — which looks exactly like the bug where they never are.
const SETTLE := 4

var _game: G2GGame = null
var _hud: G2GHud = null
var _player: G2GPlayer = null
var _other: G2GPlayer = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false

## Set by `--fx`. See the class documentation.
var _fx_only := false
## Set by `--splits`: one frame, `hud_splits`, mid-run on bhop_g2g_stages.
var _splits_only := false
var _presentation: G2GPresentation = null

## How far into its own life each effect is captured, in seconds of the effect's time, and
## the slow-down that makes that moment reachable under a software renderer.
const FX_AT := 0.22
const FX_SLOW := 0.1
var _fx_since := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_fx_only = "--fx" in OS.get_cmdline_user_args()
	_splits_only = "--splits" in OS.get_cmdline_user_args()
	if _splits_only:
		# A staged map, so the stage splits panel has sections to draw.
		OS.set_environment("G2G_INITIAL_MAP", "bhop_g2g_stages")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# The movement actions, because the sampler reads them and an unregistered action
	# pushes an engine error per action per tick. `G2GClient` registers the same set.
	DotFpsSampler.register_default_actions()

	var config := G2GConfig.new()
	config.auto_bhop = true

	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = config
	root.add_child(_game)

	_hud = G2GHud.new()
	_hud.name = "Hud"
	root.add_child(_hud)


func _process(delta: float) -> bool:
	if _done:
		return true

	# The map load is asynchronous and the HUD's status line names the map, so binding
	# before it is ready draws a dash where the map goes and calls it a picture.
	if _player == null:
		if _game.maps == null or _game.maps.current == null:
			return false

		_player = _game.add_player(&"local", "gamemann", true)
		# The sampler reads real input, and there is none behind xvfb. The commands are
		# written by hand below instead, which is also what makes the key display
		# deterministic rather than whatever the keyboard happened to be doing.
		_player.sampler = null
		_hud.bind(_game, &"local")
		_stage()
		return false

	# Every player drawn every frame, as `G2GClient._process` does: the camera and the
	# beacon are both placed by `present`, and a frame nobody presented is a camera at
	# the origin and no marker at all.
	for id in _game.players:
		(_game.players[id] as G2GPlayer).present(delta)

	if _at < _shots.size():
		var shot: Dictionary = _shots[_at]

		# Arrange, THEN settle, THEN capture — in that order and never two of them in
		# one frame. The HUD fills its labels in `_process` and the viewport hands back
		# the frame it last *drew*, so arranging and capturing together photographs the
		# state before the change. The first version did exactly that and produced a
		# `hud_practice` with no PRACTICE on it: the flag was set, the picture was of
		# the frame before it, and nothing about either was wrong enough to notice.
		# A gate is drawn at the feet, so the player has to have landed from the spawn
		# first, or the first one hangs in the air where they were falling.
		if shot.has("fx") and not bool(shot["arranged"]) and not _player.controller.state.is_grounded():
			return false

		if not bool(shot["arranged"]):
			var callable: Callable = shot["arrange"]
			callable.call()
			shot["arranged"] = true
			_wait = SETTLE
			return false

		if _wait > 0:
			_wait -= 1
			return false

		# An effect frame waits for the effect's own clock, not for a frame count.
		if shot.has("fx") and Time.get_ticks_msec() - _fx_since < int(FX_AT / FX_SLOW * 1000.0):
			return false

		if _fx_only and "--debug" in OS.get_cmdline_user_args():
			for c in _presentation.fx.find_children("*", "CPUParticles3D", true, false):
				print("[dbg] ", c.get_parent().name, "/", c.name, " ", (c as CPUParticles3D).global_position, " ", (c as CPUParticles3D).capture_aabb(), " emitting=", (c as CPUParticles3D).emitting, " pitch=", _player.controller.state.pitch)
		_capture(String(shot["name"]))
		_at += 1
		return false

	print("[hud] %d frames in screenshots/" % _shots.size())
	_done = true
	return true


## The three states, and what each is for.
func _stage() -> void:
	if _fx_only:
		_stage_fx()
		return

	if _splits_only:
		_shots = [{"name": "hud_splits", "arrange": _arrange_splits, "arranged": false}]
		return

	_shots = [
		{"name": "hud_run", "arrange": _arrange_run, "arranged": false},
		{"name": "hud_practice", "arrange": _arrange_practice, "arranged": false},
		{"name": "hud_notice", "arrange": _arrange_notice, "arranged": false},
		{"name": "hud_clock", "arrange": _arrange_clock, "arranged": false},
		{"name": "hud_no_clock", "arrange": _arrange_no_clock, "arranged": false},
		{"name": "hud_beacon", "arrange": _arrange_beacon, "arranged": false},
		{"name": "hud_hit", "arrange": _arrange_hit, "arranged": false},
		{"name": "hud_blind", "arrange": _arrange_blind, "arranged": false},
		{"name": "hud_loading", "arrange": _arrange_loading, "arranged": false},
	]


func _arrange_run() -> void:
	# A command with three keys down, so the key display has something to draw and the
	# padding that keeps it from jumping sideways is visible.
	var cmd := DotFpsCommand.new()
	cmd.move = Vector2(1.0, 1.0)
	cmd.buttons = DotFpsCommand.BUTTON_JUMP
	_player.controller.current_command = cmd
	_player.controller.state.velocity = Vector3(14.0, 0.0, 6.0)


## The stage splits panel mid-run: a stored personal best with splits and two section bests,
## a run past stage 1 and 2 and behind the best at stage 2, a notice up, keys down.
func _arrange_splits() -> void:
	_arrange_run()
	_hud.notice("Stage 2 — 00:21.40")
	var store := _game.timers.store
	if store == null:
		store = DotTimerStoreMemory.new()
		_game.timers.store = store
	var stages: int = _game.timers.stage_count(_player.timer.track)
	var style: StringName = _player.timer.run.style_id
	var record := DotTimerRecord.new()
	record.map_id = _game.maps.current.id
	record.track = _player.timer.track
	record.style_id = style
	record.player_id = _game.record_key(&"local")
	record.player_name = "gamemann"
	record.time = 15.0 * float(stages + 1)
	for k in range(1, stages + 1):
		record.splits[k] = 15.0 * float(k)
	var _put := store.put(record)
	for k in range(1, stages + 2):
		var section := DotTimerRecord.new()
		section.map_id = record.map_id
		section.track = record.track
		section.style_id = style
		section.player_id = record.player_id
		section.player_name = "gamemann"
		section.stage = k
		section.time = 14.0 + 0.3 * float(k)
		var _put_section := store.put(section)
	var run: DotTimerRun = _player.timer.run
	run.begin(0.0)
	var hz := 1.0 / maxf(run.tick_interval, 0.000001)
	for line in [[1, 14.2], [2, 31.0]]:
		run.ticks = int(float(line[1]) * hz)
		run.mark_stage(int(line[0]), 0.0)
	run.ticks = int(36.0 * hz)
	_hud.refresh_stage_reference()


func _arrange_practice() -> void:
	# A checkpoint used. The HUD must say PRACTICE from this moment, and a run that
	# quietly stayed recordable after one is the bug this frame is here to show.
	if _player.timer == null:
		# print, not push_warning: this is a tool and its output is stdout. A
		# push_warning would arrive in another stream with an engine backtrace
		# stapled to it, which reads like a crash in a script that is fine.
		print("screenshot: no timer on the player; PRACTICE cannot be drawn")
		return

	_player.timer.run.used_checkpoints = true


func _arrange_notice() -> void:
	_hud.notice("00:42.31 — rank 3")


## Forty minutes left — a thirty-minute map extended by ten — which no local map session
## on a client could ever say, so a picture showing it is a picture of the server's clock.
func _arrange_clock() -> void:
	var view := DotVoteClockView.new()
	view.adopt({"has_clock": true, "seconds_left": 2400, "running": true}, Time.get_ticks_msec() / 1000.0)
	_hud.clock_view = view


## `trigger: rtv_only` with no limit. The slot between the map and autobhop must be gone,
## not showing the local session's number and not "no limit".
func _arrange_no_clock() -> void:
	var view := DotVoteClockView.new()
	view.adopt({"has_clock": false}, Time.get_ticks_msec() / 1000.0)
	_hud.clock_view = view


## Another runner four metres straight ahead of the camera, beaconed: the ring at their
## feet, the ripple, and the column above them that the map cannot hide.
func _arrange_beacon() -> void:
	_player.controller.state.velocity = Vector3.ZERO
	_player.controller.current_command = DotFpsCommand.new()
	var here := _player.controller.state.position
	var yaw := deg_to_rad(_player.controller.state.yaw)
	var ahead := here + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 4.0

	_other = _game.add_player(&"u2", "Beaconed")
	_other.controller.state.position = ahead
	_other.global_position = ahead
	_other.beacon = true


## A confirmed headshot on the beaconed runner ahead: the hit marker round the crosshair
## and the number on their head, as a combat map draws them. Both are made to last, since
## a software renderer's four settle frames outlive a real marker's quarter second.
func _arrange_hit() -> void:
	_other.beacon = false
	# The weapon in hand, as `G2GCombat` writes it offline and `net_weapon` sends it to a
	# client: its name bottom right, and no count, because neither weapon has a magazine.
	_player.held_weapon = &"deagle"
	_hud.hit_marker.hit_sec = 30.0
	_hud.damage_numbers.life_sec = 5.0
	_hud.confirm_hit(4, 27.0, _other.controller.state.position + Vector3(0.0, 1.6, 0.0), false, true)


## The same view, blinded: nothing of the course, and the clock and keys still drawn.
func _arrange_blind() -> void:
	_player.blinded = true


## The cover a networked client shows while the server is on a map it has not loaded.
## Pushed by hand here, as `G2GClient._process` pushes it from the bridge.
func _arrange_loading() -> void:
	_player.blinded = false
	_hud.show_loading("Loading surf mesa… 45%")


# --- --fx -------------------------------------------------------------------

func _stage_fx() -> void:
	_presentation = G2GPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	var built := _presentation.setup()
	if not built.ok:
		push_error("the presentation layer: %s" % built.error.message)
	# Never the player's own settings file: a tool that writes `user://` changes the next
	# run of the real client.
	_presentation.settings.local_store = DotSettingsStoreMemory.new()
	_presentation.settings.load_now()
	_presentation.apply_all()
	_presentation.fx.spawned.connect(func(id: StringName, node: Node, why: StringName) -> void:
		if node == null:
			print("[fx] %s refused: %s" % [id, why])
		else:
			print("[fx] %s drawn at %s" % [id, str((node as Node3D).global_position)])
	)

	_shots = [
		{"name": "g2gfast_fx_start", "arrange": _arrange_fx.bind([&"start"]), "arranged": false, "fx": true},
		{"name": "g2gfast_fx_finish", "arrange": _arrange_fx.bind([&"finish"]), "arranged": false, "fx": true},
		{"name": "g2gfast_fx_both", "arrange": _arrange_fx.bind([&"start", &"finish"]), "arranged": false, "fx": true},
	]


## The player stood still at the spawn, and each named gate drawn on the floor ahead.
func _arrange_fx(which: Array) -> void:
	_presentation.fx.clear()
	_player.controller.state.velocity = Vector3.ZERO
	# Looking down a little, through the command because the command is what the tick
	# applies: a gate is drawn at the feet, and level from the eye the floor ahead is
	# behind the clock.
	var look := DotFpsCommand.new()
	look.yaw = _player.controller.state.yaw
	look.pitch = -24.0
	_player.controller.current_command = look
	var feet := _player.controller.state.position
	var yaw := deg_to_rad(_player.controller.state.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var side := forward.cross(Vector3.UP)
	for i in range(which.size()):
		var offset := 0.0 if which.size() == 1 else (float(i) - 0.5) * 1.6
		var at := feet + forward * 3.0 + side * offset
		if which[i] == &"start":
			_presentation.on_run_started(at)
		else:
			_presentation.on_run_finished(at, false)
	for particles in _presentation.fx.find_children("*", "CPUParticles3D", true, false):
		(particles as CPUParticles3D).speed_scale = FX_SLOW
	_fx_since = Time.get_ticks_msec()


func _capture(name: String) -> void:
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := image.save_png(path)

	if err != OK:
		push_error("could not write %s: %d" % [path, err])
		return

	print("[hud] %s  %dx%d" % [path, image.get_width(), image.get_height()])
