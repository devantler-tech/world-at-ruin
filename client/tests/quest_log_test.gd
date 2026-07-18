extends Node
## Regression test for the QuestLog objective tracker.
##
## QuestLog answers one question — "how far along is this objective, and is the
## quest complete yet?" — and everything about it is a product law: progress only
## ever rises (forward-only), it is clamped to the required count so it can never
## overshoot, a completed quest stays completed and is announced exactly once
## (this game has no undo), a quest never silently redefines itself, and identical
## event sequences produce identical completions (determinism). This pins each of
## those, plus the malformed-definition refusals and the safe unknown-id reads.
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/quest_log_test.tscn

var _failed := false


func _ready() -> void:
	if not _registration_rules():
		return
	if not _malformed_definitions_refused():
		return
	if not _advance_and_clamp():
		return
	if not _completion_announced_once():
		return
	if not _multi_objective_and_multi_quest():
		return
	if not _unknown_ids_safe():
		return
	if not _forward_only_walk():
		return
	if not _deterministic_replay():
		return

	print("TEST PASS — quest log holds (forward-only, clamped, complete-once, deterministic, malformed-safe)")
	get_tree().quit(0)


## Registration is forward-only: a fresh log is empty, a new quest registers, and
## a duplicate or empty id is refused without disturbing what is already there.
func _registration_rules() -> bool:
	var q := QuestLog.new()
	_check(q.total() == 0, true, "fresh: nothing registered")
	_check(q.count() == 0, true, "fresh: nothing complete")
	_check(q.add("clear_cave", [{"id": "hounds", "tag": "defeat:ash_hound", "count": 3}]), true, "add: a new quest registers")
	_check(q.is_registered("clear_cave"), true, "add: the quest is now registered")
	_check(q.add("clear_cave", [{"id": "other", "tag": "x", "count": 1}]), false, "add: a duplicate quest id is refused")
	_check(q.add("", [{"id": "a", "tag": "x", "count": 1}]), false, "add: an empty quest id is refused")
	_check(q.total() == 1, true, "add: refusals changed nothing")
	_check(q.required("clear_cave", "hounds") == 3, true, "add: the objective kept its required count")
	# The stored definition is a copy: mutating the caller's array cannot reshape it.
	var defs: Array = [{"id": "walk", "tag": "reach:shrine", "count": 1}]
	q.add("pilgrimage", defs)
	defs[0]["count"] = 99
	_check(q.required("pilgrimage", "walk") == 1, true, "add: the stored definition is a copy")
	return not _failed


## Every malformed objective list is refused at add() rather than corrupting
## progress tracking later.
func _malformed_definitions_refused() -> bool:
	var q := QuestLog.new()
	var bad := {
		"empty list": [],
		"not a dictionary": ["nope"],
		"missing id": [{"tag": "x", "count": 1}],
		"empty id": [{"id": "", "tag": "x", "count": 1}],
		"duplicate objective id": [{"id": "a", "tag": "x", "count": 1}, {"id": "a", "tag": "y", "count": 1}],
		"missing tag": [{"id": "a", "count": 1}],
		"empty tag": [{"id": "a", "tag": "", "count": 1}],
		"zero count": [{"id": "a", "tag": "x", "count": 0}],
		"negative count": [{"id": "a", "tag": "x", "count": -2}],
		"non-int count": [{"id": "a", "tag": "x", "count": "three"}],
	}
	for label: String in bad:
		var objectives: Array = bad[label]
		_check(q.add("quest_" + label, objectives), false, "malformed refused: %s" % label)
	_check(q.total() == 0, true, "malformed: nothing was registered")
	return not _failed


## record() advances only objectives listening for the tag, and clamps progress to
## the required count so it can never overshoot.
func _advance_and_clamp() -> bool:
	var q := QuestLog.new()
	q.add("hunt", [{"id": "hounds", "tag": "defeat:ash_hound", "count": 3}])
	_check(q.progress_of("hunt", "hounds") == 0, true, "record: starts at zero")
	_eq_list(q.record("defeat:wolf"), "", "record: an unlistened tag completes nothing")
	_check(q.progress_of("hunt", "hounds") == 0, true, "record: an unlistened tag advances nothing")
	_eq_list(q.record("defeat:ash_hound"), "", "record: one of three does not complete")
	_check(q.progress_of("hunt", "hounds") == 1, true, "record: advanced by the default amount")
	_eq_list(q.record("defeat:ash_hound", 0), "", "record: a zero amount is a no-op")
	_eq_list(q.record("defeat:ash_hound", -5), "", "record: a negative amount is a no-op")
	_eq_list(q.record("", 1), "", "record: an empty tag is a no-op")
	_check(q.progress_of("hunt", "hounds") == 1, true, "record: no-ops advanced nothing")
	# A huge amount clamps to the required count — never overshoots.
	_eq_list(q.record("defeat:ash_hound", 100), "hunt", "record: overshooting still completes the quest")
	_check(q.progress_of("hunt", "hounds") == 3, true, "record: progress clamped to the required count")
	return not _failed


