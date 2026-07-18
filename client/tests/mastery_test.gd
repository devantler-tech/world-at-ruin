extends Node
## Regression test for the Mastery weapon-mastery ledger (issue #76).
##
## Mastery is the progression pillar, and every part of it is a product law: the
## banked floor is forward-only (it can never decrease — the no-resets law); no
## point is minted or lost (accrual adds exactly its award, banking only relabels
## unbanked as banked — the no-inflation law); a bar of BANK_STEP points banks in
## whole steps carrying the remainder; identical accrual scripts produce identical
## ledgers (determinism); weapons are independent; and the degenerate inputs
## refuse cleanly (a non-positive award is never a debit, an unknown weapon reads
## zero). This pins each of those.
##
## It also pins the death → bloodstain → reclaim loop (#129), where value MOVES
## between pools and every transition is a potential dupe or leak: a death never
## reaches the banked floor, die → reclaim conserves `total` exactly, dying again
## destroys the standing stain exactly once (it can never be reclaimed after),
## reclaiming twice mints nothing, and the handed-out stain is a copy that cannot
## be edited into a dupe.
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/mastery_test.tscn

var _failed := false


func _ready() -> void:
	# --- fresh ledger: every weapon reads all-zero ---
	var m := Mastery.new()
	_check(m.banked("sword") == 0, true, "fresh: banked is zero")
	_check(m.unbanked("sword") == 0, true, "fresh: unbanked is zero")
	_check(m.total("sword") == 0, true, "fresh: total is zero")
	_check(m.weapons().is_empty(), true, "fresh: no weapons tracked")
	if _failed:
		return

	# --- a partial bar accrues but does not bank ---
	var step := Mastery.BANK_STEP
	_check(m.accrue("sword", step - 1) == 0, true, "accrue below a bar banks nothing")
	_check(m.banked("sword") == 0, true, "sub-bar: banked still zero")
	_check(m.unbanked("sword") == step - 1, true, "sub-bar: unbanked holds the award")
	_check(m.total("sword") == step - 1, true, "sub-bar: total is the award")
	if _failed:
		return

	# --- exactly a bar banks one step, leaving no remainder ---
	var one := Mastery.new()
	_check(one.accrue("sword", step) == 1, true, "a full bar banks one step")
	_check(one.banked("sword") == step, true, "full bar: banked is one step")
	_check(one.unbanked("sword") == 0, true, "full bar: nothing left unbanked")
	if _failed:
		return

	# --- several bars plus a remainder: banks the whole bars, carries the rest ---
	var many := Mastery.new()
	_check(many.accrue("sword", 2 * step + 7) == 2, true, "two bars and change banks two steps")
	_check(many.banked("sword") == 2 * step, true, "multi-bar: banked is two steps")
	_check(many.unbanked("sword") == 7, true, "multi-bar: the remainder carries")
	_check(many.total("sword") == 2 * step + 7, true, "multi-bar: no point lost")
	if _failed:
		return

	# --- the remainder carries across calls and banks on the crossing accrual ---
	var carry := Mastery.new()
	_check(carry.accrue("sword", step - 10) == 0, true, "carry: first award does not fill the bar")
	_check(carry.accrue("sword", 15) == 1, true, "carry: the award that crosses the bar banks it")
	_check(carry.banked("sword") == step, true, "carry: exactly one step banked")
	_check(carry.unbanked("sword") == 5, true, "carry: the overshoot carries as new progress")
	_check(carry.total("sword") == step + 5, true, "carry: total conserved across calls")
	if _failed:
		return

	# --- a non-positive award is refused: accrual is never a debit ---
	var neg := Mastery.new()
	neg.accrue("sword", 250)
	var before_banked := neg.banked("sword")
	var before_unbanked := neg.unbanked("sword")
	_check(neg.accrue("sword", -1000) == 0, true, "a negative award is refused")
	_check(neg.accrue("sword", 0) == 0, true, "a zero award is refused")
	_check(neg.banked("sword") == before_banked, true, "refused award did not change banked")
	_check(neg.unbanked("sword") == before_unbanked, true, "refused award did not change unbanked")
	_check(neg.accrue("", 500) == 0, true, "an empty weapon id is refused")
	if _failed:
		return

	if not _forward_only_ratchet():
		return
	if not _conservation():
		return
	if not _weapons_are_independent():
		return
	if not _deterministic_replay():
		return
	if not _death_spares_the_banked_floor():
		return
	if not _death_then_reclaim_conserves():
		return
	if not _second_death_destroys_the_standing_stain():
		return
	if not _reclaim_happens_at_most_once():
		return
	if not _a_death_that_drops_nothing_preserves_the_stain():
		return
	if not _death_is_degenerate_safe():
		return

	print("TEST PASS — mastery ledger holds (forward-only, conservation, banking, per-weapon, deterministic, death/bloodstain, degenerate-safe)")
	get_tree().quit(0)


