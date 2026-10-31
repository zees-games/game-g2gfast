extends RefCounted

## Per-map movement settings: dot-game's [DotGameMapConfig] over the cvars a map may change.
##
## `cfg/game/game-g2gfast/dot_map/map/<name>.yml` (a glob such as `surf_%.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; anything else a file says is logged and ignored. Never the auto-bhop cvar: that is the server's and the styles' call, not a map's.

const GAME_ID := "game-g2gfast"

## cvar -> its constraint.
const KEYS := {
	"sv_airaccelerate": {"type": "float", "min": 0.0, "max": 10000.0},
	"sv_accelerate": {"type": "float", "min": 0.0, "max": 1000.0},
	"sv_gravity": {"type": "float", "min": 100.0, "max": 5000.0},
	"sv_friction": {"type": "float", "min": 0.0, "max": 100.0},
	"sv_maxspeed": {"type": "float", "min": 50.0, "max": 5000.0},
	"sv_maxvelocity": {"type": "float", "min": 100.0, "max": 100000.0},
	"sv_airwishcap": {"type": "float", "min": 0.0, "max": 1000.0},
	"sv_enablebunnyhopping": {"type": "bool"},
	# The shared spellings (docs/movement.md); never sv_autohop, for the same reason as the auto-bhop cvar.
	"sv_runspeed": {"type": "float", "min": 50.0, "max": 5000.0},
	"sv_airwishspeed": {"type": "float", "min": 0.0, "max": 1000.0},
}

## cvar -> the [G2GConfig] field behind it (a client has no console, only the config).
const FIELDS := {
	"sv_airaccelerate": "air_accelerate",
	"sv_accelerate": "accelerate",
	"sv_gravity": "gravity",
	"sv_friction": "friction",
	"sv_maxspeed": "max_speed",
	"sv_maxvelocity": "max_velocity",
	"sv_airwishcap": "air_wish_cap",
	"sv_enablebunnyhopping": "enable_bunnyhopping",
	"sv_runspeed": "max_speed",
	"sv_airwishspeed": "air_wish_cap",
}


## The applier over [param console]'s cvars, for the server.
static func build(console: DotConsole) -> DotGameMapConfig:
	return DotGameMapConfig.for_console(GAME_ID, console, KEYS)


## Points a client's [DotGameClient] at the game's config; call `client.map_changed(id)` per map.
static func wire_client(client: DotGameClient, game: Node) -> void:
	client.map_config_game = GAME_ID
	client.map_config_keys = KEYS
	client.map_config_get_fn = func(key: String) -> Variant:
		return game.config.get(FIELDS[key]) if FIELDS.has(key) else null
	client.map_config_set_fn = func(key: String, value: Variant) -> bool:
		if not FIELDS.has(key):
			return false
		var current: Variant = game.config.get(FIELDS[key])
		game.config.set(FIELDS[key], bool(value) if current is bool else float(value))
		game.apply_movement()
		return true
