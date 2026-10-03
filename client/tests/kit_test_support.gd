class_name KitTestSupport
extends RefCounted
## Test-only kit inspection and CPU morph oracle. This reads imported mesh
## arrays independently of production assembly, so deterministic composition
## checks cannot agree with a bug by sharing the assembler under test.


static func load_contract(scene_path: String, report_path: String) -> Dictionary:
	var report := read_report(report_path)
	if report.is_empty():
		return {"problem": "cannot read %s" % report_path}
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return {"problem": "kit GLB missing or unimported: %s" % scene_path}
	var kit := packed.instantiate()
	var skeleton := find_skeleton(kit)
	var problem := ""
	if skeleton == null:
		problem = "no Skeleton3D in the kit"
	elif skeleton.get_bone_count() != int(report["bones"]):
		problem = "bone count %d != contracted %s" % [skeleton.get_bone_count(), report["bones"]]
	if not problem.is_empty():
		kit.free()
		return {"problem": problem}
	var mesh_instance := find_skinned_mesh(skeleton)
	if mesh_instance == null:
		kit.free()
		return {"problem": "no skinned MeshInstance3D under the kit skeleton"}
	return {"problem": "", "kit": kit, "mesh": mesh_instance.mesh, "report": report}


static func read_report(report_path: String) -> Dictionary:
	var f := FileAccess.open(report_path, FileAccess.READ)
	if f == null:
		return {}
	var out := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.contains("="):
			out[line.get_slice("=", 0)] = line.get_slice("=", 1)
	return out


## Compare imported shape count and order with the caller's historical contract.
## Vocabulary is diagnostic only; creature and humanoid suites retain their labels.
static func shape_contract_problem(mesh: Mesh, names: PackedStringArray, label: String) -> String:
	if mesh.get_blend_shape_count() != names.size():
		return "%s count %d != contracted %d" % [label, mesh.get_blend_shape_count(), names.size()]
	for index in names.size():
		var actual := String(mesh.get_blend_shape_name(index))
		if actual != names[index]:
			return "%s %d is '%s', contract says '%s' — shipped shape names may never change" % [label, index, actual, names[index]]
	return ""


static func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


static func find_skinned_mesh(skel: Skeleton3D) -> MeshInstance3D:
	for child in skel.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			return child
	return null


static func base_vertices(mesh: Mesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


## base + sum(weight * delta). Normalized targets store absolute positions;
## relative targets store offsets. Hash the mixed raw vertex bytes unchanged.
static func mix_fingerprint(mesh: Mesh, weights: Dictionary) -> String:
	var base := base_vertices(mesh)
	var mixed := PackedVector3Array(base)
	var blends := mesh.surface_get_blend_shape_arrays(0)
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for shape_name: String in weights:
		var idx := -1
		for i in mesh.get_blend_shape_count():
			if String(mesh.get_blend_shape_name(i)) == shape_name:
				idx = i
				break
		if idx < 0:
			return "missing-shape:%s" % shape_name
		var targets: PackedVector3Array = blends[idx][Mesh.ARRAY_VERTEX]
		var w: float = weights[shape_name]
		for v in mixed.size():
			var delta := targets[v] - base[v] if normalized else targets[v]
			mixed[v] += delta * w
	return hash_bytes(mixed.to_byte_array())


static func hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
