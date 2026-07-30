class_name ReachAtmosphere
## Builds the complete Environment shared by the Ashfall Reach and every
## preview that judges player-facing work under its shipping atmosphere.
##
## The sun remains a scene-owned DirectionalLight3D. This module owns the sky,
## image treatment, depth fog, capability-gated volumetrics, and grading that
## determine how that light reaches the final frame.

const SKY_TOP := Color(0.23, 0.18, 0.22)
const SKY_HORIZON := Color(0.55, 0.35, 0.24)
const GROUND_BOTTOM := Color(0.1, 0.09, 0.09)
const FOG_COLOR := Color(0.35, 0.28, 0.24)


static func build(volumetrics_on: bool) -> Environment:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = SKY_TOP
	sky_material.sky_horizon_color = SKY_HORIZON
	sky_material.ground_bottom_color = GROUND_BOTTOM
	sky_material.ground_horizon_color = SKY_HORIZON
	sky_material.sun_angle_max = 40.0
	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.9
	# SDFGI keeps sky ambient out of underground cave systems, whose darkness
	# comes from occlusion and whose illumination comes from their torches.
	environment.sdfgi_enabled = true
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.05
	environment.tonemap_white = 6.0

	# Tight contact occlusion seats props without painting grey haloes into
	# direct sunlight.
	environment.ssao_enabled = true
	environment.ssao_radius = 1.4
	environment.ssao_intensity = 2.4
	environment.ssao_power = 1.7
	environment.ssao_detail = 0.6
	environment.ssao_light_affect = 0.0
	environment.ssao_ao_channel_affect = 0.35

	# Only genuinely over-bright ember surfaces bloom; the ashen mid-tones stay
	# crisp.
	environment.glow_enabled = true
	environment.glow_normalized = true
	environment.glow_intensity = 0.32
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.05
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	environment.glow_hdr_threshold = 1.45
	environment.glow_hdr_scale = 2.0

	environment.fog_enabled = true
	environment.fog_light_color = FOG_COLOR
	environment.fog_light_energy = 0.9
	environment.fog_sun_scatter = 0.06
	environment.fog_density = 0.010
	environment.fog_aerial_perspective = 0.35
	environment.fog_sky_affect = 0.4
	CaveAtmosphere.apply(environment, 0.0)
	Volumetrics.apply(environment, volumetrics_on)

	# Restrained contrast and saturation keep the ash from going milky while
	# leaving ember highlights as the only truly warm part of the frame.
	environment.adjustment_enabled = true
	environment.adjustment_brightness = 1.0
	environment.adjustment_contrast = 1.08
	environment.adjustment_saturation = 0.94
	return environment
