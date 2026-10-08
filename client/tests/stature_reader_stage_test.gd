extends Node
## Base-owned preparation for #593. Only the exact planned reader stage may
## advance; it must preserve historical characters and keep writers on v4/7.

const PLANNED := "res://tests/data/planned_recipe_v5.json"
const PROBE := "user://stature_reader_probe.json"
const FINGERPRINTS := {
	"wanderer": "d135169b7c475ad79a63cb99acb7405e3828795ebc0f7a19e504f9d7276608c8",
	"villager": "ed8d7ff6c9b54e020e082fe7dcf20c47f3b50c23fdfacb2e115436cea6f0551c",
	"elder": "396d3fb64d96419b5f1c31f70e9f9e102124462d1148c84790d6bff9def931cc",
	"brute": "511490262282a2a9f9955681c37b819eb034aa55ad8bf987c1d36c42ad361a04",
}
## Baseline geometry at reviewed main 6b878853b7b75745cb86bee01d6c04c9ee3fe3cf.
const GOLDEN_FINGERPRINTS := {
	"res://tests/data/golden_recipe_v1.json": "d1f1a0b2d82d23eb5d0f1f9025fcca1a988245a824bff0e6b0776aa94a057741",
	"res://tests/data/golden_recipe_v2.json": "93271c76b276438c6a9c7de171812e37531fef8a649c9112d813b70f31a846de",
	"res://tests/data/golden_recipe_v3.json": "deefef8eb057c6007a79b2ca03795dc3d532fa99665b9b976d38d28e91c4f5b2",
	"res://tests/data/golden_recipe_v4.json": "3a0259185bce5f49f81cf5c4f80aca0a5d3ad61073a90ccdb917330dfc8c71c9",
}
var _failed := false


func _ready() -> void:
	var factory_script := load("res://scripts/character_factory.gd") as GDScript
	var constants: Dictionary = factory_script.get_script_constant_map()
	_check(constants.get("RECIPE_WRITE_VERSION", -1) == 4,
		"recipe writer ceiling must be separate and remain v4")
	if _failed:
		_finish()
		return
	var stage := SaveContractStage.new()
	_check(stage.has_method("stage_refusal"), "the planned stage needs a reviewed closed policy")
	if _failed:
		_finish()
		return
	_check(stage.call("stage_refusal", 8, 5, 7, 5, 5, 4) == "", "planned reader5/8 with writer4/7 is recognized")
	for invalid: Array in [
		[9, 5, 7, 5, 5, 4], [8, 5, 8, 5, 5, 4],
		[8, 5, 7, 5, 5, 5], [8, 5, 7, 5, 4, 4],
		[7, 5, 7, 5, 5, 4], [8, 6, 7, 5, 5, 4],
	]:
		_check(stage.callv("stage_refusal", invalid) != "", "incoherent/future reader stage is refused: %s" % str(invalid))
	_check(SaveContractStage.refusal_reason() == "", SaveContractStage.refusal_reason())
	var manifest: Dictionary = UpdateManifest.build(1, "2030-01-01T00:00:00Z", WireCodec.VERSION, WireCodec.VERSION)["manifest"]
	_check(manifest["shell"]["reads_max"] == CharacterFactory.RECIPE_VERSION, "manifest exposes actual recipe reads")
	_check(manifest["save_schema"]["writes"] == 4, "manifest keeps recipe writes v4")
	_check(manifest["save_schema"]["capability"] == UpdateManifest.SAVE_CAPABILITY_WRITES, "manifest exposes the accepted writer stage")
	for name: String in FINGERPRINTS:
		var recipe: Dictionary = CharacterFactory.load_recipe(CharacterCreator.PRESET_DIR + name + ".json")
		var built := CharacterFactory.build(recipe)
		_check(built != null, "historical preset builds: %s" % name)
		if built != null:
			_check(CharacterFactory.fingerprint(built).ends_with(FINGERPRINTS[name]), "historical fingerprint stays exact: %s" % name)
			built.free()
	for path: String in GOLDEN_FINGERPRINTS:
		var golden: Dictionary = CharacterFactory.load_recipe(path)
		var historical := CharacterFactory.build(golden)
		_check(historical != null, "historical golden builds: %s" % path)
		if historical != null:
			_check(CharacterFactory.fingerprint(historical).ends_with(GOLDEN_FINGERPRINTS[path]), "golden fingerprint stays exact: %s" % path)
			historical.free()
	var planned: Dictionary = CharacterFactory.load_recipe(PLANNED)
	if CharacterFactory.RECIPE_VERSION == 4:
		_check(CharacterFactory.refusal_reason(planned) != "", "preparation cannot open recipe5 yet")
	else:
		_check(CharacterFactory.RECIPE_VERSION == 5, "unplanned recipe reader ceiling is refused")
		if not _failed:
			await _check_expanded_reader(planned)
	_finish()


