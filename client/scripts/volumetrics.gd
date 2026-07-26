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
const DENSITY := 0.005
## Scattering albedo: warm-neutral ash, slightly darker than white so the
## volume tints toward FOG_COLOR under the low sun instead of glowing grey.
const ALBEDO := Color(0.80, 0.74, 0.68)
## Mild backward scattering. Ash is smoke-like particulate rather than clear
## mist: the old +0.6 bias concentrated the response into the view toward the
## sun, leaving the same cloud dark when viewed from the side the light reaches
## first (#346). A fixed-camera capture proved that even +0.15 kept that
## ordering inverted. -0.15 makes direct source-facing illumination lead while
## staying far from the -1.0 limit, so the opposite side retains a softer
## transmitted read. The renderer still derives the response from every live
## Light3D, so it follows the sun as that light moves.
const ANISOTROPY := -0.15
## Far edge of the froxel volume. The playable field and its landmark ruins
## sit well inside this; beyond it the depth fog takes over seamlessly.
const LENGTH := 64.0
## A little ambient in-scatter so fully shadowed fog reads as dim air, not a
## black void between the player and the terrain.
const AMBIENT_INJECT := 0.10
## Keep most of the sky visible through the volume — the sky gradient is a
## deliberate palette choice, and the depth fog already applies its own
## restrained sky_affect (0.4).
const SKY_AFFECT := 0.25


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


## Leading token of the line the game prints once the probe has run (#232).
##
## CI's frame-capture job greps the capture log for this to learn WHICH PATH the
## frames it is about to publish actually depict. The token lives here, beside
## the probe, so the string the workflow parses and the string the game prints
## cannot drift apart — renaming it in one place alone would make the capture
## job's verdict silently unknowable, which is the failure #232 exists to close.
## volumetrics_test pins both states.
const CAPTURE_MARKER := "VOLUMETRICS"

## The exact line main.gd prints for a probe verdict.
##
## The SECOND whitespace-separated field is the machine-readable verdict — `on`
## or `off` — and the remainder is for a human reading the log. CI parses that
## second field, so it is a contract, not prose.
static func marker(enabled: bool) -> String:
	if enabled:
		return "%s on — R32_Uint atomic storage image supported" % CAPTURE_MARKER
	return "%s off — GPU lacks R32_Uint atomic storage image support" % CAPTURE_MARKER


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
