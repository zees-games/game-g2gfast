extends DotGameCheckSuite

const G2GArsenal := preload("../game/g2g_arsenal.gd")
const G2GAvatars := preload("../game/g2g_avatars.gd")
const G2GMovementNames := preload("../game/g2g_movement_names.gd")
const G2GBrowser := preload("../game/g2g_browser.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GCombat := preload("../game/g2g_combat.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GIdentity := preload("../game/g2g_identity.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GProps := preload("../game/g2g_props.gd")
const G2GServices := preload("../game/g2g_services.gd")
const G2GUnits := preload("../game/g2g_units.gd")
const G2GVote := preload("../game/g2g_vote.gd")
const ExitProbe := preload("dedicated_exit_probe.gd")
const DedicatedWorld := preload("dedicated_world.gd")
const Accounts := preload("dedicated_accounts.gd")

## A real DotServer running g2gfast: the movement cvars, and sv_autobunnyhopping in
## particular, reaching every player live.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]

## Sections entered against sections that ran to their last line, and the total number of
## checks — the second being the one the first cannot be. A runtime error inside a section
## aborts that function; the section counter sees it, and the checks it never reached are
## what the total sees when the section had already announced itself. See
## docs/testing.md: this suite had neither until 2026-09-24.
const SECTIONS := 23
const CHECKS := 282

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## [b]A suite that writes to `user://` is a suite whose result depends on the last run.[/b]
## This one wrote the real punishment store, the server's ban and admin files and its audit
## log at their defaults, so every run appended to all of them: 290 punishments in the store
## a real server enforces, and a gag against the same test uid every time. docs/testing.md
## has the two suites that began failing on an unchanged tree over exactly this.
const SERVER_DIR := "user://g2g_dedicated"

var _entered := 0
var _completed := 0
## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a
## listing prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "g2gfast"

var server: DotServer = null
var query_host: DotQueryHost = null
var game: G2GGame = null


var _stats_errors: PackedStringArray = []



func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


func _physics(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


## A finished copy of [param run], for asking `can_record` without finishing the real one.

## [method _run_command] for a coroutine handler: the live tools record each action on a
## punishment store, which may be remote, so the reply can land a frame late.
func _run_command_later(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)
