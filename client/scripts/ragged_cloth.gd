class_name RaggedCloth
extends RefCounted
## Opt-in surface preview for the immutable ragged base (#946).
## All maps are authored here from arithmetic and seeded noise; no reference
## image or generated asset is changed. Planar kit UVs stay the same, including
## their shared front/back mapping. This does not author folds or cloth motion.
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
static func make_maps(palette: Color) -> Array[Texture2D]:
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
			albedo.set_pixel(x, y, Color(palette.r * tone, palette.g * tone, palette.b * tone))
			var slope := Vector3(warp_wave * (0.42 if raised_warp else 0.12),
				weft_wave * (0.12 if raised_warp else 0.42), 1.0).normalized()
			normal.set_pixel(x, y, Color(slope.x * 0.5 + 0.5, slope.y * 0.5 + 0.5, slope.z * 0.5 + 0.5))
			var matte := clampf(0.9 + stain * 0.1 + fibre * 0.045, 0.82, 0.98)
			roughness.set_pixel(x, y, Color(matte, matte, matte))
	albedo.generate_mipmaps()
	normal.generate_mipmaps(true)
	roughness.generate_mipmaps()
	return [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(normal),
		ImageTexture.create_from_image(roughness)]


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
