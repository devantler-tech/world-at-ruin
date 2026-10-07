class_name RaggedCloth
extends RefCounted
## Opt-in surface preview for the immutable ragged base (#946).
## All maps are authored here from arithmetic and seeded noise; no reference
## image or generated asset is changed. Planar kit UVs stay the same, including
## their shared front/back mapping. Broad relief suggests folded fabric;
## silhouette and cloth motion remain independent of these surface maps.
## The three immutable textures are built once, shared across characters, and
## mip-filtered; each character keeps its own material settings.
## The activation/removal decision is tracked by #947, due 2026-11-01.

const FLAG_ENV := "WAR_RAGGED_CLOTH_DETAIL"
const MAP_SIZE := 1024
static var _maps: Array[Texture2D] = []


## Require an explicit opt-in so ordinary launches retain the accepted base.
static func enabled() -> bool:
	return OS.get_environment(FLAG_ENV) == "1"


## Duplicate the imported material so its double-sided opaque coverage stays
## intact and opting out later cannot inherit a mutated resource.
static func material(source: StandardMaterial3D) -> StandardMaterial3D:
	if _maps.is_empty():
		_maps = make_maps(_palette(source.albedo_texture))
	var result := source.duplicate() as StandardMaterial3D
	result.albedo_texture = _maps[0]
	result.normal_texture = _maps[1]
	result.roughness_texture = _maps[2]
	result.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	result.roughness = 1.0
	result.metallic = 0.0
	result.normal_enabled = true
	result.normal_scale = 0.45
	result.metallic_specular = 0.2
	result.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	# The kit UVs fit 0..1. Repeating anisotropy selects sampler 17 in Godot's
	# Metal shader, beyond the 16 slots on older/virtual Apple GPUs. Clamp keeps
	# the same filtering quality without an unnecessary repeat sampler.
	result.texture_repeat = false
	return result


## Independent rebakes expose determinism to the regression without clearing a
## production cache. Uneven warp/weft yarns alternate which strand rises at a
## crossing; low-frequency wear and fine fibres vary colour and roughness.
static func make_maps(palette: Color, tailoring: bool = true, folds: bool = true) -> Array[Texture2D]:
	var albedo := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8)
	var normal := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8)
	var roughness := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_R8)
	var wear := FastNoiseLite.new()
	wear.seed = 946
	wear.frequency = 0.008
	for y in MAP_SIZE:
		var v := float(y) / MAP_SIZE
		var weft := v * 128.0
		for x in MAP_SIZE:
			var u := float(x) / MAP_SIZE
			var warp := u * 96.0 + 0.16 * sin(v * TAU * 5.0)
			var bent_weft := weft + 0.12 * sin(u * TAU * 7.0)
			var raised_warp := posmod(int(floor(warp)) + int(floor(bent_weft)), 2) == 0
			var warp_wave := sin(warp * TAU)
			var weft_wave := sin(bent_weft * TAU)
			var fibre := sin(float(x * 17 + y * 31)) * 0.5
			var stain := wear.get_noise_2d(float(x), float(y))
			var tone := 1.04 + stain * 0.24 + fibre * 0.035
			# Yarn tone is deliberately restrained: broad dark grid lines read
			# as a plaid print instead of the tiny relief of woven cloth.
			tone += (warp_wave + weft_wave) * 0.015
			var sewn := _sewn_edge(u, v) if tailoring else Vector3.ZERO
			var folded := _fold_relief(u, v) if folds else Vector3.ZERO
			tone *= 1.0 + folded.x
			var cloth := Color(palette.r * tone, palette.g * tone, palette.b * tone)
			# Undyed, worn thread belongs to the kit's brown colour family.
			# Rounded thread relief is separate from its colour, so light can
			# pick out the seam instead of reading it as a printed stripe.
			var thread := Color(0.56, 0.40, 0.25)
			albedo.set_pixel(x, y, cloth.lerp(thread, sewn.x * 0.85))
			var slope := Vector3(warp_wave * (0.42 if raised_warp else 0.12) + sewn.y + folded.y,
				weft_wave * (0.12 if raised_warp else 0.42) + sewn.z + folded.z, 1.0).normalized()
			normal.set_pixel(x, y, Color(slope.x * 0.5 + 0.5, slope.y * 0.5 + 0.5, slope.z * 0.5 + 0.5))
			var matte := clampf(0.9 + stain * 0.1 + fibre * 0.045 + sewn.x * 0.025, 0.82, 0.98)
			roughness.set_pixel(x, y, Color(matte, matte, matte))
	albedo.generate_mipmaps()
	normal.generate_mipmaps(true)
	roughness.generate_mipmaps()
	return [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(normal),
		ImageTexture.create_from_image(roughness)]


