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
##  6b. The hue filter's CUTOFFS hold — a fixture straddling the saturation and
##     luminance boundaries pins exactly which bands survive, so moving or
##     deleting a threshold fails here rather than silently admitting unstable
##     near-grey, crushed or blown-out hues into real measurements.
##  6c. The percentile CONVENTION is nearest-rank, proved on a population where
##     it differs from the truncating form no frame fixture can separate.
##  7. Determinism — the same frame measured twice reports the same numbers.
##
## Laws 6b, 6c and the finiteness guards exist because a Codex review found
## them missing: the original suite proved each law could fail for the ONE
## break each ablation introduced, which is not the same as proving it fails
## for every break it claims to cover.
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
## Half of the last DISPLAYED digit, not a comfortable margin. The metric is
## deterministic, so the only drift these need to absorb is the rounding in the
## figures written into `docs/art-direction/README.md` (12.7%, 6.3 deg). Wider
## bands would let the measurement disagree with the published baseline while
## the suite stayed green — e.g. 0.131 renders as "13.1%" against a documented
## 12.7% — which defeats the point of pinning the doc to the tool.
const LUMA_TOLERANCE := 0.0005
const HUE_TOLERANCE_DEG := 0.05

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
	# Finiteness first: `NaN < CONTROL_MIN_…` is false, so both lower bounds
	# below would be skipped and this law would pass having measured nothing.
	if not is_finite(control["luma_range"]) or not is_finite(control["hue_span_deg"]):
		_fail("wide-gamut control produced a non-finite measurement (value %f, hue %f) — law 3 cannot vouch for anything" %
			[control["luma_range"], control["hue_span_deg"]])
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
	# Bounded on BOTH sides. An upper bound alone would accept 0 deg, which
	# cannot contain the required 90 samples and so violates the contract just
	# as badly as the 100 deg a percentile trim gives — it would simply fail in
	# the flattering direction.
	_near("asymmetric hue span", asym_span, 10.0, 0.5)

	# ── Law 6: absent colour is not a tight hue ──────────────────────────
	var grey := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	grey.fill(Color(0.4, 0.4, 0.4))
	var grey_m: Dictionary = Metrics.measure(grey)
	if int(grey_m["hue_samples"]) != 0:
		_fail("a flat grey image contributed %d hue samples — the saturation filter is not holding" %
			grey_m["hue_samples"])
	# Compared against the sentinel EXACTLY, not `>= 0.0`. NaN fails every
	# comparison, so a `>= 0.0` test would pass if the empty-population branch
	# regressed to NaN — and `format()` reads that NaN as "no coloured pixels"
	# too, so the regression would be silent on both surfaces. This path is the
	# one the other finiteness guards cannot reach, since they all measure
	# populations that DO carry colour.
	if grey_m["hue_span_deg"] != Metrics.NO_HUE:
		_fail("a colourless image reported %f instead of the NO_HUE sentinel (%f) — a tight span, or a NaN masquerading as one, is exactly the wrong answer here" %
			[grey_m["hue_span_deg"], Metrics.NO_HUE])

	# ── Law 6b: the filter CUTOFFS, not just the colourless case ─────────
	# Grey alone proves saturation 0 is excluded, and nothing more: lowering
	# the threshold to 0.001, or deleting the luminance window entirely, keeps
	# every law above green. The cave fixture sits wholly inside the
	# boundaries and the control sweeps every value, so neither can expose it.
	# This fixture straddles all three cutoffs and pins the surviving count
	# exactly — the only assertion that fails in BOTH directions.
	var bands := _boundary_bands()
	var band_m: Dictionary = Metrics.measure(bands["image"])
	if int(band_m["hue_samples"]) != int(bands["expected"]):
		_fail("boundary fixture contributed %d hue samples, expected %d — a saturation or luminance cutoff has moved (sat > %.2f, luma %.2f..%.2f)" %
			[band_m["hue_samples"], bands["expected"],
			Metrics.HUE_MIN_SATURATION, Metrics.HUE_MIN_LUMA, Metrics.HUE_MAX_LUMA])

	# ── Law 6c: the percentile CONVENTION ────────────────────────────────
	# Fixing the nearest-rank formula without guarding it just waits for the
	# next rewrite to reintroduce the tempting `int(q * (n - 1))`. No frame
	# fixture can hold this: the two formulas coincide at the 57600 samples a
	# 1600x900 frame yields, which is why the bug survived review here in the
	# first place. 150 is the smallest convenient population where they part —
	# nearest-rank selects index 148, the truncating form 147.
	var ramp := PackedFloat32Array()
	for i in 150:
		ramp.append(float(i))
	var p99: float = Metrics._percentile(ramp, 0.99)
	if p99 != 148.0:
		_fail("p99 over 150 ascending samples is %.1f, expected 148.0 (nearest-rank, 1-based rank ceil(0.99*150)=149) — 147.0 means the truncating int(q*(n-1)) form is back" % p99)
	var p1: float = Metrics._percentile(ramp, 0.01)
	if p1 != 1.0:
		_fail("p1 over 150 ascending samples is %.1f, expected 1.0 (nearest-rank, rank ceil(0.01*150)=2)" % p1)

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


