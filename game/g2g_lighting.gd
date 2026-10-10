extends RefCounted

## This game's lighting, which is [DotLightRig] and one decision of its own.
##
## [b]It used to be the implementation and is now the caller.[/b] Reading a map's own sun,
## ambient, fog and sky out of a manifest and turning them into an [Environment] is not a
## thing about a bhop timer — it is a thing about any game that loads a world somebody else
## authored — so it is dot-lighting now, with its own suite, and what stays here is the
## part that is genuinely this game's: which profile a machine gets.
##
## See docs/map-rendering.md, "Lighting: the map says how it is lit", for what the lighting block is and where it
## comes from.


## Applies the lighting a manifest carries and returns the sun.
static func apply(parent: Node3D, lighting: Dictionary) -> DirectionalLight3D:
	var sun := DotLightRig.apply(
		parent, DotLightDocument.from_dictionary(lighting), profile()
	)
	_recolour_white_sky(parent, lighting)
	_darken_black_sky(parent, lighting)
	return sun


## A clear day's zenith, for a sky this table does not know.
const CLEAR_SKY := Color(0.36, 0.55, 0.82)

## The colour of the top of a sky, by the name a map gives it, for a map whose ambient
## cannot say. Lower case, without Source's `_hdr` suffix.
##
## Stock Source skies are approximate zeniths of those skies, picked by eye, not measured
## (the textures are not in any pakfile here); the custom ones are the
## mapper's own `_ambient` on another imported map that names the same sky, which is the
## best evidence there is of what that sky looks like.
const SKY_TOPS := {
	# The stock skies the format ships with.
	"sky_day01_01": Color(0.37, 0.56, 0.82),
	"sky_day01_04": Color(0.40, 0.58, 0.80),
	"sky_day01_05": Color(0.42, 0.60, 0.82),
	"sky_day01_06": Color(0.45, 0.55, 0.70),
	"sky_day01_07": Color(0.40, 0.56, 0.78),
	"sky_day01_08": Color(0.38, 0.55, 0.80),
	"sky_day01_09": Color(0.42, 0.57, 0.78),
	"sky_day02_01": Color(0.52, 0.56, 0.62),
	"sky_dust": Color(0.55, 0.62, 0.72),
	"sky_borealis01": Color(0.12, 0.18, 0.30),
	"sky_wasteland02": Color(0.55, 0.60, 0.62),
	"militia": Color(0.62, 0.68, 0.76),
	"italy": Color(0.40, 0.58, 0.84),
	"office": Color(0.46, 0.52, 0.60),
	"assault": Color(0.50, 0.58, 0.68),
	"tides": Color(0.42, 0.62, 0.86),
	"cx": Color(0.40, 0.56, 0.80),
	# Custom skies: the ambient another imported map set for the same name.
	"mpa52": Color(0.53, 0.73, 0.93),  # bhop_lego2's 0.85/0.94/0.98, deepened: near white again
	"space_13": Color(0.46, 0.42, 0.76),  # bhop_supernova
	"mpa104": Color(0.49, 0.62, 0.80),  # surf_mesa, surf_greensway, bhop_tesquo_v2
	"hav": Color(0.56, 0.69, 0.84),  # bhop_arcane_v2, bhop_grove
}


## The sky-top colour a map should have instead of its ambient, or transparent when its
## ambient is usable.
##
## [b]Four maps had a white sky.[/b] dot-lighting takes the top of the procedural sky from
## the map's `_ambient`, which in Source is the colour the sky lit the map with. A mapper who
## never set it compiles with the editor's default `255 255 255`, and surf_beginner2, bhop_aztec,
## bhop_mario_fxd and bhop_evolve are drawn under a blank white dome. That white is not a
## statement about the sky, so here the sky is looked up by its name instead (the name is
## in the file; the texture set is another game's and is not). Only the sky changes: the
## rest of the environment keeps the map's ambient as it stands.
static func white_sky_replacement(lighting: Dictionary) -> Color:
	var sun: Dictionary = lighting.get("sun", {}) if lighting.get("sun") is Dictionary else {}
	var ambient: Variant = sun.get("ambient_colour", null)

	if not (ambient is Array) or (ambient as Array).size() < 3:
		return Color(0, 0, 0, 0)

	for c: Variant in (ambient as Array).slice(0, 3):
		if float(c) < 0.99:
			return Color(0, 0, 0, 0)

	var name := str(lighting.get("sky_name", "")).to_lower().trim_suffix("_hdr")
	return SKY_TOPS.get(name, CLEAR_SKY)


