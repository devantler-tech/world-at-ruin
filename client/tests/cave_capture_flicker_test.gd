extends Node
## Regression test: the cave's captured ILLUMINANT is deterministic (#321).
##
## The torches are the cave's only light source, and they flicker on accumulated
## wall-clock time — energy swings 1.38 → 2.82, slightly over 2×. `frame_capture`
## settles a fixed number of FRAMES while that phase advances by DELTA, so before
## `freeze_flicker()` every capture photographed whatever phase the frame pacing
## happened to land on. Measured on unchanged `main`, two consecutive runs:
## cave-walkout 16.8% → 20.8% of value range, cave-chamber 12.5% → 14.1%, while
## every outdoor vantage repeated exactly. That ±4pp floor is wider than the
## effect most cave art PRs are asked to prove through this path, so any value
## delta below it was unfalsifiable.
##
## What it holds:
##  1. PINNED — two independently built caves, frozen the same way, agree
##     exactly. This is the property the evidence path actually needs.
##  2. PHASE-INDEPENDENT — a cave whose clock has already run agrees with a
##     fresh one after freezing. Freezing must SET the phase, not merely stop
##     advancing whatever phase it had reached.
##  3. STOPPED — the frozen phase survives further `_process` ticks, so frames
##     settled after the freeze are all lit identically.
##  4. NON-VACUOUS — two DIFFERENT freeze times give DIFFERENT energies. Without
##     this, every assertion above would pass just as well against a torch whose
##     energy never varied at all, and the test would be pinning nothing.
##
## Run: godot --headless --path client res://tests/cave_capture_flicker_test.tscn

const SEED := 42
## Energies are compared exactly in spirit; this absorbs float round-trip only.
const EPSILON := 1e-6
## A second freeze time, far enough around the curve to land somewhere else.
const OTHER_TIME := 2.7
## The non-vacuity floor: at two unrelated phases at least one torch must differ
## by more than this, or "deterministic" is being proven against a constant.
const MIN_PHASE_SPREAD := 0.05


func _ready() -> void:
	# 1. PINNED.
	var a := _build()
	var b := _build()
	a.freeze_flicker()
	b.freeze_flicker()
	var ea := _energies(a)
	var eb := _energies(b)
	if ea.is_empty():
		_fail("the cave built no torch lights — nothing lights a cave frame")
		return
	if ea.size() != eb.size():
		_fail("two builds of seed %d made %d and %d torches" % [SEED, ea.size(), eb.size()])
		return
	var drift := _max_diff(ea, eb)
	if drift > EPSILON:
		_fail("two frozen caves disagree by %.6f in torch energy — a capture is not reproducible" % drift)
		return

	# 2. PHASE-INDEPENDENT — let one cave's clock run before freezing it.
	var c := _build()
	c._process(0.37)
	c._process(0.41)
	c.freeze_flicker()
	var drift_run := _max_diff(ea, _energies(c))
	if drift_run > EPSILON:
		_fail(("a cave whose clock already ran disagrees by %.6f after freezing — "
			+ "freeze_flicker stops the phase instead of setting it") % drift_run)
		return

	# 3. STOPPED — the engine must not tick the phase on after the freeze. This
	# asserts `is_processing()` and then lets REAL frames pass, rather than
	# calling `_process` by hand: a manual call bypasses `set_process(false)`
	# and would test a path the running game never takes.
	if a.is_processing():
		_fail("the cave still processes after freezing — the phase would walk on during settle frames")
		return
	for _i in 3:
		await get_tree().process_frame
	var drift_after := _max_diff(ea, _energies(a))
	if drift_after > EPSILON:
		_fail("torch energy moved %.6f over three frames after freezing — settle frames would each be lit differently" % drift_after)
		return

	# 4. NON-VACUOUS — the metric must be able to tell two phases apart, or
	# every check above is satisfied by a torch that simply never flickers.
	var d := _build()
	d.freeze_flicker(CaveSystemGen.FLICKER_CAPTURE_TIME + OTHER_TIME)
	var spread := _max_diff(ea, _energies(d))
	if spread <= MIN_PHASE_SPREAD:
		_fail(("two unrelated flicker phases differ by only %.4f (need > %.2f) — "
			+ "this test would pass against a constant light and pins nothing")
			% [spread, MIN_PHASE_SPREAD])
		return

	print("TEST PASS — %d torches pinned, phase spread %.3f" % [ea.size(), spread])
	get_tree().quit(0)


func _build() -> CaveSystemGen:
	var cave := CaveSystemGen.new()
	cave.seed_value = SEED
	add_child(cave)
	return cave


## Every torch light's energy, in a stable order so two builds compare pairwise.
func _energies(cave: CaveSystemGen) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for child in cave.get_children():
		for c in child.get_children():
			if c is OmniLight3D:
				out.append((c as OmniLight3D).light_energy)
	return out


func _max_diff(x: PackedFloat32Array, y: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in mini(x.size(), y.size()):
		worst = maxf(worst, absf(x[i] - y[i]))
	return worst


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
