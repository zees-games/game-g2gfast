extends RefCounted

## Per-map additions for an imported map whose original is not in the pack: a sky, a
## self-lit material, and props, from Kenney (CC0) stand-ins only.
##
## [b]Why a file per map and not more rows in substitutes.json.[/b] That table answers
## "what does this stock material look like" for every map; this answers "what does THIS
## map's area need that the pack could not carry" (a sky, a neon, a lantern on a ledge),
## which no other map shares. Data in `maps/dressing/<id>.json`, drawn by this class, so
## the map importer and the pack stay untouched and a map without a file is unchanged.
##
## A `box` takes `height` and `depth` as multiples of `size`: a banner board is one wide, thin box.
##
## [codeblock]
## {
##   "sky":  {"top": [r,g,b], "horizon": [r,g,b], "ground": [r,g,b]},
##   "bloom": true,
##   "materials": [{"match": "neons/*", "glow": 1.2, "tint": [r,g,b]}],   # first match wins
##   "props": [{"model": "nature/plant_bushLarge", "at": [x,y,z], "yaw": 0, "scale": 1},
##             {"model": "holiday/lantern", "at": [x,y,z], "light": {"colour": [r,g,b], "energy": 2, "range": 12, "height": 1}},
##             {"shape": "sphere", "size": 2.0, "colour": [r,g,b], "at": [x,y,z]}]
## }
## [/codeblock]
## Positions are metres in the map's own space (the numbers a [code]shot.gd[/code] pose
## uses). Props have no collision: they are scenery, and a stand-in must never change a
## route. [code]model[/code] is under [code]res://props/kenney/[/code].

const G2GPaths := preload("g2g_paths.gd")

const CHANNEL := "g2g.dressing"
const DIR := "res://maps/dressing/%s.json"
const MODELS := "res://props/kenney/%s.glb"


## The dressing for a map, or an empty dictionary when it has none.
static func load_for(map_id: String) -> Dictionary:
	var path := G2GPaths.rebase(DIR % map_id)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		DotLog.warn(CHANNEL, "a dressing file is not a JSON object", {"path": path})
		return {}
	return parsed


## Applies a map's dressing under [param map]: the sky, the glow on its materials, and a
## `Dressing` node of props. Returns how many props were placed.
static func apply(map: Node3D, map_id: String) -> int:
	var data := load_for(map_id)
	if data.is_empty():
		return 0
	_sky(map, data.get("sky", {}), bool(data.get("bloom", false)))
	_materials(map, data.get("materials", []))
	var placed := _props(map, data.get("props", []))
	DotLog.debug(CHANNEL, "map dressed", {"map": map_id, "props": placed})
	return placed


static func _colour(v: Variant, fallback: Color) -> Color:
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _sky(map: Node3D, sky: Variant, bloom: bool) -> void:
	for child in map.get_children():
		var world := child as WorldEnvironment
		if world == null or world.environment == null:
			continue
		var env := world.environment
		if bloom:
			env.glow_enabled = true
		if not (sky is Dictionary) or (sky as Dictionary).is_empty():
			return
		var d: Dictionary = sky
		var mat := ProceduralSkyMaterial.new()
		mat.sky_top_color = _colour(d.get("top"), Color(0.2, 0.4, 0.8))
		mat.sky_horizon_color = _colour(d.get("horizon"), Color(0.6, 0.7, 0.9))
		mat.ground_horizon_color = mat.sky_horizon_color
		mat.ground_bottom_color = _colour(d.get("ground"), Color(0.1, 0.1, 0.15))
		# A packed sky, when the map had one, was set on `env.sky`; a dressing sky
		# replaces it on purpose: it exists for the maps whose own faces are not here.
		env.sky = Sky.new()
		env.sky.sky_material = mat
		env.background_mode = Environment.BG_SKY
		return


