shader_type fog;

uniform float placed_density = 1.0;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.35);
uniform float field_wavelength = 2.5;
uniform float cross_wavelength = 1.7;
uniform float field_speed = 1.08;
uniform float field_swing = 0.52;
uniform float field_time = 0.0;
uniform vec3 ash_albedo : source_color = vec3(0.80, 0.74, 0.68);

void fog() {
	vec3 along = normalize(wind_dir);
	vec3 across = normalize(vec3(-along.z, 0.0, along.x));
	vec3 advected = WORLD_POSITION - along * field_time * field_speed;
	float wind_phase = dot(advected, along) / field_wavelength;
	float cross_phase = dot(advected, across) / cross_wavelength;
	float pattern = (
		0.45 * sin(wind_phase)
		+ 0.25 * sin(2.0 * wind_phase + cross_phase + 1.3)
		+ 0.18 * cos(3.0 * wind_phase - 2.0 * cross_phase + 0.4)
		+ 0.12 * cos(2.0 * wind_phase + WORLD_POSITION.y / 1.4 + 0.7)
	);

	// Match the settled FogMaterial's soft ellipsoid rim and floor-heavy
	// settling while multiplying only the travelling part around a mean of 1.
	vec3 centred = UVW * 2.0 - 1.0;
	float rim = 1.0 - smoothstep(0.58, 1.0, length(centred));
	float settling = mix(1.0, 0.62, smoothstep(0.0, 1.0, UVW.y));

	ALBEDO = ash_albedo;
	DENSITY = placed_density * (1.0 + field_swing * pattern) * rim * settling;
}
