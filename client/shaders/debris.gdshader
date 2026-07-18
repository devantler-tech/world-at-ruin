// Opaque ground debris — bone piles and rubble.
//
// Split from `foliage.gdshader` after review: the vegetation shader writes
// ALPHA and an alpha-scissor threshold for its cutout cards, and routing solid
// stone through that path buys nothing. Debris is fully opaque and closed, so
// it belongs on a plain opaque shader that also gets back-face culling back —
// which the shared shader had given up purely so cutout cards could be seen
// from both sides.
//
// What it keeps from the vegetation path is the per-instance tint: variation
// derived from INSTANCE_ID, so no two rubble piles are the same shade, at no
// cost and with no effect on determinism.
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint_low : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 tint_high : source_color = vec3(1.0, 1.0, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.85;

varying vec3 inst_tint;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	inst_tint = mix(tint_low, tint_high, hash11(float(INSTANCE_ID) * 1.7 + 3.3));
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb * inst_tint;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.2;
}
