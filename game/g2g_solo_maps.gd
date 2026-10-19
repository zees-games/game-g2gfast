extends RefCounted

## The courses a solo game in the browser offers on M, beside the ones it ships.
##
## [b]Why the game keeps a copy.[/b] A server names its courses in its own `cfg/content.yml`
## and the shell's `client/solo.json` lists map packs a game fetches [i]before[/i] it starts,
## which for these courses (a pack each, 20-odd of them) would be the whole set downloaded
## on the title screen. The game offers the names and fetches the one that is picked, the
## way it fetches its first map. dot-server-deploy's `cfg.example/content.yml` is the stock
## list; `examples/headless_client.gd` fails when the two drift.

## Where a pack lives: the stock list's owner.
const OWNER := "gamemann"

## The service the client shell publishes for a solo session (`TmcSolo.MAPS_SERVICE`). Looked
## up by name and duck-typed: nothing in a pack may name a shell class.
const SERVICE := &"dot_solo"

const IDS: PackedStringArray = [
	"surf_mesa",
	"surf_beginner2",
	"surf_kitsune",
	"surf_aquaflow",
	"surf_arcade",
	"surf_interference",
	"surf_summit",
	"surf_year3000",
	"surf_greensway",
	"surf_life_of_duck",
	"surf_stonework3",
	"bhop_ananas",
	"bhop_aztec",
	"bhop_badges",
	"bhop_badges_mini",
	"bhop_evolve",
	"bhop_fur",
	"bhop_fury_2",
	"bhop_grove",
	"bhop_interloper",
	"bhop_platformer_fxd",
	"bhop_monster_jam",
	"bhop_pandora2_fix",
	"bhop_pit",
	"bhop_supernova",
	"bhop_tesquo_v2",
]


## The shell's solo session, or null when this game is not running inside one.
static func session() -> Object:
	return DotRegistry.get_service(SERVICE)