## A surface's override material is its own [ShaderMaterial] (one per surface), so
## setting a parameter here touches only the surfaces whose material name matches.
static func _materials(map: Node3D, rules: Variant) -> void:
	if not (rules is Array) or (rules as Array).is_empty():
		return
	for node in map.get_children():
		var mi := node as MeshInstance3D
		var mesh := (mi.mesh as ArrayMesh) if mi != null else null
		if mesh == null:
			continue
		for at in range(mesh.get_surface_count()):
			var surface_name: String = mesh.surface_get_name(at).to_lower()
			var mat := mi.get_surface_override_material(at) as ShaderMaterial
			if mat == null:
				continue
			for rule: Dictionary in rules:
				if not surface_name.match(str(rule.get("match", ""))):
					continue
				if rule.has("alpha"):
					_make_see_through(mat, clampf(float(rule["alpha"]), 0.02, 1.0))
				if rule.has("tint"):
					var tinted := _colour(rule["tint"], Color.WHITE)
					# Keep the see-through alpha `_make_see_through` just wrote.
					if rule.has("alpha") and not _is_water(mat):
						tinted.a = float(rule["alpha"])
					mat.set_shader_parameter("tint", tinted)
				if rule.has("glow"):
					mat.set_shader_parameter("glow", float(rule["glow"]))
				break


static func _is_water(mat: ShaderMaterial) -> bool:
	return mat.shader != null and mat.shader.resource_path.ends_with("g2g_bsp_water.gdshader")


## Draws a surface see-through at [param alpha]. The importer reads `$translucent` into
## the manifest, but a map's own panel material (a blue glass pane with an opaque PNG)
## can lack the flag, and then it is an opaque slab where the original was a window;
## this is the per-map fix that needs no importer change. Water already writes ALPHA:
## its two opacities are lowered instead (a pool's underside seen from a cave).
static func _make_see_through(mat: ShaderMaterial, alpha: float) -> void:
	if _is_water(mat):
		mat.set_shader_parameter("alpha_down", alpha)
		mat.set_shader_parameter("alpha_grazing", minf(1.0, alpha * 1.5))
		return
	var translucent := load(G2GPaths.rebase("res://game/g2g_bsp_translucent.gdshader")) as Shader
	if mat.shader != translucent:
		mat.shader = translucent
	var tint: Variant = mat.get_shader_parameter("tint")
	var c: Color = tint if tint is Color else Color.WHITE
	c.a = alpha
	mat.set_shader_parameter("tint", c)


static func _props(map: Node3D, props: Variant) -> int:
	if not (props is Array) or (props as Array).is_empty():
		return 0
	var holder := Node3D.new()
	holder.name = "Dressing"
	# Not collision, and not the world: the probes that sample `World` skip it.
	holder.set_meta(&"dot_no_collision", true)
	map.add_child(holder)
	var placed := 0
	for p: Dictionary in props:
		var node: Node3D = null
		if p.has("model"):
			var path := G2GPaths.rebase(MODELS % str(p["model"]))
			var scene := load(path) as PackedScene
			if scene == null:
				DotLog.warn(CHANNEL, "a dressing model did not load", {"path": path})
				continue
			node = scene.instantiate() as Node3D
		else:
			node = _primitive(p)
		if node == null:
			continue
		var at: Array = p.get("at", [0, 0, 0])
		node.position = Vector3(float(at[0]), float(at[1]), float(at[2]))
		node.rotation_degrees.y = float(p.get("yaw", 0.0))
		node.scale = Vector3.ONE * float(p.get("scale", 1.0))
		holder.add_child(node)
		if p.get("light") is Dictionary:
			# A lantern that does not light what is round it is a grey stick in a dark map.
			var l: Dictionary = p["light"]
			var omni := OmniLight3D.new()
			omni.light_color = _colour(l.get("colour"), Color(1.0, 0.8, 0.5))
			omni.light_energy = float(l.get("energy", 2.0))
			omni.omni_range = float(l.get("range", 12.0))
			omni.position = Vector3(0, float(l.get("height", 1.0)), 0)
			node.add_child(omni)
		placed += 1
	return placed


static func _primitive(p: Dictionary) -> MeshInstance3D:
	var size := float(p.get("size", 1.0))
	var mesh: PrimitiveMesh
	match str(p.get("shape", "sphere")):
		"box":
			var box := BoxMesh.new()
			box.size = Vector3(size, size * float(p.get("height", 1.0)), size * float(p.get("depth", 1.0)))
			mesh = box
		"cylinder":
			var cyl := CylinderMesh.new()
			cyl.top_radius = size * 0.5
			cyl.bottom_radius = size * 0.5
			cyl.height = size * float(p.get("height", 1.0))
			mesh = cyl
		_:
			var sph := SphereMesh.new()
			sph.radius = size * 0.5
			sph.height = size * float(p.get("height", 1.0))
			mesh = sph
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _colour(p.get("colour"), Color.WHITE)
	mat.roughness = 0.85
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi
