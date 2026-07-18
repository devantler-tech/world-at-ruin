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

	print("TEST PASS — mastery ledger holds (forward-only, conservation, banking, per-weapon, deterministic, degenerate-safe)")
	get_tree().quit(0)


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
