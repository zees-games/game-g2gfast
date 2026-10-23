extends RefCounted

const G2GConfig := preload("../g2g_config.gd")
const G2GMovement := preload("../g2g_movement.gd")

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, because they have to be exact inverses and nothing
## checks that for you — the headless net suite round-trips each of them.
##
## [b]Movement travels as the CONFIG, not as the tunables.[/b] A client rebuilds its
## tunables from the same [G2GConfig] fields through the same [G2GMovement] the server
## used, so the two derive bit-identical values — which is what prediction needs. A
## fingerprint rides with it so a mismatch is one log line rather than a week of "the
## netcode feels bad".

enum Kind {
	## Tick rate, who you are, the movement, the server tick. NOT the map: see [constant MAP].
	HELLO,
	## A player joined, or changed: name, peer, net id, avatar, style, track.
	JOIN,
	LEAVE,
	## The movement changed under everybody. Carries the config fields.
	MOVEMENT,
	## One message of dot-map's map-change protocol, host to peer: announce, load or abort.
	## A [DotMapMessage] as JSON. See [method write_map_message] and G2GNetBridge's
	## "Map changes" section. It used to be a bare map id sent AFTER the server had
	## changed, which a client resolved against its own build.
	MAP,
	## A player's run state changed: started, stopped, paused. A DotTimerNet.RunState.
	TIMER,
	## A player finished. A DotTimerNet.Finish plus the rank.
	FINISH,
	## Somebody set a record worth announcing.
	RECORD,
	## Text for everyone: a stage split, a refusal, a vote result.
	NOTICE,
	## The map vote: a sound cue to play, or a second of the countdown before a ballot.
	## Last, because a kind is its index on the wire.
	VOTE,
	## The map's time left, from the vote's clock: sent when it changes rather than
	## counted, so an extend reaches the HUD. Last, for the same reason.
	CLOCK,
	## A hunter now exists, or is being described to a client that just connected: its net
	## id, its kind, where it is. Its movement comes in snapshots. Appended: a kind is its
	## index on the wire.
	NPC,
	## A hunter is gone — killed, reclaimed or cleared.
	NPC_GONE,
	## Where one player stands on the board they are on: their best, the record, their
	## rank and the board's size. Server to that player only — a client has no store to
	## ask. Appended: a kind is its index on the wire.
	STANDING,
	## What a client is allowed to do on its own screen, and which chat commands it can type:
	## `sv_flashlight`, `sv_allow_thirdperson`, and the public command list the help screen
	## draws. On admit and whenever one of them changes. Appended, for the reason above.
	RULES,
	## Every map the server has, for the M screen: `[{id, name, tier, kind, rotation,
	## current}]` as JSON. Sent only to a player holding the changemap flag, on asking.
	## Appended, for the reason above.
	MAPS,
	## Who this client is watching, server to that client only: the target's player key
	## (empty for nobody) and the camera mode. The client's own spectator manager is a
	## mirror, told rather than asked, and its camera follows the target from the poses it
	## already has. Appended.
	SPECTATE,
	## Who is watching a player: their key and the names of their spectators, to that
	## player and to everybody watching them. Only sent while `sv_spec_list` is on; an
	## empty list clears it. Appended.
	SPECTATORS,
	## A hit the server applied, to the player who fired it only: the victim's entity id, the
	## health it took, where it landed, whether it killed and whether it was the head. The
	## hit marker and the damage numbers are drawn from this, never predicted. Appended.
	HIT,
	## A player died, to everybody: who, and how their body falls (dot-player-char's
	## [DotPlayerDeath], the server's pick, last and optional). Every client copies a ragdoll
	## from the figure it draws and hides the figure. Appended.
	DEATH,
	## A dead player is alive again, at a start: every client shows the figure it hid on
	## DEATH. Appended.
	ALIVE,
	## What a staged map's splits panel compares one player against: their best and the
	## record as cumulative splits with their totals, and their best time per section.
	## Server to that player only (a client has no store), on spawn, style change and a
	## filed run or section. Appended.
	STAGE_REF,
	## A player was killed, to everybody: killer (0 for the world), victim, weapon and head.
	## The final killcam notes the last one. Appended.
	KILL,
	## The deathmatch ended: the killcam's length and the top of the board, to everybody.
	## Appended.
	MATCH_END,
}

