extends Node
## Base-owned preparation for #593. Only the exact planned reader stage may
## advance; it must preserve historical characters and keep writers on v4/7.

const EQUIPMENT_ORACLE := preload("res://tests/equipment_visibility_test.gd")
const PLANNED := "res://tests/data/planned_recipe_v5.json"
const HISTORICAL := preload("res://tests/historical/character_factory_v4.gd")
const HISTORICAL_INPUTS := "res://tests/data/stature_historical_inputs.json"
const HISTORICAL_INPUTS_SHA256 := "889296c755569fc46905fd6c60fa751bb0ed97a620d7d7b02094c730e7042def"
const PRESET_DIR := "res://recipes/"
const HISTORICAL_FLAGS := ["WAR_RAGGED_CLOTH_DRAPE", "WAR_RAGGED_WRAP_REFINEMENT", "WAR_RAGGED_CLOTH_DETAIL"]
var _art_flags := {}
var _historical_recipes := {}
var _historical_fingerprints := {}
var _probe := "user://stature_reader_probe.process-%d.json" % OS.get_process_id()
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
var _save: SaveIsolation


func _ready() -> void:
	for flag: String in HISTORICAL_FLAGS:
		_art_flags[flag] = OS.get_environment(flag)
		OS.set_environment(flag, "")
	_check_historical_inputs()
	if _failed:
		_finish()
		return
	_prepare_historical_references()
	if _failed:
		_finish()
		return
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
		var recipe: Dictionary = _historical_recipes[name]
		_check(CharacterFactory.load_recipe(PRESET_DIR + name + ".json") == recipe, "historical preset parser preserves original input: %s" % name)
		var candidate_input := recipe.duplicate(true)
		var built := CharacterFactory.build(candidate_input)
		_check(candidate_input == recipe, "building historical preset cannot mutate its recipe: %s" % name)
		_check(built != null, "historical preset builds: %s" % name)
		if built != null:
			_check_historical_fingerprint(built, name)
			built.free()
	for path: String in GOLDEN_FINGERPRINTS:
		var golden: Dictionary = _historical_recipes[path]
		_check(CharacterFactory.load_recipe(path) == golden, "historical golden parser preserves original input: %s" % path)
		var candidate_input := golden.duplicate(true)
		var historical := CharacterFactory.build(candidate_input)
		_check(candidate_input == golden, "building historical golden cannot mutate its recipe: %s" % path)
		_check(historical != null, "historical golden builds: %s" % path)
		if historical != null:
			_check_historical_fingerprint(historical, path)
			historical.free()
	var planned: Dictionary = CharacterFactory.load_recipe(PLANNED)
	if CharacterFactory.RECIPE_VERSION == 4:
		_check(CharacterFactory.refusal_reason(planned) != "", "preparation cannot open recipe5 yet")
	else:
		_check(CharacterFactory.RECIPE_VERSION == 5, "unplanned recipe reader ceiling is refused")
		if not _failed:
			await _check_expanded_reader(planned)
	_finish()


func _check_historical_inputs() -> void:
	_check(FileAccess.get_sha256(HISTORICAL_INPUTS) == HISTORICAL_INPUTS_SHA256, "historical input manifest stays exact")
	if _failed:
		return
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(HISTORICAL_INPUTS))
	for path: String in document["sha256"]:
		_check(FileAccess.get_sha256(path) == document["sha256"][path], "historical source/asset input stays exact: %s" % path)


func _prepare_historical_references() -> void:
	# Capture ALL original observations before any candidate parser/build can
	# mutate shared imported resources. Expectations never come from the candidate.
	var cases := {}
	for name: String in FINGERPRINTS:
		cases[name] = {"path": PRESET_DIR + name + ".json", "mac": FINGERPRINTS[name]}
	for path: String in GOLDEN_FINGERPRINTS:
		cases[path] = {"path": path, "mac": GOLDEN_FINGERPRINTS[path]}
	for label: String in cases:
		var recipe: Dictionary = HISTORICAL.load_recipe(cases[label]["path"])
		var reference := HISTORICAL.build(recipe.duplicate(true))
		_check(reference != null, "retained historical factory builds: %s" % label)
		if reference == null:
			continue
		var native_reference := HISTORICAL.fingerprint(reference)
		_check(reference.position == Vector3.ZERO, "retained historical visual root stays exact: %s" % label)
		if OS.get_name() == "macOS" and OS.has_feature("arm64") and Engine.get_version_info()["hex"] == 0x040701:
			_check(native_reference.ends_with(cases[label]["mac"]), "retained macOS fingerprint anchor stays exact: %s" % label)
		_historical_recipes[label] = recipe
		_historical_fingerprints[label] = native_reference
		reference.free()


