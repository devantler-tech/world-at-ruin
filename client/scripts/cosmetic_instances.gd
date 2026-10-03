class_name CosmeticInstances
extends RefCounted
## Ordered cosmetic transforms, inspectable before RenderingServer submission.
## Placement records stay caller-owned: foliage records rendered positions;
## cave talus retains sampled positions and owns its batch cleanup.

static func transforms(mesh: Mesh, items: Array) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var lift := mesh.get_aabb().size.y * 0.4
	for placement: Dictionary in items:
		var pos: Vector3 = placement["pos"]
		var prop_scale := float(placement["scale"])
		var basis := Basis(Vector3.UP, float(placement["yaw"])).scaled(Vector3.ONE * prop_scale)
		var rendered := Vector3(pos.x, pos.y + lift * prop_scale, pos.z)
		result.append(Transform3D(basis, rendered))
	return result

static func batch(mesh: Mesh, poses: Array[Transform3D]) -> MultiMesh:
	var result := MultiMesh.new()
	result.transform_format = MultiMesh.TRANSFORM_3D
	result.mesh = mesh
	result.instance_count = poses.size()
	for i in poses.size():
		result.set_instance_transform(i, poses[i])
	return result