enum Ask {
	## I have loaded and can receive. Tell me everything.
	READY,
	## Put me on this style (index into the server's ordered table).
	STYLE,
	## Put me on this track.
	TRACK,
	## Here is my avatar.
	AVATAR,
	## Put me back at the start.
	RESTART,
	## Rock the vote.
	RTV,
	## Save a checkpoint (0), teleport to it (1), clear them (2).
	CHECKPOINT,
	## One message of dot-map's map-change protocol, peer to host: progress or ready.
	## Last, because a kind is its index on the wire.
	MAP,
	## The M screen: an empty id asks for the map list, an id asks to change to it. Both
	## are refused unless the asker holds the changemap flag. Appended.
	MAPS,
	## Spectating, from a click rather than a chat line: one of the SPECTATE_* steps.
	## Appended.
	SPECTATE,
}

## [constant Ask.SPECTATE]'s body. Numbered rather than signed because `write_int` is a
## varint and a varint is never negative.
const SPECTATE_STOP := 0
const SPECTATE_NEXT := 1
const SPECTATE_PREVIOUS := 2
const SPECTATE_BEST := 3
## The free-roam key: into a free camera, or back onto a player.
const SPECTATE_ROAM := 4

## [constant Ask.RESTART]'s body. An empty body reads as [constant RESTART_TRACK], which is
## exactly what every client before the body existed meant by R.
##
## TRACK: the start of the track you are on. STAGE: the start of the stage you are in, or
## the track's start when you are in none. MAIN: the main track's start zone, from anywhere
## (a bonus included) — the double tap.
const RESTART_TRACK := 0
const RESTART_STAGE := 1
const RESTART_MAIN := 2

## Spectator names one SPECTATORS event carries. A server full of people watching one
## runner is the case this exists for, and thirty-two names is more than fits on a screen.
const SPECTATORS_MAX := 32

const NAME_BYTES := 64
const AVATAR_BYTES := 4096
const TEXT_BYTES := 256

## A map-change message from the host: an announce carries the whole [DotMapDef], meta
## and all. A few hundred bytes in practice; the cap is what a hostile or broken host
## can make a client parse.
const MAP_MESSAGE_BYTES := 4096

## A map-change message from a peer: a ready or a progress, an id, a version and a
## number. Far smaller than the host's, because it is what a CLIENT can make the server
## parse, and a peer has no reason ever to send more.
const MAP_REPLY_BYTES := 256


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Movement --------------------------------------------------------------

## The G2GConfig fields the simulation reads. Everything else stays server-side.
static func write_movement(config: G2GConfig) -> PackedByteArray:
	# Snapped first, so the fingerprint is of what the receiver will read: a
	# double that does not survive float32 would otherwise fingerprint differently
	# on the two ends while every visible value agreed.
	config.snap_movement()
	var writer := _w()
	for field in G2GConfig.MOVEMENT_FIELDS:
		var value: Variant = config.get(field)
		if value is bool:
			writer.write_bool(value)
		else:
			writer.write_float32(float(value))
	writer.write_string(G2GMovement.tunables_for(config).fingerprint(), 32)
	return writer.to_bytes()


## Applies a MOVEMENT body to a config. Returns the server's fingerprint.
static func read_movement(reader: DotNetReader, config: G2GConfig) -> String:
	for field in G2GConfig.MOVEMENT_FIELDS:
		var current: Variant = config.get(field)
		if current is bool:
			config.set(field, reader.read_bool())
		else:
			config.set(field, reader.read_float32())
	return reader.read_string(32)


