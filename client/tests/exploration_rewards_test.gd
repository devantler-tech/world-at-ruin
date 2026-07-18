extends Node
## Regression test for the ExplorationRewards layer (issue #75).
##
## Exploration must pay off in BREADTH, never bigger numbers (Phase 6: "the
## reason to walk somewhere, and breadth rather than bigger numbers; horizontal
## progression throughout"). Every rule here is a product law: a reward is one of
## a CLOSED horizontal set (waypoint / lore / cosmetic / map-reveal) with no
## representable power field; registration is forward-only (a place never
## redefines its reward); a reward is claimed at most once (no undo); identical
## walks grant identically (determinism); and the `find_vertical` audit catches
## any reward that tried to smuggle in power. This pins each, with a synthetic
## power-carrying reward as the negative control that proves the guard has teeth.
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/exploration_rewards_test.tscn

var _failed := false


func _ready() -> void:
	# --- the closed schema: each horizontal kind accepted in its exact shape ---
	_check(ExplorationRewards.is_valid({"kind": "waypoint", "id": "shrine", "name": "Wardens' Shrine"}), true, "schema: a well-formed waypoint is valid")
	_check(ExplorationRewards.is_valid({"kind": "lore", "id": "ashfall_01"}), true, "schema: a well-formed lore entry is valid")
	_check(ExplorationRewards.is_valid({"kind": "cosmetic", "id": "ash_dye"}), true, "schema: a well-formed cosmetic is valid")
	_check(ExplorationRewards.is_valid({"kind": "map_reveal", "region": "ruin_field"}), true, "schema: a well-formed map-reveal is valid")
	if _failed:
		return

	# --- the horizontal-only guard: power is not a representable reward ---
	_check(ExplorationRewards.is_valid({"kind": "waypoint", "id": "x", "name": "X", "power": 5}), false, "guard: an extra power field is refused")
	_check(ExplorationRewards.is_valid({"kind": "stat", "id": "str", "amount": "10"}), false, "guard: an unknown (power-shaped) kind is refused")
	_check(ExplorationRewards.is_valid({"kind": "lore", "id": "x", "damage": "9"}), false, "guard: a smuggled numeric field is refused as an extra key")
	_check(ExplorationRewards.is_valid({"kind": "waypoint", "id": "x"}), false, "guard: a missing required field is refused")
	_check(ExplorationRewards.is_valid({"kind": "lore", "id": ""}), false, "guard: an empty required field is refused")
	_check(ExplorationRewards.is_valid({"kind": "lore", "id": 7}), false, "guard: a non-string required field is refused")
	_check(ExplorationRewards.is_valid({}), false, "guard: an empty reward is refused")
	_check(ExplorationRewards.is_valid({"id": "x", "name": "X"}), false, "guard: a reward with no kind is refused")
	if _failed:
		return

	# --- registration: valid rewards register; forward-only refuses redefinition ---
	var r := ExplorationRewards.new()
	_check(r.total() == 0, true, "fresh: nothing registered")
	_check(r.count() == 0, true, "fresh: nothing claimed")
	_check(r.add("shrine", {"kind": "waypoint", "id": "shrine", "name": "Wardens' Shrine"}), true, "add: a valid reward registers")
	_check(r.is_registered("shrine"), true, "add: the place now has a reward")
	_check(r.add("shrine", {"kind": "lore", "id": "other"}), false, "add: a place never redefines its reward (forward-only)")
	_check(r.add("", {"kind": "lore", "id": "x"}), false, "add: an empty poi id is refused")
	_check(r.add("bad", {"kind": "waypoint", "id": "x", "name": "X", "power": 9}), false, "add: an invalid (power-carrying) reward is refused")
	_check(r.total() == 1, true, "add: refusals changed nothing")
	if _failed:
		return

	# --- reward_for returns an immutable copy ---
	var got := r.reward_for("shrine")
	_check(got["id"] == "shrine", true, "reward_for: returns the registered reward")
	got["id"] = "tampered"
	_check(r.reward_for("shrine")["id"] == "shrine", true, "reward_for: the returned copy cannot mutate the registry")
	_check(r.reward_for("nope").is_empty(), true, "reward_for: an unknown id yields an empty reward")
	if _failed:
		return

	# --- claim: grants once, in id order, composing with a discovery result ---
	var g := ExplorationRewards.new()
	g.add("b_cave", {"kind": "lore", "id": "cave_01"})
	g.add("a_shrine", {"kind": "waypoint", "id": "shrine", "name": "Shrine"})
	g.add("c_arch", {"kind": "cosmetic", "id": "arch_trophy"})
	# The wanderer wakes in the cave and reaches the shrine on the same step; ids
	# arrive exactly as Discovery.observe would return them.
	var first := g.claim(["b_cave", "a_shrine"])
	_check(first.size() == 2, true, "claim: both discovered places grant")
	_check(first[0]["id"] == "shrine", true, "claim: granted in id order (a_shrine first)")
	_check(first[1]["id"] == "cave_01", true, "claim: granted in id order (b_cave second)")
	_check(g.count() == 2, true, "claim: two rewards now claimed")
	# Reaching the same places again grants nothing — the no-undo.
	var again := g.claim(["a_shrine", "b_cave"])
	_check(again.is_empty(), true, "claim: an already-claimed place grants nothing (idempotent)")
	_check(g.count() == 2, true, "claim: the claimed count did not grow")
	# A place with no registered reward, and an unknown id, are simply skipped.
	var third := g.claim(["c_arch", "ghost_town"])
	_check(third.size() == 1, true, "claim: the newly-reached rewarded place grants; the unknown id is skipped")
	_check(third[0]["id"] == "arch_trophy", true, "claim: the right reward granted")
	_check(g.is_claimed("c_arch"), true, "claim: c_arch is now claimed")
	_check(g.is_claimed("ghost_town"), false, "claim: an unknown id is never marked claimed")
	if _failed:
		return

	# --- degenerate inputs are safe ---
	var d := ExplorationRewards.new()
	d.add("place", {"kind": "lore", "id": "x"})
	_check(d.claim([]).is_empty(), true, "degenerate: an empty found-list grants nothing")
	_check(d.claim([42, "place"]).size() == 1, true, "degenerate: a non-string id is skipped, the real one grants")
	_check(d.claim(["place", "place"]).is_empty(), true, "degenerate: a repeated id in one call never double-grants")
	_check(d.claimed().size() == 1, true, "degenerate: exactly one place claimed")
	_eq_list(d.claimed(), "place", "degenerate: claimed() is the one place")
	if _failed:
		return

	# --- determinism: two identical registrations + claims agree byte-for-byte ---
	if not _deterministic_replay():
		return

	# --- the find_vertical audit, with a power-carrying reward as the control ---
	var lawful := [
		{"kind": "waypoint", "id": "shrine", "name": "Shrine"},
		{"kind": "lore", "id": "ashfall_01"},
		{"kind": "cosmetic", "id": "ash_dye"},
		{"kind": "map_reveal", "region": "ruin_field"},
	]
	_check(ExplorationRewards.find_vertical(lawful).is_empty(), true, "audit: an all-horizontal set has no violations")
	var tainted := lawful.duplicate(true)
	tainted.append({"kind": "waypoint", "id": "cheat", "name": "Cheat", "power": 99}) # the negative control
	tainted.append("not-a-dictionary")
	var violations := ExplorationRewards.find_vertical(tainted)
	_check(violations.size() == 2, true, "audit: the power reward and the non-dictionary are both caught")
	if _failed:
		return

	print("TEST PASS — exploration rewards hold (closed horizontal schema, forward-only, claim-once, deterministic, audited)")
	get_tree().quit(0)


## Runs the identical registration + claim script on two independent instances and
## asserts the whole granted trace and final claimed set are identical — the
## determinism the product law requires of anything on the authoritative path.
func _deterministic_replay() -> bool:
	var trace_a := _run_scripted_claims(ExplorationRewards.new())
	var trace_b := _run_scripted_claims(ExplorationRewards.new())
	_check(trace_a == trace_b, true, "determinism: two identical claim scripts produce identical grants")
	return not _failed


## A fixed script of registrations and claims; returns a "|"-joined trace of every
## claim's granted ids plus the final sorted claimed set, so two runs can be
## compared as one string.
func _run_scripted_claims(r: ExplorationRewards) -> String:
	r.add("north", {"kind": "lore", "id": "north_tale"})
	r.add("east", {"kind": "cosmetic", "id": "east_mark"})
	r.add("home", {"kind": "waypoint", "id": "home", "name": "Home"})
	var trace: Array[String] = []
	for step: Array in [["home"], ["east", "north"], ["home", "east"], ["north"]]:
		var granted := r.claim(step)
		var ids: Array[String] = []
		for reward: Dictionary in granted:
			ids.append(reward["id"])
		trace.append(",".join(ids))
	trace.append("=" + ",".join(r.claimed()))
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
