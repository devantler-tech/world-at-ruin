class_name QuestLog
extends RefCounted
## Quest log — the deterministic spine of "the reason to do things": WHICH of a
## player's objectives are done. Phase 6 names quests as a pillar of the game, and
## every quest — reach a place, clear a cave, help an NPC — rests on one primitive
## answered here: "how far along is this objective, and is the quest complete
## yet?". Discovery answers the exploration twin ("has this place been reached?");
## this answers the goal-tracking one.
##
## This library answers only that. It is PURE — no scene tree, no engine state, no
## clock, no `user://` — so it is deterministic and unit-testable, exactly like
## `Discovery`, `Telegraph` and `ExplorationRewards`. It is driven by opaque event
## TAGS: gameplay reports "an ash hound fell" as [method record] with a tag, and
## every incomplete objective listening for that tag advances. WHAT an objective's
## tag means, what completing a quest GRANTS (rewards belong to
## `ExplorationRewards`/a loot layer, deferred), how a quest is offered or turned
## in, and PERSISTING progress across a logout are the caller's concern and
## separate follow-ups.
##
## It mirrors this world's two standing laws as MECHANICAL invariants, not
## review-time hopes:
##   - FORWARD-ONLY, no undo: an objective's progress only ever rises, clamped to
##     its required count — it never decreases, never overshoots — and a quest,
##     once complete, stays complete. There is no abandon, no reset; this game
##     takes nothing a player earned back.
##   - DETERMINISTIC: quests and their objectives are visited in a stable order
##     and every ordered result is sorted by id, so the same sequence of events
##     yields the same completions byte-for-byte on every run.
## A quest also never silently redefines itself: registration is forward-only, so
## a definition is fixed once added.

## quest id -> the ordered Array of objective Dictionaries
## ({ "id": String, "tag": String, "count": int }) that quest requires. A quest is
## complete when every objective's progress has reached its count.
var _quests: Dictionary = {}

## quest id -> { objective id -> current progress (0..count) }. Progress only rises.
var _progress: Dictionary = {}

## The set of quest ids whose every objective is complete (id -> true). Only ever
## grows — a completed quest is never un-completed (the no-undo).
var _complete: Dictionary = {}


## Register `quest_id` with an ordered, non-empty list of objectives. Each
## objective is a Dictionary carrying exactly a non-empty String `id` (unique
## within the quest), a non-empty String `tag` (the event it listens for), and an
## int `count` >= 1 (how many matching events complete it). Returns false (and
## changes nothing) if the id is empty, already registered (registration is
## forward-only — a quest never silently redefines itself), or any objective is
## malformed. A deep copy is stored, so a caller mutating its definition afterwards
## never disturbs the registered one.
func add(quest_id: String, objectives: Array) -> bool:
	if quest_id.is_empty() or _quests.has(quest_id):
		return false
	if not _objectives_valid(objectives):
		return false
	var stored: Array = []
	var start: Dictionary = {}
	for raw: Variant in objectives:
		var obj: Dictionary = raw
		stored.append({"id": obj["id"], "tag": obj["tag"], "count": obj["count"]})
		start[obj["id"]] = 0
	_quests[quest_id] = stored
	_progress[quest_id] = start
	return true


## Whether `quest_id` names a registered quest.
func is_registered(quest_id: String) -> bool:
	return _quests.has(quest_id)


