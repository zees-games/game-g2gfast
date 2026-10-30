extends RefCounted

## Carries the weapon layer over the link: the server's three signals out as events, a joiner's
## snapshot, and a client's events back into the layer's mirror calls. [member sink] is
## `(peer_id, kind, body)`, peer 0 meaning every ready peer, so a check can wire one end to the other.

const G2GArsenal := preload("../g2g_arsenal.gd")
const G2GEvents := preload("g2g_events.gd")
const G2GWeaponLayer := preload("../g2g_weapon_layer.gd")
const EXTENT := G2GEvents.NPC_EXTENT

var sink: Callable = Callable()
var _watched: DotWeaponDrops = null


func _init(to: Callable = Callable()) -> void:
	sink = to


## Server, every tick: follows whichever layer the game has now (a map change builds a new one).
func watch(layer: G2GWeaponLayer) -> void:
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == _watched:
		return
	_watched = drops
	if drops != null:
		drops.dropped.connect(_on_dropped)
		drops.settled.connect(_on_settled)
		drops.removed.connect(_on_removed)


## Every weapon lying about, at rest where it lies, for a joiner.
func send_snapshot(peer_id: int, layer: G2GWeaponLayer) -> void:
	if layer == null or layer.drops == null:
		return
	for entry in layer.drops.snapshot():
		sink.call(peer_id, G2GEvents.Kind.WEAPON_DROP,
			_drop_body(entry["state"], int(entry["id"]), entry["at"], Vector3.ZERO, float(entry["life"]), bool(entry["rest"])))


## Client: whether [param kind] was a weapon event, applied to the layer's mirror.
func apply(kind: int, reader: DotNetReader, layer: G2GWeaponLayer) -> bool:
	if kind < G2GEvents.Kind.WEAPON_DROP or kind > G2GEvents.Kind.WEAPON_GONE:
		return false
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == null:
		return true
	match kind:
		G2GEvents.Kind.WEAPON_DROP:
			var d := read_drop(reader)
			if bool(d["ok"]):
				drops.mirror_drop(int(d["id"]), {"id": G2GArsenal.id_from_wire(int(d["weapon"])),
					"magazine": int(d["magazine"]), "reserve": int(d["reserve"])},
					d["at"], d["velocity"], float(d["seconds"]), bool(d["rest"]))
		G2GEvents.Kind.WEAPON_SETTLED:
			var s := read_settled(reader)
			if bool(s["ok"]):
				drops.mirror_settled(int(s["id"]), s["at"])
		_:
			var gone := read_gone(reader)
			if bool(gone["ok"]):
				drops.mirror_removed(int(gone["id"]))
	return true


func _on_dropped(id: int, state: Dictionary, at: Transform3D, velocity: Vector3, _owner: int) -> void:
	sink.call(0, G2GEvents.Kind.WEAPON_DROP, _drop_body(state, id, at, velocity, _watched.rules.lifetime, false))


func _on_settled(id: int, at: Transform3D) -> void:
	sink.call(0, G2GEvents.Kind.WEAPON_SETTLED, write_settled(id, at))


func _on_removed(id: int, _taker: int) -> void:
	var w := DotNetWriter.new()
	w.write_varint(id)
	sink.call(0, G2GEvents.Kind.WEAPON_GONE, w.to_bytes())


func _drop_body(state: Dictionary, id: int, at: Transform3D, velocity: Vector3, seconds: float, rest: bool) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	w.write_varint(G2GArsenal.wire_of(StringName(state["id"])))
	w.write_varint(maxi(0, int(state.get("magazine", 0))))
	w.write_varint(maxi(0, int(state.get("reserve", 0))))
	_write_pose(w, at)
	w.write_vector3_range(velocity, -64.0, 64.0, 12)
	w.write_varint(ceili(maxf(seconds, 0.0)))
	w.write_bool(rest)
	return w.to_bytes()


static func write_settled(id: int, at: Transform3D) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	_write_pose(w, at)
	return w.to_bytes()


static func read_drop(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "weapon": reader.read_varint(),
		"magazine": reader.read_varint(), "reserve": reader.read_varint()}
	out["at"] = _read_pose(reader)
	out["velocity"] = reader.read_vector3_range(-64.0, 64.0, 12)
	out["seconds"] = reader.read_varint()
	out["rest"] = reader.read_bool()
	out["ok"] = reader.ok()
	return out


static func read_settled(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "at": _read_pose(reader)}
	out["ok"] = reader.ok()
	return out


static func read_gone(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint()}
	out["ok"] = reader.ok()
	return out


static func _write_pose(w: DotNetWriter, at: Transform3D) -> void:
	w.write_vector3_range(at.origin, -EXTENT, EXTENT, 20)
	w.write_quaternion(at.basis.get_rotation_quaternion(), 9)


static func _read_pose(reader: DotNetReader) -> Transform3D:
	var origin := reader.read_vector3_range(-EXTENT, EXTENT, 20)
	return Transform3D(Basis(reader.read_quaternion(9)), origin)
