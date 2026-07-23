shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Render-only transition between the starter cave's weathered exterior and
// the exact local ground substance sampled by WorldGen. UV.xy + UV2.x are its
// RGB albedo, UV2.y is roughness, and COLOR.a is the terrain-distance/contact
// weight. The rock mesh beneath remains the collision surface.

void vertex() {
	// Keep the overlay just above its source surface. The displacement reaches
	// 4 mm only at full contact and vanishes with the blend, avoiding z-fighting
	// without moving the generated rock or its collision.
	VERTEX += NORMAL * (0.004 * COLOR.a);
}

void fragment() {
	ALBEDO = vec3(UV, UV2.x);
	ROUGHNESS = UV2.y;
	SPECULAR = 0.18;
	ALPHA = COLOR.a;
}