func _check_expanded_reader(planned: Dictionary) -> void:
	_check(CharacterFactory.refusal_reason(planned) == "", "planned v5 fixture is readable")
	if _failed:
		return
	for version in range(1, 5):
		for key in ["thigh", "calf"]:
			_check(CharacterFactory.refusal_reason({"version": version, "joint_push": {key: 1.1}}) != "", "new leg key cannot hide in old schema")
	_check(CharacterFactory.refusal_reason({"version": 5, "joint_push": {"spine_01": 1.1}}) != "", "unguarded key stays refused")
	_check(CharacterFactory.refusal_reason({"version": 6}) != "", "future recipe stays refused")
	var ordinary: Dictionary = CharacterFactory.load_recipe(CharacterCreator.PRESET_DIR + "wanderer.json")
	var absent := ordinary.duplicate(true)
	absent["version"] = 5
	var historical := CharacterFactory.build(ordinary)
	var expanded := CharacterFactory.build(absent)
	_check(CharacterFactory.fingerprint(historical) == CharacterFactory.fingerprint(expanded), "absent v5 keys do not alter existing character")
	historical.free()
	expanded.free()
	_check_leg_geometry()
	_check_equipment_fit()
	_check_writer_preservation(planned, ordinary)
	_check_update_metadata()
	await _check_real_boot(planned, ordinary)


func _check_leg_geometry() -> void:
	var neutral := CharacterFactory.build({"version": 5})
	var thigh := CharacterFactory.build({"version": 5, "joint_push": {"thigh": 1.2}})
	var calf := CharacterFactory.build({"version": 5, "joint_push": {"calf": 1.2}})
	var short_body := CharacterFactory.build({"version": 5, "joint_push": {"thigh": 0.85, "calf": 0.85}})
	var tall_body := CharacterFactory.build({"version": 5, "joint_push": {"thigh": 1.2, "calf": 1.2}})
	if neutral == null or thigh == null or calf == null or short_body == null or tall_body == null:
		_check(false, "all independent stature controls must build")
		return
	var baseline := _segments(neutral)
	var upper := _segments(thigh)
	var lower := _segments(calf)
	_check(upper.x > baseline.x + 0.05 and absf(upper.y - baseline.y) < 0.00001, "thigh changes upper leg alone")
	_check(lower.y > baseline.y + 0.05 and absf(lower.x - baseline.x) < 0.00001, "calf changes lower leg alone")
	_check(absf(_hip_width(tall_body) - _hip_width(neutral)) < 0.00001, "leg length does not widen the hips")
	var short_height := _height(short_body)
	var tall_height := _height(tall_body)
	_check(tall_height > short_height + 0.2, "actual skinned body stature differs by more than 20cm")
	print("STATURE short=%.6f tall=%.6f upper=%.6f lower=%.6f" % [short_height, tall_height, upper.x, lower.y])
	for built: Node3D in [neutral, thigh, calf, short_body, tall_body]:
		var skeleton := CharacterFactory.find_skeleton(built)
		skeleton.force_update_all_bone_transforms()
		for bone in skeleton.get_bone_count():
			_check(skeleton.get_bone_global_pose(bone).is_equal_approx(skeleton.get_bone_global_rest(bone)), "all leg rests remain TRS-compatible")
		built.free()