## Report that an event tagged `tag` occurred `amount` times (default 1). Every
## incomplete objective — across every registered quest — that listens for `tag`
## advances by `amount`, clamped so its progress never exceeds its required count
## (forward-only). Returns the ids of the quests THIS call newly completed, sorted,
## so the caller can fire a one-time completion hook per quest; a quest already
## complete is never returned again (idempotent — the no-undo). A non-positive
## `amount`, or a tag no objective listens for, advances nothing and completes
## nothing.
func record(tag: String, amount: int = 1) -> Array[String]:
	var newly: Array[String] = []
	if amount <= 0 or tag.is_empty():
		return newly
	for quest_id: String in _quests:
		if _complete.has(quest_id):
			continue
		var objectives: Array = _quests[quest_id]
		var progress: Dictionary = _progress[quest_id]
		var advanced := false
		for obj: Dictionary in objectives:
			if obj["tag"] != tag:
				continue
			var obj_id: String = obj["id"]
			var required: int = obj["count"]
			var current: int = progress[obj_id]
			if current >= required:
				continue
			# Add only the room that is actually left, never `current + amount`:
			# a colossal amount would overflow int64 and wrap NEGATIVE, driving
			# progress backwards through the very forward-only law this upholds.
			# `required > current` here, so the addend is positive and bounded.
			progress[obj_id] = current + min(amount, required - current)
			advanced = true
		if advanced and _is_all_complete(quest_id):
			_complete[quest_id] = true
			newly.append(quest_id)
	newly.sort()
	return newly


## Current progress toward the objective `objective_id` of `quest_id`, in
## [0, count]. Returns 0 for an unknown quest or objective (safe). Pair with
## [method required] to interpret it: complete when progress >= required.
func progress_of(quest_id: String, objective_id: String) -> int:
	if not _progress.has(quest_id):
		return 0
	var progress: Dictionary = _progress[quest_id]
	if not progress.has(objective_id):
		return 0
	return progress[objective_id] as int


## The required count for the objective `objective_id` of `quest_id`, or 0 if
## either is unknown (a required of 0 therefore also reads as "unknown objective").
func required(quest_id: String, objective_id: String) -> int:
	if not _quests.has(quest_id):
		return 0
	for obj: Dictionary in _quests[quest_id] as Array:
		if obj["id"] == objective_id:
			return obj["count"] as int
	return 0


## Whether `quest_id` is fully complete (every objective's progress has reached its
## count). Safe (false) for an unknown quest.
func is_complete(quest_id: String) -> bool:
	return _complete.has(quest_id)


## Every completed quest's id, sorted. The returned array is a copy — mutating it
## never disturbs the forward-only completed set.
func completed() -> Array[String]:
	var out: Array[String] = []
	for quest_id: String in _complete:
		out.append(quest_id)
	out.sort()
	return out


## Every registered quest's id, sorted. A copy, safe to mutate.
func registered() -> Array[String]:
	var out: Array[String] = []
	for quest_id: String in _quests:
		out.append(quest_id)
	out.sort()
	return out


## How many quests are complete.
func count() -> int:
	return _complete.size()


## How many quests are registered in total.
func total() -> int:
	return _quests.size()


## Whether every objective of `quest_id` has reached its required count. Assumes
## the quest is registered.
func _is_all_complete(quest_id: String) -> bool:
	var progress: Dictionary = _progress[quest_id]
	for obj: Dictionary in _quests[quest_id] as Array:
		var current: int = progress[obj["id"]]
		if current < (obj["count"] as int):
			return false
	return true


## Whether `objectives` is a valid, non-empty objective list: every entry a
## Dictionary carrying exactly a non-empty String `id` (unique within the list), a
## non-empty String `tag`, and an int `count` >= 1. This is the whole
## well-formed-quest guard — a malformed definition is refused at [method add]
## rather than corrupting progress tracking later.
func _objectives_valid(objectives: Array) -> bool:
	if objectives.is_empty():
		return false
	var seen: Dictionary = {}
	for raw: Variant in objectives:
		if raw is not Dictionary:
			return false
		var obj: Dictionary = raw
		var id: Variant = obj.get("id")
		if id is not String or (id as String).is_empty() or seen.has(id):
			return false
		var tag: Variant = obj.get("tag")
		if tag is not String or (tag as String).is_empty():
			return false
		var c: Variant = obj.get("count")
		if c is not int or (c as int) < 1:
			return false
		seen[id] = true
	return true