func _check_historical_fingerprint(current: Node3D, label: String) -> void:
	var observed := HISTORICAL.fingerprint(current)
	_check(observed == _historical_fingerprints[label], "exact native historical fingerprint stays unchanged: %s" % label)
	_check(CharacterFactory.fingerprint(current) == observed, "production fingerprint keeps its historical algorithm: %s" % label)
	_check(current.position == Vector3.ZERO, "historical visual root stays exact: %s" % label)

func _check_expanded_reader(planned: Dictionary) -> void:
	_check(CharacterFactory.refusal_reason(planned) == "", "planned v5 fixture is readable")
	if _failed:
		return
	for version in range(1, 5):
		for key in ["thigh", "calf"]:
			_check(CharacterFactory.refusal_reason({"version": version, "joint_push": {key: 1.1}}) != "", "new leg key cannot hide in old schema")
	_check(CharacterFactory.refusal_reason({"version": 5, "joint_push": {"spine_01": 1.1}}) != "", "unguarded key stays refused")
	_check(CharacterFactory.refusal_reason({"version": 6}) != "", "future recipe stays refused")
	var ordinary: Dictionary = CharacterFactory.load_recipe(PRESET_DIR + "wanderer.json")
	var absent := ordinary.duplicate(true)
	absent["version"] = 5
	var historical := CharacterFactory.build(ordinary)
	var expanded := CharacterFactory.build(absent)
	_check(CharacterFactory.fingerprint(historical) == CharacterFactory.fingerprint(expanded), "absent v5 keys do not alter existing character")
	_check(historical.position == Vector3.ZERO and expanded.position == historical.position, "absent v5 keys preserve historical visual root")
	historical.free()
	expanded.free()
	_check_leg_geometry()
	_check_equipment_fit()
	await _check_ground_contact()
	_check_writer_preservation(planned, ordinary)
	_check_reader_only_clear(planned, ordinary)


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
	PersistenceTestSupport.remove_file(_probe)
	_check(CharacterCreator.writer_vocabulary_problem({}, planned) != "", "empty creator cannot originate v5 legs")
	_check(CharacterCreator.writer_vocabulary_problem(ordinary, planned) != "", "ordinary creator cannot originate v5 legs")
	_check(not CharacterStore.save_to(_probe, planned), "first save cannot originate reader-only schema or leg keys")
	_check(not FileAccess.file_exists(_probe), "refused first write creates no save")
	_check(CharacterStore.save_to(_probe, ordinary), "ordinary save stays writable")
	var before := FileAccess.get_file_as_bytes(_probe)
	_check(not CharacterStore.save_to(_probe, planned), "old save cannot originate v5")
	_check(FileAccess.get_file_as_bytes(_probe) == before, "refused expansion leaves old bytes intact")
	var file := FileAccess.open(_probe, FileAccess.WRITE)
	file.store_string(JSON.stringify(planned, "  ", true, true))
	file.close()
	var loaded: Dictionary = CharacterStore.load_from(_probe)
	_check(loaded == planned, "reader loads planned state with zero loss")
	var creator := CharacterCreator.new()
	creator._recipe = loaded.duplicate(true)
	creator._initial_recipe = loaded.duplicate(true)
	creator._set_recipe_region_equipment("head", "relic_goggles")
	var edited := creator._recipe.duplicate(true)
	creator.free()
	_check(edited["version"] == 5 and edited["joint_push"] == planned["joint_push"], "ordinary real creator edit preserves v5 and exact new values")
	_check(CharacterCreator.writer_vocabulary_problem(loaded, edited) == "", "creator allows exact future-value preservation")
	_check(CharacterStore.save_to(_probe, edited), "store permits ordinary edit of already-present v5")
	_check(CharacterStore.load_from(_probe) == edited, "ordinary edit round-trips every expanded field")
	before = FileAccess.get_file_as_bytes(_probe)
	for key in ["thigh", "calf"]:
		var changed := edited.duplicate(true)
		changed["joint_push"][key] = 1.05
		_check(CharacterCreator.writer_vocabulary_problem(edited, changed) != "", "creator refuses changing reader-only leg value")
		_check(not CharacterStore.save_to(_probe, changed), "store refuses changing reader-only leg value")
		_check(FileAccess.get_file_as_bytes(_probe) == before, "reader-only value refusal preserves bytes")
		var removed := edited.duplicate(true)
		removed["joint_push"].erase(key)
		_check(CharacterCreator.writer_vocabulary_problem(edited, removed) != "", "creator refuses removing reader-only leg data")
		_check(not CharacterStore.save_to(_probe, removed), "reader-only leg data cannot be removed")
		_check(FileAccess.get_file_as_bytes(_probe) == before, "refused removal preserves exact bytes")
	var partial := planned.duplicate(true)
	partial["joint_push"].erase("calf")
	file = FileAccess.open(_probe, FileAccess.WRITE)
	file.store_string(JSON.stringify(partial, "  ", true, true))
	file.close()
	before = FileAccess.get_file_as_bytes(_probe)
	var partial_edit := partial.duplicate(true)
	partial_edit["equipment"]["head"] = "relic_goggles"
	_check(CharacterCreator.writer_vocabulary_problem(partial, partial_edit) == "", "creator preserves a single existing leg key")
	_check(CharacterStore.save_to(_probe, partial_edit), "ordinary edit preserves partial expanded state")
	before = FileAccess.get_file_as_bytes(_probe)
	partial_edit["joint_push"]["calf"] = 1.12
	_check(CharacterCreator.writer_vocabulary_problem(partial, partial_edit) != "", "creator cannot add the missing second leg key")
	_check(not CharacterStore.save_to(_probe, partial_edit), "store cannot add the missing second leg key")
	_check(FileAccess.get_file_as_bytes(_probe) == before, "partial-state refusal preserves exact bytes")
	var schema_only := ordinary.duplicate(true)
	schema_only["version"] = 5
	_check(CharacterFactory.write_refusal_reason(schema_only, ordinary) != "", "even an empty schema5 stamp cannot originate")
	for spec: Array in CharacterCreator.writable_bone_sliders():
		_check(not (spec[1] == "joint_push" and spec[2] in ["thigh", "calf"]), "new leg controls stay absent from writable UI")
	PersistenceTestSupport.remove_file(_probe)


