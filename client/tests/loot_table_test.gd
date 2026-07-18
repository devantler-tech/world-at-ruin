extends Node
## Regression test for the LootTable drop layer (issue #87).
##
## Two product laws meet in a drop table, and this pins both. FIRST, the roll is
## deterministic: an integer roll maps to exactly one item by cumulative weight in
## insertion order, identically on every platform and every replay — so a drop can
## be reproduced and audited from its originating seed, and there is no
## client-side RNG to manipulate. SECOND, open-world loot is BOUND: an item is one
## of a CLOSED horizontal set (weapon / cosmetic / trophy / lore) with no
## representable power field, so "a sword is a sword" cannot be violated. A
## synthetic power-carrying item is the negative control that proves the guard has
## teeth, and an exhaustive roll sweep proves the weights are honoured exactly
## rather than approximately.
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/loot_table_test.tscn

var _failed := false


func _ready() -> void:
	# --- the closed schema: each horizontal kind accepted in its exact shape ---
	_check(LootTable.is_valid_item({"kind": "weapon", "id": "ash_sword", "name": "Ashen Blade"}), true, "schema: a well-formed weapon is valid")
	_check(LootTable.is_valid_item({"kind": "cosmetic", "id": "ash_dye"}), true, "schema: a well-formed cosmetic is valid")
	_check(LootTable.is_valid_item({"kind": "trophy", "id": "hound_fang"}), true, "schema: a well-formed trophy is valid")
	_check(LootTable.is_valid_item({"kind": "lore", "id": "ashfall_02"}), true, "schema: a well-formed lore page is valid")
	if _failed:
		return

	# --- the horizontal-only guard: power is not a representable drop ---
	_check(LootTable.is_valid_item({"kind": "weapon", "id": "x", "name": "X", "damage": "9"}), false, "guard: a smuggled damage field is refused")
	_check(LootTable.is_valid_item({"kind": "cosmetic", "id": "x", "armour": "3"}), false, "guard: a smuggled armour field is refused")
	_check(LootTable.is_valid_item({"kind": "stat", "id": "str", "amount": "10"}), false, "guard: an unknown (power-shaped) kind is refused")
	_check(LootTable.is_valid_item({"kind": "weapon", "id": "x"}), false, "guard: a missing required field is refused")
	_check(LootTable.is_valid_item({"kind": "lore", "id": ""}), false, "guard: an empty required field is refused")
	_check(LootTable.is_valid_item({"kind": "lore", "id": 7}), false, "guard: a non-string required field is refused")
	_check(LootTable.is_valid_item({}), false, "guard: an empty item is refused")
	_check(LootTable.is_valid_item({"id": "x", "name": "X"}), false, "guard: an item with no kind is refused")
	if _failed:
		return

	# --- building a table: weights must be positive, items must be lawful ---
	var t := LootTable.new()
	_check(t.is_empty(), true, "fresh: the table is empty")
	_check(t.total_weight() == 0, true, "fresh: no weight")
	_check(t.select(0).is_empty(), true, "fresh: an empty table drops nothing")
	_check(t.add(3, {"kind": "trophy", "id": "common_ash"}), true, "add: a valid entry is accepted")
	_check(t.add(0, {"kind": "trophy", "id": "zero"}), false, "add: a zero weight is refused")
	_check(t.add(-2, {"kind": "trophy", "id": "negative"}), false, "add: a negative weight is refused")
	_check(t.add(5, {"kind": "weapon", "id": "cheat", "name": "Cheat", "damage": "999"}), false, "add: a power-carrying item never enters a table")
	_check(t.size() == 1, true, "add: refusals changed nothing")
	_check(t.total_weight() == 3, true, "add: refusals added no weight")
	if _failed:
		return

	# --- selection: exact cumulative-weight slices, in insertion order ---
	# Weights 3 / 1 / 1 over a 5-wide roll space: rolls 0,1,2 -> common,
	# roll 3 -> blade, roll 4 -> page.
	var d := LootTable.new()
	d.add(3, {"kind": "trophy", "id": "common"})
	d.add(1, {"kind": "weapon", "id": "blade", "name": "Ashen Blade"})
	d.add(1, {"kind": "lore", "id": "page"})
	_check(d.total_weight() == 5, true, "select: the roll space is the weight sum")
	_check(_id_at(d, 0) == "common", true, "select: roll 0 lands in the first slice")
	_check(_id_at(d, 1) == "common", true, "select: roll 1 lands in the first slice")
	_check(_id_at(d, 2) == "common", true, "select: roll 2 is the last of the first slice")
	_check(_id_at(d, 3) == "blade", true, "select: roll 3 is the first of the second slice")
	_check(_id_at(d, 4) == "page", true, "select: roll 4 is the final slice")
	if _failed:
		return

	# --- rolls outside the space fold in, so a caller never has to pre-range ---
	_check(_id_at(d, 5) == "common", true, "select: a roll of exactly total_weight wraps to the first slice")
	_check(_id_at(d, 8) == "blade", true, "select: a large roll wraps by modulo")
	_check(_id_at(d, -1) == "page", true, "select: a negative roll folds to the final slice")
	_check(_id_at(d, -5) == "common", true, "select: a negative multiple folds to the first slice")
	if _failed:
		return

	# --- the weights are honoured EXACTLY: sweep every roll in the space ---
	var counts := _sweep_counts(d)
	_check(counts.get("common", 0) == 3, true, "weights: the weight-3 entry occupies exactly 3 outcomes")
	_check(counts.get("blade", 0) == 1, true, "weights: the weight-1 weapon occupies exactly 1 outcome")
	_check(counts.get("page", 0) == 1, true, "weights: the weight-1 page occupies exactly 1 outcome")
	if _failed:
		return

	# --- a returned drop is a copy; the table cannot be mutated through it ---
	var got := d.select(3)
	_check(got["id"] == "blade", true, "copy: select returns the entry's item")
	got["id"] = "tampered"
	_check(_id_at(d, 3) == "blade", true, "copy: mutating a returned drop never disturbs the table")
	var listed := d.entries()
	_check(listed.size() == 3, true, "entries: every entry is listed")
	_check(listed[0]["weight"] == 3, true, "entries: the weight is reported")
	var listed_item: Dictionary = listed[0]["item"]
	listed_item["id"] = "tampered"
	_check(_id_at(d, 0) == "common", true, "entries: mutating a listed item never disturbs the table")
	if _failed:
		return

	# --- determinism: two identically-built tables agree on every roll ---
	if not _deterministic_replay():
		return

	# --- the find_vertical audit, with a power-carrying drop as the control ---
	var lawful := [
		{"kind": "weapon", "id": "ash_sword", "name": "Ashen Blade"},
		{"kind": "cosmetic", "id": "ash_dye"},
		{"kind": "trophy", "id": "hound_fang"},
		{"kind": "lore", "id": "ashfall_02"},
	]
	_check(LootTable.find_vertical(lawful).is_empty(), true, "audit: an all-horizontal set has no violations")
	var tainted := lawful.duplicate(true)
	tainted.append({"kind": "weapon", "id": "cheat", "name": "Cheat", "damage": "999"}) # the negative control
	tainted.append("not-a-dictionary")
	var violations := LootTable.find_vertical(tainted)
	_check(violations.size() == 2, true, "audit: the power weapon and the non-dictionary are both caught")
	if _failed:
		return

	print("TEST PASS — loot table holds (closed horizontal schema, deterministic weighted selection, exact weights, audited)")
	get_tree().quit(0)


