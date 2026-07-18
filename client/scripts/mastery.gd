class_name Mastery
extends RefCounted
## Weapon-mastery ledger — the deterministic spine of progression. The settled
## design makes weapon mastery *the* way a character grows: "Progression = weapon
## mastery, earned by using the weapon", "a filled bar **banks unlosable
## progress** — a ratchet floor", and content is "tuned against the **banked
## floor**, not peak mastery". Every later progression feature — arsenal unlocks,
## the death/bloodstain penalty, the mastery bar UI, content difficulty — rests
## on one primitive answered here: "how much mastery does this character hold in
## this weapon, and how much of it is locked in for good?".
##
## Each weapon has two quantities, both in the same unit (mastery points):
##   - `banked`  — points locked in. This is the **ratchet floor**: it is
##                 UNLOSABLE and, by law, only ever grows. Death never touches it.
##   - `unbanked` — points on the current bar, not yet locked in. `accrue` fills
##                 this; every whole `BANK_STEP` it holds is converted to banked.
##                 This is the at-risk pool a later death penalty will draw from.
##
## Two product laws are enforced structurally here rather than policed later
## (this game has no undo, so a leak cannot be recalled):
##   - **Forward-only.** `banked` is monotonic non-decreasing across any sequence
##     of operations — nothing in this ledger can lower it. This is the
##     progression-side of "no hard resets, ever", and the guard exists before
##     the first player does (the same rationale as the save-data guard, #3).
##   - **No inflation.** `accrue` is the only way value enters, it adds exactly
##     the amount awarded (banking merely relabels unbanked as banked — it never
##     mints points), and a negative amount is refused: accrual is an award, never
##     a debit. `total` therefore rises by exactly what was accrued and by nothing
##     else.
##   - **Conservation across the death loop.** `die` is the only way value leaves,
##     and it moves points rather than deleting them: what leaves `unbanked` is
##     exactly what the bloodstain receives. `reclaim` returns them through
##     `accrue`, once, so a die → reclaim round trip restores `total` exactly. The
##     single deliberate destruction — a new death replacing a standing bloodstain
##     — discards those points outright, so they can neither be reclaimed nor
##     duplicated.
##
## This library is PURE — no scene tree, no engine state, no clock, no `user://`
## — so it is deterministic and unit-testable, exactly like `Discovery`,
## `Telegraph`, and the server sim.
##
## The death → bloodstain → reclaim-or-lose-forever loop lives here too (#129):
## it moves value only within `unbanked`, so it is the same ledger's business,
## and holding the bloodstain here is what makes "reclaim at most once" a
## structural property rather than a caller's obligation. Still deliberately out
## of scope (each a follow-up
## child of #76): meaningful-combat **source gating** and diminishing
## returns (server-authoritative — the anti-AFK-grind guard, so `accrue` here
## trusts its already-gated award and never judges where a point came from);
## serialization + persistence (gated on the save schema); and the sidegrade
## "no strict dominance" arsenal rule (that lives with the ability schema).

## The bar size: every whole BANK_STEP points of unbanked mastery is locked into
## the banked floor. A tuning placeholder until combat pacing is real — kept a
## named constant, never a magic number, so the banking law reads clearly and the
## value can move in one place without touching the logic.
const BANK_STEP := 100

## weapon id (String) -> {"banked": int, "unbanked": int}. A weapon appears here
## only once it has been accrued to; an untracked weapon reads as all-zero.
var _tracks: Dictionary = {}

## The one standing bloodstain: weapon id (String) -> points (int), empty when
## none stands. Held HERE rather than by the caller so "there is exactly one, a
## new death replaces it, and it can be reclaimed at most once" are properties of
## the ledger instead of rules a caller has to remember — the dupe vectors are
## designed out, which is the only safe posture in a game with no undo.
var _bloodstain: Dictionary = {}


## Award `amount` mastery points to `weapon`, then lock every whole bar the
## unbanked pool now holds into the banked floor. Returns the number of bars
## banked by THIS call (0 if the bar did not fill). A non-positive `amount` is
## refused and changes nothing (returns 0): accrual is forward-only — an award,
## never a debit — so the ratchet has no reverse. An empty weapon id is refused
## the same way. The awarded amount is assumed already gated (meaningful combat,
## diminishing returns) by the server-authoritative caller; this ledger does not
## re-judge the source.
func accrue(weapon: String, amount: int) -> int:
	if weapon.is_empty() or amount <= 0:
		return 0
	var track: Dictionary = _tracks.get(weapon, {"banked": 0, "unbanked": 0})
	var unbanked: int = track["unbanked"] + amount
	# Integer division banks whole bars in one step (no per-bar loop, so a large
	# award can never spin), and the remainder carries as progress toward the next
	# bar — no awarded point is ever dropped.
	var bars: int = unbanked / BANK_STEP
	track["banked"] += bars * BANK_STEP
	track["unbanked"] = unbanked - bars * BANK_STEP
	_tracks[weapon] = track
	return bars


