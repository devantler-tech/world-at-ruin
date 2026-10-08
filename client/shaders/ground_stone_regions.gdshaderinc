// Regional exposure never re-deals the cellular stone identities or their substance.
// Blend all competing regions, taking each region's strongest site once. Summing
// same-region sites would create a density seam where their Voronoi cells meet.
vec2 regional_stone_thresholds(vec2 at) {
	float nearest = 1e20;
	for (int i = 0; i < 9; i++) {
		nearest = min(nearest, distance(at, stone_region_sites[i].xy));
	}
	float weights[4];
	for (int r = 0; r < 4; r++) {
		weights[r] = 0.0;
	}
	for (int i = 0; i < 9; i++) {
		int r = int(stone_region_sites[i].z);
		float w = max(0.0, 1.0 - (distance(at, stone_region_sites[i].xy) - nearest)
			/ stone_region_blend_band);
		weights[r] = max(weights[r], w);
	}
	vec2 profile = vec2(0.0);
	float total = 0.0;
	for (int r = 0; r < 4; r++) {
		profile += stone_region_profiles[r] * weights[r];
		total += weights[r];
	}
	return profile / total;
}
