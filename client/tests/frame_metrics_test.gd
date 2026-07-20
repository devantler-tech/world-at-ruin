extends Node
## Pins `tools/frame_metrics.gd` — the separation metric that `frame_capture`
## prints beside every vantage — against the frame the maintainer actually
## rejected, and proves the metric is capable of reporting the opposite verdict.
##
## The point of a diagnostic like this is that it can say "flat". A metric that
## reported "flat" on every input would be indistinguishable from a working one
## when pointed at the cave, and would quietly bless the first frame that fixed
## the problem. So every law below comes with its refutation.
##
## Laws, each isolated:
##  1. Fixture precondition — the rejected Phase 0 frame is present, is the size
##     it was captured at, and yields a full coloured population. If this fails
##     the fixture is broken, not the metric, and laws 2-3 would be measuring
##     nothing.
##  2. Baseline — the cave frame re-derives the figures recorded in
##     `docs/art-direction/README.md`: a narrow value range and a ~6 deg hue span.
##  3. Non-vacuity — a synthetic wide-gamut control moves BOTH axes to the far
##     end of their scales through the same code, so law 2 describes the frame
##     rather than the method.
##  4. Hue is circular — a wrapped population reports its true narrow arc and
##     NOT the ~360 deg the superseded percentile subtraction would report.
##  5. Hue is the tightest arc, not a symmetric trim — an asymmetric population
##     reports the minimum window and not the ~96 deg a percentile spread gives.
##  6. Absent colour is reported as absent, never as a perfectly tight hue.
##  7. Determinism — the same frame measured twice reports the same numbers.
##
## Run: godot --headless --path client res://tests/frame_metrics_test.tscn

const Metrics := preload("res://tools/frame_metrics.gd")

## The rejected Phase 0 cave frame, committed by #219. Lives outside the Godot
## project (the project root is `client/`), so it is reached through the real
## filesystem rather than `res://`.
const CAVE_FRAME := "docs/phase-0/cave-chamber.png"
const CAVE_WIDTH := 1600
const CAVE_HEIGHT := 900

## Recorded baseline for that frame, re-derived by this tool and written into
## `docs/art-direction/README.md`. The tolerances are rounding bands, not
## tuning room: the measurement is deterministic, so any real drift here means
## the metric changed and the recorded baseline is now a lie.
const CAVE_LUMA_RANGE := 0.127
const CAVE_HUE_SPAN_DEG := 6.3
const LUMA_TOLERANCE := 0.005
const HUE_TOLERANCE_DEG := 0.2

## What the control must clear for law 3 to mean anything. Set far from both the
## cave figures and the control's own measured values (98.9% and 319.4 deg), so
## the test states "these are different worlds" without pinning the control's
## exact numbers, which are a property of the synthetic fixture rather than of
## the art.
const CONTROL_MIN_LUMA_RANGE := 0.90
const CONTROL_MIN_HUE_SPAN_DEG := 300.0

var _failed := false


