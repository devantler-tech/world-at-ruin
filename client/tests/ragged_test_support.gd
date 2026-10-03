class_name RaggedTestSupport
extends RefCounted
## A real opted-in garment fixture for independently controlled ablations.


static func preview_fixture() -> Dictionary:
	var state := TestEnvironment.snapshot([RaggedCloth.FLAG_ENV])
	OS.set_environment(RaggedCloth.FLAG_ENV, "1")
	var character := CharacterFactory.build(CharacterFactory.load_recipe("res://recipes/wanderer.json"))
	var garment := CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D
	return {"character": character, "garment": garment, "mesh": garment.mesh,
		"preview": garment.get_active_material(0), "environment": state}


## An ablation must preserve the live mesh and common render settings.
static func retained_settings(garment: MeshInstance3D, mesh: Mesh, preview: StandardMaterial3D, ablation: StandardMaterial3D) -> bool:
	return ablation != preview and garment.get_active_material(0) == preview and garment.mesh == mesh \
		and ablation.albedo_color == preview.albedo_color and ablation.normal_scale == preview.normal_scale \
		and ablation.cull_mode == preview.cull_mode and ablation.transparency == preview.transparency \
		and ablation.texture_filter == preview.texture_filter and ablation.texture_repeat == preview.texture_repeat \
		and ablation.roughness == preview.roughness


static func release_fixture(fixture: Dictionary) -> void:
	(fixture["character"] as Node).free()
	TestEnvironment.restore(fixture["environment"])