## A quest completes exactly once: further matching events never re-announce it
## and never move its progress (the no-undo).
func _completion_announced_once() -> bool:
	var q := QuestLog.new()
	q.add("errand", [{"id": "step", "tag": "help:npc", "count": 2}])
	_eq_list(q.record("help:npc"), "", "complete-once: not yet")
	_eq_list(q.record("help:npc"), "errand", "complete-once: announced on the completing event")
	_check(q.is_complete("errand"), true, "complete-once: the quest reads complete")
	_check(q.count() == 1, true, "complete-once: exactly one complete")
	_eq_list(q.record("help:npc"), "", "complete-once: never announced again")
	_check(q.progress_of("errand", "step") == 2, true, "complete-once: progress did not move past the count")
	_check(q.count() == 1, true, "complete-once: the count did not double")
	_eq_list(q.completed(), "errand", "complete-once: completed() lists it")
	return not _failed


## A multi-objective quest completes only when EVERY objective is done, and one
## event tag advances matching objectives across several quests at once — with the
## newly-completed ids returned sorted.
func _multi_objective_and_multi_quest() -> bool:
	var q := QuestLog.new()
	q.add("two_parts", [
		{"id": "gather", "tag": "pick:ash_bloom", "count": 2},
		{"id": "return", "tag": "reach:shrine", "count": 1},
	])
	q.record("pick:ash_bloom", 2)
	_check(q.is_complete("two_parts"), false, "multi-objective: one objective done is not enough")
	_eq_list(q.record("reach:shrine"), "two_parts", "multi-objective: the last objective completes it")

	# One tag, two quests, both completed by the same event — sorted result.
	var m := QuestLog.new()
	m.add("z_last", [{"id": "a", "tag": "reach:shrine", "count": 1}])
	m.add("a_first", [{"id": "a", "tag": "reach:shrine", "count": 1}])
	m.add("untouched", [{"id": "a", "tag": "other", "count": 1}])
	_eq_list(m.record("reach:shrine"), "a_first,z_last", "multi-quest: both completed, sorted by id")
	_check(m.is_complete("untouched"), false, "multi-quest: the unlistening quest is untouched")
	_eq_list(m.registered(), "a_first,untouched,z_last", "multi-quest: registered() is sorted")
	return not _failed


## Every read is safe for an unknown quest or objective id — never a crash.
func _unknown_ids_safe() -> bool:
	var q := QuestLog.new()
	q.add("known", [{"id": "step", "tag": "x", "count": 1}])
	_check(q.is_registered("nope"), false, "unknown: is_registered is safe")
	_check(q.is_complete("nope"), false, "unknown: is_complete is safe")
	_check(q.progress_of("nope", "step") == 0, true, "unknown: progress_of on an unknown quest is 0")
	_check(q.progress_of("known", "nope") == 0, true, "unknown: progress_of on an unknown objective is 0")
	_check(q.required("nope", "step") == 0, true, "unknown: required on an unknown quest is 0")
	_check(q.required("known", "nope") == 0, true, "unknown: required on an unknown objective is 0")
	return not _failed


## Progress only ever rises across a long event walk, and a completed quest never
## leaves the completed set — the forward-only law, asserted at every step.
func _forward_only_walk() -> bool:
	var q := QuestLog.new()
	q.add("long", [{"id": "a", "tag": "tick", "count": 4}, {"id": "b", "tag": "beat", "count": 2}])
	var prev_a := 0
	var prev_b := 0
	var prev_done := 0
	for i: int in range(12):
		q.record("tick" if i % 2 == 0 else "beat")
		var now_a := q.progress_of("long", "a")
		var now_b := q.progress_of("long", "b")
		if now_a < prev_a or now_b < prev_b:
			_fail("forward-only broke: progress decreased (a %d->%d, b %d->%d)" % [prev_a, now_a, prev_b, now_b])
			return false
		if q.count() < prev_done:
			_fail("forward-only broke: the completed set shrank")
			return false
		prev_a = now_a
		prev_b = now_b
		prev_done = q.count()
	_check(prev_a == 4, true, "forward-only: objective a reached and held its count")
	_check(prev_b == 2, true, "forward-only: objective b reached and held its count")
	_check(q.is_complete("long"), true, "forward-only: the quest completed")
	return not _failed


## Runs the identical definition + event script on two independent logs and
## asserts every per-record result and the final state are identical — the
## determinism the product law requires.
func _deterministic_replay() -> bool:
	var trace_a := _run_scripted_events(QuestLog.new())
	var trace_b := _run_scripted_events(QuestLog.new())
	_check(trace_a == trace_b, true, "determinism: two identical event scripts agree")
	return not _failed


## A fixed script of adds and records; returns the "|"-joined trace of every
## record result plus the final completed set, so two runs compare as one string.
func _run_scripted_events(q: QuestLog) -> String:
	q.add("north", [{"id": "walk", "tag": "reach:north", "count": 2}])
	q.add("east", [{"id": "walk", "tag": "reach:east", "count": 1}, {"id": "slay", "tag": "defeat:hound", "count": 3}])
	q.add("home", [{"id": "rest", "tag": "reach:home", "count": 1}])
	var trace: Array[String] = []
	for event: String in ["reach:north", "defeat:hound", "reach:east", "reach:north", "defeat:hound", "defeat:hound", "reach:home"]:
		trace.append(",".join(q.record(event)))
	trace.append("=" + ",".join(q.completed()))
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
