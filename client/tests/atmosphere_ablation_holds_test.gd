extends Node
## Pins `atmosphere_ablation._holds`, the check that decides whether an
## Environment override actually took (#393).
##
## The guard it replaces used exact identity, which rejected every override whose
## value is not exactly representable in float32 — reporting a correctly-applied
## candidate as "something re-applies it each frame" and refusing to publish the
## whole table. That is a false NEGATIVE, so it fails loudly rather than
## silently; but it made the harness unable to measure a candidate shipping
## value at all, which is what a proposed atmosphere trade is (#273).
##
## Kept headless and arithmetic-only on purpose. The defect is a storage-precision
## question, not a rendering one, and the ablation tool itself only runs windowed
## with a GPU — a guard provable only by a manual windowed run is one that stops
## being re-checked.
##
## Run: godot --headless --path client res://tests/atmosphere_ablation_holds_test.tscn

## The tool under test, loaded rather than referenced: it is a tool script with
## no `class_name`, so there is no global to call through.
const ABLATION := preload("res://tools/atmosphere_ablation.gd")

## The candidate values that exposed the defect — the volumetric and height fog
## densities a trade measurement for #273 asks for.
##
## Only the WANTED values are pinned; the doubles they read back as are computed.
## Writing those out as literals was tried and is a trap: the decimal repr of a
## float32-rounded double does not survive a round trip through GDScript's parser
## reliably, so the recorded constants sat one ULP off what the engine actually
## stores and the test failed on its own literals rather than on the code. Law 1
## pins the property that matters instead, and pins it from both sides.
const CANDIDATES := [0.0035, 0.0025, 0.0015, 0.045, 0.036]

var _failed := false


func _ready() -> void:
	# LAW 1 — a value that survived a float32 round trip HELD. This is the whole
	# defect: each of these pairs was reported as a reset.
	#
	# Pinned from BOTH sides, which is what keeps this from being circular:
	# first that the value genuinely does not survive exact comparison — so it
	# really does exercise the defect and is not a vacuous case — and then that
	# `_holds` accepts it anyway. The first assertion is the RED condition; drop
	# it and a later change making every value exactly representable would leave
	# the law green while testing nothing.
	for want: float in CANDIDATES:
		var stored: float = PackedFloat32Array([want])[0]
		if is_same(stored, want):
			_fail("%.17f survives float32 exactly, so it cannot exercise the defect this pins"
				% want)
			return
		if not ABLATION._holds(stored, want):
			_fail("float32 round-trip of %.17f reads back as %.17f and must count as applied"
				% [want, stored])
			return

	# LAW 2 — a GENUINE reset is still caught. The guard exists to notice that
	# `main._process` re-applied the shipped atmosphere over an override, and
	# loosening it into a tolerance would have retired that. The shipped
	# volumetric density (0.005) against a 0.0025 candidate is exactly that case,
	# and the two differ by far more than one float32 step.
	if ABLATION._holds(0.005, 0.0025):
		_fail("a reset from 0.0025 back to the shipped 0.005 must NOT count as applied")
		return
	# And the comparison is EXACT, not a tolerance. An offset of 1e-9 sits far
	# inside `is_equal_approx`'s ~1e-6 epsilon, so a tolerance-based guard would
	# wave this through; matching the float32 round-trip instead rejects it. This
	# is what keeps the guard as strict as the `is_same` it replaces for every
	# difference that is not the storage round-trip itself.
	var stored: float = PackedFloat32Array([0.0035])[0]
	if ABLATION._holds(stored + 1.0e-9, 0.0035):
		_fail("a value off the stored float32 by 1e-9 must NOT count as applied")
		return

	# LAW 3 — non-float overrides keep exact identity. Every condition the tool
	# shipped with sets a bool or an enum, so a change here would regress the
	# cases the guard was originally written for.
	if not ABLATION._holds(false, false) or not ABLATION._holds(true, true):
		_fail("bool overrides must compare exactly")
		return
	if ABLATION._holds(true, false) or ABLATION._holds(false, true):
		_fail("a bool override that did not take must be caught")
		return
	if not ABLATION._holds(Environment.TONE_MAPPER_LINEAR, Environment.TONE_MAPPER_LINEAR):
		_fail("enum overrides must compare exactly")
		return
	if ABLATION._holds(Environment.TONE_MAPPER_FILMIC, Environment.TONE_MAPPER_LINEAR):
		_fail("an enum override that did not take must be caught")
		return

	# LAW 4 — an unset property reads back as null, which is a misspelling in the
	# condition table rather than a value that held. Answering true here would
	# turn a typo into a silently unmeasured row.
	if ABLATION._holds(null, 0.0035):
		_fail("a null read-back must NOT count as applied")
		return

	# LAW 5 — the primitive the harness pre-flights its condition table with
	# actually distinguishes a real Environment property from a typo.
	#
	# Pinned because the harness's own success path cannot prove it: a run where
	# every key is valid exercises only the "no unknown keys" branch, so a `in`
	# that answered true for everything would sail through the very run that is
	# supposed to be the evidence. Both directions are asserted here instead.
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

	print("TEST PASS: atmosphere_ablation_holds")
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("atmosphere_ablation_holds: %s" % message)
	print("TEST FAIL: atmosphere_ablation_holds — %s" % message)
	get_tree().quit(1)
