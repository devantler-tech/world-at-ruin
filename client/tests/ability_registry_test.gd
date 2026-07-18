extends Node
## Regression test for the Ability data model + registry (issue #70, Part of #9).
##
## Abilities are the classless weapon-mastery arsenal, authored as data so "an
## agent adds an ability by adding data plus a test". Two settled combat laws are
## enforced here mechanically, not by review taste (the product card calls them
## "simulatable ... an agent-ownable CI guard"):
##   • NO POWER INFLATION — every ability in a comparable class shares one power
##     budget ("mastery unlocks new arsenals, never more damage").
##   • NO STRICT DOMINANCE — within a class no ability Pareto-dominates another
##     ("every new arsenal ability must be a SIDEGRADE, never a strict upgrade").
## It also pins the forward-only content contract (a mastered ability never
## vanishes — no-resets law) and the loud refusal of malformed data.
##
## The teeth are proven with NEGATIVE CONTROLS: a synthetic strict-upgrade
## ability must trip the dominance guard and a synthetic power-inflated ability
## must trip the power guard — each in isolation from the other.
##
## Pure logic + res:// reads only — no scene, no save, no boot — so it is safe to
## run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/ability_registry_test.tscn

const SHIPPED := "res://tests/data/shipped_abilities.txt"
const BUDGETS := "res://tests/data/shipped_class_power.txt"
const CYCLE_FLOORS := "res://tests/data/shipped_class_cycle_floor.txt"

var _failed := false