## Five bands, each isolating ONE hue-filter cutoff, sized so the metric's grid
## samples every pixel exactly once (320 wide = SAMPLE_WIDTH, so one column per
## sample; one row per row).
##
## Colours are `Color(r, g, g)` — a red tint over grey — because that shape
## makes both filtered quantities solvable by hand rather than by trial:
## saturation is `(r - g) / r` and Rec. 709 luminance is `0.2126r + 0.7874g`.
## Each row is derived from those two formulas, NOT tuned until the test passed,
## which would make the fixture agree with whatever the code happened to do.
##
## Bands sit **immediately either side of each cutoff** — 0.002 away, not in the
## middle of the admitted region. A fixture placed loosely (0.04 vs 0.08 around
## a 0.05 floor) only brackets the threshold to a broad interval: moving the
## floor to 0.06 would leave every verdict unchanged and the law green. Pinning
## each cutoff to +/-0.002 is what makes a moved threshold actually fail here.
##
## | band | saturation | luminance | verdict | pins |
## |---|---|---|---|---|
## | A | 0.048 | 0.500 | excluded | saturation floor, from below |
## | B | 0.052 | 0.500 | included | saturation floor, from above |
## | C | 0.500 | 0.048 | excluded | luminance minimum, from below |
## | D | 0.500 | 0.052 | included | luminance minimum, from above |
## | E | 0.061 | 0.952 | excluded | luminance maximum, from above |
## | F | 0.066 | 0.948 | included | luminance maximum, from below |
## | G | 0.500 | 0.500 | included | anchors the count, far from every edge |
##
## Bands E and F keep saturation just ABOVE the floor on purpose: a brighter,
## more obvious white would be rejected for being desaturated and would prove
## nothing about the luminance ceiling they exist to test.
##
## The image is FORMAT_RGBAF, not RGBA8. Eight-bit channels quantise in steps of
## 1/255 = 0.0039 — wider than the 0.004 gaps these bands rely on — so the pairs
## would collapse into each other and the law would silently stop discriminating.
func _boundary_bands() -> Dictionary:
	# Derived from saturation = (r - g) / r and luminance = 0.2126r + 0.7874g,
	# solved per band rather than tuned until the test agreed with the code.
	var bands: Array[Color] = [
		Color(0.51964, 0.49470, 0.49470),  # A  s=0.048  luma=0.500
		Color(0.52134, 0.49423, 0.49423),  # B  s=0.052  luma=0.500
		Color(0.07917, 0.03959, 0.03959),  # C  s=0.500  luma=0.048
		Color(0.08577, 0.04289, 0.04289),  # D  s=0.500  luma=0.052
		Color(1.0, 0.93904, 0.93904),      # E  s=0.061  luma=0.952
		Color(1.0, 0.93396, 0.93396),      # F  s=0.066  luma=0.948
		Color(0.82470, 0.41235, 0.41235),  # G  s=0.500  luma=0.500
	]
	var w := Metrics.SAMPLE_WIDTH
	var img := Image.create(w, bands.size(), false, Image.FORMAT_RGBAF)
	for y in bands.size():
		for x in w:
			img.set_pixel(x, y, bands[y])
	# Bands B, D, F and G survive — one sample per column each.
	return {"image": img, "expected": 4 * w}


func _near(what: String, got: float, want: float, tolerance: float) -> void:
	# NaN fails every comparison, so a bare `absf(got - want) > tolerance` would
	# PASS on a metric that returned NaN — the comparison hole is a silent
	# fail-open in exactly the guards meant to catch silence.
	if not is_finite(got):
		_fail("%s is not a finite number (%f) — the metric produced no usable measurement" % [what, got])
		return
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
