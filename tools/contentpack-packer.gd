extends SceneTree
## Native pack construction runs only inside the operator's private imported snapshot.


## Packages the validated source and its generated import closure in sorted native order.
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		_fail("pack helper requires the selected inventory and two staged outputs")
		return
	var selected: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not (selected is Array) or selected.is_empty():
		_fail("selected inventory is empty or invalid")
		return
	var names: Dictionary = {}
	for item: Dictionary in selected:
		var name: String = item["path"]
		names[name] = true
		# An exported base may map text resources to old compiled siblings.
		# Explicit identity remaps make the overlay's source win that lookup.
		if name.get_extension() in ["gd", "tres", "tscn"]:
			var remap := ConfigFile.new()
			remap.set_value("remap", "path", "res://" + name)
			if remap.save("res://" + name + ".remap") != OK:
				_fail("exported-base identity remap could not be staged")
				return
			names[name + ".remap"] = true
		if FileAccess.file_exists("res://" + name + ".uid"):
			names[name + ".uid"] = true
		if FileAccess.file_exists("res://" + name + ".import"):
			names[name + ".import"] = true
	var imported_names: Array = names.keys()
	for name: String in imported_names:
		if name.ends_with(".import"):
			var config := ConfigFile.new()
			if config.load("res://" + name) != OK:
				_fail("import remap cannot be read")
				return
			for target: String in config.get_value("deps", "dest_files", []):
				if not target.begins_with("res://.godot/imported/") or target.contains(".."):
					_fail("import remap escapes the generated resource closure")
					return
				names[target.trim_prefix("res://")] = true
	var ordered: Array = names.keys()
	ordered.sort()
	# The native scene importer assigns arbitrary subresource IDs. Re-emitting
	# through ResourceSaver with traversal-stable IDs preserves runtime values
	# while making the generated scene bytes reproducible across clean imports.
	for name: String in ordered:
		if name.begins_with(".godot/imported/") and name.ends_with(".scn"):
			var scene := ResourceLoader.load("res://" + name, "", ResourceLoader.CACHE_MODE_IGNORE)
			if scene == null:
				_fail("imported scene cannot be normalized natively")
				return
			_stable_resource_ids(scene, {})
			var bundle: Dictionary = scene.get("_bundled")
			var node_count: int = bundle.get("node_count", -1)
			var node_ids: Variant = bundle.get("node_ids")
			var id_paths: Variant = bundle.get("id_paths")
			if (
				node_count <= 0 or node_count > 10000
				or not (node_ids is PackedInt32Array) or node_ids.size() != node_count
				or not (id_paths is Array) or not id_paths.is_empty()
			):
				_fail("imported scene has unsupported node-ID references")
				return
			var stable_ids := PackedInt32Array()
			for index in range(node_count):
				stable_ids.append(index + 1)
			bundle["node_ids"] = stable_ids
			scene.set("_bundled", bundle)
			if ResourceSaver.save(scene, "res://" + name) != OK:
				_fail("deterministic imported scene could not be saved natively")
				return
	var packer := PCKPacker.new()
	if packer.pck_start(args[1]) != OK:
		_fail("native pack could not start")
		return
	var resources: Array = []
	for name: String in ordered:
		var source := "res://" + name
		var raw := FileAccess.get_file_as_bytes(source)
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK or digest.update(raw) != OK:
			_fail("resource digest failed")
			return
		if packer.add_file(source, ProjectSettings.globalize_path(source)) != OK:
			_fail("selected resource could not enter native pack")
			return
		resources.append({"path": name, "sha256": digest.finish().hex_encode(), "size": raw.size()})
	if packer.flush() != OK:
		_fail("native pack flush failed")
		return
	var inventory := FileAccess.open(args[2], FileAccess.WRITE)
	if inventory == null:
		_fail("native resource inventory could not be staged")
		return
	inventory.store_string(JSON.stringify(resources))
	inventory.close()
	print("PACK BUILD PASS — %d cumulative resources" % resources.size())
	quit(0)


## Reports a native build refusal instead of producing a success marker.
func _fail(message: String) -> void:
	push_error(message)
	quit(1)


## Assigns deterministic resource IDs while visiting shared resources only once.
func _stable_resource_ids(value: Variant, seen: Dictionary) -> void:
	if value is Resource:
		var resource: Resource = value
		if seen.has(resource.get_instance_id()):
			return
		seen[resource.get_instance_id()] = true
		resource.resource_scene_unique_id = "content_%d" % seen.size()
		var properties := resource.get_property_list()
		properties.sort_custom(_property_name_less)
		for property: Dictionary in properties:
			if int(property["usage"]) & PROPERTY_USAGE_STORAGE:
				_stable_resource_ids(resource.get(property["name"]), seen)
	elif value is Array:
		for item: Variant in value:
			_stable_resource_ids(item, seen)
	elif value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			_stable_resource_ids(value[key], seen)


## Orders serialization traversal by property name, independent of discovery order.
func _property_name_less(a: Dictionary, b: Dictionary) -> bool:
	return str(a["name"]) < str(b["name"])
