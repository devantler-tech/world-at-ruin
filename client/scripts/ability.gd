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
##      Three anchors, each closing what the previous one leaves open. Every
##      ability of a (role|effect) category shares ONE frozen per-cast power
##      budget, so a new weapon or telegraph cannot introduce a stronger version
##      of an existing category. Because that bounds only how much a cast does,
##      every ability must also meet a frozen cast+cooldown CYCLE FLOOR, which
##      bounds how often it lands — together capping per-target throughput at
##      budget/floor. And because a brand-new category could otherwise claim any
##      opening value permanently, CI bounds an added category against the scale
##      already shipped. A shipped ability additionally may never become a STRICT
##      upgrade of its own base version (the CI "no strict self-buff" anchor).
##
##      SCOPE, stated honestly: this bounds PER-TARGET throughput. Telegraph AREA
##      is not in the model. Today that is latent rather than live: `telegraph` is
##      a KIND only (part of `class_key`, the comparable-class key — the power
##      budget is keyed on `(role|effect)` alone) and an ability carries no shape
##      magnitude — no half-angle, no radius — so there is nothing to widen yet
##      (`range_m` does exist, and trades on the dominance axes). The gap opens
##      when ability data carries real shape magnitudes: two abilities on the same
##      budget and cycle then differ in how many targets one cast reaches, and no
##      guard sees it. That multi-target economy is DECIDED,
##      not pending: devantler-tech/world-at-ruin#82 settled it (maintainer
##      direction 2026-07-18, option C) as a REVIEWED BALANCE DECISION rather than
##      a future CI guard, because bounding it means inventing an area-vs-power
##      exchange rate and freezing it permanently under the no-resets law. So
##      widening a telegraph is a balance review the maintainer approves (see
##      AGENTS.md); do not add a mechanical area guard here without fresh
##      direction superseding that.
##
##   2. NO STRICT DOMINANCE (the sidegrade law) — "Every new arsenal ability must
##      be a SIDEGRADE, never a strict upgrade." Within a comparable class no
##      ability may Pareto-dominate another across the situational trade-off axes,
##      so every ability is a real choice and none is dead on arrival.
##
## A "comparable class" is (role, effect, telegraph): two abilities are only
## strict-upgrade-comparable when they are the SAME KIND of tool. A frontal cone
## and a point-blank circle are different tactical tools — neither is an upgrade
## of the other by definition — so they are not compared. WEAPON is deliberately
## excluded: the design puts weapons on the HORIZONTAL axis, so a bow's cone and a
## sword's cone are competing choices that must trade off, never one strictly
## better. The guards bite precisely where a real upgrade could hide: same kind of
## tool, one just better.
##
## The seed abilities in res://abilities are illustrative scaffolding that
## exercises the guards; the numbers are NOT balance-tuned content. The
## INVARIANTS (one per-cast power per role|effect category, no Pareto dominance,
## no strict self-buff over base) are the settled laws — the values are
## placeholders combat content will replace.

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

## The highest ability schema this build fully understands. A file declaring a
## HIGHER version is refused outright rather than half-applied: a newer schema
## may add targeting or cost semantics this build would silently ignore, and a
## mastered ability behaving with missing constraints is exactly the permanent,
## un-undoable harm the product law forbids. Bump this in the same change that
## teaches the parser the new version's fields.
const SCHEMA_VERSION := 1

## Every field this schema defines. An unrecognised key is refused rather than
## ignored: within a known version there is nothing legitimate for it to mean, so
## it is either a typo or content from a schema this build cannot honour — and a
## silent skip is how a half-understood ability reaches a player. Genuinely new
## fields arrive with a SCHEMA_VERSION bump, which is what the ceiling above
## gates on.
const _KNOWN_FIELDS := [
	"id", "version", "weapon", "role", "effect", "telegraph",
	"cast_time_ms", "cooldown_ms", "resource_cost", "range_m", "power",
]


