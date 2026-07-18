class_name LootTable
extends RefCounted
## A weighted drop table — what defeating something or opening a container yields.
## Phase 6 names loot as core content, and this world states the rule for it
## exactly: loot is "Elder-Scrolls-shaped: a sword is a sword", weapons are
## horizontal ("your arsenal; cosmetic variety only"), and open-world loot is
## BOUND — a cosmetic edge, never a stat. This library is the open-world drop
## layer, and it makes both of that rule's halves mechanical rather than a matter
## of a reviewer's vigilance.
##
## [b]1. The roll is deterministic and server-shaped.[/b] [method select] maps an
## integer `roll` to exactly one entry by cumulative weight in insertion order —
## same roll, same drop, always. It is integer-only and insertion-order stable, so
## it resolves identically on every platform (the same discipline the server sim
## holds with integer-millimetre coordinates). Crucially the library owns NO
## randomness: the authoritative caller supplies the roll, so a drop is
## reproducible, replay-able and audit-able after the fact, and there is no
## client-side RNG for a player to manipulate.
##
## [b]2. Power is not representable.[/b] An item is one of a CLOSED set of kinds
## ([constant KIND_WEAPON] an arsenal weapon, [constant KIND_COSMETIC] an
## appearance unlock, [constant KIND_TROPHY] a keepsake, [constant KIND_LORE] a
## codex page), and each kind has a FIXED field set with no numeric field
## anywhere — so a drop that would make you stronger simply cannot be expressed.
## This is the drop-layer twin of the exploration-reward horizontal guard: the
## same "no vertical progression sneaks in as content grows" defence, one layer
## down. A dropped sword is an ARSENAL entry, not a power increase; how well you
## use it is your mastery.
##
## [b]Deliberately out of scope.[/b] The bounded ENDGAME vertical — gear that does
## carry stats, capped by a loft and stat-normalised back to a cosmetic edge
## outside endgame instances — is a separate layer, and picking its numbers is a
## balance judgement for the maintainer rather than a mechanical rule, so it is a
## later child rather than a guess made here. Likewise quantities (materials,
## currency and the wider economy), and WIRING a table to a real drop source. This
## library stays the pure, testable open-world/horizontal core.
##
## The library is PURE — no scene tree, no engine state, no clock, no `user://` —
## so it is deterministic and unit-testable, exactly like [ExplorationRewards],
## [Discovery] and [Telegraph].

## An arsenal weapon — which sword, not how strong. Variety, never power.
const KIND_WEAPON := "weapon"
## An appearance unlock (a dye, a skin, a title) — looks, not power.
const KIND_COSMETIC := "cosmetic"
## A keepsake or display piece proving where you have been.
const KIND_TROPHY := "trophy"
## A codex page found on a body or in a chest — the world's fiction.
const KIND_LORE := "lore"

## The closed schema: kind -> the EXACT set of extra string keys that kind
## requires (beyond `kind` itself). An item must carry precisely these keys, each
## a non-empty [String] — no missing key, no extra key. The absence of any numeric
## field, and the ban on extra keys, is what makes "a sword is a sword"
## impossible to violate rather than merely discouraged.
const _SCHEMA := {
	KIND_WEAPON: ["id", "name"],
	KIND_COSMETIC: ["id"],
	KIND_TROPHY: ["id"],
	KIND_LORE: ["id"],
}

## The drop entries in insertion order, each `{"weight": int, "item": Dictionary}`.
## Insertion order is part of the determinism contract: it fixes which slice of
## the weight range each item occupies.
var _entries: Array[Dictionary] = []

## The running sum of every entry's weight — the size of the roll space.
var _total: int = 0


## Add a drop weighted `weight` against the other entries. Returns false (and
## changes nothing) if `weight` is not positive, or if `item` is not a valid
## horizontal loot item per the closed schema — so a power-carrying drop can
## never enter a table. A copy of the item is stored, so a caller mutating its
## dictionary afterwards never disturbs the table.
func add(weight: int, item: Dictionary) -> bool:
	if weight <= 0:
		return false
	if not is_valid_item(item):
		return false
	_entries.append({"weight": weight, "item": item.duplicate(true)})
	_total += weight
	return true


## How many entries the table holds.
func size() -> int:
	return _entries.size()


## Whether the table holds no entries (and so can drop nothing).
func is_empty() -> bool:
	return _entries.is_empty()


## The sum of every entry's weight — the size of the roll space. An entry of
## weight `w` occupies `w` of these `total_weight()` outcomes.
func total_weight() -> int:
	return _total


## The drop for `roll` — a copy of the item whose cumulative weight slice
## contains `roll`, or an empty dictionary if the table is empty.
##
## `roll` may be ANY integer: it is reduced modulo [method total_weight] (negative
## rolls included), so a caller never has to pre-range it. Selection walks the
## entries in insertion order, so the same roll always yields the same drop on
## every platform — the property that makes a drop reproducible from its
## originating seed. The caller is the authority on where `roll` comes from and
## should draw it uniformly; this library only maps it.
func select(roll: int) -> Dictionary:
	if _entries.is_empty():
		return {}
	# GDScript's % keeps the sign of the dividend, so fold a negative roll back
	# into [0, _total) rather than letting it miss every slice.
	var r: int = roll % _total
	if r < 0:
		r += _total
	var cumulative: int = 0
	for entry: Dictionary in _entries:
		cumulative += entry["weight"]
		if r < cumulative:
			var item: Dictionary = entry["item"]
			return item.duplicate(true)
	# Unreachable: r < _total == the final cumulative. Kept as a total function.
	return {}


## Every entry as `{"weight": int, "item": Dictionary}`, in insertion order, with
## the items copied — so a content pipeline or a CI check can walk a shipped
## table (and hand its items to [method find_vertical]) without being able to
## mutate it.
func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in _entries:
		var item: Dictionary = entry["item"]
		out.append({"weight": entry["weight"], "item": item.duplicate(true)})
	return out


## Whether `item` is a valid horizontal loot item: a Dictionary whose `kind` is
## one of the closed set, carrying EXACTLY that kind's required keys (each a
## non-empty String) and nothing else. This is the whole horizontal-only guard:
## there is no representable numeric/power field, and extra keys (where a
## `damage` or `armour` field might otherwise be smuggled in) are refused.
static func is_valid_item(item: Dictionary) -> bool:
	var kind: Variant = item.get("kind")
	if kind is not String or not _SCHEMA.has(kind):
		return false
	var required: Array = _SCHEMA[kind]
	# Exactly `kind` plus the required keys — no more, no fewer.
	if item.size() != required.size() + 1:
		return false
	for key: String in required:
		var value: Variant = item.get(key)
		if value is not String or (value as String).is_empty():
			return false
	return true


## Audit a batch of loot items for the horizontal-only law and return the ones
## that violate it (invalid kind, wrong shape, or a smuggled-in extra/power
## field). An empty result means the whole set is law-abiding. A content pipeline
## or a CI check can assert "no open-world drop grants power" over every shipped
## item in one call — the drop-layer counterpart of the exploration-reward sweep.
static func find_vertical(items: Array) -> Array[Dictionary]:
	var violations: Array[Dictionary] = []
	for raw: Variant in items:
		if raw is Dictionary:
			var item: Dictionary = raw
			if not is_valid_item(item):
				violations.append(item)
		else:
			violations.append({"kind": "not-a-dictionary"})
	return violations
