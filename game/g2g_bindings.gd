extends RefCounted

## Every key this client reads, as one table: the action, the setting that stores it, the
## words a player sees, the default, and the card it goes on.
##
## [b]Data, because four things read it and they must never disagree.[/b] The client matches
## events against the actions, the settings schema declares one binding per row, the menu's
## Controls page draws a key button per row, and the help screen (H) lists what each key
## does. Before this the keys were a `match` on keycodes in `G2GClient` and a sentence in its
## doc comment, and the sentence had already drifted once — the README said Shift for duck
## for as long as the dead `[input]` block did.
##
## [b]dot-menu's `DotMenuBindings` does the work[/b] (2026-10-09): applying a row, the
## fallback to the default, the swap when a key is taken, the reset. This file is the rows.
##
## [b]The movement actions are dot-player-controller's own names.[/b] `DotFpsSampler` polls
## `dot_fps_*` and `register_default_actions` only creates what is missing, so a binding
## applied here first is the one it reads — there is no second copy of the movement keys.
##
## [b]Stored per DEVICE, except chat.[/b] A key is a fact about a keyboard. The two chat keys
## were ACCOUNT scope before this table existed and keep it, because changing a stored
## setting's scope would quietly reset somebody's chosen key.
##
## [b]Tab is the scoreboard, held[/b], as in every game in the genre and every game in this
## family. It was "next style" until 2026-10-09; that moved to N, and schema 3's migration
## drops a stored "Tab" for it so nobody is left with two actions on one key. Escape is in
## no row and cannot be bound: it is the menu, and how a browser releases the pointer.

const ACCOUNT := DotSettingsDef.Scope.ACCOUNT

## Rows, in the order the menu and the help screen draw them.
const ROWS: Array[Dictionary] = [
	{"action": &"dot_fps_forward", "setting": &"bind_forward", "label": "Forward", "default": "W", "group": "Movement"},
	{"action": &"dot_fps_back", "setting": &"bind_back", "label": "Back", "default": "S", "group": "Movement"},
	{"action": &"dot_fps_left", "setting": &"bind_left", "label": "Strafe left", "default": "A", "group": "Movement"},
	{"action": &"dot_fps_right", "setting": &"bind_right", "label": "Strafe right", "default": "D", "group": "Movement"},
	{"action": &"dot_fps_jump", "setting": &"bind_jump", "label": "Jump", "default": "Space", "group": "Movement"},
	{"action": &"dot_fps_crouch", "setting": &"bind_duck", "label": "Duck", "default": "Ctrl", "group": "Movement"},

	{"action": &"g2g_restart", "setting": &"bind_restart", "label": "Restart run", "default": "R", "group": "Running"},
	{"action": &"g2g_checkpoint_save", "setting": &"bind_checkpoint_save", "label": "Save checkpoint", "default": "C", "group": "Running"},
	{"action": &"g2g_checkpoint_load", "setting": &"bind_checkpoint_load", "label": "Go to checkpoint", "default": "V", "group": "Running"},
	{"action": &"g2g_style_next", "setting": &"bind_style_next", "label": "Next style", "default": "N", "group": "Running"},
	# M is dot-menu's map menu (`dot_menu_maps`), still stored as `bind_map_next` so a key a
	# player moved stays moved.
	{"action": &"dot_menu_maps", "setting": &"bind_map_next", "label": "Change map", "default": "M", "group": "Running"},
	{"action": &"g2g_zones", "setting": &"bind_zones", "label": "Zone editor (offline, or an admin)", "default": "Z", "group": "Running"},

	{"action": &"g2g_flashlight", "setting": &"bind_flashlight", "label": "Flashlight", "default": "F", "group": "View"},
	{"action": &"g2g_hide_others", "setting": &"bind_hide_others", "label": "Hide other players", "default": "O", "group": "View"},
	# Only a spectator's key: it sends the free-camera request while somebody is watching, and
	# does nothing otherwise. G was free on every screen.
	{"action": &"g2g_roam", "setting": &"bind_roam", "label": "Free camera (spectating)", "default": "G", "group": "View"},
	{"action": &"g2g_third_person", "setting": &"bind_third_person", "label": "First / third person", "default": "F5", "group": "View"},

	{"action": &"g2g_chat", "setting": &"chat_open_key", "label": "Chat", "default": "Y", "group": "Communication", "scope": ACCOUNT},
	{"action": &"g2g_chat_team", "setting": &"chat_team_key", "label": "Team chat", "default": "U", "group": "Communication", "scope": ACCOUNT},
	# dot-voice's action (DotVoiceManager.TALK_ACTION), so dot-menu's table sees the game has a talk
	# key and adds none; the setting stays bind_voice, so nobody's stored key is reset. K, because
	# V is Go to checkpoint here.
	{"action": &"dot_voice_talk", "setting": &"bind_voice", "label": "Push to talk", "default": "K", "group": "Communication"},
	# Look at a player and press (dot-game's DotGameClient): G is the free camera, H help, K talk.
	{"action": &"voice_gag", "setting": &"bind_voice_gag", "label": "Look at a player: stop (or resume) hearing them", "default": "J", "group": "Communication"},
	{"action": &"voice_mute", "setting": &"bind_voice_mute", "label": "Look at a player: mute (or unmute) their voice and chat", "default": "L", "group": "Communication"},

	{"action": &"g2g_scoreboard", "setting": &"bind_scoreboard", "label": "Scoreboard (hold)", "default": "Tab", "group": "Interface"},
	{"action": &"g2g_help", "setting": &"bind_help", "label": "Help", "default": "H", "group": "Interface"},
	{"action": &"g2g_servers", "setting": &"bind_servers", "label": "Server list", "default": "F3", "group": "Interface"},
	{"action": &"g2g_theme_next", "setting": &"bind_theme_next", "label": "Next HUD theme", "default": "P", "group": "Interface"},
]


## The table as dot-menu's, ready to declare, apply and draw.
static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	for row in ROWS:
		keys.add(row["action"], row["setting"], str(row["label"]), str(row["default"]), str(row["group"]),
			int(row.get("scope", DotSettingsDef.Scope.DEVICE)))
	# No weapons or items to switch between here, so the wheel jumps (a bhop game wants a tick
	# per press); two rebindable extra rows on dot_fps_jump, Space stays.
	var _wheel := keys.add_wheel_jump("Movement")
	return keys