## Validate one decoded ability object and return a normalised, typed Dictionary,
## or null (loudly) on ANY malformed field. Every field is type- and
## range-guarded (the recipe_type_guard lesson, #47): a wrong-typed persisted
## field must produce a clean refusal, never a crash or a silent mis-read.
##
## Forward compatibility is handled by REFUSING, not by ignoring: a file whose
## `version` exceeds SCHEMA_VERSION, or which carries a field this schema does
## not define, is rejected loudly so an older build gates incompatible content
## instead of half-applying it (a mastered ability must never run with semantics
## its binary silently dropped).
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

	for key: String in d.keys():
		if key not in _KNOWN_FIELDS:
			push_error("Ability '%s': unknown field '%s' — refusing rather than half-applying" % [id, key])
			return null

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
	if out["version"] > SCHEMA_VERSION:
		push_error("Ability '%s': schema version %d is newer than this build understands (%d) — refusing rather than half-applying"
			% [id, out["version"], SCHEMA_VERSION])
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


## The comparable-class key (for the sidegrade guard): two abilities compete for
## the same choice when they are the same KIND of tool — same role, same effect,
## same telegraph shape.
##
## WEAPON is deliberately NOT part of this key. AGENTS.md's axis map puts weapons
## on the HORIZONTAL axis ("a sword is a sword"): mastering a different weapon
## must widen your options, never hand you a better version of what you had. So a
## bow's damage cone and a sword's damage cone ARE competing choices and must be
## mutual sidegrades — if the bow reaches further it has to pay for it somewhere.
## Keying on weapon would put them in separate groups and let weapon mastery ship
## as a strict upgrade, permanently inflating the arsenal along the one axis the
## design declares flat.
static func class_key(a: Dictionary) -> String:
	return "%s|%s|%s" % [a["role"], a["effect"], a["telegraph"]]


## The power-budget key (for the no-inflation guard): per-cast power depends on
## the trifecta role and the effect, NOT on the weapon or telegraph — a sword and
## a bow that both deal a damage-role hit share one power ceiling, so a new weapon
## or telegraph can never introduce a higher-power version of an existing
## category. It is deliberately COARSER than `class_key`.
static func budget_key(a: Dictionary) -> String:
	return "%s|%s" % [a["role"], a["effect"]]


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


## Guard 1 — no per-cast power inflation. Every ability's power must equal the
## FROZEN budget recorded for its (role|effect) category in `budgets` (loaded
## from the committed ledger). Returns a violation for every ability whose
## category has no frozen budget or whose power differs from it.
##
## The budget is anchored OUTSIDE the mutable ability set on purpose: deriving it
## from the current abilities would let a change that raises EVERY member of a
## category pass unseen, since CI only ever evaluates the resulting checkout. The
## committed ledger — append-only, with values immutable against the base
## revision, both enforced in CI — is the anchor that makes the per-cast ceiling
## real over time, and keying it on (role|effect) stops a new weapon or telegraph
## from introducing a higher-power version of an existing category.
##
## This is NECESSARY but not SUFFICIENT for "never more power": per-cast power is
## not effective throughput, which also depends on cast time and cooldown. That
## remainder is held by `find_throughput_inflation` and its frozen cycle-floor
## ledger — NOT, as this note once claimed, by the CI "no strict self-buff over
## base" anchor, which cannot see it: trading a shorter cooldown for a shorter
## range is no Pareto win, so it passes as a sidegrade while roughly doubling
## damage per second. The initial scale of a genuinely NEW (role|effect) category
## is bounded in CI against the categories already shipped.
##
## Still NOT bounded, and deliberately so: multi-target reach. Throughput here is
## per-target — telegraph AREA is not in the model. No shape magnitude is
## expressible today, so nothing can be widened yet; but ONCE ability data carries
## shape magnitudes, a wider cone at the same cycle and budget would hit more
## targets for more total damage, and no guard would see it.
## devantler-tech/world-at-ruin#82 SETTLED this (maintainer direction 2026-07-18,
## option C): it stays a reviewed balance decision, not a CI guard, because the
## area-vs-power exchange rate is game balance and freezing one would be permanent
## under the no-resets law. Widening a telegraph is a maintainer-approved balance
## review (AGENTS.md), never something green CI grants.
static func find_power_inflation(abilities: Array, budgets: Dictionary) -> Array:
	var violations: Array = []
	for ab in abilities:
		var key := budget_key(ab)
		if not budgets.has(key):
			violations.append(
				"category [%s] ('%s') has no frozen power budget — register it in the ledger" % [key, ab["id"]])
		elif ab["power"] != budgets[key]:
			violations.append(
				"power inflation: '%s' has power %d but the frozen budget for category [%s] is %d"
				% [ab["id"], ab["power"], key, budgets[key]])
	return violations