func _ready() -> void:
	var img := _load_cave_frame()
	if img == null:
		_finish()
		return

	# ── Law 1: fixture precondition ──────────────────────────────────────
	# Everything below reads this image. If it is not the frame that was
	# measured, at the size it was measured, the baseline is meaningless.
	if img.get_width() != CAVE_WIDTH or img.get_height() != CAVE_HEIGHT:
		_fail("fixture %s is %dx%d, expected %dx%d — the recorded baseline was taken at the latter" %
			[CAVE_FRAME, img.get_width(), img.get_height(), CAVE_WIDTH, CAVE_HEIGHT])
		_finish()
		return
	var cave: Dictionary = Metrics.measure(img)
	if int(cave["samples"]) <= 0:
		_fail("fixture yielded no samples at all — the metric never ran")
		_finish()
		return
	# The cave is dim but it is not grey: every sampled pixel clears the
	# saturation and mid-value filters. A fixture that had lost its colour
	# would make the 6 deg reading below true and uninformative.
	if int(cave["hue_samples"]) != int(cave["samples"]):
		_fail("fixture precondition: %d of %d samples carry colour — the recorded 6.3 deg span was measured over the full population" %
			[cave["hue_samples"], cave["samples"]])

	# ── Law 2: the recorded baseline ─────────────────────────────────────
	_near("cave value range", cave["luma_range"], CAVE_LUMA_RANGE, LUMA_TOLERANCE)
	_near("cave hue span", cave["hue_span_deg"], CAVE_HUE_SPAN_DEG, HUE_TOLERANCE_DEG)

	# ── Law 3: non-vacuity, through the same code path ───────────────────
	var control: Dictionary = Metrics.measure(_wide_gamut())
	if control["luma_range"] < CONTROL_MIN_LUMA_RANGE:
		_fail("wide-gamut control reports value range %.3f — the metric cannot report a wide frame, so the cave reading proves nothing" %
			control["luma_range"])
	if control["hue_span_deg"] < CONTROL_MIN_HUE_SPAN_DEG:
		_fail("wide-gamut control reports hue span %.1f deg — the metric cannot report a wide gamut, so the 6.3 deg reading proves nothing" %
			control["hue_span_deg"])

	# ── Law 4: hue wraps ─────────────────────────────────────────────────
	# Samples straddling 0 deg span 2 deg of real colour. The superseded
	# percentile subtraction reports ~359 deg here — scoring a nearly
	# monochrome frame as almost the whole gamut, i.e. failing OPEN in the
	# exact diagnostic that exists to catch flatness.
	var wrapped := PackedFloat32Array([359.0, 359.5, 0.0, 0.5, 1.0])
	var wrapped_span: float = Metrics.hue_span_deg(wrapped)
	_near("wrapped hue span", wrapped_span, 2.0, 0.001)
	if wrapped_span > 300.0:
		_fail("wrapped population reported %.1f deg — this is the superseded linear subtraction, not a circular arc" %
			wrapped_span)

	# ── Law 5: tightest arc, not a symmetric trim ────────────────────────
	# 90 samples inside 10 deg, 10 outliers near 100 deg — no wrap involved.
	# The minimum 90% window is 10 deg; a p5->p95 spread keeps half the
	# outliers and reports ~96 deg. Both forms are "correct" on symmetric
	# data, which is why this population is the one that separates them.
	var asymmetric := PackedFloat32Array()
	for i in 90:
		asymmetric.append(float(i) * 10.0 / 89.0)
	for i in 10:
		asymmetric.append(100.0 + float(i) * 0.1)
	var asym_span: float = Metrics.hue_span_deg(asymmetric)
	if asym_span > 12.0:
		_fail("asymmetric population reported %.1f deg — expected the tightest 90%% arc (~10 deg), so this is a percentile trim" %
			asym_span)

	# ── Law 6: absent colour is not a tight hue ──────────────────────────
	var grey := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	grey.fill(Color(0.4, 0.4, 0.4))
	var grey_m: Dictionary = Metrics.measure(grey)
	if int(grey_m["hue_samples"]) != 0:
		_fail("a flat grey image contributed %d hue samples — the saturation filter is not holding" %
			grey_m["hue_samples"])
	if grey_m["hue_span_deg"] >= 0.0:
		_fail("a colourless image reported a %.1f deg hue span instead of 'no coloured pixels' — the tightest possible reading is exactly the wrong answer here" %
			grey_m["hue_span_deg"])

	# ── Law 7: determinism ───────────────────────────────────────────────
	var again: Dictionary = Metrics.measure(img)
	if again["luma_range"] != cave["luma_range"] or again["hue_span_deg"] != cave["hue_span_deg"]:
		_fail("the same frame measured twice reported different numbers — the metric is not deterministic")

	print("MEASURED cave-chamber :: %s" % Metrics.format(cave))
	print("MEASURED wide-gamut control :: %s" % Metrics.format(control))
	_finish()


## The rejected frame lives beside the repo, not inside the Godot project.
func _load_cave_frame() -> Image:
	var path := ProjectSettings.globalize_path("res://").path_join("..").path_join(CAVE_FRAME)
	var img := Image.load_from_file(path)
	if img == null:
		_fail("could not load the Phase 0 fixture at %s — it is committed by #219 and this test measures it" % path)
	return img


## A full hue sweep across x over a full black-to-hue-to-white ramp down y: the
## widest frame the metric can be handed. Built in code rather than committed as
## a PNG so the control cannot drift from what it claims to be.
func _wide_gamut() -> Image:
	var w := 640
	var h := 360
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)
		for x in w:
			var hue := float(x) / float(w)
			# Saturating to the pure hue alone tops out at that hue's own
			# luminance (pure blue is 0.07), so the ramp continues to white —
			# otherwise the control could not exercise the top of the scale.
			var c: Color
			if t < 0.5:
				c = Color.from_hsv(hue, 1.0, t * 2.0)
			else:
				c = Color.from_hsv(hue, 2.0 - t * 2.0, 1.0)
			img.set_pixel(x, y, c)
	return img


func _near(what: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) > tolerance:
		_fail("%s is %.4f, expected %.4f +/- %.4f — the recorded baseline in docs/art-direction/README.md no longer matches the tool" %
			[what, got, want, tolerance])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)


func _finish() -> void:
	if _failed:
		get_tree().quit(1)
		return
	print("TEST PASS — frame separation metric matches its recorded baseline and can report the opposite")
	get_tree().quit(0)
