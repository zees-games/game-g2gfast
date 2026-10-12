extends Node3D

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GMap := preload("../game/g2g_map.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")

## Renders an imported map to PNGs and exits. `tools/bsp_preview.sh <id> <out.png>`.
##
## An imported map is the one thing in this repository whose bugs are invisible to
## every assertion available: the vertex count can be right, the manifest can be
## right, every material can be correctly configured, and the map can still be
## inside-out, unlit or 200 times too big. This file's own lesson, four times over.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_kitsune"
	var out := args[1] if args.size() > 1 else "user://bsp_preview.png"
	var shots := int(args[2]) if args.size() > 2 else 4

	# Through the catalogue, like everything else -- an imported map has no scene of
	# its own any more, so resolving one by path only works for the hand-written ones.
	var catalogue := G2GMapCatalogue.discover()
	var def := catalogue.get_map(StringName(id))
	if def == null:
		push_error("no map '%s'. Known: %s" % [id, ", ".join(
			catalogue.maps.map(func(m: DotMapDef) -> String: return String(m.id)))])
		get_tree().quit(1)
		return
	var packed: PackedScene = load(def.scene_path)
	if packed == null:
		push_error("no scene for %s at %s" % [id, def.scene_path])
		get_tree().quit(1)
		return
	var map: Node3D = packed.instantiate()
	if map is G2GBspMap:
		(map as G2GBspMap).build_from(def)
	add_child(map)
	await get_tree().process_frame

	# [b]Set on the MATERIALS, not on the node.[/b] The comment that stood here said
	# to assign these before `add_child` because `_build()` runs from `_ready()`. It
	# does not: `build_from` above builds there and then, so every material already
	# exists by the time either line runs and an assignment to the export reaches
	# nothing. Both overrides had never once changed a pixel -- the two renders that
	# proved it came out byte-identical.
	if args.size() > 4 or args.size() > 5:
		for mi: MeshInstance3D in _meshes(map):
			for i in range(mi.get_surface_override_material_count()):
				var m := mi.get_surface_override_material(i) as ShaderMaterial
				if m == null:
					continue
				# `-` (or anything not a number) leaves the map's own value, so a caller can
				# reach `keepenv` without overriding the two things it is trying to look at.
				if args.size() > 4 and args[4].is_valid_float():
					m.set_shader_parameter("ambient", float(args[4]))
				if args.size() > 5 and args[5].is_valid_float():
					m.set_shader_parameter("light_boost", float(args[5]))

	# `lm` overrides every material to show the baked lighting alone. A map whose
	# albedo is black -- kitsune's is, over 5892 triangles of `tools/toolsblack` --
	# renders identically whether the lightmap works or is never sampled at all, so
	# there is no camera angle that answers the question. This one does.
	if args.size() > 6 and args[6] == "lm":
		for mi: MeshInstance3D in _meshes(map):
			for i in range(mi.get_surface_override_material_count()):
				var m := mi.get_surface_override_material(i) as ShaderMaterial
				if m == null:
					continue
				m.set_shader_parameter("has_albedo", false)
				m.set_shader_parameter("tint", Color.WHITE)
				m.set_shader_parameter("ambient", 0.0)
				m.set_shader_parameter("light_boost", 1.0)

	# PREVIEW_MARK=<substring> draws every surface whose material names it in flat
	# magenta, double-sided. A face that is missing in a frame is either not drawn or
	# drawn and then covered, and this is what tells the two apart.
	var mark := OS.get_environment("PREVIEW_MARK")
	if mark != "":
		var flat := StandardMaterial3D.new()
		flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flat.albedo_color = Color.MAGENTA
		if OS.get_environment("PREVIEW_MARK_CULL") == "":
			flat.cull_mode = BaseMaterial3D.CULL_DISABLED
		for mi: MeshInstance3D in _meshes(map):
			for i in range(mi.mesh.get_surface_count()):
				if mi.mesh.surface_get_name(i).contains(mark):
					mi.set_surface_override_material(i, flat)

	var aabb := _world_aabb(map)
	print("[preview] %s aabb pos=%s size=%s m" % [id, aabb.position, aabb.size])

	# [b]The map brings its own [WorldEnvironment] and it was silently winning this one.[/b]
	# A second `WorldEnvironment` in a tree does not merge with the first and does not
	# warn at runtime -- one of them is simply used. So every diagnostic render this tool
	# has ever produced was drawn under the MAP's tone map, fog and glow while its own
	# code below said, plainly, that it was drawing under a neutral one. That is the
	# worst kind of instrument: it reports a number that is about something else.
	#
	# It matters most for `lm`, whose entire job is to show the baked lighting with
	# nothing on top of it. Under the map's own environment a lightmap spanning code
	# values 9 to 249 rendered as a flat 167-to-227 wash and the lighting looked broken
	# when it was fine -- the fog was what flattened it.
	#
	# So the map's is taken out and named, rather than left to chance. `keepenv` as the
	# fourth argument puts it back, for the one question this tool cannot otherwise
	# answer: what the map looks like as the GAME draws it.
	var keep_env := args.has("keepenv")
	for found: WorldEnvironment in _environments(map):
		print("[preview] map environment: %s%s" % [found.name,
			" (kept)" if keep_env else " (removed; pass keepenv to keep it)"])
		if not keep_env:
			found.get_parent().remove_child(found)
			found.queue_free()
		# PREVIEW_NOGLOW=1 turns the map's glow off, to tell a surface that is bright from
		# one the bloom made bright (surf_lt_unicorn's white portal discs, 2026-10-11).
		elif OS.get_environment("PREVIEW_NOGLOW") != "" and found.environment != null:
			found.environment.glow_enabled = false

	if not keep_env:
		var env := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.05, 0.06, 0.09)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.30, 0.32, 0.38)
		e.ambient_light_energy = 0.5
		env.environment = e
		add_child(env)

	var cam := Camera3D.new()
	cam.far = 6000.0
	add_child(cam)

	# From the spawn, turning on the spot. An orbit of a 600 m map at 1600x900 is
	# three pixels per ramp and cannot tell "unlit" from "small", which is the whole
	# question an imported map raises.
	var from_spawn := args.size() > 3 and args[3] == "spawn"
	var c := aabb.get_center()
	var r: float = maxf(aabb.size.length() * 0.55, 1.0)
	var eye := c
	# PREVIEW_PITCH (radians, up is positive) looks up from the spawn -- at a 3D skybox,
	# say, which a spawn in a canyon never shows at the default slight look down.
	var pitch := -0.15
	if OS.get_environment("PREVIEW_PITCH").is_valid_float():
		pitch = float(OS.get_environment("PREVIEW_PITCH"))
	if from_spawn and map is G2GMap:
		eye = (map as G2GMap).spawn_for(0) + Vector3(0.0, 1.2, 0.0)
	# PREVIEW_EYE="x,y,z" (metres, Godot axes) stands somewhere other than the spawn --
	# ON a ramp, say, because a face that draws from across the canyon and vanishes when
	# a player is riding it is invisible from every spawn frame. PREVIEW_YAW turns the
	# first shot (radians, 0 looks down -Z).
	var eye_env := OS.get_environment("PREVIEW_EYE").split(",")
	var yaw0 := 0.6
	if eye_env.size() == 3 and from_spawn:
		eye = Vector3(float(eye_env[0]), float(eye_env[1]), float(eye_env[2]))
		yaw0 = 0.0
	if OS.get_environment("PREVIEW_YAW").is_valid_float():
		yaw0 = float(OS.get_environment("PREVIEW_YAW"))
	for i in range(shots):
		var a := TAU * float(i) / float(shots) + yaw0
		if from_spawn:
			cam.global_position = eye
			cam.rotation = Vector3(pitch, a, 0.0)
		else:
			cam.global_position = c + Vector3(cos(a) * r, r * 0.42, sin(a) * r)
			cam.look_at(c, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(out.replace(".png", "_%d.png" % i))
		print("[preview] wrote ", out.replace(".png", "_%d.png" % i))
	get_tree().quit()


func _world_aabb(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in _meshes(root):
		var b := mi.global_transform * mi.get_aabb()
		if first:
			box = b; first = false
		else:
			box = box.merge(b)
	return box


## Every [WorldEnvironment] in a subtree. See the block that calls it.
func _environments(root: Node) -> Array[WorldEnvironment]:
	var out: Array[WorldEnvironment] = []
	if root is WorldEnvironment:
		out.append(root as WorldEnvironment)
	for child in root.get_children():
		out.append_array(_environments(child))
	return out


func _meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
