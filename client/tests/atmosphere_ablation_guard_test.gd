extends Node
## Pins the ablation harness's own read-back guard, which decides whether a
## measured row may be believed.
##
## `atmosphere_ablation` writes an override onto the [Environment], then reads it
## back to prove nothing rewrote it before the frame was measured. That check is
## the difference between "this term does nothing" as a finding and as an
## artifact, so the guard being wrong silently invalidates a whole run — in
## either direction.
##
## It has been wrong in the permissive-looking direction once. The check was
## [method @GlobalScope.is_same], which is exact identity, and every condition
## that NEUTRALISES a term writes `false`, `0.0`, `1.0` or `2.0` — all exactly
## representable in 32 bits, all surviving [Environment]'s narrowing unchanged.
## The first conditions to DIM a term instead wrote values that are not, so
## `0.03` read back as `0.02999999932945` and sixteen correct rows across both
## vantages were reported as failed writes. A guard that fires on correct data
## gets read as noise, and the next real re-application would have been ignored
## with it.
##
## So this fixes both directions at once: the narrowing is accepted, and a real
## rewrite — which is always the whole distance from a candidate back to the
## shipped grade — is still caught.
##
## Run: godot --headless --path client res://tests/atmosphere_ablation_guard_test.tscn

## The harness under test, loaded as a script rather than instantiated: the guard
## is static, and building the tool's node would start a measurement run.
const ABLATION := preload("res://tools/atmosphere_ablation.gd")


func _ready() -> void:
	# LAW 1 — a 32-bit round trip counts as stuck. These are the literal
	# read-back values the failing run printed, not invented ones, so this law
	# fails again if the tolerance is ever tightened back past reality.
	var narrowed: Array = [
		[0.02999999932945, 0.03],
		[0.00249999994412, 0.0025],
		[0.00166666670702, 1.0 / 600.0],
		[0.00124999997206, 0.00125],
		[0.01499999966472, 0.015],
	]
	for pair: Array in narrowed:
		if not ABLATION._override_stuck(pair[0], pair[1]):
			_fail("a 32-bit round trip of %.17f must count as stuck" % (pair[1] as float))
			return

	# LAW 2 — a real re-application is still caught. `main._process` writes the
	# whole shipped grade back, so every case here is a candidate reverting to
	# some other real value. This is the coverage the repair must not have given
	# away, and it is the reason the tolerance is nine orders of magnitude below
	# the smallest of these gaps rather than merely "small".
	var rewritten: Array = [
		# Literal values rather than the live constants: these stand for the gap
		# a rewrite leaves, and pinning them to whatever ships today would let a
		# future retune quietly shrink the distance this law measures.
		[0.06, 0.03], # height fog reverted over a candidate
		[0.005, 1.0 / 600.0], # volumetric reverted over a candidate
		[0.06, 0.0], # a neutralising row reverted — the original coverage
		[0.005, 0.0],
		[0.03, 0.015], # reverted to a different candidate
	]
	for pair: Array in rewritten:
		if ABLATION._override_stuck(pair[0], pair[1]):
			_fail("%.17f must NOT count as the write %.17f" % [pair[0] as float, pair[1] as float])
			return

	# LAW 3 — the tolerance sits between the two populations rather than merely
	# above one of them. A gap of 1e-5 is far larger than any narrowing and must
	# fail; 1e-9 is the narrowing's own scale and must pass. Without this law the
	# tolerance could be widened until law 2's gaps started passing and law 1
	# would never notice.
	if ABLATION._override_stuck(0.03 + 1.0e-5, 0.03):
		_fail("a 1e-5 gap is far beyond a 32-bit narrowing and must not count as stuck")
		return
	if not ABLATION._override_stuck(0.03 + 1.0e-9, 0.03):
		_fail("a 1e-9 gap is the narrowing's own scale and must count as stuck")
		return

	# LAW 4 — non-floats keep exact identity. Widening these would give away real
	# coverage for nothing: a bool or an enum that reads back changed has been
	# genuinely rewritten, never narrowed.
	if ABLATION._override_stuck(true, false):
		_fail("a bool that reads back changed must never count as stuck")
		return
	if not ABLATION._override_stuck(false, false):
		_fail("an unchanged bool must count as stuck")
		return

	# LAW 5 — the property-existence check the run pre-flights its condition table
	# with actually discriminates.
	#
	# Pinned because a passing ablation run cannot demonstrate it: every key in
	# the shipped table is valid, so a run only ever exercises the "nothing
	# unknown" branch and a check that answered true for everything would sail
	# through the very run meant to be its evidence. Both directions asserted.
	var probe := Environment.new()
	for real_key: String in [
		"volumetric_fog_density", "fog_height_density", "fog_density", "sdfgi_enabled",
	]:
		if not (real_key in probe):
			_fail("`%s` is a real Environment property and must be recognised" % real_key)
			return
	for typo: String in ["volumetric_fog_densty", "fog_heigth_density", "not_a_property"]:
		if typo in probe:
			_fail("`%s` is not an Environment property and must be rejected" % typo)
			return

	print("TEST PASS — the ablation read-back guard accepts 32-bit narrowing and still catches a rewrite")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
