@tool
class_name RecipeGallery
extends Node3D
## Taste-gate gallery for the character system (issue #24, stage 2): every
## recipe under res://recipes/ built by CharacterFactory and lined up under
## the taste lighting. Open scenes/recipes.tscn in the editor — edit a recipe
## JSON or toggle `refresh` to rebuild. Runs headless in CI via the factory
## test; will later be where new NPC/enemy silhouettes are judged.

const RECIPES_DIR := "res://recipes/"
const SPACING := 1.5
const CLAY := Color(0.69, 0.64, 0.57)

## Toggle in the inspector to rebuild after editing recipe files.
@export var refresh: bool = false:
	set(_v):
		if is_inside_tree():
			rebuild()

var _built: Array[Node] = []


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	for node in _built:
		node.queue_free()
	_built.clear()
	var names := _recipe_names()
	for i in names.size():
		var recipe = CharacterFactory.load_recipe(RECIPES_DIR + names[i] + ".json")
		if recipe == null:
			continue
		var instance := CharacterFactory.build(recipe)
		if instance == null:
			push_error("RecipeGallery: '%s' failed to build" % names[i])
			continue
		var x := (i - (names.size() - 1) * 0.5) * SPACING
		instance.position.x = x
		_apply_clay(instance)
		add_child(instance)
		_built.append(instance)
		var label := Label3D.new()
		label.text = names[i]
		label.font_size = 48
		label.outline_size = 14
		label.modulate = Color(0.78, 0.8, 0.84)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = Vector3(x, 2.0, 0.0)
		add_child(label)
		_built.append(label)


func _recipe_names() -> PackedStringArray:
	var names := PackedStringArray()
	for file in DirAccess.get_files_at(RECIPES_DIR):
		# Exported builds list remapped resources; strip the suffix so the
		# same scan works in the editor, headless CI, and an export.
		if file.ends_with(".json"):
			names.append(file.get_basename())
	names.sort()
	return names


## Matte warm clay so the taste gate judges FORM; skins arrive in stage 4.
func _apply_clay(instance: Node3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = CLAY
	mat.roughness = 0.65
	var stack: Array[Node] = [instance]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			(node as MeshInstance3D).material_override = mat
		for child in node.get_children():
			stack.push_back(child)
