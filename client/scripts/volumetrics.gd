class_name Volumetrics
## GPU capability gate for froxel volumetric fog (#158).
##
## Godot's volumetric fog allocates an R32_Uint atomic storage image. Some
## adapters do not support that format for that usage — the CI runner's
## virtualised Apple GPU reports "Format 'R32_Uint' does not support usage as
## atomic storage image" — and on those the fog volume never initialises and
## the whole frame fails to composite. So volumetrics are enabled only where
## the device affirmatively reports support; everywhere else keeps the plain
## height-fog fallback, which renders correctly on everything.

## The ash volume, tuned against the existing depth fog rather than replacing
## it: the depth fog carries far-field haze, the volumetrics carry the air
## itself — sun shafts and pooling density near the player.
##
## Density stays well under Godot's default (0.05): the depth fog already
## contributes distance attenuation, and stacking a heavy volume on top would
## milk out the frame the grading pass works to keep crisp.
const DENSITY := 0.018
## Scattering albedo: warm-neutral ash, slightly darker than white so the
## volume tints toward FOG_COLOR under the low sun instead of glowing grey.
const ALBEDO := Color(0.80, 0.74, 0.68)
## Forward scattering. The Reach's sun sits low; a high-ish anisotropy is what
## turns uniform haze into visible shafts when looking sunward.
const ANISOTROPY := 0.6
## Far edge of the froxel volume. The playable field and its landmark ruins
## sit well inside this; beyond it the depth fog takes over seamlessly.
const LENGTH := 96.0
## A little ambient in-scatter so fully shadowed fog reads as dim air, not a
## black void between the player and the terrain.
const AMBIENT_INJECT := 0.15
## Keep most of the sky visible through the volume — the sky gradient is a
## deliberate palette choice, and the depth fog already applies its own
## restrained sky_affect (0.4).
const SKY_AFFECT := 0.35


## True only when a rendering device exists AND it supports R32_Uint as an
## atomic storage image — the exact format+usage combination the froxel
## volumetrics allocate. Null-safe: headless runs and renderers without a
## RenderingDevice have nothing to enable volumetrics on.
static func supported(rd: RenderingDevice) -> bool:
	if rd == null:
		return false
	return rd.texture_is_format_supported_for_usage(
		RenderingDevice.DATA_FORMAT_R32_UINT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
	)


## Probes the live rendering device of this process.
static func probe() -> bool:
	return supported(RenderingServer.get_rendering_device())


## Applies the probe verdict to an Environment. Enabled: the tuned ash
## volumetrics above. Disabled: volumetric fog affirmatively off and the
## volumetric parameters left untouched — never a half-applied state.
static func apply(env: Environment, enable: bool) -> void:
	env.volumetric_fog_enabled = enable
	if not enable:
		return
	env.volumetric_fog_density = DENSITY
	env.volumetric_fog_albedo = ALBEDO
	env.volumetric_fog_anisotropy = ANISOTROPY
	env.volumetric_fog_length = LENGTH
	env.volumetric_fog_ambient_inject = AMBIENT_INJECT
	env.volumetric_fog_sky_affect = SKY_AFFECT
