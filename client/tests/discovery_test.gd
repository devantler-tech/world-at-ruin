extends Node
## Regression test for the Discovery exploration tracker (issue #71).
##
## Discovery answers one question — "has this player reached this place yet?" —
## and everything about it is a product law: the reach edge is inclusive, the
## test is planar (a landmark is a mark on the ground, blind to height), a place
## once found stays found (this game has no undo, so observing it again is a
## no-op), the found set only ever grows, and identical walks produce identical
## results (determinism). This pins each of those, plus the degenerate-safe
## refusals (negative radius, duplicate/empty id, unknown id).
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally
## and deterministic in CI.
##
## Run: godot --headless --path client res://tests/discovery_test.tscn

var _failed := false


func _ready() -> void:
	# --- registration: unique, non-empty ids; forward-only ---
	var d := Discovery.new()
	_check(d.total() == 0, true, "fresh: nothing registered")
	_check(d.count() == 0, true, "fresh: nothing found")
	_check(d.add("shrine", Vector3.ZERO, 14.0), true, "add: a new place registers")
	_check(d.is_registered("shrine"), true, "add: the place is now registered")
	_check(d.add("shrine", Vector3(9, 0, 9), 3.0), false, "add: a duplicate id is refused")
	_check(d.add("", Vector3.ZERO, 5.0), false, "add: an empty id is refused")
	_check(d.total() == 1, true, "add: refusals changed nothing")
	if _failed:
		return

	# --- finding: out of reach vs in reach, and idempotency (the no-undo) ---
	_eq_list(d.observe(Vector3(100, 0, 100)), "", "observe: far away finds nothing")
	_check(d.count() == 0, true, "observe: nothing found yet")
	_eq_list(d.observe(Vector3(5, 0, 0)), "shrine", "observe: inside the reach finds the place")
	_check(d.is_discovered("shrine"), true, "observe: the place is now found")
	_check(d.count() == 1, true, "observe: exactly one found")
	_eq_list(d.observe(Vector3.ZERO), "", "observe: a found place is never returned again")
	_check(d.count() == 1, true, "observe: the count did not double-count")
	if _failed:
		return

	# --- the inclusive reach edge (matches Telegraph's <=) ---
	var edge := Discovery.new()
	edge.add("mark", Vector3.ZERO, 5.0)
	_eq_list(edge.observe(Vector3(5.001, 0, 0)), "", "edge: just past the reach is not found")
	_eq_list(edge.observe(Vector3(5, 0, 0)), "mark", "edge: exactly on the reach is found")
	if _failed:
		return

	# --- planar law: height never changes whether a place is found ---
	var high := Discovery.new()
	high.add("mark", Vector3.ZERO, 5.0)
	_eq_list(high.observe(Vector3(3, 1000, 0)), "mark", "planar: height is ignored")
	if _failed:
		return

	# --- multiple places in one reach: returned sorted by id, all found ---
	var many := Discovery.new()
	many.add("b_pillar", Vector3.ZERO, 5.0)
	many.add("a_well", Vector3.ZERO, 5.0)
	many.add("c_arch", Vector3(50, 0, 0), 2.0)
	_eq_list(many.observe(Vector3(1, 0, 1)), "a_well,b_pillar", "many: both in-reach places, sorted by id")
	_check(many.count() == 2, true, "many: the far place stayed unfound")
	_eq_list(many.discovered(), "a_well,b_pillar", "many: discovered() is sorted")
	if _failed:
		return

	# --- degenerate & unknown: negative radius reaches nothing; unknown id safe ---
	var deg := Discovery.new()
	deg.add("void", Vector3.ZERO, -1.0)
	_eq_list(deg.observe(Vector3.ZERO), "", "degenerate: a negative-radius place is never found")
	_check(deg.is_discovered("void"), false, "degenerate: it stays unfound")
	_check(deg.is_discovered("nope"), false, "unknown: is_discovered is safe for an unknown id")
	_check(deg.is_registered("nope"), false, "unknown: is_registered is safe for an unknown id")
	if _failed:
		return

	# --- forward-only: the found set only ever grows across a walk ---
	if not _monotonic_walk():
		return

	# --- determinism: the same walk twice agrees byte-for-byte ---
	if not _deterministic_replay():
		return

	# --- a real walk of the shipped world: cave, then the shrine, each once ---
	var world := Discovery.new()
	world.add("wardens_shrine", Vector3.ZERO, 14.0)
	world.add("starter_cave", Vector3(-56, 0, -20), 10.0)
	_eq_list(world.observe(Vector3(-56, 2, -22)), "starter_cave", "world: wake in the cave, find the cave")
	_eq_list(world.observe(Vector3(-56, 2, -22)), "", "world: still in the cave, nothing new")
	_eq_list(world.observe(Vector3(3, 0, 3)), "wardens_shrine", "world: walk to the centre, find the shrine")
	_check(world.count() == 2, true, "world: both landmarks found, once each")
	if _failed:
		return

	# --- expansion reader: future vault state changes live discovery behaviour ---
	if not _test_restored_vault_state():
		return

	print("TEST PASS — discovery tracker holds (reach, planar, idempotent, forward-only, deterministic, degenerate-safe)")
	get_tree().quit(0)