## The full cycle one cast occupies: casting it, then waiting out its cooldown.
## This is the denominator of effective throughput (power per cycle), so both
## halves must count — shaving cast time inflates throughput exactly as shortening
## the cooldown does.
static func cycle_ms(a: Dictionary) -> int:
	return a["cast_time_ms"] + a["cooldown_ms"]


## Guard 3 — no THROUGHPUT inflation. Per-cast power is frozen by
## `find_power_inflation`, so what remains free is how often a cast lands: an
## ability whose cast+cooldown cycle shrinks does strictly more damage per second
## on the same frozen budget. Neither of the other guards sees it — the power
## guard only reads `power`, and the sidegrade guard reads a shorter cooldown
## traded against a shorter range as a legitimate sidegrade rather than a Pareto
## win. So every ability's cycle must be at least the FROZEN floor recorded for
## its (role|effect) category, which bounds throughput at `budget / floor`.
##
## Like the power budget the floor is anchored OUTSIDE the mutable ability set,
## in a committed append-only ledger whose values CI holds immutable against the
## base revision — otherwise a change that shortened EVERY member of a category
## would pass unseen.
static func find_throughput_inflation(abilities: Array, floors: Dictionary) -> Array:
	var violations: Array = []
	for ab in abilities:
		var key := budget_key(ab)
		var cycle := cycle_ms(ab)
		if not floors.has(key):
			violations.append(
				"category [%s] ('%s') has no frozen cycle floor — register it in the ledger" % [key, ab["id"]])
		elif cycle < floors[key]:
			violations.append(
				"throughput inflation: '%s' has a %d ms cast+cooldown cycle but the frozen floor for category [%s] is %d ms"
				% [ab["id"], cycle, key, floors[key]])
	return violations


## Load the frozen class power-budget ledger: `weapon|role|effect|telegraph=power`
## lines (comment/blank lines ignored), returned as a class_key -> int map. A
## malformed or non-integer line is reported and skipped. Reads res:// only.
static func load_class_budgets(path: String) -> Dictionary:
	var out := {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Ability: cannot open power-budget ledger %s" % path)
		return out
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq < 0:
			push_error("Ability: malformed budget line '%s'" % line)
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if not value.is_valid_int():
			push_error("Ability: non-integer budget in '%s'" % line)
			continue
		if out.has(key):
			# A duplicate key must NEVER silently raise a frozen budget: keep the
			# first value, refuse the rest loudly. CI also rejects duplicate keys.
			push_error("Ability: duplicate class budget key '%s' in %s" % [key, path])
			continue
		out[key] = value.to_int()
	return out


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
	if not is_finite(f):
		push_error("Ability '%s': '%s' must be finite" % [id, field])
		return -1
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
	if not is_finite(f):
		push_error("Ability '%s': '%s' must be finite" % [id, field])
		return NAN
	if f < 0.0:
		push_error("Ability '%s': '%s' must be >= 0" % [id, field])
		return NAN
	return f
