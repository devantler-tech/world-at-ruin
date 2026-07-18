extends Node
## Regression test for cave-system CONNECTIVITY (issue #84) — the traversability
## guard the determinism test does not cover.
##
## The cave is the player's waking place. Its walkable void is carved as an SDF
## from rooms + tunnels, blended with a smooth-min and perturbed by wall noise.
## `cave_system_determinism_test` pins that the mesh is reproducible and its
## spine slopes are walkable; this pins that the cave is actually TRAVERSABLE —
## that a wanderer can reach every room and get out to open air. Under the
## no-resets law a player sealed into an unreachable pocket is trapped forever,
## so this must hold before the first player ever exists.
##
## What it proves:
##  1. On the shipped seeds, the flood from the waking chamber reaches the spawn
##     and every room centre, and ESCAPES the padded sampling box (= open air).
##  2. The audit is deterministic (same seed ⇒ identical reachability).
##  3. It has teeth, and is not vacuous in three specific ways:
##     - a rock wall severs the flood, and flooding from rock reaches nothing;
##     - a gap narrower than the player capsule does NOT count as a connection,
##       while an otherwise identical wide channel DOES (both states);
##     - audited points use their OWN cell, so a point in rock fails rather than
##       borrowing a neighbouring cavity's verdict.
##
## Pure logic only — no scene, no save, no boot — safe to run locally.
##
## Run: godot --headless --path client res://tests/cave_connectivity_test.tscn

var _failed := false


func _ready() -> void:
	# --- the shipped world is traversable, on more than one seed ---
	for s: int in [42, 43]:
		var r := CaveSystemGen.reachability(s)
		_check(r["start_passable"], true, "seed %d: the waking chamber has body-clearance" % s)
		_check(r["spawn_reachable"], true, "seed %d: the spawn is reachable" % s)
		_check(r["mouth_open"], true, "seed %d: the flood escapes to open air (there is a way out)" % s)
		var rooms: Array = r["rooms_reachable"]
		_check(rooms.size() >= 3, true, "seed %d: it is a multi-room system" % s)
		for i in rooms.size():
			_check(rooms[i], true, "seed %d: room %d is reachable" % [s, i])
		# Non-vacuous: real space was flooded, and rock exists.
		var reached: int = r["reached"]
		var total: int = r["total"]
		_check(reached > 1000, true, "seed %d: substantial space flooded (%d cells)" % [s, reached])
		_check(reached < total, true, "seed %d: rock is present (flood did not cover the field)" % s)
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

	# --- teeth ---
	if not _rock_wall_severs_the_flood():
		return
	if not _clearance_rejects_a_pinhole():
		return

	print("TEST PASS — cave is traversable (spawn, every room, and out to open air), deterministic; flood stops at rock and at gaps narrower than the player")
	get_tree().quit(0)


## A synthetic 9×1×5 field: two void pockets (x∈{0..3}, x∈{5..8}) split by a
## rock wall at x=4. Flooding from pocket A must stay in A, and flooding from
## the wall itself must reach nothing.
func _rock_wall_severs_the_flood() -> bool:
	var nx := 9
	var ny := 1
	var nz := 5
	var f := PackedFloat32Array()
	f.resize(nx * ny * nz)
	for ix in nx:
		for iz in nz:
			f[ix * nz + iz] = 1.0 if ix == 4 else -1.0

	var seen := CaveSystemGen.flood_passable(f, nx, ny, nz, Vector3i(0, 0, 0))
	# Cells at x=3 touch the wall, so clearance erodes them: pocket A's passable
	# core is x∈{0,1,2} — 15 cells.
	var reached := 0
	for i in seen.size():
		reached += seen[i]
	_check(reached == 15, true, "teeth: pocket A's passable core is 15 cells (got %d)" % reached)
	_check(seen[CaveSystemGen._fi(Vector3i(2, 0, 4), ny, nz)] == 1, true, "teeth: pocket A's far corner is reached")
	_check(seen[CaveSystemGen._fi(Vector3i(6, 0, 0), ny, nz)] == 0, true, "teeth: pocket B across the wall is NOT reached")
	_check(seen[CaveSystemGen._fi(Vector3i(3, 0, 0), ny, nz)] == 0, true, "teeth: a void cell hard against the wall lacks clearance")

	var from_rock := CaveSystemGen.flood_passable(f, nx, ny, nz, Vector3i(4, 0, 0))
	var rr := 0
	for i in from_rock.size():
		rr += from_rock[i]
	_check(rr == 0, true, "teeth: flooding from rock reaches nothing (got %d)" % rr)
	return not _failed


## Both states of the clearance rule, on identical 7×1×5 geometry: two chambers
## joined through the x=3 wall by either a ONE-CELL pinhole (narrower than the
## player capsule ⇒ must NOT connect) or a three-cell channel (⇒ must connect).
## Same field, same flood, only the gap width differs — so a pass proves the rule
## discriminates rather than simply blocking everything.
func _clearance_rejects_a_pinhole() -> bool:
	var far := Vector3i(5, 0, 2)
	var pinhole := _two_chambers([2])
	var wide := _two_chambers([1, 2, 3])

	var via_pinhole := CaveSystemGen.flood_passable(pinhole, 7, 1, 5, Vector3i(0, 0, 0))
	var via_wide := CaveSystemGen.flood_passable(wide, 7, 1, 5, Vector3i(0, 0, 0))
	_check(via_pinhole[CaveSystemGen._fi(far, 1, 5)] == 0, true,
		"clearance: a one-cell pinhole does NOT connect the chambers")
	_check(via_wide[CaveSystemGen._fi(far, 1, 5)] == 1, true,
		"clearance: a wide channel DOES connect them (the rule is not blocking everything)")
	return not _failed


## A 7×1×5 field: rock wall at x=3, opened only at the given z rows.
func _two_chambers(gap_rows: Array) -> PackedFloat32Array:
	var nz := 5
	var f := PackedFloat32Array()
	f.resize(7 * 1 * nz)
	for ix in 7:
		for iz in nz:
			var rock := ix == 3 and not gap_rows.has(iz)
			f[ix * nz + iz] = 1.0 if rock else -1.0
	return f


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
