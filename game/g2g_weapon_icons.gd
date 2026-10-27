extends RefCounted

## The deathmatch weapons' pictures: weapon id to sprite tag; the rest is dot-ui's [DotWeaponIconStyle].

const TAGS := {
	&"deagle": &"pistol", &"knife": &"knife",
}

## The one instance the HUD and the console share.
static var shared: DotWeaponIconStyle = _make()


static func _make() -> DotWeaponIconStyle:
	var s := DotWeaponIconStyle.new()
	s.tags = TAGS
	return s
