class_name Ability
extends RefCounted
## Ability data model — the deterministic, data-driven core of the classless
## weapon-mastery arsenal (AGENTS.md "Design — classless weapon mastery").
##
## An ability is DATA: one JSON file per ability under res://abilities/, so "an
## agent adds an ability by adding data plus a test" (roadmap #9). Both tiers
## consume the SAME data — the authoritative server resolves the ability and the
## client previews/predicts it — exactly like the shared Telegraph geometry, so
## the schema lives here as ONE pure source of truth: no scene tree, no engine
## state, no user:// — deterministic and unit-testable, and safe to load headless.
##
## This library carries the two settled combat product-laws as MECHANICAL guards
## rather than review taste (the product card calls them "simulatable ... an
## agent-ownable CI guard rather than a matter of taste"). There is no undo in
## this game, so — like the save-fixture guard that landed before the first
## player — these exist BEFORE the first ability content does:
##
##   1. NO POWER INFLATION — "Mastery unlocks new arsenals, never more damage."
##      The open-world arsenal grows in options, never in raw power, and a value
##      leak is irreversible. So every ability in a comparable class shares ONE
##      power budget: adding an ability can never raise the ceiling.
##
##   2. NO STRICT DOMINANCE (the sidegrade law) — "Every new arsenal ability must
##      be a SIDEGRADE, never a strict upgrade." Within a comparable class no
##      ability may Pareto-dominate another across the situational trade-off axes,
##      so every ability is a real choice and none is dead on arrival.
##
## A "comparable class" is (weapon, role, effect, telegraph): two abilities are
## only strict-upgrade-comparable when they are the SAME KIND of tool. A frontal
## cone and a point-blank circle are different tactical tools — neither is an
## upgrade of the other by definition — so they are not compared. The guards bite
## precisely where a real upgrade could hide: same kind of tool, one just better.
##
## The seed abilities in res://abilities are illustrative scaffolding that
## exercises the guards; the numbers are NOT balance-tuned content. The
## INVARIANTS (equal power within a class, no Pareto dominance) are the settled
## laws — the values are placeholders combat content will replace.

## Where per-ability JSON lives, one file per ability (stem == id by convention).
const DIR := "res://abilities"

## The trifecta (AGENTS.md) plus the identity axes. An ability is only compared
## for "strict upgrade" against another of the same weapon, role, effect and
## telegraph — the same kind of tool.
const WEAPONS := ["sword", "staff", "bow", "focus", "shield", "dagger", "hammer", "spear"]
const ROLES := ["damage", "tank", "healer"]
const EFFECTS := ["damage", "heal", "shield", "control"]
## Telegraph shapes mirror the Telegraph geometry library exactly.
const TELEGRAPHS := ["circle", "ring", "cone", "rect"]

## Situational axes where LOWER is better (what the ability costs the caster).
const COST_AXES := ["cast_time_ms", "cooldown_ms", "resource_cost"]
## Situational axes where HIGHER is better (what the ability gives the caster).
## `power` is deliberately NOT here: it is not a free trade axis — it is pinned
## equal within a class by the no-power-inflation guard, so it never
## differentiates two abilities and never enters the dominance test.
const BENEFIT_AXES := ["range_m"]

## Integer fields (milliseconds and unit costs are whole numbers).
const _INT_FIELDS := ["version", "cast_time_ms", "cooldown_ms", "resource_cost", "power"]


## Validate one decoded ability object and return a normalised, typed Dictionary,
## or null (loudly) on ANY malformed field. Every field is type- and
## range-guarded (the recipe_type_guard lesson, #47): a wrong-typed persisted
## field must produce a clean refusal, never a crash or a silent mis-read.
## Unknown keys are ignored on purpose, so a newer data file stays loadable by an
## older client (forward-only compatibility).
static func parse(data: Variant) -> Variant:
	if data is not Dictionary:
		push_error("Ability: not a JSON object")
		return null
	var d: Dictionary = data

	var out := {}
	var id := _require_id(d)
	if id.is_empty():
		return null
	out["id"] = id

	for field in ["weapon", "role", "effect", "telegraph"]:
		var allowed: Array = _allowed_for(field)
		var value := _require_enum(d, field, allowed, id)
		if value.is_empty():
			return null
		out[field] = value

	for field in _INT_FIELDS:
		var n := _require_nonneg_int(d, field, id)
		if n < 0:
			return null
		out[field] = n
	if out["version"] < 1:
		push_error("Ability '%s': version must be >= 1" % id)
		return null

	var reach := _require_nonneg_number(d, "range_m", id)
	if is_nan(reach):
		return null
	out["range_m"] = reach

	return out


## Load every ability under `dir`, sorted by filename so the registry is
## deterministic. A file that fails to parse is reported and skipped (the
## forward-only content test then catches a shipped ability that has gone
## missing). Reads res:// only — never touches the player's save.
static func load_all(dir: String = DIR) -> Array:
	var out: Array = []
	var da := DirAccess.open(dir)
	if da == null:
		push_error("Ability: cannot open %s" % dir)
		return out
	var names := da.get_files()
	names.sort()
	for name in names:
		if not name.ends_with(".json"):
			continue
		var path := "%s/%s" % [dir, name]
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_error("Ability: cannot open %s" % path)
			continue
		var parsed: Variant = parse(JSON.parse_string(file.get_as_text()))
		if parsed == null:
			push_error("Ability: %s failed to parse" % path)
			continue
		out.append(parsed)
	return out


