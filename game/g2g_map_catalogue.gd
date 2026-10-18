extends RefCounted

const G2GPaths := preload("g2g_paths.gd")

## Finds every map this game can play, by looking rather than by being told.
##
## [b]There is no list of maps anywhere in this repository.[/b] There was one — three
## ids in [method G2GGame._map_catalogue] — and a second in `tools/export_zones.gd`,
## and this tree has now had that same bug in `setup.sh`, `tools/check.sh`,
## `tools/package_check.sh` and both bootstrap scripts. A map is a scene plus a
## sidecar describing it, and both of those are things the map itself carries, so
## neither can go stale: a map that is present is found, and a map that is deleted
## stops being offered.
##
## Two shapes are recognised:
##
## [codeblock]
## maps/<id>.tscn        + maps/<id>.zones.json      hand-written: a scene and a script
## <root>/<id>/<id>.json                             imported: data, and nothing else
## [/codeblock]
##
## Everything the catalogue needs — tier, author, display name, kind — comes out of
## that sidecar, because it is generated from the map rather than written beside it.
##
## [b]An imported map has no scene and no script of its own[/b], and that is what makes
## it droppable. Every one of them is [constant IMPORTED_SCENE], which ships inside the
## build, pointed at a different manifest through [member DotMapDef.meta]. A generated
## `<id>.tscn` cannot work for a map that arrives after the export — `res://` is a
## read-only PCK in a shipped build — so an imported map is data at a path, and the
## paths searched include ones outside `res://` for exactly that reason.

const CHANNEL := "g2g.maps"
static var BUILT_IN_DIR := G2GPaths.rebase("res://maps")

## The one scene every imported map uses. It is in the build; the maps are not.
static var IMPORTED_SCENE := G2GPaths.rebase("res://maps/imported_map.tscn")

## Where imported maps are looked for, in order, before anything the host adds.
##
## `res://maps/imported` is where a run from source keeps them and is baked into an
## export; `user://maps` is where anything downloaded at runtime lands, and is the only
## one of the two a shipped server can be given a new map through.
static var IMPORTED_ROOTS := [G2GPaths.rebase("res://maps/imported"), "user://maps"]

## Suffixes an exported build appends. [method DirAccess.get_files] returns the names
## as they are packed, not as they were authored, so a `.tscn` is `.tscn.remap` in an
## export and a scan that matches on `.tscn` finds **nothing there** while working
## perfectly from source — this family's "a code path only one deployment shape
## reaches" with the deployment shape being the shipped one.
const STRIPPED := [".remap", ".import"]


## What [member DotMapDef.author] reads when nobody wrote an author down: a hand-built
## map is this game's own, and an import with no credit in its zones file says so. Both
## are placeholders rather than names, and [method credit] is how anything that shows a
## player who made a map tells the two apart (`[credit-1]`).
const BUILT_IN_AUTHOR := "g2gfast"
const IMPORTED_AUTHOR := "imported"


## The person to credit for [param map], or "" when there is nobody to name.
## The version a map pack is published as: `0.0.0-` and the first twelve hex digits of
## a SHA-256 over every file in the map's directory, path and bytes, in path order.
##
## [b]Derived, not kept.[/b] Every pack was `@0.0.0`, and dot-cloud keys a mount on
## `id@version` and can never undo one, so a client that had mounted the old bhop_aztec
## was told "bhop_aztec, 0.0.0" by a server that had the new one, believed it, and
## played other geometry. A hash changes exactly when the files do: no per-map number to
## remember to bump in `maps.json`, and republishing what has not changed gives the same
## version, so nobody downloads anything. The directories a publisher never ships
## (`.godot`, `.git`, `__pycache__`) are left out; `.import` markers are in, because a
## changed import setting is a changed pack.
static func pack_version(dir: String) -> String:
	var files := PackedStringArray()
	_files_under(dir.rstrip("/"), "", files)
	files.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in files:
		ctx.update(("%s\n" % rel).to_utf8_buffer())
		var fh := FileAccess.open(dir.path_join(rel), FileAccess.READ)
		if fh == null:
			continue
		while not fh.eof_reached():
			var chunk := fh.get_buffer(1 << 20)
			if chunk.is_empty():
				break
			ctx.update(chunk)
		ctx.update(PackedByteArray([0]))
	return "0.0.0-" + ctx.finish().hex_encode().substr(0, 12)