## Registers three places and reaches each in turn, asserting the found set is a
## superset of the previous step at every step (it never shrinks) and grows by
## exactly the newly-reached place.
func _monotonic_walk() -> bool:
	var d := Discovery.new()
	d.add("p1", Vector3(0, 0, 0), 3.0)
	d.add("p2", Vector3(20, 0, 0), 3.0)
	d.add("p3", Vector3(40, 0, 0), 3.0)
	var stops := [Vector3(100, 0, 0), Vector3(0, 0, 0), Vector3(20, 0, 0), Vector3(40, 0, 0), Vector3(0, 0, 0)]
	var prev: Array[String] = []
	for stop: Vector3 in stops:
		d.observe(stop)
		var now := d.discovered()
		for id: String in prev:
			if not now.has(id):
				_fail("forward-only broke: %s disappeared from the found set" % id)
				return false
		if now.size() < prev.size():
			_fail("forward-only broke: the found set shrank")
			return false
		prev = now
	_eq_list(prev, "p1,p2,p3", "forward-only: the whole walk found all three")
	return not _failed


## Runs the identical registration + observe script on two independent trackers
## and asserts every per-observe result and the final found set are identical —
## the determinism the product law requires of anything on the authoritative path.
func _deterministic_replay() -> bool:
	var log_a := _run_scripted_walk(Discovery.new())
	var log_b := _run_scripted_walk(Discovery.new())
	_check(log_a == log_b, true, "determinism: two identical walks produce identical results")
	return not _failed


## The v2 vault reader is not parser-only: discovery names it accepts can be
## restored into the real tracker before the writer is activated. Unknown names
## are carried as discovered too, so a rollback build never drops a place added
## by a newer writer merely because this build has no point-of-interest for it.
func _test_restored_vault_state() -> bool:
	var restored := Discovery.new()
	restored.add("wardens_shrine", Vector3.ZERO, 14.0)
	if not restored.has_method("restore"):
		_fail("the expanded vault shape has no Discovery.restore application path")
		return false
	restored.call("restore", ["wardens_shrine", "future_place", "wardens_shrine"])
	_eq_list(restored.discovered(), "future_place,wardens_shrine",
		"restore: names become one deterministic append-only set")
	if _failed:
		return false
	_eq_list(restored.observe(Vector3.ZERO), "",
		"restore: a persisted place is not discovered a second time after boot")
	_check(restored.is_discovered("future_place"), true,
		"restore: an unknown future place is preserved as discovered")
	return not _failed


## A fixed script of adds and observes; returns the "|"-joined trace of every
## observe result plus the final sorted found set, so two runs can be compared
## as one string.
func _run_scripted_walk(d: Discovery) -> String:
	d.add("north", Vector3(0, 0, -30), 6.0)
	d.add("east", Vector3(30, 0, 0), 6.0)
	d.add("home", Vector3.ZERO, 4.0)
	var trace: Array[String] = []
	for stop: Vector3 in [Vector3(2, 0, 0), Vector3(30, 0, 2), Vector3(0, 0, -30), Vector3(2, 0, 0)]:
		trace.append(",".join(d.observe(stop)))
	trace.append("=" + ",".join(d.discovered()))
	return "|".join(trace)


func _eq_list(actual: Array[String], expected: String, label: String) -> void:
	_check(",".join(actual) == expected, true, "%s (got \"%s\")" % [label, ",".join(actual)])


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