## Reuse the existing independent renderer-geometry oracle: morph mix, original
## inverse binds, and signed nearest TRIANGLE clearance, never nearest vertices.
func _check_equipment_fit() -> void:
	var oracle := EQUIPMENT_ORACLE.new() as Node
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


## Measure the rendered body and boot soles after real Player capsules settle.
## The historical contact is the reference; moving test actors to fit their
## geometry would hide the exact floating/sinking regression this checks.
func _check_ground_contact() -> void:
	var stage := Node3D.new()
	add_child(stage)
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(100.0, 0.1, 30.0)
	collision.shape = shape
	collision.position.y = -0.05
	floor_body.add_child(collision)
	stage.add_child(floor_body)
	var oracle := EQUIPMENT_ORACLE.new() as Node
	var players: Array[Player] = []
	var labels: Array[String] = []
	for preset: String in FINGERPRINTS:
		for factors: Vector2 in [Vector2.ONE, Vector2(0.85, 0.85), Vector2(1.2, 1.2), Vector2(0.85, 1.2), Vector2(1.2, 0.85)]:
			var recipe: Dictionary = CharacterFactory.load_recipe(PRESET_DIR + preset + ".json")
			recipe["equipment"]["feet"] = "boots_worn"
			if factors != Vector2.ONE:
				recipe["version"] = 5
				recipe["joint_push"] = recipe.get("joint_push", {})
				recipe["joint_push"]["thigh"] = factors.x
				recipe["joint_push"]["calf"] = factors.y
			var player := Player.new()
			player.control_enabled = false
			stage.add_child(player)
			player.position = Vector3(float(players.size() - 10) * 2.0, 2.0, 0.0)
			player.set_character(recipe)
			var body := player.get("_character_body") as Node3D
			body.process_mode = Node.PROCESS_MODE_DISABLED
			players.append(player)
			labels.append("%s %s" % [preset, str(factors)])
	for _frame in 100:
		await get_tree().physics_frame
	var reference := Vector3.ZERO
	var reference_capsule: Array = []
	for index in players.size():
		var player := players[index]
		_check(player.is_on_floor(), "actual Player capsule settles on the floor: " + labels[index])
		player.set_physics_process(false)
		var body := player.get("_character_body") as Node3D
		var skeleton := CharacterFactory.find_skeleton(body)
		skeleton.reset_bone_poses()
		skeleton.force_update_all_bone_transforms()
		var mesh := CharacterFactory.find_skinned_mesh(skeleton)
		var boots := skeleton.get_node(NodePath(CharacterFactory.EQUIP_PREFIX + "boots_worn")) as MeshInstance3D
		var body_drawn: Array = oracle.call("drawn", skeleton, mesh)
		var boots_drawn: Array = oracle.call("drawn", skeleton, boots)
		var contact := Vector3(_lowest_world_y(skeleton, body_drawn[0]), _lowest_world_y(skeleton, boots_drawn[0]), player.global_position.y)
		if index % 5 == 0:
			_check(body.position == Vector3.ZERO, "historical visual root remains exact: " + labels[index])
			reference = contact
			reference_capsule = _capsule_signature(player)
		_check(absf(contact.x - reference.x) < 0.003, "body sole keeps historical floor contact within 3mm: " + labels[index])
		_check(absf(contact.y - reference.y) < 0.003, "boot sole keeps historical floor contact within 3mm: " + labels[index])
		_check(_capsule_signature(player) == reference_capsule, "stature preserves exact capsule geometry and offset: " + labels[index])
		print("STATURE_GROUND %s body_delta=%.6f boot_delta=%.6f" % [labels[index], contact.x - reference.x, contact.y - reference.y])
	oracle.free()
	stage.free()