func _ready() -> void:
	var abilities := Ability.load_all()
	_check(not abilities.is_empty(), "registry loads at least one ability")
	if _failed:
		return

	# --- determinism: same load order every time ---
	_check(_ids(abilities) == _ids(Ability.load_all()), "registry load order is deterministic")

	# --- ids unique, and each ability has its own <id>.json (stem == id) ---
	var ids := _ids(abilities)
	var loaded := {}
	for id: String in ids:
		_check(not loaded.has(id), "ability id '%s' is unique" % id)
		loaded[id] = true
		_check(FileAccess.file_exists("%s/%s.json" % [Ability.DIR, id]),
			"ability '%s' lives in its own file (stem == id)" % id)
	if _failed:
		return

	# --- forward-only content contract: shipped set and loaded set agree ---
	var shipped := _shipped_ids()
	_check(not shipped.is_empty(), "shipped_abilities.txt lists at least one id")
	for sid: String in shipped:
		_check(loaded.has(sid), "SHIPPED ability '%s' still loads + validates (no-resets law)" % sid)
	for id: String in ids:
		_check(sid_shipped(shipped, id), "loaded ability '%s' is registered in shipped_abilities.txt" % id)
	if _failed:
		return

	# --- the two law-guards are clean on the real seed ---
	# Power budgets are anchored in a committed, append-only, value-immutable
	# ledger (CI enforces that against the base revision) — not derived from the
	# mutable ability set — so raising a whole class can never pass unseen.
	var budgets := Ability.load_class_budgets(BUDGETS)
	_check(not budgets.is_empty(), "class power-budget ledger loads")
	# One frozen budget per class: a duplicate key would let a later, higher line
	# silently raise a class ceiling (CI enforces this against the base too).
	_check(_ledger_keys(BUDGETS).size() == budgets.size(),
		"class power-budget ledger has no duplicate class keys")
	var infl := Ability.find_power_inflation(abilities, budgets)
	_check(infl.is_empty(), "seed holds the no-power-inflation law: %s" % str(infl))
	var dom := Ability.find_strict_dominance(abilities)
	_check(dom.is_empty(), "seed holds the sidegrade law (no strict dominance): %s" % str(dom))
	# Freezing per-cast power bounds how much a cast does, not how often it lands.
	# The cycle floor is the other half of "never more damage": same ledger
	# permanence rules, same CI immutability against the base revision.
	var floors := Ability.load_class_budgets(CYCLE_FLOORS)
	_check(not floors.is_empty(), "class cycle-floor ledger loads")
	_check(_ledger_keys(CYCLE_FLOORS).size() == floors.size(),
		"class cycle-floor ledger has no duplicate class keys")
	var thr := Ability.find_throughput_inflation(abilities, floors)
	_check(thr.is_empty(), "seed holds the no-throughput-inflation law: %s" % str(thr))
	if _failed:
		return

	# --- a valid ability parses (sanity), then build the negative controls ---
	var base := {
		"id": "sword_probe", "version": 1,
		"weapon": "sword", "role": "damage", "effect": "damage", "telegraph": "cone",
		"cast_time_ms": 300, "cooldown_ms": 4000, "resource_cost": 15,
		"range_m": 4.0, "power": 100,
	}
	_check(Ability.parse(base) != null, "a valid ability parses")

	# NEGATIVE CONTROL 1 — a strict upgrade of the sword/cone class (faster cast,
	# nothing worse) MUST trip the dominance guard, and must NOT trip the power
	# guard (its power still matches the class budget) — isolation.
	var upgrade := base.duplicate()
	upgrade["id"] = "sword_reforged"
	upgrade["cast_time_ms"] = 200
	var upgrade_ab: Variant = Ability.parse(upgrade)
	_check(upgrade_ab != null, "dominance control parses")
	var with_upgrade := abilities.duplicate()
	with_upgrade.append(upgrade_ab)
	_check(not Ability.find_strict_dominance(with_upgrade).is_empty(),
		"dominance guard catches a strict-upgrade ability (teeth)")
	_check(Ability.find_power_inflation(with_upgrade, budgets).is_empty(),
		"the strict-upgrade control does not also trip the power guard (isolation)")

	# NEGATIVE CONTROL 2 — same situational axes as cleave but more power MUST
	# trip the power guard, and must NOT trip the dominance guard (identical
	# situational axes ⇒ no Pareto win) — isolation.
	var inflated := base.duplicate()
	inflated["id"] = "sword_mighty"
	inflated["power"] = 130
	var inflated_ab: Variant = Ability.parse(inflated)
	_check(inflated_ab != null, "power control parses")
	var with_inflated := abilities.duplicate()
	with_inflated.append(inflated_ab)
	_check(not Ability.find_power_inflation(with_inflated, budgets).is_empty(),
		"power guard catches a power-inflated ability (teeth)")
	_check(Ability.find_strict_dominance(with_inflated).is_empty(),
		"the power-inflated control does not also trip the dominance guard (isolation)")

	# NEGATIVE CONTROL 3 — the throughput bypass: halve the cooldown while giving
	# up a sliver of range. Power still equals the frozen budget and the range
	# regression means it is no Pareto win, so BOTH other guards pass it — yet it
	# lands roughly twice as often for ~2x damage per second. Only the cycle floor
	# catches it, which is precisely why that ledger exists.
	var faster := base.duplicate()
	faster["id"] = "sword_flurry"
	faster["cooldown_ms"] = 2000
	faster["range_m"] = 3.9
	var faster_ab: Variant = Ability.parse(faster)
	_check(faster_ab != null, "throughput control parses")
	var with_faster := abilities.duplicate()
	with_faster.append(faster_ab)
	_check(not Ability.find_throughput_inflation(with_faster, floors).is_empty(),
		"throughput guard catches a shortened-cycle ability (teeth)")
	_check(Ability.find_power_inflation(with_faster, budgets).is_empty(),
		"the throughput control slips past the power guard (why the cycle floor is needed)")
	_check(Ability.find_strict_dominance(with_faster).is_empty(),
		"the throughput control slips past the sidegrade guard (why the cycle floor is needed)")
	if _failed:
		return

	# --- dominates() directly: the seed pair is a mutual sidegrade ---
	var cleave: Variant = _by_id(abilities, "sword_cleave")
	var riposte: Variant = _by_id(abilities, "sword_riposte")
	_check(cleave != null and riposte != null, "the sword/cone pair is present")
	if _failed:
		return
	_check(not Ability.dominates(cleave, riposte), "cleave does not dominate riposte (sidegrade)")
	_check(not Ability.dominates(riposte, cleave), "riposte does not dominate cleave (sidegrade)")
	_check(Ability.dominates(upgrade_ab, cleave), "the reforged control does dominate cleave")

	# --- malformed data is refused loudly (returns null), never crashes ---
	_expect_rejected(_drop(base, "power"), "a missing field")
	_expect_rejected(_with(base, "weapon", "laser"), "an unknown enum value")
	_expect_rejected(_with(base, "role", 5), "a wrong-typed field")
	_expect_rejected(_with(base, "cast_time_ms", -1), "a negative cost")
	_expect_rejected(_with(base, "cooldown_ms", 1.5), "a fractional integer")
	_expect_rejected(_with(base, "range_m", "far"), "a wrong-typed range")
	_expect_rejected(_with(base, "range_m", INF), "an infinite range")
	_expect_rejected(_with(base, "cooldown_ms", INF), "an infinite cost")
	_expect_rejected(_with(base, "version", 0), "a version below 1")
	_expect_rejected(_with(base, "id", ""), "an empty id")
	_expect_rejected([], "a non-object")
	if _failed:
		return

	print("TEST PASS — ability registry: %d shipped abilities, sidegrade + no-power-inflation + no-throughput-inflation laws hold" % ids.size())
	get_tree().quit(0)


# --- helpers ---------------------------------------------------------------

func _ids(abilities: Array) -> Array:
	var out: Array = []
	for ab: Dictionary in abilities:
		out.append(ab["id"])
	return out


func _by_id(abilities: Array, id: String) -> Variant:
	for ab: Dictionary in abilities:
		if ab["id"] == id:
			return ab
	return null


func sid_shipped(shipped: PackedStringArray, id: String) -> bool:
	return id in shipped


## Every budget-line key (duplicates included), so the caller can compare its
## count against the deduped Dictionary size to catch a repeated class key.
func _ledger_keys(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq >= 0:
			out.append(line.substr(0, eq).strip_edges())
	return out


func _shipped_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(SHIPPED, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			out.append(line)
	return out


func _with(base: Dictionary, key: String, value: Variant) -> Dictionary:
	var d := base.duplicate()
	d[key] = value
	return d


func _drop(base: Dictionary, key: String) -> Dictionary:
	var d := base.duplicate()
	d.erase(key)
	return d


func _expect_rejected(data: Variant, what: String) -> void:
	if _failed:
		return
	if Ability.parse(data) != null:
		_fail("malformed data (%s) was accepted — it must be refused" % what)


func _check(condition: bool, label: String) -> void:
	if _failed:
		return
	if not condition:
		_fail(label)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