static func _files_under(root: String, rel: String, out: PackedStringArray) -> void:
	var here := root if rel.is_empty() else root.path_join(rel)
	for f in DirAccess.get_files_at(here):
		out.append(f if rel.is_empty() else rel.path_join(f))
	for d in DirAccess.get_directories_at(here):
		if d in [".godot", ".git", "__pycache__"]:
			continue
		_files_under(root, d if rel.is_empty() else rel.path_join(d), out)


static func credit(map: DotMapDef) -> String:
	if map == null:
		return ""
	var who := map.author.strip_edges()
	return "" if who == BUILT_IN_AUTHOR or who == IMPORTED_AUTHOR else who

## Every map on disk, as a fresh catalogue.
##
## [param extra_roots] are searched for imported maps after [constant IMPORTED_ROOTS] —
## an operator's own directory, wherever they keep it.
##
## [param content] is the Workshop's index (null is the process's shared one); the maps of
## subscribed packs of an accepted kind follow it, after this game's own so that an id of
## ours always wins. Solo or online is the index's, so a server lists none of them.
static func discover(
	extra_roots: PackedStringArray = PackedStringArray(), content: DotContentIndex = null
) -> DotMapCatalogue:
	var catalogue := DotMapCatalogue.new()
	for map in scan(extra_roots):
		var added := catalogue.add(map)
		if not added.ok:
			DotLog.warn(CHANNEL, "a map was refused by the catalogue",
				{"id": String(map.id), "why": added.error.message})
	catalogue.follow_content(content if content != null else DotContentIndex.shared(),
		accepted_map_kinds())
	return catalogue


## The file a game pack states what it takes from subscriptions in (dot-cloud's
## docs/workshop.md, "What a game accepts"). Read from there, not repeated, because the
## site offers a pack by this same file and a second list would drift from it.
const PROVIDES_PATH := "res://provides.json"

## What [method accepted_map_kinds] answers when the file cannot be read.
const ACCEPTED_MAP_KINDS_FALLBACK := ["surf", "bhop", "kz", "race"]


## The `map_kind`s of subscribed maps this game lists: `accepts.map_kinds` in `provides.json`.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := G2GPaths.rebase(PROVIDES_PATH)
	var parsed: Variant = null
	if FileAccess.file_exists(path):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null
	if not (kinds is Array):
		kinds = ACCEPTED_MAP_KINDS_FALLBACK
	for kind: Variant in (kinds as Array):
		out.append(str(kind))
	return out


## Whether [param def] came from a subscribed pack rather than from this game or its disk.
static func is_workshop(def: DotMapDef) -> bool:
	return def != null and def.entry_key != ""


## Bring an existing catalogue up to date with the disk, in place.
##
## [b]In place, and not by building a new one.[/b] [DotMapRotation] holds the
## catalogue by reference and reads its pool live, so replacing the object leaves the
## rotation pointing at the old set — which still works, and offers exactly the maps
## that are no longer there.
##
## Returns what changed: `added`, `removed` and `total`.
static func rescan(
	catalogue: DotMapCatalogue, extra_roots: PackedStringArray = PackedStringArray()
) -> Dictionary:
	var added: Array[StringName] = []
	var removed: Array[StringName] = []
	if catalogue == null:
		return {"added": added, "removed": removed, "total": 0}

	var found := scan(extra_roots)
	var seen: Dictionary = {}
	for map in found:
		seen[map.id] = map
		if catalogue.has(map.id):
			# Replace rather than skip: a re-imported map may have a new tier, a new
			# name or a new scene, and a catalogue that only ever grows would keep
			# describing the version that was there when the server booted.
			catalogue.remove(map.id)
			catalogue.add(map)
		elif catalogue.add(map).ok:
			added.append(map.id)

	for existing in catalogue.maps.duplicate():
		# A subscribed pack's map is not on this disk to be found, and is not removed by
		# its absence: the catalogue's own follower owns those rows.
		if is_workshop(existing):
			continue
		if not seen.has(existing.id):
			catalogue.remove(existing.id)
			removed.append(existing.id)

	# A map found on disk under a pack map's id replaced it above; give the pack its rows back.
	catalogue.refresh_content()

	return {"added": added, "removed": removed, "total": catalogue.size()}


