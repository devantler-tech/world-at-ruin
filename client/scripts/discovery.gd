class_name Discovery
extends RefCounted
## Discovery tracker — the deterministic spine of exploration: WHICH places the
## wanderer has found. The world already ships distinct landmarks (the Wardens'
## Shrine at the centre, the starter cave at `WorldGen.CAVE_SITE`, the ruin
## field) that a player walks past today with no acknowledgement; the design
## wants exploration to matter ("the reason to walk somewhere, breadth rather
## than bigger numbers"). Every exploration reward, waypoint, lore unlock, or
## map fog rests on one primitive answered here: "has this player reached this
## place yet?".
##
## This library answers only that. It is PURE — no scene tree, no engine state,
## no clock, no `user://` — so it is deterministic and unit-testable, exactly
## like `Telegraph`'s shape predicates and `Interactable.choose`. WHAT a
## discovery unlocks (rewards, cosmetics, waypoints) and any player-visible
## toast are the caller's concern and separate follow-ups; persistence of the
## found set waits on the persistence work.
##
## Membership is measured on the XZ plane (a landmark is a mark on the ground,
## so the wanderer's height never changes whether a place is found), the reach
## edge is inclusive, and — this game has no undo — the found set only ever
## grows: a place discovered stays discovered, and observing it again is a
## no-op. Points of interest are registered by a stable string id; every
## ordered result is sorted by that id so two runs of the same walk agree
## byte-for-byte.

## A registered point of interest: its planar centre and its discovery reach.
var _pois: Dictionary = {}

## The set of found point-of-interest ids (id -> true). Only ever grows.
var _discovered: Dictionary = {}


## Register a point of interest under a unique, non-empty `id`, centred at
## `center` with a discovery reach of `radius` metres. Returns false (and
## changes nothing) if the id is empty or already registered — registration is
## forward-only, so a place never silently redefines itself. A negative radius
## is accepted but degenerate: the place is simply never discoverable (it
## catches nothing, matching `Telegraph`), never a crash.
func add(id: String, center: Vector3, radius: float) -> bool:
	if id.is_empty() or _pois.has(id):
		return false
	_pois[id] = {"center": center, "radius": radius}
	return true


## Whether `id` names a registered point of interest.
func is_registered(id: String) -> bool:
	return _pois.has(id)


## Reach the wanderer to `position` and mark every not-yet-found point of
## interest within planar reach as discovered. Returns the ids discovered by
## THIS call (sorted by id, so the order is deterministic), so the caller can
## fire a one-time hook per newly-found place; a place already found is never
## returned again (idempotent — the "no undo"). Height is ignored.
func observe(position: Vector3) -> Array[String]:
	var found: Array[String] = []
	for id: String in _pois:
		if _discovered.has(id):
			continue
		var poi: Dictionary = _pois[id]
		if _in_reach(poi["center"], poi["radius"], position):
			_discovered[id] = true
			found.append(id)
	found.sort()
	return found


## Whether the place `id` has been found. Safe (false) for an unknown id.
func is_discovered(id: String) -> bool:
	return _discovered.has(id)


## Every found place, sorted by id. The returned array is a copy — mutating it
## never disturbs the tracker's forward-only found set.
func discovered() -> Array[String]:
	var out: Array[String] = []
	for id: String in _discovered:
		out.append(id)
	out.sort()
	return out


## How many places have been found.
func count() -> int:
	return _discovered.size()


## How many places are registered in total.
func total() -> int:
	return _pois.size()


## Inside a place's discovery reach on the XZ plane (inclusive edge). A negative
## radius is degenerate and reaches nothing; height is dropped so a tall or
## hovering wanderer at the same footprint is found the same way.
func _in_reach(center: Vector3, radius: float, point: Vector3) -> bool:
	if radius < 0.0:
		return false
	var a := Vector2(point.x, point.z)
	var b := Vector2(center.x, center.z)
	return a.distance_squared_to(b) <= radius * radius
