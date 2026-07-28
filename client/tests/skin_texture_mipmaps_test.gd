extends Node
## The shipped skins must carry a mip chain (issue #489).
##
## `CharacterFactory` assigns a skin at RUNTIME — `_skin_material()` calls
## `load()` on the path from `skins.json` — so no committed scene or material
## resource ever references these textures. Godot's importer only turns
## mipmaps on for a texture it has SEEN used in 3D (`detect_3d/compress_to`),
## and that detection runs in the editor at scene-load time. It therefore never
## fires for a texture reached only through `load()`, and the skins keep the 2D
## import defaults, `mipmaps/generate=false`, forever.
##
## The material asks for `LINEAR_WITH_MIPMAPS` (the `StandardMaterial3D`
## default), so with no chain to sample the GPU falls back to bilinear on level
## 0. A 1024x1024 photographic skin minified at gameplay range then aliases:
## every screen pixel takes one arbitrary texel instead of the average of the
## many it covers, which reads as a regular stipple across the skin — and it is
## worst where skin is largest on screen and unbroken, the arms and shoulders.
##
## Equipment textures come in through the baked GLB's materials, so the
## importer does see them in 3D and they already carry mipmaps. Only the
## runtime-assigned skins are exposed, which is why this is an asset-import
## contract rather than a material bug.
##
## Checked here rather than by grepping the `.import` files, because what
## matters is the imported RESULT the player's GPU samples.
##
## Run: godot --headless --path client res://tests/skin_texture_mipmaps_test.tscn

const SKINS_DIR := "res://assets/characters/humanoid_kit/skins/"
const SKINS_REGISTRY := SKINS_DIR + "skins.json"
const WANDERER := "res://recipes/wanderer.json"

## The `BaseMaterial3D.TextureFilter` values that sample a mip chain. Enabling
## the chain buys nothing if the material stops asking for it, so the shipped
## material is checked too.
const MIPMAP_FILTERS: Array[int] = [
	BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
	BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
	BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC,
	BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC,
]


func _ready() -> void:
	if not _control_discriminates():
		return

	var registry := _read_registry()
	if registry.is_empty():
		_fail("cannot read %s" % SKINS_REGISTRY)
		return
	var skins: Dictionary = registry.get("skins", {})
	if skins.is_empty():
		_fail("skins registry lists no skins")
		return

	for skin_name: String in skins:
		var path := SKINS_DIR + String(skins[skin_name]["texture"])
		var texture: Texture2D = load(path)
		if texture == null:
			_fail("skin texture missing or unimported: %s" % path)
			return
		var image := texture.get_image()
		if image == null:
			_fail("skin texture %s imported to no image" % skin_name)
			return
		if not image.has_mipmaps():
			_fail(("skin '%s' (%s) imported with no mip chain — it is assigned by "
				+ "load() at runtime, so the importer's 3D detection never turns mipmaps "
				+ "on for it; set mipmaps/generate=true in its .import") % [skin_name, path.get_file()])
			return

	if not _shipped_material_samples_mipmaps():
		return

	print("TEST PASS — %d shipped skins carry a mip chain, and the skin material samples it" % skins.size())
	get_tree().quit(0)


## The check must be able to FAIL. `has_mipmaps()` reporting true for
## everything would make the loop above pass whatever the import says, so prove
## on images this test builds itself that the predicate separates the two
## states.
func _control_discriminates() -> bool:
	var bare := Image.create(64, 64, false, Image.FORMAT_RGB8)
	if bare.has_mipmaps():
		_fail("control: an image created without mipmaps reports has_mipmaps() true")
		return false
	var chained := Image.create(64, 64, false, Image.FORMAT_RGB8)
	chained.generate_mipmaps()
	if not chained.has_mipmaps():
		_fail("control: an image with a generated chain reports has_mipmaps() false")
		return false
	return true


## End-to-end: the material the player's body actually renders with must both
## carry a mipmapped texture and ask for a filter that samples it.
func _shipped_material_samples_mipmaps() -> bool:
	var recipe: Dictionary = CharacterFactory.load_recipe(WANDERER)
	if recipe.is_empty():
		_fail("cannot load %s" % WANDERER)
		return false
	var built := CharacterFactory.build(recipe)
	if built == null:
		_fail("CharacterFactory.build returned nothing for the wanderer")
		return false
	var skeleton := CharacterFactory.find_skeleton(built)
	var body := CharacterFactory.find_skinned_mesh(skeleton)
	if body == null:
		_fail("no body mesh under the built wanderer")
		built.free()
		return false
	var material := body.get_surface_override_material(0) as BaseMaterial3D
	if material == null:
		_fail("the built body carries no surface override material")
		built.free()
		return false
	var filter := material.texture_filter
	var albedo := material.albedo_texture
	built.free()
	if filter not in MIPMAP_FILTERS:
		_fail("the skin material's texture_filter is %d, which samples no mip chain" % filter)
		return false
	if albedo == null:
		_fail("the skin material carries no albedo texture")
		return false
	if not albedo.get_image().has_mipmaps():
		_fail("the skin material's albedo texture carries no mip chain")
		return false
	return true


func _read_registry() -> Dictionary:
	var file := FileAccess.open(SKINS_REGISTRY, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