## Death may only ever reach the current bar: the banked floor is unlosable by
## law, so no sequence of deaths can lower it, and the points that leave unbanked
## are exactly the ones the bloodstain receives.
func _death_spares_the_banked_floor() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 250)  # 2 bars banked, 50 on the current bar
	var banked_before := m.banked("sword")
	var stain := m.die(50)
	_check(m.banked("sword") == banked_before, true, "death: banked floor untouched")
	_check(m.unbanked("sword") == 25, true, "death: half the at-risk pool remains")
	_check(int(stain.get("sword", 0)) == 25, true, "death: the stain holds exactly what left unbanked")
	# Repeated deaths keep eroding only the bar, never the floor.
	for i in 6:
		m.die(50)
		if m.banked("sword") != banked_before:
			_fail("death: banked floor moved after repeated deaths")
			return false
	_check(m.unbanked("sword") >= 0, true, "death: the at-risk pool never goes negative")
	return not _failed


## A die → reclaim round trip restores `total` EXACTLY — the points are moved,
## never minted or leaked. Dying alone costs exactly what the stain holds.
func _death_then_reclaim_conserves() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 250)
	m.accrue("staff", 90)
	var before := m.total("sword") + m.total("staff")

	var stain := m.die(50)
	var dropped := _stain_sum(stain)
	var after_death := m.total("sword") + m.total("staff")
	_check(after_death == before - dropped, true, "death costs exactly the stain, no more")

	var recovered := m.reclaim()
	_check(recovered == dropped, true, "reclaim returns exactly what was dropped")
	_check(m.total("sword") + m.total("staff") == before, true, "die → reclaim conserves total exactly")
	_check(m.bloodstain().is_empty(), true, "reclaim consumes the stain")
	return not _failed


## Dying again while a stain still stands destroys the old one — "reclaim it or
## lose it forever". Those points are gone, not moved: they can neither be
## reclaimed afterwards nor counted twice.
func _second_death_destroys_the_standing_stain() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 99)
	var first := m.die(100)
	_check(_stain_sum(first) == 99, true, "first death takes the whole at-risk pool at 100%")
	var after_first := m.total("sword")

	m.accrue("sword", 40)
	var second := m.die(50)
	_check(_stain_sum(second) == 20, true, "second death takes half of the new pool")
	_check(_stain_sum(m.bloodstain()) == _stain_sum(second), true, "only the newest stain stands")

	var recovered := m.reclaim()
	_check(recovered == 20, true, "reclaim returns only the newest stain — the first is lost forever")
	_check(m.total("sword") == after_first + 40, true, "the destroyed points never come back")
	return not _failed


## Reclaiming twice is the obvious dupe vector; the second call must be a no-op.
func _reclaim_happens_at_most_once() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 180)
	m.die(50)
	var first := m.reclaim()
	var total_after := m.total("sword")
	var second := m.reclaim()
	_check(first > 0, true, "reclaim: the first call returns the stain")
	_check(second == 0, true, "reclaim: a second call returns nothing")
	_check(m.total("sword") == total_after, true, "reclaim: a second call mints no points")

	# Handing out a copy matters: mutating it must not re-arm a reclaim.
	m.die(50)
	var handle := m.bloodstain()
	handle["sword"] = 999_999
	_check(m.reclaim() < 999_999, true, "the bloodstain() copy cannot be edited into a dupe")
	return not _failed


## A death that puts nothing at risk must not destroy the stain still standing.
## This is the softened-penalty path the design calls for in group content, so
## getting it wrong would make leniency HARSHER than full risk: the gentle death
## would silently bin mastery a full-risk death would have left reclaimable.
func _a_death_that_drops_nothing_preserves_the_stain() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 180)  # 1 bar banked, 80 at risk
	var dropped := _stain_sum(m.die(50))
	_check(dropped == 40, true, "no-op death setup: the first death drops half the pool")

	var recoverable_before := m.total("sword") + _stain_sum(m.bloodstain())
	var nothing := m.die(0)
	_check(nothing.is_empty(), true, "a zero-share death drops nothing")
	_check(_stain_sum(m.bloodstain()) == dropped, true, "a zero-share death leaves the standing stain intact")
	_check(m.total("sword") + _stain_sum(m.bloodstain()) == recoverable_before, true,
		"a zero-share death destroys nothing recoverable")
	_check(m.reclaim() == dropped, true, "the stain is still reclaimable after a zero-share death")

	# Same when the share is real but the pool is too small to floor above zero.
	var tiny := Mastery.new()
	tiny.accrue("sword", 1)
	_check(_stain_sum(tiny.die(100)) == 1, true, "tiny pool: a full-risk death drops the single point")
	tiny.accrue("sword", 1)
	_check(tiny.die(50).is_empty(), true, "a share that floors to zero drops nothing")
	_check(_stain_sum(tiny.bloodstain()) == 1, true, "a floored-to-zero death leaves the earlier stain standing")
	return not _failed


