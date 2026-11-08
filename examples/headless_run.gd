extends "headless_run_bank.gd"

## Runs g2gfast headless: units, the genre field of view, a stock avatar on a rig,
## first and third person, auto-bhop gated by the config, and a bot down both maps.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## [/codeblock]

const G2GProgress := preload("../game/g2g_progress.gd")

const CHECKS := 261

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 27

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — headless run")
	print("")

	# `-- --only=<method>[,<method>...]` boots and runs those sections in that order, for
	# working on one or finding which earlier one leaves state behind: the totals are not
	# checked and the exit code is the sections' alone.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			await _test_boot()
			for method in arg.substr(7).split(",", false):
				await Callable(self, method).call()
			print("ONLY %s: %d passed, %d failed (totals not checked)" % [arg.substr(7), _passed, _failed])
			get_tree().quit(1 if _failed > 0 else 0)
			return

	_test_units()
	_test_source_fov()
	_test_movement_from_config()
	await _test_boot()
	await _test_boot_map_owner()
	_test_avatars()
	await _test_cameras()
	await _test_auto_bhop_gate()
	await _test_zone_files_match()
	_test_reach()
	await _test_bhop_run()
	await _test_stage_command()
	await _test_needle_bonus()
	await _test_ridge_bonus()
	await _test_weave_bonus()
	await _test_bend_bonus()
	await _test_stages_descent()
	await _test_hairpin_bonus()
	await _test_stutter_bonus()
	await _test_surf_run()
	await _test_bonus_track()
	await _test_the_fall_line()
	await _test_ghost()
	await _test_progression()
	await _test_spectating()
	await _test_effects_and_the_run()
	# Last, on its own map load: the stages map's surf bonus is sensitive to what ran
	# before it (`[bank-hang-1]`), and a section placed ahead of it moved that ride.
	await _test_restart_key()

	print("")
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## dot-stats and dot-achievements, over the runs this suite actually made.
##
## [b]Every check here is against a number the runs above PRODUCED.[/b] A progression
## suite that files its own readings and reads them back is testing dot-stats, which
## dot-stats already does; what is untested anywhere else is whether a finish in this
## game reaches those two addons at all.
func _test_progression() -> void:
	_section("progression")

	var progress := game.progress

	# `_check` here returns void, so the guard is a plain test, not `if not _check(...)`.
	_check(progress != null, "the server keeps progress")

	if progress == null:
		return

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	# Every stat an achievement reads must be one the schema declares. Nothing in
	# either addon can check this: dot-achievements does not know the schema exists
	# and dot-stats does not know the catalogue does.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	_progression_stats(progress)
	await _progression_achievements(progress)
	var split: Array[String] = await ProgressKeysCheck.run(progress)
	_check(split.is_empty(), "stats file under the stable key, records under the record key", str(split))
	_done()


func _progression_stats(progress: G2GProgress) -> void:
	# The reporter drops an unpublished stat with "will not be reported why=unpublished",
	# so the two the e2e run saw rejected must be published in the declared schema.
	var schema := G2GStats.schema()
	for id: StringName in [G2GStats.RUNS_STARTED, G2GStats.STRAFES]:
		var published := false
		for d: DotStatsDef in schema.stats:
			if d.id == id:
				published = d.publish
		_check(published, "%s is published to the site" % id)
	var values := progress.session_values(&"bot")

	_check(
		values.get_value(G2GStats.RUNS_STARTED, 0.0) > 0.0,
		"runs started were counted",
		"%d" % int(values.get_value(G2GStats.RUNS_STARTED, 0.0))
	)
	_check(
		values.get_value(G2GStats.RUNS_FINISHED, 0.0) > 0.0,
		"and so were finishes",
		"%d" % int(values.get_value(G2GStats.RUNS_FINISHED, 0.0))
	)

	# A best time is LOWEST, and the distinction between "held zero" and "never seen"
	# is what stops every player's personal best being zero the moment the feature
	# ships. A finished run means there IS a time, so it must be above zero.
	_check(
		values.get_value(G2GStats.BEST_TIME, 0.0) > 0.0,
		"a best time was filed as a time rather than as a zero",
		"%.3f s" % values.get_value(G2GStats.BEST_TIME, 0.0)
	)

	_check(
		values.get_value(G2GStats.JUMPS, 0.0) > 0.0,
		"the movement counters were read off the controller",
		"%d jumps" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	# The counters are a running total the game RESETS on every finish, so filing the
	# total on each sample would add the whole history every tick. At 128 Hz over the
	# runs above that would be six figures for a few hundred jumps.
	_check(
		values.get_value(G2GStats.JUMPS, 0.0) < 100000.0,
		"and filed as deltas rather than as the running total each tick",
		"%d" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	_check(
		values.get_value(G2GStats.PERFECT_JUMPS, 0.0)
			<= values.get_value(G2GStats.JUMPS, 0.0),
		"perfect jumps never exceed jumps"
	)

	# In units, because everything a player reads in this game is. A top speed under
	# a hundred would be metres per second wearing the wrong label.
	_check(
		values.get_value(G2GStats.TOP_SPEED, 0.0) > 100.0,
		"top speed was filed in genre units",
		"%.0f u/s" % values.get_value(G2GStats.TOP_SPEED, 0.0)
	)

	# Distance is the one figure this layer measures itself, and it refuses a jump of
	# more than half a metre in one tick — a respawn, a stage warp or a `!r`. The bot
	# above was teleported into the finish zone at least once, so a distance equal to
	# the map's whole length would mean the guard is not working.
	var distance := values.get_value(G2GStats.DISTANCE, 0.0)
	_check(distance > 0.0, "distance was measured", "%.0f m" % distance)
	_check(
		distance < 100000.0,
		"and a teleport was not counted as travel",
		"%.0f m" % distance
	)



func _progression_achievements(progress: G2GProgress) -> void:
	var values := progress.session_values(&"bot")

	_check(
		progress.achievements.is_unlocked("bot", &"g2g.first_finish"),
		"finishing a course unlocked the achievement for it"
	)

	# The differencing. A player with N session finishes must hold N lifetime
	# finishes, not the running sum 1+2+...+N that a direct signal connection makes.
	var held := progress.achievements.progress_of("bot")

	if held != null:
		_check(
			absf(
				held.value_of(G2GStats.RUNS_FINISHED)
					- values.get_value(G2GStats.RUNS_FINISHED, 0.0)
			) < 0.001,
			"lifetime finishes equal session finishes, so the link differences",
			"%.0f vs %.0f" % [
				held.value_of(G2GStats.RUNS_FINISHED),
				values.get_value(G2GStats.RUNS_FINISHED, 0.0),
			]
		)

		# A LOWEST stat is an absolute in both systems and must be passed through
		# rather than differenced — differencing a personal best would be meaningless,
		# and dot-achievements' link says so.
		_check(
			absf(
				held.value_of(G2GStats.BEST_TIME)
					- values.get_value(G2GStats.BEST_TIME, 0.0)
			) < 0.001,
			"and a best time is passed through rather than differenced",
			"%.3f vs %.3f" % [
				held.value_of(G2GStats.BEST_TIME),
				values.get_value(G2GStats.BEST_TIME, 0.0),
			]
		)

	# Under Thirty: an AT_MOST rule on a LOWEST stat passes for a never-recorded player (missing
	# reads as zero), so a second rule needs a finished run; a new player must NOT have it.
	await progress.begin(&"nobody", "Nobody")
	_check(
		not progress.achievements.is_unlocked("nobody", &"g2g.sub_thirty"),
		"a player who has never run has not finished a course in under thirty seconds"
	)
	await progress.leave(&"nobody")
