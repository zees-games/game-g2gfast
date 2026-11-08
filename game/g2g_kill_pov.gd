extends RefCounted

## What a kill view records of the killer's screen beyond the camera: the weapon in hand.
## g2gfast has no view model, magazine or aim-down-sights, so the rest of dot-replay's aux stays zero.

## Aux slot of the held weapon's id hash.
const WEAPON := 0

static var _names: Dictionary = {}


## The aux floats for [param p], sized to the ring's [param size] (a shorter ring gets what fits).
static func aux_of(p: Object, size: int = 1) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(size, 0))
	var held: Variant = p.get(&"held_weapon") if p != null else null
	var id := StringName(held) if held != null else &""
	if id != &"" and out.size() > WEAPON:
		out[WEAPON] = float(int(String(id).hash() & 0xFFFFFF))
	return out


## The display name of the weapon an aux hash names, or empty.
static func weapon_name(hash_value: float, defs: Dictionary) -> String:
	if _names.size() != defs.size():
		_names.clear()
		for k: Variant in defs:
			var def: Variant = defs[k]
			_names[int(String(k).hash() & 0xFFFFFF)] = def.display_name if def != null and def.display_name != "" else String(k)
	return String(_names.get(int(hash_value), ""))