func _segments(built: Node3D) -> Vector2:
	var s := CharacterFactory.find_skeleton(built)
	s.force_update_all_bone_transforms()
	var hip := s.get_bone_global_rest(s.find_bone("thigh_l")).origin
	var knee := s.get_bone_global_rest(s.find_bone("calf_l")).origin
	var ankle := s.get_bone_global_rest(s.find_bone("foot_l")).origin
	return Vector2(hip.distance_to(knee), knee.distance_to(ankle))


func _hip_width(built: Node3D) -> float:
	var s := CharacterFactory.find_skeleton(built)
	return s.get_bone_global_rest(s.find_bone("thigh_l")).origin.distance_to(s.get_bone_global_rest(s.find_bone("thigh_r")).origin)


func _height(built: Node3D) -> float:
	var s := CharacterFactory.find_skeleton(built)
	s.force_update_all_bone_transforms()
	var vertices := CharacterFactory.cpu_skin(s, CharacterFactory.find_skinned_mesh(s))
	var low := INF
	var high := -INF
	for vertex in vertices:
		low = minf(low, vertex.y)
		high = maxf(high, vertex.y)
	_check(not vertices.is_empty(), "body height uses real skinned vertices")
	return high - low


func _check_writer_preservation(planned: Dictionary, ordinary: Dictionary) -> void:
	PersistenceTestSupport.remove_file(PROBE)
	_check(CharacterCreator.writer_vocabulary_problem({}, planned) != "", "empty creator cannot originate v5 legs")
	_check(CharacterCreator.writer_vocabulary_problem(ordinary, planned) != "", "ordinary creator cannot originate v5 legs")
	_check(not CharacterStore.save_to(PROBE, planned), "first save cannot originate reader-only schema or leg keys")
	_check(not FileAccess.file_exists(PROBE), "refused first write creates no save")
	_check(CharacterStore.save_to(PROBE, ordinary), "ordinary save stays writable")
	var before := FileAccess.get_file_as_bytes(PROBE)
	_check(not CharacterStore.save_to(PROBE, planned), "old save cannot originate v5")
	_check(FileAccess.get_file_as_bytes(PROBE) == before, "refused expansion leaves old bytes intact")
	var file := FileAccess.open(PROBE, FileAccess.WRITE)
	file.store_string(JSON.stringify(planned, "  ", true, true))
	file.close()
	var loaded: Dictionary = CharacterStore.load_from(PROBE)
	_check(loaded == planned, "reader loads planned state with zero loss")
	var creator := CharacterCreator.new()
	creator._recipe = loaded.duplicate(true)
	creator._initial_recipe = loaded.duplicate(true)
	creator._set_recipe_region_equipment("head", "relic_goggles")
	var edited := creator._recipe.duplicate(true)
	creator.free()
	_check(edited["version"] == 5 and edited["joint_push"] == planned["joint_push"], "ordinary real creator edit preserves v5 and exact new values")
	_check(CharacterCreator.writer_vocabulary_problem(loaded, edited) == "", "creator allows exact future-value preservation")
	_check(CharacterStore.save_to(PROBE, edited), "store permits ordinary edit of already-present v5")
	_check(CharacterStore.load_from(PROBE) == edited, "ordinary edit round-trips every expanded field")
	before = FileAccess.get_file_as_bytes(PROBE)
	for key in ["thigh", "calf"]:
		var changed := edited.duplicate(true)
		changed["joint_push"][key] = 1.05
		_check(CharacterCreator.writer_vocabulary_problem(edited, changed) != "", "creator refuses changing reader-only leg value")
		_check(not CharacterStore.save_to(PROBE, changed), "store refuses changing reader-only leg value")
		_check(FileAccess.get_file_as_bytes(PROBE) == before, "reader-only value refusal preserves bytes")
		var removed := edited.duplicate(true)
		removed["joint_push"].erase(key)
		_check(CharacterCreator.writer_vocabulary_problem(edited, removed) != "", "creator refuses removing reader-only leg data")
		_check(not CharacterStore.save_to(PROBE, removed), "reader-only leg data cannot be removed")
		_check(FileAccess.get_file_as_bytes(PROBE) == before, "refused removal preserves exact bytes")
	var partial := planned.duplicate(true)
	partial["joint_push"].erase("calf")
	file = FileAccess.open(PROBE, FileAccess.WRITE)
	file.store_string(JSON.stringify(partial, "  ", true, true))
	file.close()
	before = FileAccess.get_file_as_bytes(PROBE)
	var partial_edit := partial.duplicate(true)
	partial_edit["equipment"]["head"] = "relic_goggles"
	_check(CharacterCreator.writer_vocabulary_problem(partial, partial_edit) == "", "creator preserves a single existing leg key")
	_check(CharacterStore.save_to(PROBE, partial_edit), "ordinary edit preserves partial expanded state")
	before = FileAccess.get_file_as_bytes(PROBE)
	partial_edit["joint_push"]["calf"] = 1.12
	_check(CharacterCreator.writer_vocabulary_problem(partial, partial_edit) != "", "creator cannot add the missing second leg key")
	_check(not CharacterStore.save_to(PROBE, partial_edit), "store cannot add the missing second leg key")
	_check(FileAccess.get_file_as_bytes(PROBE) == before, "partial-state refusal preserves exact bytes")
	var schema_only := ordinary.duplicate(true)
	schema_only["version"] = 5
	_check(CharacterFactory.write_refusal_reason(schema_only, ordinary) != "", "even an empty schema5 stamp cannot originate")
	for spec: Array in CharacterCreator.writable_bone_sliders():
		_check(not (spec[1] == "joint_push" and spec[2] in ["thigh", "calf"]), "new leg controls stay absent from writable UI")
	PersistenceTestSupport.remove_file(PROBE)


