class_name FrameMetrics
extends RefCounted
## Measures art-direction **check 1 — separation** on a captured frame, so
## "does this read as flat?" is a reading rather than a matter of squinting.
##
## `docs/art-direction/README.md` gives every agent a six-step judging list, and
## two of its steps — value range and material/hue variety — were run by eye.
## Eyes are exactly what produced "good indie" on the Phase 0 frames the
## maintainer rejected outright. This puts the two numbers next to every frame
## `frame_capture` writes, and gives each art PR a recorded baseline to beat.
##
## **Reporting only. There is deliberately no threshold here** — a legitimately
## monochrome scene (a night interior, a sandstorm) is a valid composition, and
## auto-failing it would make the tool a liar. What condemns a frame is failing
## on BOTH axes at once, which is a judgement a reader makes with these two
## numbers in hand, not one this file makes for them.
##
## The method is the contract written down in `docs/art-direction/README.md`
## ("Check 1 is measurable on both its axes"). Two decisions there are
## load-bearing and are restated at their implementation below: the frame is
## **point-sampled** rather than filtered down, and the hue figure is a
## **minimum circular arc**, never a percentile subtraction.

## Sample width the frame is reduced to before measuring. The recorded
## observations in `docs/art-direction/README.md` were taken at ~320px wide, and
## the figure is kept identical so this tool re-derives them rather than
## producing a third, differently-scaled set of numbers.
const SAMPLE_WIDTH := 320

## A pixel carries colour — and so may vote on hue — only above this HSV
## saturation. Below it the hue channel is numerically defined but perceptually
## meaningless: near-grey pixels carry a hue that swings wildly on rounding, so
## admitting them would let sensor-grade noise widen the span of a frame that
## has no colour in it at all.
const HUE_MIN_SATURATION := 0.05
## Hue votes are also restricted to mid-values. Crushed blacks and blown
## highlights both quantise hard, so their hue is an artifact of clipping rather
## than a property of the art.
const HUE_MIN_LUMA := 0.05
const HUE_MAX_LUMA := 0.95
## The share of coloured pixels the reported arc must contain.
const HUE_WINDOW_SHARE := 0.9

## Percentiles bounding the reported value range. p1..p99 rather than min..max
## on purpose: the HUD text drawn OVER the 3D view, and any single stray
## specular pixel, would otherwise set the range for the whole frame and every
## capture would report "wide" regardless of the art behind it.
const LUMA_LOW_PERCENTILE := 0.01
const LUMA_HIGH_PERCENTILE := 0.99

## Returned by [method hue_span_deg] when the frame has too little colour for the
## question to have an answer. Reported as "no coloured pixels" rather than as
## 0°, because a flat span and an absent population are different findings and
## collapsing them would let an all-grey frame report the tightest possible hue.
const NO_HUE := -1.0


## Both metrics for one frame, as `{luma_range, luma_p_low, luma_p_high,
## hue_span_deg, hue_samples, samples}`. One entry point so a caller cannot
## measure the two axes over different populations by accident.
static func measure(img: Image) -> Dictionary:
	var lumas := PackedFloat32Array()
	var hues := PackedFloat32Array()
	_collect(img, lumas, hues)
	lumas.sort()
	var low := _percentile(lumas, LUMA_LOW_PERCENTILE)
	var high := _percentile(lumas, LUMA_HIGH_PERCENTILE)
	return {
		"luma_p_low": low,
		"luma_p_high": high,
		"luma_range": high - low,
		"hue_span_deg": hue_span_deg(hues),
		"hue_samples": hues.size(),
		"samples": lumas.size(),
	}


## One line per vantage, in the shape the capture job prints beside `CAPTURED`.
static func format(m: Dictionary) -> String:
	var hue := "no coloured pixels"
	if m["hue_span_deg"] >= 0.0:
		hue = "%.1f deg over %d px" % [m["hue_span_deg"], m["hue_samples"]]
	return "value %.1f%% of range (p1 %.3f -> p99 %.3f) - hue %s" % [
		m["luma_range"] * 100.0, m["luma_p_low"], m["luma_p_high"], hue]