## Every map on disk, as definitions, sorted by id so two scans agree.
static func scan(extra_roots: PackedStringArray = PackedStringArray()) -> Array[DotMapDef]:
	var out: Array[DotMapDef] = []
	out.append_array(_built_in())
	var seen: Dictionary = {}
	for root in roots(extra_roots):
		for map in _imported(root):
			# First root wins. An operator's own directory is searched last, so a map
			# shipped in the build is not silently replaced by one somebody dropped in
			# next to it -- and two roots holding the same id is a thing that happens
			# the first time anybody copies a map instead of moving it.
			if not seen.has(map.id):
				seen[map.id] = true
				out.append(map)
	# By the id's text. `a.id < b.id` compares two StringNames, which Godot orders by where
	# each was interned rather than by text: the order differed per process, so two scans
	# did not agree and a rotation with no file cycled maps in no stable order.
	out.sort_custom(func(a: DotMapDef, b: DotMapDef) -> bool: return String(a.id) < String(b.id))
	return out


static func _built_in() -> Array[DotMapDef]:
	var out: Array[DotMapDef] = []
	for id in _scene_ids(BUILT_IN_DIR):
		var scene := "%s/%s.tscn" % [BUILT_IN_DIR, id]
		out.append(_define(id, scene, "%s/%s.zones.json" % [BUILT_IN_DIR, id], BUILT_IN_AUTHOR))
	return out