func _capsule_signature(player: Player) -> Array:
	for child: Node in player.get_children():
		if child is CollisionShape3D and child.shape is CapsuleShape3D:
			return [child.shape.radius, child.shape.height, child.transform]
	_check(false, "grounding oracle must find the actual Player capsule")
	return []


func _lowest_world_y(skeleton: Skeleton3D, vertices: PackedVector3Array) -> float:
	_check(not vertices.is_empty(), "contact oracle examines real rendered vertices")
	var low := INF
	for vertex: Vector3 in vertices:
		low = minf(low, (skeleton.global_transform * vertex).y)
	return low


func _check_reader_only_clear(planned: Dictionary, ordinary: Dictionary) -> void:
	_save = SaveIsolation.new("user://stature_clear_probe.json")
	if not _save.begin():
		_check(false, "delete probe must isolate every save seam")
		return
	var path := CharacterStore.save_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(planned, "  ", true, true))
	file.close()
	var before := FileAccess.get_file_as_bytes(path)
	_check(CharacterStore.load_saved() == planned, "clear probe uses accepted expanded state")
	CharacterStore.clear()
	_check(FileAccess.get_file_as_bytes(path) == before, "reader-only delete preserves expanded bytes")
	_check(not FileLock.owns(path), "refused expanded delete holds no writer lock")
	_check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(FileLock.path_for(path))), "refused delete removes its lock directory")
	_check(FileLock.acquire(path), "refused expanded delete releases its writer lock")
	FileLock.release(path)
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(ordinary, "  ", true, true))
	file.close()
	CharacterStore.clear()
	_check(not FileAccess.file_exists(path), "ordinary supported deletion remains functional")
	_check(_save.real_save_untouched(), "delete probe never touches played state")


func _exit_tree() -> void:
	PersistenceTestSupport.remove_file(_probe)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " — save isolation breach"
	print("TEST FAIL — " + message)
	get_tree().quit(1)


func _finish() -> void:
	for flag: String in _art_flags:
		OS.set_environment(flag, _art_flags[flag])
	if _failed:
		_fail("stature reader stage")
		return
	if _save != null and not _save.real_save_untouched():
		_fail("stature reader save isolation")
		return
	print("TEST PASS — stature reader stage")
	get_tree().quit(0)