## Original shallow gathers fan out below the waist. Rounded ridges and their
## slopes are centimetre-scale beside the tiny weave; irregular centres and
## widths avoid a printed stripe grid. The shared atlas does not pretend to
## follow either ragged hem. Folded waist lips have a separate crosswise roll.
## Return colour modulation and authored tangent-space slopes.
static func _fold_relief(u: float, v: float) -> Vector3:
	var depth := clampf((v - 0.29) / 0.43, 0.0, 1.0)
	var onset := smoothstep(0.29, 0.36, v)
	var relief := Vector3.ZERO
	for index in 4:
		var centre := 0.31 + float(index) * 0.126 + sin(float(index) * 2.1) * 0.016
		var fan := (centre - 0.5) * depth * 0.22
		var width := 0.019 + depth * 0.014 + float(index % 2) * 0.004
		var distance := u - centre - fan
		var ridge := exp(-distance * distance / (width * width))
		var height := 0.017 * onset * (1.0 - depth * 0.30)
		var lateral := -2.0 * distance / (width * width) * ridge * height
		relief.x += (ridge - 0.25) * 0.11 * onset
		relief.y += lateral
		# The lean of each gather contributes to the crosswise normal as
		# well; onset stays below the waist's independent sewn rows.
		relief.z -= lateral * (centre - 0.5) * 0.22 / 0.43
	# Keep the roll beyond the narrow sewn rows, so the sewing-only control
	# still measures actual thread rather than crediting broad fold lighting.
	for row: float in [0.145, 0.32]:
		var distance := v - row
		var width := 0.006
		var roll := exp(-distance * distance / (width * width))
		relief.x -= roll * 0.10
		relief.z += -2.0 * distance / (width * width) * roll * 0.004
	return relief


## Two original running-stitch rows reinforce the folded waist. The immutable
## planar UVs map 0.4 metres across the wrap: each short thread is about 6 mm
## long, with small, deterministic changes in slant and spacing. Front and rear
## share this atlas, so these rows do not pretend to follow both ragged hems.
## The seam-off capture keeps the weave and removes only these thread fields.
static func _sewn_edge(u: float, v: float) -> Vector3:
	var row := 0.18 if v < 0.23 else 0.278
	if absf(v - row) <= 0.007:
		var offset := 0.013 if row > 0.23 else 0.0
		return _thread(u + offset, v - row)
	# Inset side reinforcement tapers with the hanging panels. Their shared
	# UVs have different hems: stop above both instead of printing a false
	# seam across the rear's empty atlas area. No alpha or coverage changes.
	if v < 0.30 or v > 0.70:
		return Vector3.ZERO
	var edge := 0.22 + (v - 0.25) * 0.20
	var side := u - edge if u < 0.5 else u - (1.0 - edge)
	if absf(side) > 0.007:
		return Vector3.ZERO
	var thread := _thread(v, side)
	return Vector3(thread.x, thread.z, thread.y)


## Short capsules give thread rounded tips and a cross-section that changes
## normals. Slightly rubbed, unequal lengths break up machine-perfect rows.
static func _thread(along: float, across: float) -> Vector3:
	var stitch := floorf(along / 0.026)
	var centre := (stitch + 0.5) * 0.026
	var slant := 0.20 + sin(stitch * 2.3) * 0.06
	var length := 0.007 + sin(stitch * 1.7) * 0.0006
	var end := clampf(along - centre, -length, length)
	var dx := along - centre - end
	var dy := across - end * slant
	var width := 0.0017
	var profile := exp(-(dx * dx + dy * dy) / (width * width)) * (0.85 + sin(stitch * 3.1) * 0.15)
	return Vector3(profile, dx / width * profile * 3.0, dy / width * profile * 3.0)


## Keep the existing kit's colour family, without magnifying its coarse grid.
static func _palette(texture: Texture2D) -> Color:
	var image := texture.get_image()
	var sum := Color(0.0, 0.0, 0.0)
	# A fixed sparse grid can alias onto every dark yarn in the old map.
	# Average all texels once instead of changing the cloth's colour by chance.
	for y in image.get_height():
		for x in image.get_width():
			sum += image.get_pixel(x, y)
	var count := float(image.get_width() * image.get_height())
	return Color(sum.r / count, sum.g / count, sum.b / count)
