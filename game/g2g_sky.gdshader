// An imported map's own 2D sky: six faces from its pakfile, in the engine's face layout.
//
// The layout is Quake's, which the format kept: faces rt, lf, bk, ft, up, dn are +X, -X,
// +Y, -Y, +Z and -Z in the map's own axes, and within a face (s, t) in -1..1 maps to the
// direction through Quake 2's st_to_vec table -- rt (1, -s, t), lf (-1, s, t), bk (s, 1, t),
// ft (-s, -1, t), up (-t, -s, 1), dn (t, -s, -1) -- with the texture's v running down
// from t = 1. The importer writes the faces (tools/bsp_import.py packed_sky_faces); a face
// table that was wrong would show as a horizon broken at the seams, which is how it is
// checked (tools/bsp_preview.sh, looking round from the spawn).
shader_type sky;

uniform sampler2D face_rt : source_color, filter_linear, repeat_disable;
uniform sampler2D face_lf : source_color, filter_linear, repeat_disable;
uniform sampler2D face_bk : source_color, filter_linear, repeat_disable;
uniform sampler2D face_ft : source_color, filter_linear, repeat_disable;
uniform sampler2D face_up : source_color, filter_linear, repeat_disable;
uniform sampler2D face_dn : source_color, filter_linear, repeat_disable;

// Applied to the sky as drawn; 1 shows the faces as the mapper painted them.
uniform float exposure = 1.0;
// A per-map dressing correction (maps/dressing/<id>.json, sky.tint / sky.overcast): the
// faces are multiplied by `tint`, and `overcast` (0..1) pulls them toward their own grey,
// then flattens that grey toward its mean so a clear sky's gradient reads as cloud cover.
uniform vec3 tint = vec3(1.0);
uniform float overcast : hint_range(0.0, 1.0) = 0.0;
uniform vec3 overcast_grey = vec3(0.55);

vec2 face_uv(vec2 st) {
	return vec2((st.x + 1.0) * 0.5, 1.0 - (st.y + 1.0) * 0.5);
}

void sky() {
	// Godot (x, y, z) is the map's (x, z, -y), so the map's direction is (x, -z, y).
	vec3 d = vec3(EYEDIR.x, -EYEDIR.z, EYEDIR.y);
	vec3 a = abs(d);
	vec3 colour;

	if (a.x >= a.y && a.x >= a.z) {
		if (d.x > 0.0) {
			colour = texture(face_rt, face_uv(vec2(-d.y, d.z) / a.x)).rgb;
		} else {
			colour = texture(face_lf, face_uv(vec2(d.y, d.z) / a.x)).rgb;
		}
	} else if (a.y >= a.z) {
		if (d.y > 0.0) {
			colour = texture(face_bk, face_uv(vec2(d.x, d.z) / a.y)).rgb;
		} else {
			colour = texture(face_ft, face_uv(vec2(-d.x, d.z) / a.y)).rgb;
		}
	} else {
		if (d.z > 0.0) {
			colour = texture(face_up, face_uv(vec2(-d.y, -d.x) / a.z)).rgb;
		} else {
			colour = texture(face_dn, face_uv(vec2(-d.y, d.x) / a.z)).rgb;
		}
	}

	float luma = dot(colour, vec3(0.299, 0.587, 0.114));
	colour = mix(colour, mix(vec3(luma), overcast_grey, 0.5), overcast);
	COLOR = colour * tint * exposure;
}
