extends Node
## Regression test for the Phase 0 art pipeline (issue #20): the cave
## generator must be deterministic, seed-sensitive, and actually carved.
##  1. Same seed twice ⇒ identical geometry fingerprint (vertex-stream hash).
##  2. Different seed ⇒ different fingerprint (the seed genuinely steers it).
##  3. The entrance cut removed triangles, and the floor band holds: no vertex
##     sits meaningfully below the rumpled floor.
##
## Run: godot --headless --path client res://tests/cave_determinism_test.tscn

const SEED_A := 42
const SEED_B := 43
const RADIUS := 8.0


func _ready() -> void:
	var a1 := CaveGen.build_mesh(SEED_A, RADIUS)
	var a2 := CaveGen.build_mesh(SEED_A, RADIUS)
	var b := CaveGen.build_mesh(SEED_B, RADIUS)

	var fp_a1 := CaveGen.fingerprint(a1)
	var fp_a2 := CaveGen.fingerprint(a2)
	var fp_b := CaveGen.fingerprint(b)

	if fp_a1 != fp_a2:
		_fail("same seed produced different caves:\n  %s\n  %s" % [fp_a1, fp_a2])
		return
	if fp_a1 == fp_b:
		_fail("different seeds produced identical caves: %s" % fp_a1)
		return

	var arrays := a1.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.size() == 0:
		_fail("empty cave")
		return

	# 20 icosahedron faces * 4^SUBDIVISIONS with no cut would be 20480 tris;
	# the entrance must have removed some. SurfaceTool.commit() indexes the
	# mesh, so count triangles from whichever stream is present.
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var tri_count: int = (indices.size() if indices.size() > 0 else verts.size()) / 3
	if tri_count >= 20480:
		_fail("no entrance cut: %d tris" % tri_count)
		return

	var floor_limit := -0.55 * RADIUS - 0.08 * RADIUS * 2.0
	for v in verts:
		if v.z < floor_limit:
			_fail("vertex below the floor band: z=%f < %f" % [v.z, floor_limit])
			return

	print("TEST PASS — %s" % fp_a1)
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