## Degenerate shares and empty ledgers refuse cleanly rather than inventing or
## destroying value.
func _death_is_degenerate_safe() -> bool:
	var fresh := Mastery.new()
	_check(fresh.die(50).is_empty(), true, "death on a fresh ledger yields no stain")

	var m := Mastery.new()
	m.accrue("sword", 150)  # 1 bar banked, 50 at risk
	_check(m.die(0).is_empty(), true, "a 0% death takes nothing")
	_check(m.unbanked("sword") == 50, true, "a 0% death leaves the pool intact")
	_check(m.die(-50).is_empty(), true, "a negative share clamps to 0 and takes nothing")

	var all := m.die(500)  # clamps to 100%
	_check(_stain_sum(all) == 50, true, "a share above 100 clamps to the whole pool")
	_check(m.unbanked("sword") == 0, true, "a 100% death empties the bar")
	_check(m.banked("sword") == Mastery.BANK_STEP, true, "even a 100% death spares the floor")
	return not _failed


## Total points held in a bloodstain.
func _stain_sum(stain: Dictionary) -> int:
	var sum := 0
	for weapon: String in stain:
		sum += int(stain[weapon])
	return sum


## Drives a long, varied accrual sequence and asserts the banked floor never
## decreases at any step — the forward-only ratchet, the progression-side of the
## no-resets law.
func _forward_only_ratchet() -> bool:
	var m := Mastery.new()
	var awards := [30, 90, 5, 200, 1, 149, 400, 0, 60, 25, 300]
	var prev_banked := 0
	for a: int in awards:
		m.accrue("sword", a)
		var now := m.banked("sword")
		if now < prev_banked:
			_fail("forward-only broke: banked fell from %d to %d" % [prev_banked, now])
			return false
		prev_banked = now
	# The banked floor is always a whole number of bars.
	_check(m.banked("sword") % Mastery.BANK_STEP == 0, true, "forward-only: banked is whole bars")
	return not _failed


## Asserts total = banked + unbanked rises by exactly the sum of the awards and by
## nothing else — no point minted, none lost (the no-inflation law).
func _conservation() -> bool:
	var m := Mastery.new()
	var awards := [17, 83, 250, 9, 141, 500]
	var sum := 0
	for a: int in awards:
		m.accrue("staff", a)
		sum += a
		_check(m.banked("staff") + m.unbanked("staff") == sum, true, "conservation: total tracks the running sum")
		_check(m.total("staff") == sum, true, "conservation: total() equals banked+unbanked")
		if _failed:
			return false
	return not _failed


## Accrues to two weapons interleaved and asserts each track holds only its own
## awards — mastery in one weapon never bleeds into another.
func _weapons_are_independent() -> bool:
	var m := Mastery.new()
	m.accrue("sword", 120)
	m.accrue("staff", 40)
	m.accrue("sword", 30)
	_check(m.total("sword") == 150, true, "independence: sword holds only its awards")
	_check(m.total("staff") == 40, true, "independence: staff holds only its awards")
	_check(m.banked("sword") == Mastery.BANK_STEP, true, "independence: sword banked its own bar")
	_check(m.banked("staff") == 0, true, "independence: staff has not filled a bar")
	_check(",".join(m.weapons()) == "staff,sword", true, "independence: weapons() is sorted")
	return not _failed


## Runs the identical accrual script on two independent ledgers and asserts their
## final state is identical for every weapon — the determinism the product law
## requires of anything progression rests on.
func _deterministic_replay() -> bool:
	_check(_scripted_ledger() == _scripted_ledger(), true, "determinism: identical scripts produce identical ledgers")
	return not _failed


## A fixed script of interleaved awards; returns an order-stable string snapshot
## of the whole ledger so two runs can be compared as one value.
func _scripted_ledger() -> String:
	var m := Mastery.new()
	var script := [["sword", 40], ["staff", 260], ["sword", 75], ["dagger", 5], ["staff", 40], ["sword", 300]]
	for award: Array in script:
		m.accrue(award[0], award[1])
	var parts: Array[String] = []
	for weapon: String in m.weapons():
		parts.append("%s:%d/%d" % [weapon, m.banked(weapon), m.unbanked(weapon)])
	return "|".join(parts)


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
