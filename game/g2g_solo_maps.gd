extends RefCounted

## The courses a solo game in the shell offers on M, beside the ones it ships.
##
## The list is the maps collection as the origin publishes it (`<owner>/airdrift-maps/collection.json`,
## read by [method G2GGame.offer_collection] once the game is up) plus [constant IDS], each fetched when picked.
## [constant IDS] is what M offers until then and when no origin answers: dot-server-deploy's
## `cfg.example/content.yml` stock list, which `examples/headless_client.gd` holds in step.

## Where a pack lives: the stock list's owner.
const OWNER := "gamemann"

## The service the client shell publishes for a solo session (`TmcSolo.MAPS_SERVICE`). Looked
## up by name and duck-typed: nothing in a pack may name a shell class.
const SERVICE := &"dot_solo"

## The maps collection a solo game offers, under [constant OWNER].
const COLLECTION := "airdrift-maps"

## The newest `collection.json` format this build reads.
const COLLECTION_FORMAT := 1

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


## The map ids of [param collection]'s `collection.json` body `{format, id, version, packs:
## ["<owner>/<map>"]}`: packs under [param owner] only, since a map is fetched under one owner.
static func collection_maps(body: Variant, collection: String, owner: String) -> DotResult:
	if not (body is Dictionary) or not ((body as Dictionary).get("packs") is Array):
		return DotResult.fail(DotError.CODE_PARSE, "%s: collection.json has no packs list." % collection)
	var doc := body as Dictionary
	var format := int(doc.get("format", 0)) if (doc.get("format") is int or doc.get("format") is float) else 0
	if format < 1 or format > COLLECTION_FORMAT:
		return DotResult.fail(DotError.CODE_VERSION, "%s: collection.json format %s is not one this build reads." % [collection, str(doc.get("format"))])
	if str(doc.get("id", collection)) != collection:
		return DotResult.fail(DotError.CODE_INVALID, "%s: collection.json says it is %s." % [collection, str(doc.get("id"))])
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9_-]{0,63}$")
	var out := PackedStringArray()
	for pack: Variant in (doc["packs"] as Array):
		var parts := str(pack).split("/")
		if pack is String and parts.size() == 2 and parts[0] == owner and re.search(parts[1]) != null and not out.has(parts[1]):
			out.append(parts[1])
	return DotResult.success(out)