## Reuse the existing independent renderer-geometry oracle: morph mix, original
## inverse binds, and signed nearest TRIANGLE clearance, never nearest vertices.
func _check_equipment_fit() -> void:
	var oracle := load("res://tests/equipment_visibility_test.gd").new() as Node
	var reference := {}
	for factors: Vector2 in [Vector2.ONE, Vector2(0.85, 0.85), Vector2(1.2, 1.2), Vector2(0.85, 1.2), Vector2(1.2, 0.85)]:
		var recipe := {"version": 5, "joint_push": {"thigh": factors.x, "calf": factors.y},
			"equipment": {"legs": "pants_wool", "feet": "boots_worn"}}
		var built := CharacterFactory.build(recipe)
		_check(built != null, "pants and boots build at both leg extremes")
		if built == null:
			continue
		var skeleton := CharacterFactory.find_skeleton(built)
		skeleton.force_update_all_bone_transforms()
		var body := CharacterFactory.find_skinned_mesh(skeleton)
		var drawn: Array = oracle.call("drawn", skeleton, body)
		var surface: Dictionary = oracle.call("build_surface", drawn[0], drawn[1], body.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX])
		for entry: Array in [["pants_wool", "calf_l"], ["boots_worn", "foot_l"]]:
			var garment := skeleton.get_node(NodePath(CharacterFactory.EQUIP_PREFIX + entry[0])) as MeshInstance3D
			var garment_drawn: Array = oracle.call("drawn", skeleton, garment)
			var joint_y := skeleton.get_bone_global_pose(skeleton.find_bone(entry[1])).origin.y
			var joint_band := PackedVector3Array()
			for vertex: Vector3 in garment_drawn[0]:
				if absf(vertex.y - joint_y) < 0.10:
					joint_band.append(vertex)
			_check(joint_band.size() > 20, "fit checks examine actual knee/ankle garment vertices")
			var fraction: float = oracle.call("contributing_fraction", joint_band, surface)
			if factors == Vector2.ONE:
				reference[entry[0]] = fraction
			_check(fraction > 0.5 and fraction >= float(reference[entry[0]]) - 0.03,
				"%s keeps knee/ankle surface clearance at %s (%.5f)" % [entry[0], str(factors), fraction])
			print("STATURE_FIT %s %s contributing=%.6f vertices=%d" % [str(factors), entry[0], fraction, joint_band.size()])
		var buried: float = oracle.call("contributing_fraction", drawn[0], surface)
		_check(buried < 0.1, "coincident-body ablation cannot pass the clearance oracle")
		built.free()
	oracle.free()


