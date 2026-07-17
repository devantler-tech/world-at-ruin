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
##
## This library is PURE — no scene tree, no engine state, no clock, no `user://`
## — so it is deterministic and unit-testable, exactly like `Discovery`,
## `Telegraph`, and the server sim. Deliberately out of scope (each a follow-up
## child of #76): the death → bloodstain → reclaim-or-lose-forever loop (which
## touches only `unbanked`); meaningful-combat **source gating** and diminishing
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


func _track_field(weapon: String, field: String) -> int:
	if not _tracks.has(weapon):
		return 0
	return _tracks[weapon][field]
