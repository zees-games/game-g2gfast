extends RefCounted

## The wire format's tail: requests, avatar, NPC, rules, maps, spectate, combat and match-end encoders.
## Path-based base of g2g_events.gd (no class_name), which inherits it all.

## Names one SPECTATORS event carries: thirty-two is more than fits on a screen.
const SPECTATORS_MAX := 32
const NAME_BYTES := 64
const AVATAR_BYTES := 4096


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


static func write_int(value: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(value, 0))
	return writer.to_bytes()


static func read_int(reader: DotNetReader) -> int:
	return reader.read_varint()


static func write_avatar(avatar: DotAvatar) -> PackedByteArray:
	var writer := _w()
	writer.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return writer.to_bytes()


static func read_avatar(reader: DotNetReader) -> DotAvatar:
	var text := reader.read_string(AVATAR_BYTES)
	if text == "":
		return null
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	var built := DotAvatar.from_dict(parsed)
	return built.value if built.ok else null


const NPC_ID_BYTES := 64

## Where a hunter may be when it is announced, in this game's units. A surf map is large;
## the snapshot carries the real position a tick later, this only places the body.
const NPC_EXTENT := 65536.0


static func write_npc(net_id: int, kind_id: StringName, at: Vector3) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(net_id)
	writer.write_string(String(kind_id), NPC_ID_BYTES)
	writer.write_vector3_range(at, -NPC_EXTENT, NPC_EXTENT, 28)
	return writer.to_bytes()


static func read_npc(reader: DotNetReader) -> Dictionary:
	var out := {
		"net_id": reader.read_varint(),
		"kind_id": StringName(reader.read_string(NPC_ID_BYTES)),
		"position": reader.read_vector3_range(-NPC_EXTENT, NPC_EXTENT, 28),
	}
	out["ok"] = reader.ok()
	return out


static func write_npc_gone(net_id: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(net_id)
	return writer.to_bytes()


static func read_npc_gone(reader: DotNetReader) -> Dictionary:
	var out := {"net_id": reader.read_varint()}
	out["ok"] = reader.ok()
	return out


## A RULES body is what a hostile or broken server can make a client parse. Forty-odd
## public commands with their one-line help come to about 3 KB; the cap leaves room for a
## server with twice as many and refuses anything that is not a command list.
const RULES_BYTES := 12288

## JSON rather than fields: the command list is a variable-length table a client only draws.
## [code]{"flashlight": bool, "thirdperson": bool, "commands": [[name, help], ...]}[/code].
## Shortened from the end of the list, never cut: a truncated JSON document does not parse.
static func write_rules(rules: Dictionary) -> PackedByteArray:
	var body := rules.duplicate(true)
	var commands: Array = body.get("commands", [])
	var text := JSON.stringify(body)

	while text.to_utf8_buffer().size() > RULES_BYTES and not commands.is_empty():
		commands.pop_back()
		body["commands"] = commands
		text = JSON.stringify(body)

	var writer := _w()
	writer.write_string(text, RULES_BYTES)
	return writer.to_bytes()


## Never fails into a half-read: anything that does not parse to a dictionary is
## [code]{"ok": false}[/code], and the flags a server left out read as their defaults
## (everything allowed), which is what a server older than the flag meant.
static func read_rules(reader: DotNetReader) -> Dictionary:
	var text := reader.read_string(RULES_BYTES)
	# A JSON instance rather than `JSON.parse_string`, which prints an engine ERROR with a
	# backtrace for every malformed body: a server sending a bad one is the server's
	# problem, and the client's answer is a quiet refusal.
	var json := JSON.new()
	var parsed: Variant = json.data if reader.ok() and json.parse(text) == OK else null

	if not (parsed is Dictionary):
		return {"ok": false}

	var commands: Array = []

	for row in (parsed as Dictionary).get("commands", []):
		if row is Array and (row as Array).size() >= 2:
			commands.append([str(row[0]), str(row[1])])

	return {
		"ok": true,
		"flashlight": bool((parsed as Dictionary).get("flashlight", true)),
		"thirdperson": bool((parsed as Dictionary).get("thirdperson", true)),
		"commands": commands,
	}


## What the map list may occupy. 42 maps are about 4 KB; a server with three hundred
## gets the first ones that fit rather than a list cut in half.
const MAPS_BYTES := 32768


static func write_maps(rows: Array) -> PackedByteArray:
	var list := rows.duplicate()
	var text := JSON.stringify(list)
	while text.to_utf8_buffer().size() > MAPS_BYTES and not list.is_empty():
		list.pop_back()
		text = JSON.stringify(list)
	var writer := _w()
	writer.write_string(text, MAPS_BYTES)
	return writer.to_bytes()


static func read_maps(reader: DotNetReader) -> Array:
	var text := reader.read_string(MAPS_BYTES)
	var json := JSON.new()
	if not reader.ok() or json.parse(text) != OK or not (json.data is Array):
		return []
	var out: Array = []
	for row: Variant in json.data:
		if row is Dictionary and (row as Dictionary).has("id"):
			out.append(row)
	return out


## A map id asked for over the wire. Bounded by what an id is.
static func write_map_id(id: String) -> PackedByteArray:
	var writer := _w()
	writer.write_string(id, NAME_BYTES)
	return writer.to_bytes()


static func read_map_id(reader: DotNetReader) -> String:
	return reader.read_string(NAME_BYTES)


## Whom a client is watching. [param target] is a player key ("u12", or the ghost's), empty
## for nobody; [param mode] is a `DotSpectatorView.Mode`.
static func write_spectate(target: String, mode: int, target_name: String = "") -> PackedByteArray:
	var writer := _w()
	writer.write_string(target, NAME_BYTES)
	writer.write_uint(clampi(mode, 0, 255), 8)
	writer.write_string(target_name, NAME_BYTES)
	return writer.to_bytes()


static func read_spectate(reader: DotNetReader) -> Dictionary:
	var target := reader.read_string(NAME_BYTES)
	var mode := reader.read_uint(8)
	var target_name := reader.read_string(NAME_BYTES)
	return {"ok": reader.ok(), "target": target, "mode": mode, "name": target_name}


## Who is watching [param target]: up to [constant SPECTATORS_MAX] names, the rest dropped
## from the end. A count first, so a reader never reads past what was written.
static func write_spectators(target: String, names: PackedStringArray) -> PackedByteArray:
	var writer := _w()
	writer.write_string(target, NAME_BYTES)
	var count := mini(names.size(), SPECTATORS_MAX)
	writer.write_varint(count)
	for i in range(count):
		writer.write_string(names[i], NAME_BYTES)
	return writer.to_bytes()


static func read_spectators(reader: DotNetReader) -> Dictionary:
	var target := reader.read_string(NAME_BYTES)
	var count := mini(reader.read_varint(), SPECTATORS_MAX)
	var names := PackedStringArray()
	for i in range(count):
		names.append(reader.read_string(NAME_BYTES))
	return {"ok": reader.ok(), "target": target, "names": names}


## [constant Kind.DEATH]'s body: the victim's session id, then the fall when there is one. The
## fall is last and optional, so a reader that does not know it reads the victim and stops.
static func write_death(player_id: int, death: DotPlayerDeath = null) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(player_id, 0))
	if death != null:
		death.write_to(writer)
	return writer.to_bytes()