## The unlosable banked floor for `weapon` (0 for an untracked weapon). Only ever
## grows.
func banked(weapon: String) -> int:
	return _track_field(weapon, "banked")


## The at-risk points on `weapon`'s current bar, below the next BANK_STEP (0 for
## an untracked weapon).
func unbanked(weapon: String) -> int:
	return _track_field(weapon, "unbanked")


## All mastery held in `weapon`, banked plus unbanked (0 for an untracked
## weapon). Rises by exactly the amount accrued, and by nothing else.
func total(weapon: String) -> int:
	return banked(weapon) + unbanked(weapon)


## Every weapon this ledger has tracked, sorted by id, so any inspection or
## serialisation of the ledger is order-stable. The returned array is a copy.
func weapons() -> Array[String]:
	var out: Array[String] = []
	for weapon: String in _tracks:
		out.append(weapon)
	out.sort()
	return out


## Share of the at-risk pool a death takes, as a whole percent. This is a POLICY
## placeholder, not a settled number: the design flags that organised group
## content should carry a SOFTENED penalty ("full risk in open world/solo …
## softened in organised group content — flag it as a decision, not a detail"),
## so `die` takes the share as an argument and this is only its default. Tuning
## it — or handing group content a smaller one — never touches the mechanism.
const DEATH_LOSS_PERCENT := 50


## Die: move `percent` of every weapon's UNBANKED mastery into a bloodstain, and
## return a copy of it ({weapon: points}, empty when nothing was at risk).
##
## The banked floor is never read or written here — it is unlosable by law, so a
## death can only ever reach the current bar. `percent` is clamped to 0..100 and
## the share is integer-floored, so no fraction of a point is invented or lost.
##
## Dying again while a bloodstain is still unreclaimed DESTROYS the old one: the
## Souls rule, "reclaim it or lose it forever". That destruction is the only way
## this ledger can lose value, it happens exactly once, and the lost points are
## gone rather than moved — nothing can reclaim them afterwards.
##
## It is a death that DROPS SOMETHING that replaces the standing stain. A death
## which puts nothing at risk (a zero share, or a pool too small to floor above
## zero) leaves the standing stain reclaimable and returns an empty dictionary —
## otherwise a softened penalty would destroy more than a full-risk one, which is
## backwards. The return value is what THIS death dropped; use `bloodstain()` to
## read whatever currently stands.
func die(percent: int = DEATH_LOSS_PERCENT) -> Dictionary:
	var share := clampi(percent, 0, 100)
	var stain := {}
	# Sorted, so the stain is built in a stable order regardless of accrual order.
	for weapon: String in weapons():
		var track: Dictionary = _tracks[weapon]
		# Integer floor: unbanked is always below one bar, so this cannot overflow
		# and cannot take more than was at risk.
		var at_risk: int = track["unbanked"] * share / 100
		if at_risk <= 0:
			continue
		track["unbanked"] -= at_risk
		_tracks[weapon] = track
		stain[weapon] = at_risk
	if stain.is_empty():
		# A death that puts NOTHING at risk destroys nothing. Replacing the
		# standing stain here would make a no-penalty death strictly harsher than
		# a full-risk one — and the softened group-content penalty the design
		# calls for is exactly this path, so it would quietly destroy reclaimable
		# mastery precisely where the player was promised leniency. A smaller
		# penalty must never cost more than a larger one.
		return {}
	# Only a death that actually drops a stain replaces (and thereby destroys)
	# the one still standing.
	_bloodstain = stain
	return stain.duplicate()


## Reclaim the standing bloodstain: its points return to the unbanked pool, and
## any bar they fill banks as normal. Returns how many points came back.
##
## The bloodstain is consumed, so a second call returns 0 — reclaiming twice is
## the obvious dupe vector and is designed out rather than policed. Because the
## points re-enter through `accrue`, they are added exactly once and by exactly
## the amount dropped: a die → reclaim round trip conserves `total` precisely.
## (`accrue` documents that awards are gated by a server-authoritative caller;
## these points need no such gate — they are the player's own, being returned.)
func reclaim() -> int:
	var recovered := 0
	for weapon: String in _bloodstain:
		var amount: int = _bloodstain[weapon]
		recovered += amount
		accrue(weapon, amount)
	_bloodstain = {}
	return recovered


## A copy of the standing bloodstain ({weapon: points}), empty when none stands.
## A copy on purpose: handing out the live dictionary would let a caller mutate
## or re-bank the pending points, which is the same dupe vector `reclaim` closes.
func bloodstain() -> Dictionary:
	return _bloodstain.duplicate()


func _track_field(weapon: String, field: String) -> int:
	if not _tracks.has(weapon):
		return 0
	return _tracks[weapon][field]