# --- HELLO -----------------------------------------------------------------

## [b]No map id, and there was one.[/b] HELLO carried the server's map and the client
## changed to it by id out of its own catalogue — the ad-hoc version of what dot-map's
## protocol now does, and wrong in the same two ways the MAP event was: the client never
## said whether it had the map, and a map it did not have was fetched by nothing. The
## map a joiner is on now arrives as the protocol's own announce, right behind this, and
## a field left here would be a value produced and consumed by nothing.
static func write_hello(
	tick_rate: int, player_id: int, peer_id: int, server_tick: int, config: G2GConfig
) -> PackedByteArray:
	var writer := _w()
	writer.write_uint(tick_rate, 8)
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_bytes(write_movement(config))
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"tick_rate": reader.read_uint(8),
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"server_tick": reader.read_uint(32),
		"movement": reader.read_bytes(1024),
	}
	out["ok"] = reader.ok()
	return out


# --- JOIN / LEAVE ----------------------------------------------------------

## Whether every [DotTimerTrack] fits in [code]DotTimerTrack.BITS[/code], the field JOIN carries
## a track in. dot-timer owns both numbers, so a bonus added there can outgrow the field under
## this game; headless_net reads this.
static func tracks_fit() -> bool:
	return DotTimerTrack.BONUS_LAST < (1 << DotTimerTrack.BITS)


static func write_join(
	player_id: int, peer_id: int, net_id: int, display_name: String,
	avatar: DotAvatar, style_index: int, track: int
) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_varint(net_id)
	writer.write_string(display_name, NAME_BYTES)
	writer.write_uint(style_index, DotTimerNet.STYLE_BITS)
	writer.write_uint(track, DotTimerTrack.BITS)
	var text := JSON.stringify(avatar.to_dict()) if avatar != null else ""
	writer.write_string(text, AVATAR_BYTES)
	return writer.to_bytes()


static func read_join(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"net_id": reader.read_varint(),
		"name": reader.read_string(NAME_BYTES),
		"style_index": reader.read_uint(DotTimerNet.STYLE_BITS),
		"track": reader.read_uint(DotTimerTrack.BITS),
	}
	var text := reader.read_string(AVATAR_BYTES)
	out["avatar"] = null
	if text != "":
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)
			if built.ok:
				out["avatar"] = built.value
	out["ok"] = reader.ok()
	return out