static func read_death(reader: DotNetReader) -> Dictionary:
	var out := {"player_id": reader.read_varint()}
	# A byte or more left is the fall; less is the padding to the last byte.
	if reader.bits_remaining() >= 8:
		out["death"] = DotPlayerDeath.read_from(reader)
	out["ok"] = reader.ok()
	return out


## [constant Kind.SHOT]'s body.
static func write_shot(shooter: int, weapon: String, at: Vector3) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(shooter, 0))
	writer.write_string(weapon, 32)
	writer.write_float32(at.x)
	writer.write_float32(at.y)
	writer.write_float32(at.z)
	return writer.to_bytes()


static func read_shot(reader: DotNetReader) -> Dictionary:
	var shooter := reader.read_varint()
	var weapon := reader.read_string(32)
	var at := Vector3(reader.read_float32(), reader.read_float32(), reader.read_float32())
	return {"ok": reader.ok(), "shooter": shooter, "weapon": weapon, "at": at}


## [constant Kind.HIT]'s body. The point is three float32s, not a range: imported maps run
## to 30 000 units either way and a number on a body wants better than a range's step.
static func write_hit(victim: int, amount: float, point: Vector3, killed: bool, headshot: bool) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(victim, 0))
	writer.write_float_range(clampf(amount, 0.0, 1000.0), 0.0, 1000.0, 14)
	writer.write_float32(point.x)
	writer.write_float32(point.y)
	writer.write_float32(point.z)
	writer.write_uint((1 if killed else 0) | (2 if headshot else 0), 2)
	return writer.to_bytes()


static func read_hit(reader: DotNetReader) -> Dictionary:
	var victim := reader.read_varint()
	var amount := reader.read_float_range(0.0, 1000.0, 14)
	var point := Vector3(reader.read_float32(), reader.read_float32(), reader.read_float32())
	var flags := reader.read_uint(2)
	return {"ok": reader.ok(), "victim": victim, "amount": amount, "point": point,
		"killed": flags & 1 != 0, "headshot": flags & 2 != 0}


## [constant Kind.KILL]'s body: session ids, 0 for the world.
static func write_kill(killer: int, victim: int, weapon: String, headshot: bool) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(killer, 0))
	writer.write_varint(maxi(victim, 0))
	writer.write_string(weapon, 32)
	writer.write_uint(1 if headshot else 0, 1)
	return writer.to_bytes()


static func read_kill(reader: DotNetReader) -> Dictionary:
	var killer := reader.read_varint()
	var victim := reader.read_varint()
	var weapon := reader.read_string(32)
	var head := reader.read_uint(1)
	return {"ok": reader.ok(), "killer": killer, "victim": victim, "weapon": weapon, "headshot": head == 1}


## The most rows a MATCH_END carries: the podium shows three.
const MAX_MATCH_ROWS := 3


## [constant Kind.MATCH_END]'s body. [param rows] are `{name, kills, deaths}`, best first.
static func write_match_end(killcam_sec: float, rows: Array) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(clampi(roundi(killcam_sec * 10.0), 0, 300))
	var count := mini(rows.size(), MAX_MATCH_ROWS)
	writer.write_uint(count, 2)
	for i in range(count):
		var row: Dictionary = rows[i]
		writer.write_string(str(row.get("name", "")), NAME_BYTES)
		writer.write_varint(maxi(int(row.get("kills", 0)), 0))
		writer.write_varint(maxi(int(row.get("deaths", 0)), 0))
	return writer.to_bytes()


static func read_match_end(reader: DotNetReader) -> Dictionary:
	var seconds := float(reader.read_varint()) / 10.0
	var count := reader.read_uint(2)
	var rows: Array = []
	for i in range(mini(count, MAX_MATCH_ROWS)):
		var name := reader.read_string(NAME_BYTES)
		var kills := reader.read_varint()
		var deaths := reader.read_varint()
		rows.append({"name": name, "kills": kills, "deaths": deaths})
	return {"ok": reader.ok(), "killcam": seconds, "rows": rows}