## Every place imported maps are looked for.
static func roots(extra: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out := PackedStringArray()
	for root in IMPORTED_ROOTS:
		out.append(root)
	for root in extra:
		var trimmed := root.strip_edges()
		if not trimmed.is_empty() and not out.has(trimmed):
			out.append(trimmed)
	return out


static func _imported(root: String) -> Array[DotMapDef]:
	var out: Array[DotMapDef] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out                        # a root that does not exist is not an error
	for id in dir.get_directories():
		var manifest := "%s/%s/%s.json" % [root, id, id]
		# The manifest is the map. Its absence means this directory is something else,
		# which is the normal case for a root an operator also keeps .bsp files in.
		if not FileAccess.file_exists(manifest):
			continue
		var map := _define(StringName(id), IMPORTED_SCENE, manifest, IMPORTED_AUTHOR)
		# Without the mesh the map loads to an empty world and nothing says why, so a
		# half-copied directory is skipped rather than offered.
		if not FileAccess.file_exists("%s/%s/%s.bin" % [root, id, id]):
			DotLog.warn(CHANNEL, "an imported map has no mesh and was skipped",
				{"id": id, "root": root})
			continue
		out.append(map)
	return out


## The `.tscn` names directly in a directory, without the imported subdirectory.
static func _scene_ids(root: String) -> Array[StringName]:
	var out: Array[StringName] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for raw in dir.get_files():
		var name := raw
		for suffix in STRIPPED:
			if name.ends_with(suffix):
				name = name.substr(0, name.length() - suffix.length())
		if not name.ends_with(".tscn"):
			continue
		var id := StringName(name.substr(0, name.length() - 5))
		var path := "%s/%s.tscn" % [root, id]

		# [b]The shared scene is not a map.[/b] Every imported map borrows
		# [constant IMPORTED_SCENE], and it has to live in maps/ beside the
		# hand-written ones so it ships in the build -- which is exactly where this
		# scan looks. Without this it enters the catalogue as the id `imported_map`,
		# flagged imported because its scene IS the imported scene, carrying no
		# manifest because there is no map behind it. A rotation can pick it and a
		# vote can offer it, and nothing can load it.
		#
		# It is invisible on a developer machine, which is why it survived: the only
		# check that looks takes the FIRST entry flagged imported, and a machine with
		# maps/imported/ populated finds a real one first. A clean checkout has no
		# imported maps at all, so the template is the only candidate -- so CI saw it
		# on the first run and every suite here had passed for months.
		if path == IMPORTED_SCENE:
			continue

		if ResourceLoader.exists(path):
			out.append(id)
	return out


## One map whose directory IS the map, rather than a root holding several.
##
## [b]A dot-cloud mount is not shaped like a maps root and a scan pointed at one finds
## nothing while reporting no error.[/b] [method _imported] walks `<root>/<id>/<id>.json`
## -- a directory per map, named for the map. dot-cloud mounts a pack at
## `<mount>/<content_id>/<version>/`, so the directory is named for the VERSION while the
## files inside are named for the content id, and every level of that is off by one from
## what the scan expects. Pointing [member IMPORTED_ROOTS] at a mount was the obvious
## thing to try and it silently offers no maps.
##
## So a mounted pack is registered directly: the caller already knows the id, because it
## is the content id it asked dot-cloud for.
##
## Returns null when the directory does not hold the two files a map is made of, which is
## the same judgement [method _imported] makes and for the same reason -- a map with no
## mesh loads to an empty world and nothing says why.
static func at_directory(id: StringName, dir: String) -> DotMapDef:
	var base := dir.rstrip("/")
	var manifest := "%s/%s.json" % [base, id]

	if not FileAccess.file_exists(manifest):
		DotLog.warn(CHANNEL, "a mounted map has no manifest", {
			"id": String(id), "looked_for": manifest
		})
		return null

	if not FileAccess.file_exists("%s/%s.bin" % [base, id]):
		DotLog.warn(CHANNEL, "a mounted map has no mesh and was skipped", {
			"id": String(id), "dir": base
		})
		return null

	return _define(id, IMPORTED_SCENE, manifest, IMPORTED_AUTHOR)


static func _define(
	id: StringName, scene: String, sidecar: String, default_author: String
) -> DotMapDef:
	var meta := _sidecar_meta(sidecar)
	var map := DotMapDef.new()
	map.id = id
	map.scene_path = scene
	map.zones_path = sidecar if sidecar.ends_with(".zones.json") else ""
	map.meta["manifest"] = "" if sidecar.ends_with(".zones.json") else sidecar
	map.tier = int(meta.get("tier", 3))
	map.author = str(meta.get("author", default_author))
	map.kind = StringName(str(meta.get("kind", ""))) if meta.has("kind") else kind_of(id)
	map.display_name = str(meta.get("display_name", "")) if meta.has("display_name") \
		else default_name(id)
	map.meta["source"] = meta.get("source", "")
	map.meta["imported"] = scene == IMPORTED_SCENE
	return map


## A sidecar's descriptive fields, from either shape.
##
## A hand-written map's zones file nests them under `meta`, because that is where
## [DotTimerZoneSet] puts what a map says about itself; an imported map's manifest has
## them at the top. Reading both here is what lets the two shapes share everything else.
static func _sidecar_meta(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		DotLog.warn(CHANNEL, "a map sidecar is not usable", {"path": path})
		return {}
	var doc: Dictionary = parsed
	var nested: Variant = doc.get("meta", {})
	var out: Dictionary = (nested as Dictionary).duplicate() if typeof(nested) == TYPE_DICTIONARY else {}
	for key in ["tier", "author", "display_name", "kind", "source"]:
		if doc.has(key) and not out.has(key):
			out[key] = doc[key]
	return out


## What kind of map an id names, when the map did not say.
##
## The genre's own convention, and the reason it is a fallback rather than the rule:
## `surf_kitsune` really is a surf map and `bhop_g2g_stages` really is a bhop map,
## but a map that says otherwise in its sidecar is telling the truth about itself and
## a prefix is only a guess.
static func kind_of(id: StringName) -> StringName:
	var s := String(id)
	for prefix in [
		["bhop", DotMapDef.KIND_BHOP], ["surf", DotMapDef.KIND_SURF],
		["kz", DotMapDef.KIND_KZ], ["race", DotMapDef.KIND_RACE],
	]:
		if s.begins_with(str(prefix[0]) + "_"):
			return prefix[1]
	return DotMapDef.KIND_SURF


## A readable name from an id, for a map with nothing to say about itself.
static func default_name(id: StringName) -> String:
	var s := String(id)
	var kind := kind_of(id)
	if s.begins_with(String(kind) + "_"):
		return "%s: %s" % [kind, s.substr(String(kind).length() + 1).replace("_", " ")]
	return s.replace("_", " ")
