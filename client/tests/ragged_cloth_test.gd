extends Node
## Exercises the actual recipe compositor in both ragged-cloth preview states.
## The preview may change the material, never the immutable garment, another
## equipment material, the stored recipe, or the imported shared resource.

const FLAG := "WAR_RAGGED_CLOTH_DETAIL"
const GARMENT := "Equip_loincloth_ragged"
var _failed := false


## Compose real characters across flag transitions and independent rebakes,
## restoring the caller's environment after checking resource isolation.
func _ready() -> void:
	var had_flag := OS.has_environment(FLAG)
	var prior := OS.get_environment(FLAG)
	var stripes := Image.create(64, 64, false, Image.FORMAT_RGB8)
	stripes.fill(Color.WHITE)
	for y in 64:
		for x in range(0, 64, 4):
			stripes.set_pixel(x, y, Color.BLACK)
	var palette := RaggedCloth._palette(ImageTexture.create_from_image(stripes))
	_check(absf(palette.r - 0.75) < 0.001,
		"the colour average cannot alias onto regularly spaced dark yarns")
	OS.unset_environment(FLAG)
	var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	var original: Dictionary = recipe.duplicate(true)
	var off := CharacterFactory.build(recipe)
	var off_piece := _piece(off, GARMENT)
	var imported := off_piece.get_active_material(0) as StandardMaterial3D
	_check(off_piece.get_surface_override_material(0) == null,
		"ordinary launches keep the baked garment material")
	OS.set_environment(FLAG, "true")
	var malformed := CharacterFactory.build(recipe)
	_check(_piece(malformed, GARMENT).get_surface_override_material(0) == null,
		"only the explicit value 1 opts in")
	OS.set_environment(FLAG, "1")
	var on := CharacterFactory.build(recipe)
	var garment := _piece(on, GARMENT)
	var material := garment.get_surface_override_material(0) as StandardMaterial3D
	_check(material != null, "the actual CharacterFactory garment receives woven detail when opted in")
	if material != null:
		_check(material != imported, "the imported shared material is never mutated")
		_check(material.cull_mode == imported.cull_mode
			and material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
			"the double-sided opaque base retains its coverage")
		_check(garment.mesh == off_piece.mesh and garment.skin == off_piece.skin,
			"mesh topology, morphs and skin bindings remain the shipped resources")
		_check(not garment.mesh.surface_get_arrays(0)[Mesh.ARRAY_TANGENT].is_empty(),
			"the imported mesh supplies tangents for fibre normals")
		_check(material.metallic == 0.0 and material.roughness >= 0.8,
			"ragged cloth has a restrained non-metallic light response")
		_check(material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC,
			"fine threads use mipmaps and anisotropic filtering at distance")
		for texture: Texture2D in [material.albedo_texture, material.normal_texture, material.roughness_texture]:
			_check(texture != null, "all three cloth maps reach the actual material")
			if texture != null:
				var map := texture.get_image()
				_check(map.get_width() >= 512 and map.has_mipmaps(),
					"surface maps retain inspection detail and a minification chain")
		_check(material.normal_enabled and material.normal_scale > 0.0,
			"thread relief reaches the lighting path")
		_check(_spread(material.albedo_texture) > 0.035, "cloth carries tonal variation rather than a flat fill")
		_check(_spread(material.normal_texture) > 0.1, "thread normals have measurable relief")
		_check(_spread(material.roughness_texture) > 0.02, "roughness varies across worn fibres")
		var fresh := RaggedCloth.make_maps(RaggedCloth._palette(imported.albedo_texture))
		var actual: Array[Texture2D] = [material.albedo_texture, material.normal_texture, material.roughness_texture]
		for index in fresh.size():
			_check(fresh[index].get_image().get_data() == actual[index].get_image().get_data(),
				"an independent rebake reproduces every byte, including mipmaps")
		_check(_piece(on, "Equip_shirt_ragged").get_active_material(0)
			== _piece(off, "Equip_shirt_ragged").get_active_material(0),
			"the preview leaves other equipment materials alone")
		var another := CharacterFactory.build(recipe)
		var repeated := _piece(another, GARMENT).get_surface_override_material(0) as StandardMaterial3D
		_check(repeated != material, "characters own their material settings")
		_check(repeated.albedo_texture == material.albedo_texture,
			"immutable generated maps are shared instead of rebaked per character")
		another.free()
	OS.unset_environment(FLAG)
	var after := CharacterFactory.build(recipe)
	_check(_piece(after, GARMENT).get_active_material(0) == imported,
		"opting out after a preview restores the original shared material")
	_check(recipe == original and CharacterFactory.refusal_reason(recipe) == "",
		"composing the preview never rewrites the character recipe")
	off.free()
	malformed.free()
	on.free()
	after.free()
	if had_flag:
		OS.set_environment(FLAG, prior)
	else:
		OS.unset_environment(FLAG)
	if not _failed:
		print("TEST PASS — ragged cloth is opt-in, isolated, opaque and mip-filtered without changing recipes")
		get_tree().quit(0)


## Inspect the actual equipped mesh under the compositor's skeleton.
func _piece(character: Node3D, name: String) -> MeshInstance3D:
	var skeleton := CharacterFactory.find_skeleton(character)
	return skeleton.get_node(name) as MeshInstance3D


## An independent spatial sample catches a map accidentally filled with one
## value; reading only its dimensions would accept that silent no-op.
func _spread(texture: Texture2D) -> float:
	if texture == null:
		return 0.0
	var map := texture.get_image()
	var lo := Vector3.ONE
	var hi := Vector3.ZERO
	for y in range(7, map.get_height(), 13):
		for x in range(11, map.get_width(), 17):
			var pixel := map.get_pixel(x, y)
			lo = lo.min(Vector3(pixel.r, pixel.g, pixel.b))
			hi = hi.max(Vector3(pixel.r, pixel.g, pixel.b))
	return maxf(hi.x - lo.x, maxf(hi.y - lo.y, hi.z - lo.z))


## Emit the runner's failure marker and retain failure across later checks.
func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
		get_tree().quit(1)