## Point-samples the frame onto a fixed grid, collecting every pixel's luminance
## and the hue of those pixels that carry colour.
##
## **Point sampling, not [method Image.resize] — for stability, not because it
## moves the number.** A filtered downscale makes the reading depend on the
## engine's interpolation implementation, so a Godot upgrade could shift a
## committed baseline with no art having changed. Nearest-neighbour sampling
## reports luminances that genuinely occur in the frame and cannot drift that
## way.
##
## It is worth being precise about what this does NOT explain, because
## `docs/art-direction/README.md` previously attributed the gap between its two
## recorded passes (13.1% and 14.3% of value range) to this choice. Measured:
## swapping this loop for a bilinear `resize` to the same width reports 12.7% on
## the cave frame — identical to point sampling at three significant figures.
## The filter is therefore not the source of that spread, and the honest reading
## is that one of the throwaway passes differed in some other respect nobody
## recorded. That is exactly why the tool is committed.
static func _collect(img: Image, lumas: PackedFloat32Array, hues: PackedFloat32Array) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return
	var cols := mini(SAMPLE_WIDTH, w)
	# Preserve the aspect ratio so a wide frame is not sampled as if it were
	# square — the population should be spread over the picture as composed.
	var rows := maxi(1, int(round(float(cols) * float(h) / float(w))))
	rows = mini(rows, h)
	for gy in rows:
		var y := mini(h - 1, int((float(gy) + 0.5) * float(h) / float(rows)))
		for gx in cols:
			var x := mini(w - 1, int((float(gx) + 0.5) * float(w) / float(cols)))
			var px := img.get_pixel(x, y)
			var lum := px.get_luminance()
			lumas.append(lum)
			if px.s > HUE_MIN_SATURATION and lum >= HUE_MIN_LUMA and lum <= HUE_MAX_LUMA:
				hues.append(px.h * 360.0)


## Nearest-rank percentile over an already-sorted array.
static func _percentile(sorted_values: PackedFloat32Array, q: float) -> float:
	var n := sorted_values.size()
	if n == 0:
		return 0.0
	return sorted_values[clampi(int(q * float(n - 1)), 0, n - 1)]


## The width of the smallest circular arc containing 90% of the coloured pixels.
##
## **Hue is circular, so a percentile spread is not a substitute for this**, and
## the difference is not academic — it fails in the dangerous direction. A nearly
## monochrome red scene with samples at 359° and 1° spans 2° of real colour and
## reports ~358° under subtraction: it scores as almost the whole gamut precisely
## when it is at its flattest. Unwrapping at the largest gap does not rescue it
## either, because the percentile form ALSO trims 10% symmetrically from two
## tails instead of finding the tightest 90% — on an asymmetric population
## (90% inside 10°, the rest near 100°) that reports ~100° against a true arc of
## 10°, with no wrap involved at all.
##
## So: sort, append a `+360°` copy so a window may wrap, and take the minimum
## width over every start index. `docs/art-direction/README.md` records this as
## the metric and the subtraction form as superseded.
static func hue_span_deg(hues: PackedFloat32Array) -> float:
	var n := hues.size()
	if n == 0:
		return NO_HUE
	if n == 1:
		return 0.0
	var sorted_hues := hues.duplicate()
	sorted_hues.sort()
	var doubled := PackedFloat32Array()
	doubled.resize(n * 2)
	for i in n:
		doubled[i] = sorted_hues[i]
		doubled[n + i] = sorted_hues[i] + 360.0
	var k := int(ceil(HUE_WINDOW_SHARE * float(n)))
	k = clampi(k, 1, n)
	var best := 360.0
	for i in n:
		best = minf(best, doubled[i + k - 1] - doubled[i])
	return best
