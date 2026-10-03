extends Node
## Literal pre-render transforms avoid the headless MultiMesh readback gap.

func _ready() -> void:
	var script := load("res://scripts/cosmetic_instances.gd") as GDScript
	if script == null or not script.has_method("transforms"):
		_fail("cosmetic transforms need an inspectable ordered builder")
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 4, 1)
	var items: Array = [
		{"pos": Vector3(2, 3, 5), "scale": 2.0, "yaw": PI / 2.0},
		{"pos": Vector3(-4, 1, 7), "scale": 0.5, "yaw": 0.0},
	]
	var original := items.duplicate(true)
	var transforms: Array = script.call("transforms", mesh, items)
	if transforms.size() != 2 or items != original:
		_fail("ordered construction must leave caller placement records untouched")
		return
	var first: Transform3D = transforms[0]
	if not first.origin.is_equal_approx(Vector3(2, 6.2, 5)) \
			or not first.basis.x.is_equal_approx(Vector3(0, 0, -2)) \
			or not first.basis.y.is_equal_approx(Vector3(0, 2, 0)) \
			or not first.basis.z.is_equal_approx(Vector3(2, 0, 0)):
		_fail("yaw, scale or ground lift changed")
		return
	var second: Transform3D = transforms[1]
	if not second.origin.is_equal_approx(Vector3(-4, 1.8, 7)) \
			or not second.basis.is_equal_approx(Basis.IDENTITY.scaled(Vector3.ONE * 0.5)):
		_fail("placement order or per-item scale changed")
		return
	var batch: MultiMesh = script.call("batch", mesh, transforms)
	if batch.mesh != mesh or batch.instance_count != 2 \
			or batch.transform_format != MultiMesh.TRANSFORM_3D:
		_fail("batch must preserve mesh, count and 3D format")
		return
	print("TEST PASS — cosmetic transform axes, lift, order and ownership")
	get_tree().quit(0)

func _fail(reason: String) -> void:
	push_error("TEST FAIL — " + reason)
	get_tree().quit(1)
