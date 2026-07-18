extends Node
## Regression test for the armour axis guards (issue #86).
##
## Armour is the ONE place the design lets power grow ("Armour = your role/
## agility axis, and the bounded endgame vertical"), so it is the most likely
## door for the power creep the product law forbids — and there is no undo. This
## pins the three settled laws as simulated invariants:
##  1. TRADE-OFF (no strict dominance) — no same-slot piece is >= on BOTH
##     mitigation and agility and strictly better on one. "Armour is the
##     exception — real mitigation/lightness trade-offs."
##  2. CLASS HONESTY (no inversions) — a heavier class mitigates strictly more
##     and moves strictly less than a lighter one in the same slot: "light =
##     agile, heavy = takes a hit."
##  3. CLOSED SCHEMA + BOUNDED CEILING — exactly {id, slot, weight_class,
##     mitigation, agility} from closed sets, both axes inside their caps, ids
##     unique. No offence field is accepted at all, which is "keep them [the
##     weapon and armour axes] from blurring" made mechanical.
##
## Every negative control is ISOLATED: a strictly-dominant piece trips dominance
## ONLY, a mislabelled piece trips inversion ONLY, and a malformed/over-cap piece
## trips the schema guard ONLY (the pairwise guards run over well-formed records,
## so each law reports independently and a red build names the law it broke).
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally
## and deterministic in CI.
##
## Run: godot --headless --path client res://tests/armor_axis_test.tscn

var _failed := false


