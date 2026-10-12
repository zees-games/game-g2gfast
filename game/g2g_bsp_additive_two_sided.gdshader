shader_type spatial;
// A surface the map's VMT draws ADDED to what is behind it (`$additive 1`): a glow, a
// beam, a rainbow band. The texture is a picture on black, and the black is the part
// that is not there -- added, it adds nothing.
//
// Drawn opaque, which is what every one of these was until 2026-10-11, the black is a
// wall: surf_lt_unicorn rings its spawn with rainbow tubes and bands like this, and a
// player appeared inside black sheets with white blobs on them. Unlit, as the
// `unlitgeneric` materials these are; no lightmap, because a glow is its own light.
//
// `blend_add` is what puts this in the transparent pass (a shader that blends at all is
// transparent); `depth_draw_never` because a glow does not hide what is behind it.
// [b]The two-sided twin of `g2g_bsp_additive.gdshader`[/b], for a VMT that says `$nocull`
// (a rainbow band is a ribbon seen from both sides). A second file because the cull mode is a
// render mode and a render mode cannot be chosen per material.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb * tint.rgb;
}