## The comparable-class key: two abilities compete for the same choice only when
## they are the same kind of tool.
static func class_key(a: Dictionary) -> String:
	return "%s|%s|%s|%s" % [a["weapon"], a["role"], a["effect"], a["telegraph"]]


## True when `a` strictly dominates `b`: no worse on any situational axis and
## strictly better on at least one. Callers pass two abilities of the same class
## (see `class_key`); power is not consulted (it is pinned equal per class).
static func dominates(a: Dictionary, b: Dictionary) -> bool:
	var strictly_better := false
	for axis in COST_AXES:  # lower is better
		if a[axis] > b[axis]:
			return false
		if a[axis] < b[axis]:
			strictly_better = true
	for axis in BENEFIT_AXES:  # higher is better
		if a[axis] < b[axis]:
			return false
		if a[axis] > b[axis]:
			strictly_better = true
	return strictly_better


## Guard 1 — no power inflation. Returns a human-readable violation per
## comparable class whose abilities do not all share one power budget. Empty ⇒
## the "never more damage" law holds across `abilities`.
static func find_power_inflation(abilities: Array) -> Array:
	var by_class := _group_by_class(abilities)
	var violations: Array = []
	for key in by_class:
		var group: Array = by_class[key]
		var budget = group[0]["power"]
		for ab in group:
			if ab["power"] != budget:
				violations.append(
					"power inflation in class [%s]: '%s' has power %d but the class budget is %d"
					% [key, ab["id"], ab["power"], budget])
				break
	return violations


## Guard 2 — no strict dominance (the sidegrade law). Returns a human-readable
## violation for every ordered pair within a class where one ability
## Pareto-dominates another. Empty ⇒ every ability is a genuine sidegrade.
static func find_strict_dominance(abilities: Array) -> Array:
	var by_class := _group_by_class(abilities)
	var violations: Array = []
	for key in by_class:
		var group: Array = by_class[key]
		for i in group.size():
			for j in group.size():
				if i == j:
					continue
				if dominates(group[i], group[j]):
					violations.append(
						"strict dominance in class [%s]: '%s' is a strict upgrade of '%s' (must be a sidegrade)"
						% [key, group[i]["id"], group[j]["id"]])
	return violations


# --- helpers ---------------------------------------------------------------

static func _group_by_class(abilities: Array) -> Dictionary:
	var by_class := {}
	for ab in abilities:
		var key := class_key(ab)
		if not by_class.has(key):
			by_class[key] = []
		by_class[key].append(ab)
	return by_class


static func _allowed_for(field: String) -> Array:
	match field:
		"weapon":
			return WEAPONS
		"role":
			return ROLES
		"effect":
			return EFFECTS
		"telegraph":
			return TELEGRAPHS
	return []


static func _require_id(d: Dictionary) -> String:
	if not d.has("id"):
		push_error("Ability: missing 'id'")
		return ""
	if d["id"] is not String or String(d["id"]).is_empty():
		push_error("Ability: 'id' must be a non-empty string")
		return ""
	return String(d["id"])


static func _require_enum(d: Dictionary, field: String, allowed: Array, id: String) -> String:
	if not d.has(field):
		push_error("Ability '%s': missing '%s'" % [id, field])
		return ""
	if d[field] is not String:
		push_error("Ability '%s': '%s' must be a string" % [id, field])
		return ""
	var value := String(d[field])
	if value not in allowed:
		push_error("Ability '%s': unknown %s '%s'" % [id, field, value])
		return ""
	return value


## Returns the whole-number value, or -1 (loudly) if missing / non-numeric /
## fractional / negative. JSON numbers decode as float, so an integer field must
## also reject a fractional value like 1.5.
static func _require_nonneg_int(d: Dictionary, field: String, id: String) -> int:
	if not d.has(field):
		push_error("Ability '%s': missing '%s'" % [id, field])
		return -1
	var v = d[field]
	if v is not int and v is not float:
		push_error("Ability '%s': '%s' must be a number" % [id, field])
		return -1
	var f := float(v)
	if f < 0.0:
		push_error("Ability '%s': '%s' must be >= 0" % [id, field])
		return -1
	if f != floor(f):
		push_error("Ability '%s': '%s' must be a whole number" % [id, field])
		return -1
	return int(f)


## Returns the value as a float, or NaN (loudly) if missing / non-numeric /
## negative — NaN being an out-of-band sentinel no valid range can take.
static func _require_nonneg_number(d: Dictionary, field: String, id: String) -> float:
	if not d.has(field):
		push_error("Ability '%s': missing '%s'" % [id, field])
		return NAN
	var v = d[field]
	if v is not int and v is not float:
		push_error("Ability '%s': '%s' must be a number" % [id, field])
		return NAN
	var f := float(v)
	if f < 0.0:
		push_error("Ability '%s': '%s' must be >= 0" % [id, field])
		return NAN
	return f