static func _recolour_white_sky(parent: Node3D, lighting: Dictionary) -> void:
	var top := white_sky_replacement(lighting)

	if top.a == 0.0:
		return

	for child in parent.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null or world.environment.sky == null:
			continue

		var mat := world.environment.sky.sky_material as ProceduralSkyMaterial

		if mat == null:
			continue

		# The lower half mirrors the upper on this game's maps (see [method profile]).
		var mirrored := mat.ground_bottom_color == mat.sky_top_color
		mat.sky_top_color = top
		if mirrored:
			mat.ground_bottom_color = top


## Whether a map's sky is black by name: the whole of it, horizon and below included.
##
## [b]A sky called black is a statement about the sky, and nothing else in the file is.[/b]
## surf_kitsune names `blacksky` and sets no sun, no ambient and no fog, so dot-lighting
## drew it under its default daylight dome: a pale grey-blue all round a map built as neon
## lines on black, which is the brightest thing on screen wherever a wall is open
## (Christian's 2026-10-08 footage: "way too bright / distracting"). The name is read the
## way the importer reads `tools/toolsblack` -- a black is trusted when the name says so.
static func is_black_sky(lighting: Dictionary) -> bool:
	return str(lighting.get("sky_name", "")).to_lower().contains("black")


static func _darken_black_sky(parent: Node3D, lighting: Dictionary) -> void:
	if not is_black_sky(lighting):
		return

	for child in parent.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null:
			continue

		var env := world.environment
		env.background_color = Color.BLACK
		env.fog_light_color = Color.BLACK
		var mat := env.sky.sky_material as ProceduralSkyMaterial if env.sky != null else null

		if mat == null:
			continue

		mat.sky_top_color = Color.BLACK
		mat.sky_horizon_color = Color.BLACK
		mat.ground_horizon_color = Color.BLACK
		mat.ground_bottom_color = Color.BLACK


## What this machine draws.
##
## [b]Shadows off in a browser and glow kept, which is dot-lighting's `web()` and is doubly
## right here.[/b] A surf map is a large open volume — a shadow pass costs what is in frame
## and on a canyon that is the canyon — while the glow is what makes a neon strip read as a
## light, and a neon strip is how one of these maps signposts the route. Dropping the thing
## a player navigates by to save a cost they cannot see would be the wrong trade even if
## the two cost the same.
static func profile() -> DotLightProfile:
	var p := DotLightProfile.web() if _is_web() else DotLightProfile.high()
	# Every map this game plays floats inside its sky -- ramps and platforms in a skybox,
	# with nothing under the horizon but more sky -- so the dark "ground" half an enclosed
	# level wants turned every glance down between two ramps into a floor that is not
	# there. Measured against the source game's own screenshot of surf_kitsune.
	p.sky_below_horizon = true
	return p


static func _is_web() -> bool:
	# The family rule is to ask about the capability rather than the platform. There is no
	# capability query for "this GPU is slow", so this is one of the few places where the
	# platform IS the question: a browser's renderer is the constraint, whatever it runs on.
	return OS.has_feature("web")


## What a map's lighting amounts to, for a console command or a bug report.
static func describe_lines(lighting: Dictionary) -> PackedStringArray:
	return DotLightDocument.from_dictionary(lighting).describe_lines()