func _check_update_metadata() -> void:
	var manifest: Dictionary = UpdateManifest.build(10, "2030-01-01T00:00:00Z", WireCodec.VERSION, WireCodec.VERSION)["manifest"]
	var installed := {"shell_version": DevLog.VERSION, "pack_version": DevLog.VERSION,
		"save_schema": 4, "save_capability": 7, "save_reads_max": 5,
		"protocol": WireCodec.VERSION, "observed_at": "2029-01-01T00:00:00Z"}
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.UP_TO_DATE, "expanded reader accepts its manifest for ordinary saved state")
	installed["pack_version"] = "0.1.0"
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.PACK_UPDATE, "old recipe4 state can accept the reader expansion")
	installed["save_schema"] = 5
	installed["save_capability"] = 8
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.INVALID_MANIFEST, "reader-only publication cannot downstamp pre-existing schema5 state")
	var target := {"version": "0.1.98", "url": "https://updates.example/stature.pck",
		"sha256": "0000000000000000000000000000000000000000000000000000000000000000", "size": 1,
		"read_ceiling": manifest["shell"]["reads_max"], "save_capability": manifest["shell"]["reads_capability_max"],
		"speaks_protocol": manifest["protocol"], "shell_compat": {"min": "0.1.0", "max": "9.0.0"}}
	var old := target.duplicate(true)
	old["version"] = "0.1.99"
	old["read_ceiling"] = 4
	old["save_capability"] = 7
	var state := {"save": {"schema": 5, "capability": 8}, "protocol": manifest["protocol"], "shell_version": DevLog.VERSION}
	var selected := RollbackSelection.select([old, target], state)
	_check(selected["action"] == RollbackSelection.ROLLBACK and selected["version"] == target["version"], "mixed catalogue skips the newer unreadable recipe4 target")
	_check(RollbackSelection.select([old], state)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, "old catalogue cannot claim expanded-state recovery")


func _check_real_boot(planned: Dictionary, ordinary: Dictionary) -> void:
	for recipe: Dictionary in [ordinary, planned]:
		var boot := IsolatedBoot.new("user://stature_real_boot_probe.json")
		var main := boot.boot()
		if main == null:
			_check(false, "stature probe must boot the actual isolated game")
			return
		var file := FileAccess.open(CharacterStore.save_path(), FileAccess.WRITE)
		file.store_string(JSON.stringify(recipe, "  ", true, true))
		file.close()
		var before := FileAccess.get_file_as_bytes(CharacterStore.save_path())
		add_child(main)
		for _frame in 160:
			await get_tree().process_frame
		_check(main.get("_creator") == null, "existing recipe never opens first-run creator")
		_check(main.has_method("_installed_update_facts"), "real update path must separate accepted state from read ceilings")
		if main.has_method("_installed_update_facts"):
			var facts: Dictionary = main.call("_installed_update_facts")
			var expanded := int(recipe["version"]) == 5
			_check(facts.get("save_schema") == (5 if expanded else 4), "real boot uses actual accepted recipe requirement")
			_check(facts.get("save_capability") == (8 if expanded else 7), "real boot retains actual expanded capability requirement")
			_check(facts.get("save_reads_max") == 5, "real boot advertises independent reader ceiling")
		var accepted: Dictionary = CharacterStore.load_saved()
		_check(accepted == recipe, "actual boot read preserves every seeded field")
		var expected := CharacterFactory.build(accepted)
		add_child(expected)
		await get_tree().process_frame
		var player := main.get_node("Wanderer") as Player
		var actual_fp := CharacterFactory.fingerprint(player.get("_character_body"))
		var expected_fp := CharacterFactory.fingerprint(expected)
		print("STATURE_BOOT version=%d actual=%s expected=%s" % [recipe["version"], actual_fp, expected_fp])
		_check(actual_fp == expected_fp, "real boot renders the exact saved character")
		expected.free()
		_check(FileAccess.get_file_as_bytes(CharacterStore.save_path()) == before, "boot leaves accepted character bytes intact")
		main.free()
		_check(boot.real_save_untouched(), "stature boot never touches played state")
		boot = null


func _exit_tree() -> void:
	PersistenceTestSupport.remove_file(PROBE)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _finish() -> void:
	print("TEST FAIL — stature reader stage" if _failed else "TEST PASS — stature reader stage")
	get_tree().quit(1 if _failed else 0)
