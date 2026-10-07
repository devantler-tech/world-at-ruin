extends Node
## A woven map without sewn construction must fail these spatial checks.
## Literal UV bands come from the immutable garment's waist, not a production
## tailoring helper. Inspect the maps attached by the real compositor.

var _failed := false


func _ready() -> void:
	var had_flag := OS.has_environment(RaggedCloth.FLAG_ENV)
	var prior := OS.get_environment(RaggedCloth.FLAG_ENV)
	OS.set_environment(RaggedCloth.FLAG_ENV, "1")
	var character := CharacterFactory.build(CharacterFactory.load_recipe("res://recipes/wanderer.json"))
	var garment := CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D
	var material := garment.get_active_material(0) as StandardMaterial3D
	var colour := material.albedo_texture.get_image()
	var normal := material.normal_texture.get_image()
	var source := garment.mesh.surface_get_material(0) as StandardMaterial3D
	var plain_maps := RaggedCloth.make_maps(RaggedCloth._palette(source.albedo_texture), false)
	var plain_colour := plain_maps[0].get_image()
	var plain_normal := plain_maps[1].get_image()
	for row: int in [184, 285]:
		var contrast := _mean_light(colour, row - 2, row + 3) - _mean_light(colour, row - 10, row - 5)
		var relief := _normal_response(normal, row - 4, row + 5) - _normal_response(normal, row - 16, row - 7)
		print("TAILORING row=%d thread contrast=%.5f cross-seam relief=%.5f" % [row, contrast, relief])
		_check(contrast > 0.02, "the waist has visible sewn threads rather than uniform weave")
		_check(relief > 0.08, "the sewn thread changes the actual lighting normals beyond the existing weave")
		var plain_contrast := _mean_light(plain_colour, row - 2, row + 3) - _mean_light(plain_colour, row - 10, row - 5)
		var plain_relief := _normal_response(plain_normal, row - 4, row + 5) - _normal_response(plain_normal, row - 16, row - 7)
		_check(absf(plain_contrast) < 0.01, "the weave-only colour control cannot impersonate sewing")
		_check(absf(plain_relief) < 0.02, "a painted thread with weave-only normals cannot pass the lighting criterion")
	character.free()
	if had_flag:
		OS.set_environment(RaggedCloth.FLAG_ENV, prior)
	else:
		OS.unset_environment(RaggedCloth.FLAG_ENV)
	if _failed:
		get_tree().quit(1)
	else:
		print("TEST PASS — original sewn tailoring reaches the actual opted-in garment colour and lighting")
		get_tree().quit(0)


## Average a broad belt interval so an incidental bright weave texel cannot
## impersonate a line of stitches. The neighbouring band remains plain cloth.
func _mean_light(map: Image, top: int, bottom: int) -> float:
	var total := 0.0
	var count := 0
	for y in range(top, bottom):
		for x in range(205, 820):
			var pixel := map.get_pixel(x, y)
			total += pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
			count += 1
	return total / count


## A horizontal seam needs cross-seam normal relief. Weave-only normal maps
## have a smaller response; a diffuse painted line cannot pass this check.
func _normal_response(map: Image, top: int, bottom: int) -> float:
	var total := 0.0
	var count := 0
	for x in range(205, 820):
		var low := 1.0
		var high := 0.0
		for y in range(top, bottom):
			var pixel := map.get_pixel(x, y)
			low = minf(low, pixel.g)
			high = maxf(high, pixel.g)
		total += high - low
		count += 1
	return total / count


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