static func write_player(player_id: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	return writer.to_bytes()


static func read_player(reader: DotNetReader) -> int:
	return reader.read_varint()


# --- MAP -------------------------------------------------------------------

## One [DotMapMessage], as JSON inside a byte cap. Empty when it would not fit.
##
## [b]JSON rather than a field-by-field encoding[/b], because dot-map owns these shapes
## and a game that re-encoded each one would have to change whenever dot-map added a
## field to [method DotMapDef.to_dictionary] — silently dropping it until then. Every
## value in them is a string, a bool or a number, and JSON's one lossy conversion, an
## int returned as a float, is one `from_dictionary` already undoes with `int()`.
##
## [b]Empty rather than truncated.[/b] [method DotNetWriter.write_string] cuts at the cap
## without a word, and half a JSON document is a parse failure on the far end that looks
## like a hostile host. The caller refuses to send an empty body and says why.
static func write_map_message(payload: Dictionary, max_bytes: int = MAP_MESSAGE_BYTES) -> PackedByteArray:
	var text := JSON.stringify(payload)
	if text.to_utf8_buffer().size() > max_bytes:
		return PackedByteArray()
	var writer := _w()
	writer.write_string(text, max_bytes)
	return writer.to_bytes()


## The dictionary back, or an empty one for anything that is not a JSON object.
##
## Empty is safe to hand straight to dot-map: [method DotMapMessage.is_map_message] says
## no to it, and both halves of the protocol return false without acting.
static func read_map_message(reader: DotNetReader, max_bytes: int = MAP_MESSAGE_BYTES) -> Dictionary:
	var text := reader.read_string(max_bytes)
	if not reader.ok() or text == "":
		return {}
	# `JSON.new().parse` rather than `JSON.parse_string`: the static one pushes an engine
	# error for bad input, and bad input here is whatever a peer chose to send.
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var parsed: Variant = json.data
	return parsed as Dictionary if parsed is Dictionary else {}


# --- TIMER / FINISH --------------------------------------------------------

static func write_timer(player_id: int, state: DotTimerNet.RunState) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	state.write(writer)
	return writer.to_bytes()


static func read_timer(reader: DotNetReader) -> Dictionary:
	var player_id := reader.read_varint()
	var state := DotTimerNet.RunState.new()
	state.read(reader)
	return {"player_id": player_id, "state": state, "ok": reader.ok()}


static func write_finish(player_id: int, finish: DotTimerNet.Finish) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	finish.write(writer)
	return writer.to_bytes()


static func read_finish(reader: DotNetReader) -> Dictionary:
	var player_id := reader.read_varint()
	var finish := DotTimerNet.Finish.new()
	finish.read(reader)
	return {"player_id": player_id, "finish": finish, "ok": reader.ok()}


# --- NOTICE / RECORD -------------------------------------------------------

static func write_text(player_id: int, text: String) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	writer.write_string(text, TEXT_BYTES)
	return writer.to_bytes()


static func read_text(reader: DotNetReader) -> Dictionary:
	return {"player_id": reader.read_varint(), "text": reader.read_string(TEXT_BYTES)}


# --- VOTE ------------------------------------------------------------------

## Bytes a cue id may occupy. An id, never a path.
const CUE_BYTES := 32

## A cue id (empty for none) and a countdown second (0 for none). What the id sounds like
## is the client's catalogue; an id it lacks is silence, which is dot-audio's rule.
static func write_vote(cue: String, seconds_left: int, runoff: bool) -> PackedByteArray:
	var writer := _w()
	writer.write_string(cue, CUE_BYTES)
	writer.write_uint(clampi(seconds_left, 0, 255), 8)
	writer.write_bool(runoff)
	return writer.to_bytes()


static func read_vote(reader: DotNetReader) -> Dictionary:
	var out := {
		"cue": reader.read_string(CUE_BYTES),
		"seconds_left": reader.read_uint(8),
		"runoff": reader.read_bool(),
	}
	out["ok"] = reader.ok()
	return out


# --- CLOCK -----------------------------------------------------------------

## The vote's clock as [method DotVoteClockView.state_of] describes it: whether there is
## one, the whole seconds left, and whether it is counting. A client counts it down
## itself between messages; the server sends another only when that count would be wrong.
## Times as whole microseconds in a varint: exact to the thousandth the boards are sorted
## by, at any length of run, where a float32 starts losing them past an hour.
static func write_standing(player_id: int, standing: Dictionary) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	writer.write_varint(maxi(int(round(float(standing.get("pb", 0.0)) * 1000000.0)), 0))
	writer.write_varint(maxi(int(round(float(standing.get("wr", 0.0)) * 1000000.0)), 0))
	writer.write_varint(maxi(int(standing.get("rank", 0)), 0))
	writer.write_varint(maxi(int(standing.get("total", 0)), 0))
	return writer.to_bytes()


static func read_standing(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"pb": float(reader.read_varint()) / 1000000.0,
		"wr": float(reader.read_varint()) / 1000000.0,
		"rank": reader.read_varint(),
		"total": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


## The most stage lines a STAGE_REF is believed to carry; a count past it is a corrupt
## message, refused whole rather than allocating for it.
const MAX_STAGE_REF := 128


## A splits comparison as [method G2GGame.stage_reference] shapes it. Times are whole
## microseconds in varints (exact, like STANDING); a split or best that does not exist is 0.
## Splits are written for stages 1..n and bests for sections 1..n + 1.
static func write_stage_ref(player_id: int, reference: Dictionary) -> PackedByteArray:
	var writer := _w()
	var stages := clampi(int(reference.get("stages", 0)), 0, MAX_STAGE_REF)
	writer.write_varint(player_id)
	writer.write_varint(maxi(int(reference.get("track", 0)), 0))
	writer.write_string(str(reference.get("style", "")), 32)
	writer.write_varint(stages)
	for which in ["pb", "wr"]:
		var set: Dictionary = reference.get(which, {})
		writer.write_varint(_us(float(set.get("total", 0.0))))
		var splits: Dictionary = set.get("splits", {})
		for k in range(1, stages + 1):
			writer.write_varint(_us(float(_split_of(splits, k))))
	var bests: Dictionary = reference.get("bests", {})
	for k in range(1, stages + 2):
		writer.write_varint(_us(float(bests.get(k, 0.0))))
	# Last, so an older reader that stops after the bests never sees it; a newer reader of an
	# older message runs out of bytes here and refuses the message whole.
	writer.write_string(str(reference.get("map", "")), 64)
	return writer.to_bytes()


static func read_stage_ref(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"track": reader.read_varint(),
		"style": reader.read_string(32),
	}
	var stages := reader.read_varint()
	out["stages"] = stages
	if stages > MAX_STAGE_REF:
		out["ok"] = false
		return out
	for which in ["pb", "wr"]:
		var total := float(reader.read_varint()) / 1000000.0
		var splits := {}
		for k in range(1, stages + 1):
			var t := float(reader.read_varint()) / 1000000.0
			if t > 0.0:
				splits[k] = t
		out[which] = {"splits": splits, "total": total}
	var bests := {}
	for k in range(1, stages + 2):
		var t := float(reader.read_varint()) / 1000000.0
		if t > 0.0:
			bests[k] = t
	out["bests"] = bests
	out["map"] = reader.read_string(64)
	out["ok"] = reader.ok()
	return out


static func _us(seconds: float) -> int:
	return maxi(int(round(seconds * 1000000.0)), 0)


## A split by stage number whether the record keyed it with an int or a string (JSON).
static func _split_of(splits: Dictionary, k: int) -> Variant:
	return splits.get(k, splits.get(str(k), 0.0))


static func write_clock(state: Dictionary) -> PackedByteArray:
	var writer := _w()
	writer.write_bool(bool(state.get("has_clock", false)))
	writer.write_varint(maxi(int(state.get("seconds_left", 0)), 0))
	writer.write_bool(bool(state.get("running", false)))
	return writer.to_bytes()


static func read_clock(reader: DotNetReader) -> Dictionary:
	var out := {
		"has_clock": reader.read_bool(),
		"seconds_left": reader.read_varint(),
		"running": reader.read_bool(),
	}
	out["ok"] = reader.ok()
	return out


# --- Requests --------------------------------------------------------------

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


# --- NPC -------------------------------------------------------------------

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


# --- RULES -----------------------------------------------------------------

## A RULES body is what a hostile or broken server can make a client parse. Forty-odd
## public commands with their one-line help come to about 3 KB; the cap leaves room for a
## server with twice as many and refuses anything that is not a command list.
const RULES_BYTES := 12288

## JSON rather than fields, and that is the one place in this file it is: the command
## list is a variable-length table of strings a client only DRAWS, so a typed encoding
## buys nothing a reader can check, and the two flags ride along rather than costing a
## second event kind. [code]{"flashlight": bool, "thirdperson": bool, "commands": [[name,
## help], ...]}[/code].
##
## [b]Shortened from the end of the list, never cut.[/b] `write_string` truncates at the
## cap, and a JSON document cut anywhere is one that does not parse — which would cost the
## client the two flags along with the commands it could not fit.
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


# --- MAPS ------------------------------------------------------------------

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


# --- SPECTATE / SPECTATORS -------------------------------------------------------

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