func _ready() -> void:
	# --- the shipped seed set obeys all three laws ---
	var seeds: Array = Armor.SEED_PIECES.duplicate()
	_clean(Armor.find_schema_violations(seeds), "seed set: schema clean")
	_clean(Armor.find_strict_dominance(seeds), "seed set: no strictly-dominant piece")
	_clean(Armor.find_class_inversions(seeds), "seed set: no weight-class inversion")
	if _failed:
		return

	# --- the seed set actually exercises the guards: every slot, every class ---
	for slot: String in Armor.SLOTS:
		for wc: String in Armor.WEIGHT_CLASSES:
			var found := false
			for p: Dictionary in seeds:
				if p["slot"] == slot and p["weight_class"] == wc:
					found = true
					break
			_check(found, true, "seed coverage: a %s piece exists for slot '%s'" % [wc, slot])
	if _failed:
		return

	# --- 1. DOMINANCE control: a same-class piece that is simply better ---
	# Same weight class as warden_hauberk, better on both axes: creep, not a trade.
	# Deliberately still class-honest (between the light and heavy chest pieces),
	# so it trips dominance ALONE.
	var creep := {"id": "creep_vest", "slot": "chest", "weight_class": "medium", "mitigation": 50.0, "agility": 60.0}
	var with_creep: Array = seeds.duplicate()
	with_creep.append(creep)
	_flags(Armor.find_strict_dominance(with_creep), "dominance guard catches a strictly-better piece")
	_clean(Armor.find_class_inversions(with_creep), "…and that piece trips dominance ONLY (class honest)")
	_clean(Armor.find_schema_violations(with_creep), "…and its schema is clean")
	if _failed:
		return

	# --- 2. INVERSION control: a "heavy" that is the most agile, least armoured ---
	var liar := {"id": "bad_helm", "slot": "head", "weight_class": "heavy", "mitigation": 5.0, "agility": 95.0}
	var with_liar: Array = seeds.duplicate()
	with_liar.append(liar)
	_flags(Armor.find_class_inversions(with_liar), "inversion guard catches a mislabelled heavy piece")
	_clean(Armor.find_strict_dominance(with_liar), "…and that piece trips inversion ONLY (dominates nothing)")
	_clean(Armor.find_schema_violations(with_liar), "…and its schema is clean")
	if _failed:
		return

	# --- 3. SCHEMA controls, each isolated from the pairwise guards ---
	# (a) a smuggled offence field — the axis-blur the design forbids
	_isolated_schema_case(seeds,
		{"id": "blade_mail", "slot": "chest", "weight_class": "heavy", "mitigation": 60.0, "agility": 30.0, "damage": 25.0},
		"schema guard catches a smuggled offence field (axis blur)")
	# (b) over the bounded ceiling — would dominate everything if it were let in
	_isolated_schema_case(seeds,
		{"id": "godplate", "slot": "chest", "weight_class": "heavy", "mitigation": 250.0, "agility": 95.0},
		"schema guard catches mitigation past the bounded ceiling")
	# (c) a slot outside the closed set
	_isolated_schema_case(seeds,
		{"id": "tail_guard", "slot": "tail", "weight_class": "light", "mitigation": 5.0, "agility": 50.0},
		"schema guard catches an unknown slot")
	# (d) a weight class outside the closed set
	_isolated_schema_case(seeds,
		{"id": "mythic_crown", "slot": "head", "weight_class": "mythic", "mitigation": 5.0, "agility": 50.0},
		"schema guard catches an unknown weight class")
	# (e) a missing field, and a non-Dictionary record
	_isolated_schema_case(seeds,
		{"id": "half_piece", "slot": "head", "weight_class": "light", "mitigation": 5.0},
		"schema guard catches a missing field")
	if _failed:
		return
	# NOTE: SEED_PIECES.duplicate() keeps its Array[Dictionary] element type, and
	# that type survives assignment to an untyped `Array` variable — appending a
	# String to it is rejected at runtime, which would make this control vacuous.
	# Build an untyped array so the non-Dictionary branch is genuinely exercised.
	var junk: Array = []
	junk.assign(seeds)
	junk.append("not a piece")
	_flags(Armor.find_schema_violations(junk), "schema guard catches a non-Dictionary record")
	if _failed:
		return

	# (f) a duplicate id — an exact copy, so it is schema-only (equal stats never
	# dominate, same class never inverts)
	var dupe: Array = seeds.duplicate()
	dupe.append((seeds[0] as Dictionary).duplicate())
	_flags(Armor.find_schema_violations(dupe), "schema guard catches a duplicate piece id")
	_clean(Armor.find_strict_dominance(dupe), "…a duplicate never counts as dominance")
	_clean(Armor.find_class_inversions(dupe), "…nor as an inversion")
	if _failed:
		return

	# --- determinism: guard output never depends on the order pieces arrive in ---
	var shuffled: Array = []
	for i in range(seeds.size() - 1, -1, -1):
		shuffled.append(seeds[i])
	var mixed: Array = shuffled.duplicate()
	mixed.append(creep)
	mixed.append(liar)
	var ordered: Array = seeds.duplicate()
	ordered.append(creep)
	ordered.append(liar)
	_check(Armor.find_strict_dominance(mixed) == Armor.find_strict_dominance(ordered), true,
		"determinism: dominance output is order-independent")
	_check(Armor.find_class_inversions(mixed) == Armor.find_class_inversions(ordered), true,
		"determinism: inversion output is order-independent")
	if _failed:
		return

	# --- degenerate inputs never crash and flag nothing ---
	_clean(Armor.find_schema_violations([]), "degenerate: an empty set is clean")
	_clean(Armor.find_strict_dominance([]), "degenerate: an empty set dominates nothing")
	_clean(Armor.find_class_inversions([]), "degenerate: an empty set inverts nothing")
	_clean(Armor.find_strict_dominance([seeds[0]]), "degenerate: a lone piece dominates nothing")
	_clean(Armor.find_class_inversions([seeds[0]]), "degenerate: a lone piece inverts nothing")
	_check(Armor.is_wellformed("nonsense"), false, "degenerate: a non-Dictionary is never well-formed")
	if _failed:
		return

	print("TEST PASS — armour axis holds (%d seed pieces: trade-off, class-honest, closed schema within the bounded ceiling; all three guards proven with isolated negative controls)" % seeds.size())
	get_tree().quit(0)


## A malformed/out-of-range piece must trip the SCHEMA guard and leave both
## pairwise guards clean — proving each law reports independently.
func _isolated_schema_case(seeds: Array, bad: Dictionary, label: String) -> void:
	if _failed:
		return
	var candidate: Array = seeds.duplicate()
	candidate.append(bad)
	_flags(Armor.find_schema_violations(candidate), label)
	_clean(Armor.find_strict_dominance(candidate), "%s — and it is excluded from the dominance guard" % label)
	_clean(Armor.find_class_inversions(candidate), "%s — and from the inversion guard" % label)


func _clean(problems: Array[String], label: String) -> void:
	if _failed:
		return
	if not problems.is_empty():
		_fail("%s — expected no violations, got %d: %s" % [label, problems.size(), problems[0]])


func _flags(problems: Array[String], label: String) -> void:
	if _failed:
		return
	if problems.is_empty():
		_fail("%s — expected a violation, got none (the guard has no teeth)" % label)


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