## The id of the item `roll` selects from `table`, or "" when nothing drops.
func _id_at(table: LootTable, roll: int) -> String:
	var item := table.select(roll)
	if item.is_empty():
		return ""
	var id: Variant = item.get("id")
	if id is not String:
		return ""
	return id


## Selects every roll in `[0, total_weight())` and counts how many outcomes each
## item id occupies — the exhaustive proof that a weight means what it says.
func _sweep_counts(table: LootTable) -> Dictionary:
	var counts: Dictionary = {}
	for roll: int in range(table.total_weight()):
		var id := _id_at(table, roll)
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


## Builds the identical table twice and asserts both resolve every roll in the
## space identically — the determinism the product law requires of anything on
## the authoritative path.
func _deterministic_replay() -> bool:
	var trace_a := _sweep_trace(_scripted_table())
	var trace_b := _sweep_trace(_scripted_table())
	_check(trace_a == trace_b, true, "determinism: two identically-built tables resolve every roll the same")
	_check(trace_a.contains("blade"), true, "determinism: the trace is non-vacuous")
	return not _failed


## A fixed table built by a fixed script, so two independent builds are comparable.
func _scripted_table() -> LootTable:
	var table := LootTable.new()
	table.add(4, {"kind": "trophy", "id": "ash_shard"})
	table.add(2, {"kind": "weapon", "id": "blade", "name": "Ashen Blade"})
	table.add(3, {"kind": "cosmetic", "id": "soot_dye"})
	table.add(1, {"kind": "lore", "id": "page_02"})
	return table


## A "," -joined trace of the drop for every roll in the table's space, plus a
## couple of out-of-range rolls, so two builds compare as one string.
func _sweep_trace(table: LootTable) -> String:
	var ids: Array[String] = []
	for roll: int in range(-2, table.total_weight() + 2):
		ids.append(_id_at(table, roll))
	return ",".join(ids)


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
