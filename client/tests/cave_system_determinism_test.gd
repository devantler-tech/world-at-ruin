extends Node
## Regression test for the cave-system generator (issue #24, WoW-style
## redirect): deterministic, seed-sensitive, and structurally a CAVE SYSTEM.
##  1. Same seed twice ⇒ identical vertex-stream fingerprint.
##  2. Different seed ⇒ different system.
##  3. The layout is a system: multiple rooms, a descending spine (the main
##     chamber floor is genuinely BELOW the mouth), and every tunnel's floors
##     stay within walkable slope.
##  4. The mesh is real and smooth-shaded: shared-vertex surface (indexed,
##     far fewer vertices than raw triangle corners), normals present.
##
## Run: godot --headless --path client res://tests/cave_system_determinism_test.tscn

const SEED_A := 42
const SEED_B := 43
const MAX_TUNNEL_SLOPE := 0.62 ## rise/run ≈ 32° — walkable without jumping.

func _ready() -> void:
	var a1: Dictionary = CaveSystemGen.build_geometry(SEED_A)
	var a2: Dictionary = CaveSystemGen.build_geometry(SEED_A)
	var b: Dictionary = CaveSystemGen.build_geometry(SEED_B)

	var fp_a1 := CaveSystemGen.fingerprint(a1["mesh"])
	if fp_a1 != CaveSystemGen.fingerprint(a2["mesh"]):
		_fail("same seed produced different systems")
		return
	if fp_a1 == CaveSystemGen.fingerprint(b["mesh"]):
		_fail("different seeds produced identical systems")
		return

	var lay: Dictionary = a1["layout"]
	if (lay["rooms"] as Array).size() < 3:
		_fail("not a system: %d rooms" % (lay["rooms"] as Array).size())
		return
	var floors: PackedFloat32Array = lay["floors"]
	if floors[3] > floors[0] - 3.0:
		_fail("the system does not descend: mouth floor %.1f, main chamber floor %.1f" % [floors[0], floors[3]])
		return
	var path: Array = lay["path"]
	for i in path.size() - 1:
		var run := Vector2((path[i + 1] as Vector3).x - (path[i] as Vector3).x,
			(path[i + 1] as Vector3).z - (path[i] as Vector3).z).length()
		var rise := absf(floors[i + 1] - floors[i])
		if rise / maxf(run, 0.001) > MAX_TUNNEL_SLOPE:
			_fail("tunnel %d too steep: rise %.1f over run %.1f" % [i, rise, run])
			return

	var arrays := (a1["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if verts.size() < 3000 or indices.size() < 9000:
		_fail("suspiciously small mesh: %d verts, %d indices" % [verts.size(), indices.size()])
		return
	if normals.size() != verts.size():
		_fail("missing normals")
		return
	# Shared vertices are the smooth-shading substrate: an indexed surface
	# reuses each vertex ~6x; a faceted (foil-look) mesh would not.
	if float(indices.size()) / float(verts.size()) < 3.0:
		_fail("mesh is not vertex-shared (faceted): %d indices / %d verts" % [indices.size(), verts.size()])
		return

	print("TEST PASS — %s, rooms=%d, descent=%.1f m" %
		[fp_a1, (lay["rooms"] as Array).size(), floors[0] - floors[3]])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
