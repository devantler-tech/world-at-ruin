extends Node
## Regression test for cave-system CONNECTIVITY (issue #84) — the traversability
## guard the determinism test does not cover.
##
## The cave is the player's waking place. Its walkable void is carved as an SDF
## from rooms + tunnels, blended with a smooth-min and perturbed by wall noise.
## `cave_system_determinism_test` pins that the mesh is reproducible and its
## spine slopes are walkable; this pins that the void is actually CONNECTED —
## that a wanderer can reach every room and walk out through the mouth to open
## air. Under the no-resets law a player sealed into an unreachable pocket is
## trapped forever, so this must hold before the first player ever exists.
##
## What it proves:
##  1. On the shipped seeds, the flood from the waking chamber reaches the spawn,
##     every room centre, and open air beyond the mouth (the bored breach).
##  2. The audit is deterministic (same seed ⇒ identical reachability).
##  3. It has teeth: on a synthetic field split by a rock wall the flood reaches
##     one pocket and NOT the other, and flooding from rock reaches nothing —
##     so a genuinely severed void could never read as connected.
##
## Pure logic only — no scene, no save, no boot — safe to run locally.
##
## Run: godot --headless --path client res://tests/cave_connectivity_test.tscn

var _failed := false


func _ready() -> void:
	# --- the shipped world is fully connected, on more than one seed ---
	for s: int in [42, 43]:
		var r := CaveSystemGen.reachability(s)
		_check(r["start_found"], true, "seed %d: the waking chamber is void (flood has a start)" % s)
		_check(r["spawn_reachable"], true, "seed %d: the spawn is reachable through the void" % s)
		_check(r["mouth_open"], true, "seed %d: open air beyond the mouth is reachable (the breach is open)" % s)
		var rooms: Array = r["rooms_reachable"]
		_check(rooms.size() >= 3, true, "seed %d: it is a multi-room system" % s)
		for i in rooms.size():
			_check(rooms[i], true, "seed %d: room %d is reachable" % [s, i])
		# Non-vacuous: real void was flooded, and rock exists (not everything is void).
		var reached: int = r["reached"]
		var total: int = r["total"]
		_check(reached > 1000, true, "seed %d: a substantial void was flooded (%d cells)" % [s, reached])
		_check(reached < total, true, "seed %d: rock is present (flood did not cover the whole field)" % s)
		if _failed:
			return

	# --- determinism: the same seed audits identically ---
	var a := CaveSystemGen.reachability(42)
	var b := CaveSystemGen.reachability(42)
	_check(a["reached"] == b["reached"], true, "determinism: the reachable-cell count is stable")
	_check(a["mouth_open"] == b["mouth_open"] and a["rooms_reachable"] == b["rooms_reachable"], true,
		"determinism: the reachability flags are stable")
	if _failed:
		return

	# --- teeth: a rock wall genuinely severs the flood ---
	if not _severed_pocket_is_unreachable():
		return

	print("TEST PASS — cave void is connected (spawn, every room, and the mouth), deterministic, and the flood provably stops at rock")
	get_tree().quit(0)


## A synthetic 5×1×5 corner field: two void pockets (x∈{0,1} and x∈{3,4})
## separated by a solid rock wall at x=2. Flooding from pocket A must reach all
## of A and none of B, and flooding from the rock wall must reach nothing — proof
## the flood distinguishes a connected region from a severed one.
func _severed_pocket_is_unreachable() -> bool:
	var nx := 5
	var ny := 1
	var nz := 5
	var f := PackedFloat32Array()
	f.resize(nx * ny * nz)
	for ix in nx:
		for iz in nz:
			f[ix * nz + iz] = 1.0 if ix == 2 else -1.0

	var seen := CaveSystemGen.flood_void(f, nx, ny, nz, Vector3i(0, 0, 0))
	var reached := 0
	for i in seen.size():
		reached += seen[i]
	_check(reached == 10, true, "teeth: pocket A is exactly its 10 void cells (got %d)" % reached)
	_check(seen[CaveSystemGen._fi(Vector3i(0, 0, 0), ny, nz)] == 1, true, "teeth: the start cell is reached")
	_check(seen[CaveSystemGen._fi(Vector3i(1, 0, 4), ny, nz)] == 1, true, "teeth: pocket A's far corner is reached")
	_check(seen[CaveSystemGen._fi(Vector3i(3, 0, 0), ny, nz)] == 0, true, "teeth: pocket B across the wall is NOT reached")
	_check(seen[CaveSystemGen._fi(Vector3i(4, 0, 4), ny, nz)] == 0, true, "teeth: pocket B's far corner is NOT reached")

	var from_rock := CaveSystemGen.flood_void(f, nx, ny, nz, Vector3i(2, 0, 0))
	var rr := 0
	for i in from_rock.size():
		rr += from_rock[i]
	_check(rr == 0, true, "teeth: flooding from rock reaches nothing (got %d)" % rr)
	return not _failed


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_fail("%s — expected %s, got %s" % [label, expected, actual])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
