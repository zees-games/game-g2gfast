shader_type spatial;
// A surface lit by the lighting its own map compiler baked, and by nothing else.
//
// `unshaded` on purpose. The lightmap IS the lighting -- Source spent a compile
// working out that this luxel is lit magenta by a neon strip six metres away -- and
// running it through Godot's lambert term as well would light it twice and wash the
// colour out. A dynamic light in a surf map has nothing to light: the world is
// static and the only mover is the player.
//
// [b]Opaque, and the ALPHA write that used to be at the bottom of `fragment()` is
// why.[/b] Godot decides a spatial shader is TRANSPARENT by looking at whether it
// writes ALPHA -- not at what it writes -- so one unconditional `ALPHA = base.a;`
// moved every surface in every imported map into the alpha pass, where depth is not
// written and geometry is sorted per surface rather than per pixel. The result is a
// map that draws through itself: the terrain behind a wall comes out in front of it,
// a concrete floor reads as brown sand, and the whole thing looks like a map whose
// textures are missing. It rendered that way for as long as there have been imported
// maps and no assertion could see it, because every value involved is correct.
//
// The twenty surfaces across the eight maps that really are translucent get
// `g2g_bsp_translucent.gdshader`, which is this file plus the ALPHA write. Two
// shaders, because a shader cannot decide at runtime which pass it belongs to.
render_mode unshaded, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool has_albedo = true;
// The second texture of a `WorldVertexTransition` material, shown by vertex alpha
// (COLOR.a, 0 = the first texture). Only a surface whose manifest has `texture2` and an
// `alpha_offset` sets it; every other surface has no COLOR array and never reads it.
uniform sampler2D albedo2_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_albedo2 = false;
// A Kenney stand-in for a stock texture the map did not carry: pixel art, so sampled
// nearest rather than through albedo_tex's linear filter, which smears a 64 px tile
// into mud. See G2GStockSubstitutes.
uniform sampler2D pixel_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool pixel_art = false;
uniform vec2 pixel_scale = vec2(0.5, 0.5);
// How much of the albedo texture one unit of UV is.
//
// 1.0 for a texture the map carried, whose UVs are the ones the mapper placed. For a
// prototype-textured surface the mesh carries UVs in GRID SQUARES -- 64 of the genre's
// units each, the same size everywhere in the game -- and this is one over however many
// squares the installed tile happens to contain, which is the only part of the answer
// that belongs to the image rather than to the world. See tools/bsp_import.py.
uniform float uv_scale = 1.0;
// Baked light is tone-mapped into an 8-bit atlas, so the darks clamp to black.
// `ambient` lifts them back to where a player can see the geometry, which matters
// more in a movement game than fidelity to the original does.
uniform float ambient : hint_range(0.0, 1.0) = 0.10;
uniform float light_boost : hint_range(0.0, 4.0) = 1.35;
// Self-lit share of the colour, added after the light: a neon or hologram stand-in that
// stays bright in the dark. 0 for every surface unless a map's dressing file asks (G2GMapDressing).
uniform float glow : hint_range(0.0, 4.0) = 0.0;

// The player's own flashlight. `unshaded` means no light in the scene reaches this
// surface, so the one light a player carries is computed here, from a 4 x 1 float texture
// G2GFlashlight rewrites every frame and sets as this shader's DEFAULT for the parameter
// -- never per material, and never a `global uniform`, which a delivered pack cannot
// declare in the host's project settings. Black by default, which reads as off: a server,
// a suite and any build without the flashlight compile and draw exactly as before.
//
//   texel 0  position (world, m), on        texel 2  colour x energy, range (m)
//   texel 1  direction, cos outer           texel 3  cos inner, reference distance (m)
uniform sampler2D flashlight_tex : hint_default_black, filter_nearest, repeat_disable;

vec3 flashlight(vec3 world, vec3 normal) {
	vec4 at = texelFetch(flashlight_tex, ivec2(0, 0), 0);
	if (at.w < 0.5) {
		return vec3(0.0);
	}
	vec4 aim = texelFetch(flashlight_tex, ivec2(1, 0), 0);
	vec4 light = texelFetch(flashlight_tex, ivec2(2, 0), 0);
	vec4 shape = texelFetch(flashlight_tex, ivec2(3, 0), 0);
	vec3 to = world - at.xyz;
	float dist = max(length(to), 0.001);
	vec3 dir = to / dist;
	float along = dot(dir, aim.xyz);
	// A core and a spill: the beam is brightest in its middle and fades to its edge, which
	// is what the genre's flashlight texture draws.
	float spill = smoothstep(aim.w, mix(aim.w, shape.x, 0.35), along);
	float core = smoothstep(mix(aim.w, shape.x, 0.5), shape.x, along);
	float cone = spill * 0.55 + core * 0.45;
	// One over the distance past the reference, and gone at the range.
	float fall = min(shape.y / dist, 1.0) * (1.0 - smoothstep(light.w * 0.7, light.w, dist));
	float facing = max(dot(normal, -dir), 0.0);
	return light.rgb * cone * fall * facing;
}

void fragment() {
	vec4 base = has_albedo ? texture(albedo_tex, UV * uv_scale) * tint : tint;
	if (pixel_art) {
		base = texture(pixel_tex, UV * pixel_scale) * tint;
	}
	if (has_albedo2) {
		base = mix(base, texture(albedo2_tex, UV * uv_scale) * tint, clamp(COLOR.a, 0.0, 1.0));
	}
	vec3 lm = texture(lightmap_tex, UV2).rgb;
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ALBEDO = base.rgb * (lm * light_boost + ambient + flashlight(world, normal) + glow);
}
