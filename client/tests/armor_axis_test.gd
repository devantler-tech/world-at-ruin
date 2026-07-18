extends Node
## Regression test for the armour axis guards (issues #86, #96).
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
##  4. ONE SLOT VOCABULARY (#96) — the armour model and the baked equipment
##     registry describe the same body regions, so every art-layer slot (and
##     every shipped piece's slot) must be a legal Armor.SLOTS value. Read from
##     the REAL registry, so the two vocabularies can never silently drift.
##     Model-only slots are allowed and deliberate (see armor.gd's SCOPE note);
##     an art-layer slot the model rejects is the defect.
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
	# Deliberately still class-honest (between the light and heavy torso pieces),
	# so it trips dominance ALONE.
	var creep := {"id": "creep_vest", "slot": "torso", "weight_class": "medium", "mitigation": 50.0, "agility": 60.0}
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
		{"id": "blade_mail", "slot": "torso", "weight_class": "heavy", "mitigation": 60.0, "agility": 30.0, "damage": 25.0},
		"schema guard catches a smuggled offence field (axis blur)")
	# (b) over the bounded ceiling — would dominate everything if it were let in
	_isolated_schema_case(seeds,
		{"id": "godplate", "slot": "torso", "weight_class": "heavy", "mitigation": 250.0, "agility": 95.0},
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

	# --- CROSS-LAYER: the art layer's slot vocabulary must be legal here (#96) ---
	# The armour model and the baked equipment registry describe the same body
	# regions and MUST share one vocabulary; the art layer is the incumbent (its
	# slot strings are baked into shipped pieces and reachable from persisted
	# recipes), so every art slot has to be a legal armour slot. Read the REAL
	# registry, never a hardcoded copy, so drift in either direction turns CI red.
	var registry := CharacterFactory.equipment_registry()
	var art_slots: Array = registry.get("slots", [])
	# A missing/unreadable registry would make every check below pass VACUOUSLY —
	# the "a broken scanner reads exactly like a clean one" trap. Assert it loaded.
	_check(art_slots.is_empty(), false, "cross-layer: the baked equipment registry actually loaded (an empty one would pass vacuously)")
	if _failed:
		return
	for slot: Variant in art_slots:
		_check(str(slot) in Armor.SLOTS, true,
			"cross-layer: art-layer slot '%s' is a legal armour slot (Armor.SLOTS=%s)" % [str(slot), Armor.SLOTS])
	# Every shipped PIECE's slot too: the registry's own slot list and its pieces
	# could themselves disagree, and it is the pieces that actually get worn.
	var piece_slots := _piece_slots(registry)
	_check(piece_slots.is_empty(), false, "cross-layer: the registry actually declares pieces (an empty one would pass vacuously)")
	if _failed:
		return
	for slot: String in piece_slots:
		_check(slot in Armor.SLOTS, true, "cross-layer: shipped piece slot '%s' is a legal armour slot" % slot)
	if _failed:
		return

	print("TEST PASS — armour axis holds (%d seed pieces: trade-off, class-honest, closed schema within the bounded ceiling; all three guards proven with isolated negative controls) + slot vocabulary agrees with the art layer (%d art slots, %d shipped pieces)" % [seeds.size(), art_slots.size(), piece_slots.size()])
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


## Every shipped piece's slot, from the baked registry. Handles both plausible
## bake shapes (an id-keyed dictionary, which is what ships today, or an array of
## piece records) — the bake FORMAT is the art layer's concern, but the slot
## VOCABULARY is shared, and that is what this test pins.
func _piece_slots(registry: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var pieces: Variant = registry.get("pieces", null)
	if pieces is Dictionary:
		for key: Variant in (pieces as Dictionary):
			var p: Variant = (pieces as Dictionary)[key]
			if p is Dictionary and (p as Dictionary).has("slot"):
				out.append(str((p as Dictionary)["slot"]))
	elif pieces is Array:
		for p: Variant in (pieces as Array):
			if p is Dictionary and (p as Dictionary).has("slot"):
				out.append(str((p as Dictionary)["slot"]))
	out.sort()
	return out


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
