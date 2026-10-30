extends RefCounted

const G2GProgress := preload("res://game/g2g_progress.gd")

## Stats are filed under dot-game's stable key; achievements and records stay on the record key.

class _Platform extends RefCounted:
	func key() -> String:
		return "plat-9001"


class _Identity extends RefCounted:
	var uid := "acct-9001"
	var is_guest := false
	var claims: Dictionary = {}


## Failure descriptions, empty when the split holds.
static func run(progress: G2GProgress) -> Array[String]:
	var bad: Array[String] = []
	var session := DotClientSession.new()
	session.userid = 9001
	session.identity = _Identity.new()
	session.data["platform"] = _Platform.new()
	progress.note_session(session)
	var id := &"u9001"
	await progress.begin(id, "Keyed")
	if progress._stats_key(id) != &"plat-9001":
		bad.append("stats key is %s" % progress._stats_key(id))
	if progress.relay.record_of.get(&"plat-9001", &"") != progress._key(id):
		bad.append("the relay does not map the stats key to the record key")
	await progress.leave(id)
	if progress._stats_key(id) != progress._key(id) or progress.relay.record_of.has(&"plat-9001"):
		bad.append("leave left the stats key behind")
	return bad
