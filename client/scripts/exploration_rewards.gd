class_name ExplorationRewards
extends RefCounted
## Exploration rewards — WHAT a discovered place grants. The [Discovery] tracker
## answers "has this player reached this place yet?" and hands back each place
## newly reached; this library answers the very next question the design asks of
## it: what walking there is worth. Phase 6 states the rule exactly — "the reason
## to walk somewhere, and breadth rather than bigger numbers; horizontal
## progression throughout" — so an exploration reward is convenience, fiction, or
## looks, and NEVER a stat, a level, or a bigger number.
##
## That rule is enforced MECHANICALLY here, not left to a reviewer's vigilance: a
## reward is one of a CLOSED set of kinds ([constant KIND_WAYPOINT] a travel/attune
## point you can return to, [constant KIND_LORE] a codex entry, [constant
## KIND_COSMETIC] an appearance unlock, [constant KIND_MAP_REVEAL] fog cleared over
## a region), and each kind has a FIXED field set with no numeric power anywhere —
## so a reward that would make you stronger is simply not representable. This is the
## exploration-side twin of the combat power-inflation guard: the same "no vertical
## progression sneaks in as content grows" defence, at the reward layer.
##
## The library is PURE — no scene tree, no engine state, no clock, no `user://` —
## so it is deterministic and unit-testable, exactly like [Discovery] and
## [Telegraph]. It also mirrors this world's two standing laws: registration is
## FORWARD-ONLY (a place never silently redefines what it grants), and a reward is
## claimed at most ONCE (this game has no undo, so re-claiming is a no-op). It does
## not import [Discovery]; the caller composes them — feed the ids
## `Discovery.observe(pos)` returns straight into [method claim]. WHAT to do with a
## granted reward (a toast, unlocking a waypoint, revealing the map) and PERSISTING
## the claimed set across a logout are the caller's concern and separate follow-ups.

## A travel/attune point the player can return to — access, not power.
const KIND_WAYPOINT := "waypoint"
## A codex entry — the world's fiction.
const KIND_LORE := "lore"
## An appearance unlock (a dye, a title, a trophy) — looks, not power.
const KIND_COSMETIC := "cosmetic"
## Fog cleared over a named region — knowledge, not power.
const KIND_MAP_REVEAL := "map_reveal"

## The closed schema: kind -> the EXACT set of extra string keys that kind
## requires (beyond `kind` itself). A reward must carry precisely these keys, each
## a non-empty [String] — no missing key, no extra key. The absence of any numeric
## field, and the ban on extra keys, is what makes "no bigger numbers" impossible
## to express rather than merely discouraged.
const _SCHEMA := {
	KIND_WAYPOINT: ["id", "name"],
	KIND_LORE: ["id"],
	KIND_COSMETIC: ["id"],
	KIND_MAP_REVEAL: ["region"],
}

## poi id -> the reward Dictionary that place grants on first discovery.
var _rewards: Dictionary = {}

## The set of poi ids whose reward has been claimed (id -> true). Only ever grows.
var _claimed: Dictionary = {}


## Register the reward that place `poi_id` grants the first time it is discovered.
## Returns false (and changes nothing) if `poi_id` is empty, is already registered
## (registration is forward-only — a place never silently redefines its reward), or
## `reward` is not a valid horizontal reward per the closed schema. A copy of the
## reward is stored, so a caller mutating its dictionary afterwards never disturbs
## the registered one.
func add(poi_id: String, reward: Dictionary) -> bool:
	if poi_id.is_empty() or _rewards.has(poi_id):
		return false
	if not is_valid(reward):
		return false
	_rewards[poi_id] = reward.duplicate(true)
	return true


## Whether `poi_id` has a registered reward.
func is_registered(poi_id: String) -> bool:
	return _rewards.has(poi_id)


## A copy of the reward registered for `poi_id`, or an empty dictionary if none.
## The copy keeps the registered reward immutable to callers.
func reward_for(poi_id: String) -> Dictionary:
	if not _rewards.has(poi_id):
		return {}
	var reward: Dictionary = _rewards[poi_id]
	return reward.duplicate(true)


## Grant the rewards for the places just discovered. Pass the ids
## `Discovery.observe(pos)` returned; this yields a copy of the reward for each id
## that is registered AND not yet claimed, EXACTLY once, ordered by id so two
## identical walks grant identically (determinism). Unregistered ids are skipped,
## and an already-claimed id is skipped (idempotent — the no-undo), so it is safe
## to pass the same ids again or ids with no reward. Marks the returned places
## claimed.
func claim(found_ids: Array) -> Array[Dictionary]:
	var claimable: Array[String] = []
	for raw_id: Variant in found_ids:
		if raw_id is not String:
			continue
		var poi_id: String = raw_id
		if not _rewards.has(poi_id):
			continue
		if _claimed.has(poi_id):
			continue
		if not claimable.has(poi_id):
			claimable.append(poi_id)
	claimable.sort()
	var granted: Array[Dictionary] = []
	for poi_id: String in claimable:
		_claimed[poi_id] = true
		var reward: Dictionary = _rewards[poi_id]
		granted.append(reward.duplicate(true))
	return granted


## Whether the reward for `poi_id` has already been claimed. Safe (false) for an
## unknown id.
func is_claimed(poi_id: String) -> bool:
	return _claimed.has(poi_id)


## Every claimed place's id, sorted. The returned array is a copy — mutating it
## never disturbs the forward-only claimed set.
func claimed() -> Array[String]:
	var out: Array[String] = []
	for poi_id: String in _claimed:
		out.append(poi_id)
	out.sort()
	return out


## How many rewards have been claimed.
func count() -> int:
	return _claimed.size()


## How many rewards are registered in total.
func total() -> int:
	return _rewards.size()


## Whether `reward` is a valid horizontal exploration reward: a Dictionary whose
## `kind` is one of the closed set, carrying EXACTLY that kind's required keys
## (each a non-empty String) and nothing else. This is the whole horizontal-only
## guard: there is no representable numeric/power field, and extra keys (where a
## `power` field might otherwise be smuggled in) are refused.
static func is_valid(reward: Dictionary) -> bool:
	var kind: Variant = reward.get("kind")
	if kind is not String or not _SCHEMA.has(kind):
		return false
	var required: Array = _SCHEMA[kind]
	# Exactly `kind` plus the required keys — no more, no fewer.
	if reward.size() != required.size() + 1:
		return false
	for key: String in required:
		var value: Variant = reward.get(key)
		if value is not String or (value as String).is_empty():
			return false
	return true


## Audit a batch of rewards for the horizontal-only law and return the ones that
## violate it (invalid kind, wrong shape, or a smuggled-in extra/power field).
## An empty result means the whole set is law-abiding. This is the exploration
## twin of the combat registry's power-inflation sweep: a content pipeline or a
## CI check can assert "no exploration reward grants power" over every shipped
## reward in one call.
static func find_vertical(rewards: Array) -> Array[Dictionary]:
	var violations: Array[Dictionary] = []
	for raw: Variant in rewards:
		if raw is Dictionary:
			var reward: Dictionary = raw
			if not is_valid(reward):
				violations.append(reward)
		else:
			violations.append({"kind": "not-a-dictionary"})
	return violations
