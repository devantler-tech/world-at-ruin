extends Node
## Pins the frame-comparison metric (tools/frame_diff.gd) that #231 adds to the
## evidence job, and — the point of the whole exercise — pins the BLINDNESS it
## exists to cover.
##
## #231's evidence: three builds of #218's ash pools (badly broken, invisible,
## shipped) all reported a sunward luma spread of 0.541 to three decimals. The
## existing guard is a min/max over a 16x12 grid of the frame, so a localized
## effect that lands between those 192 sample points is worth exactly nothing to
## it — while a per-pixel comparison against the base separates the builds
## easily. Law 3 below reproduces that structurally rather than by anecdote: it
## constructs a change the grid PROVABLY cannot sample, and shows the grid
## statistic unmoved while the comparison reports it.
##
## Laws, each isolated:
##  1. Fixture precondition — identical frames compare as exactly zero. If this
##     fails the metric is broken and every assertion below proves nothing.
##  2. A localized change is measured, and measured EXACTLY: changed-pixel
##     fraction equals the patch's share of the frame, max equals the patch's
##     own delta.
##  3. THE DEFECT — that same change is invisible to the whole-frame grid
##     statistic. The test verifies no grid sample point lands inside the patch
##     (so the claim does not depend on the grid's exact geometry), then shows
##     every sampled pixel is byte-identical across the two frames while the
##     comparison still reports the change.
##  4. mean and max are independent axes: a small change everywhere and a large
##     change in one place are distinguishable, which is what lets a reader tell
##     "the whole frame shifted" from "one region changed".
##  5. Sub-epsilon drift does not inflate the changed-pixel count, but still
##     shows up in mean and max — the epsilon hides nothing, it only declines to
##     call it a changed pixel.
##  6. A size mismatch is REFUSED rather than rescaled, because rescaling would
##     invent differences everywhere and report a huge change for a PR that
##     changed nothing.
##
## Run: godot --headless --path client res://tests/frame_diff_test.tscn

const FrameDiff := preload("res://tools/frame_diff.gd")

## Frame size for the constructed fixtures. Large enough that the 16x12 grid
## leaves wide gaps between sample points (law 3 needs a gap to hide a patch in)
## and small enough to stay instant headless.
const W := 320
const H := 240

## The grid the existing spread guard samples, mirrored here from
## frame_capture.gd's _luma_spread_box. Law 3 does NOT trust this mirror to stay
## in sync — it asserts the patch misses every point it produces, so a guard
## that sampled a different grid would surface as a fixture failure by name
## rather than as a law silently passing.
const SAMPLE_X0 := 0.12
const SAMPLE_X1 := 0.88
const SAMPLE_Y0 := 0.22
const SAMPLE_Y1 := 0.86
const GRID_X := 16
const GRID_Y := 12

## The patch used by laws 2 and 3. Placed by _find_grid_gap() rather than
## hardcoded, so it is a gap in the ACTUAL grid, not a spot that happened to
## work once.
const PATCH := 8

var _failed := false


func _ready() -> void:
	var base := _flat(Color(0.30, 0.30, 0.30))

	# 1. Fixture precondition.
	var same: Dictionary = FrameDiff.compare_images(base, _flat(Color(0.30, 0.30, 0.30)))
	if not same["ok"]:
		_fail("fixture: identical frames did not compare at all (%s)" % same["reason"])
		return
	var same_changed: float = same["changed_fraction"]
	var same_mean: float = same["mean"]
	var same_max: float = same["max"]
	if same_changed != 0.0 or same_mean != 0.0 or same_max != 0.0:
		_fail("fixture: identical frames reported a change (changed %.6f, mean %.6f, max %.6f) — the metric is broken, so nothing below would mean anything" %
			[same_changed, same_mean, same_max])
		return

	# Locate a patch position the guard's grid cannot sample.
	var gap := _find_grid_gap()
	if gap == Vector2i(-1, -1):
		_fail("fixture: no gap between grid sample points big enough for a %dpx patch — laws 2 and 3 cannot be built" % PATCH)
		return

	# 2. A localized change is measured exactly.
	var patched := _flat(Color(0.30, 0.30, 0.30))
	_paint(patched, gap, Color(0.90, 0.90, 0.90))
	var loc: Dictionary = FrameDiff.compare_images(base, patched)
	if not loc["ok"]:
		_fail("a localized change did not compare (%s)" % loc["reason"])
		return
	var want_fraction := float(PATCH * PATCH) / float(W * H)
	var got_fraction: float = loc["changed_fraction"]
	if absf(got_fraction - want_fraction) > 1e-6:
		_fail("localized change: expected %.6f of pixels changed, got %.6f" % [want_fraction, got_fraction])
		return
	# The patch is 0.90 over a 0.30 field. Luminance is a weighted sum of equal
	# channels here, so the delta is the channel delta — but let 8-bit
	# quantisation move it a little rather than demanding an exact float.
	var got_max: float = loc["max"]
	if absf(got_max - 0.60) > 0.01:
		_fail("localized change: expected a max |dLuma| of ~0.60, got %.4f" % got_max)
		return
	var got_mean: float = loc["mean"]
	if got_mean <= 0.0:
		_fail("localized change: mean |dLuma| was %.6f — a real change must move the mean" % got_mean)
		return

	# 3. THE DEFECT: the same change is invisible to the grid statistic.
	#
	# First the fixture precondition — no sample point may land inside the
	# patch. Without this the law would be an accident of the grid's geometry.
	for p: Vector2i in _grid_points():
		if _inside_patch(p, gap):
			_fail("fixture: grid sample %s lands inside the patch at %s — law 3 would be proving the opposite of what it claims" % [p, gap])
			return
	# Now the claim itself: every pixel the guard looks at is byte-identical.
	for p: Vector2i in _grid_points():
		var a := base.get_pixel(p.x, p.y)
		var b := patched.get_pixel(p.x, p.y)
		if a != b:
			_fail("grid sample %s differs (%s vs %s) — the patch is not actually hidden from the guard" % [p, a, b])
			return
	# ...so ANY min/max statistic over those points is identical across the two
	# frames, while the comparison reported %.2f%% of pixels changed above. That
	# is #231 in one assertion: the guard cannot see this, the comparison can.
	if got_fraction <= 0.0:
		_fail("the comparison reported no change for a patch the guard cannot see — the gap #231 describes would remain open")
		return

	# 4. mean and max are independent axes.
	#
	# A small shift EVERYWHERE and a large shift in ONE PLACE must not look the
	# same. Chosen so the global shift's mean exceeds the localized patch's mean
	# while its max is far smaller — if the report carried only one of the two
	# numbers, these two frames would be indistinguishable in exactly the wrong
	# direction.
	var global_shift := _flat(Color(0.32, 0.32, 0.32))
	var glob: Dictionary = FrameDiff.compare_images(base, global_shift)
	if not glob["ok"]:
		_fail("global shift did not compare (%s)" % glob["reason"])
		return
	var glob_mean: float = glob["mean"]
	var glob_max: float = glob["max"]
	if glob_mean <= got_mean:
		_fail("a 0.02 shift over the whole frame should mean more than a %dpx patch: global mean %.6f vs localized mean %.6f" %
			[PATCH, glob_mean, got_mean])
		return
	if glob_max >= got_max:
		_fail("a 0.02 global shift should max FAR below a 0.60 patch: global max %.4f vs localized max %.4f" % [glob_max, got_max])
		return

	# 5. Sub-epsilon drift is not counted, but is not hidden either.
	var drift := _flat(Color(0.3020, 0.3020, 0.3020))
	var dr: Dictionary = FrameDiff.compare_images(base, drift)
	if not dr["ok"]:
		_fail("sub-epsilon drift did not compare (%s)" % dr["reason"])
		return
	var dr_max: float = dr["max"]
	if dr_max <= 0.0:
		_fail("sub-epsilon drift reported a max of 0 — the fixture did not actually differ, so this law tested nothing")
		return
	if dr_max >= FrameDiff.CHANGED_EPS:
		_fail("fixture: the drift frame differs by %.4f, at or above the %.4f epsilon — it is not sub-epsilon and proves nothing" %
			[dr_max, FrameDiff.CHANGED_EPS])
		return
	var dr_changed: float = dr["changed_fraction"]
	if dr_changed != 0.0:
		_fail("sub-epsilon drift counted %.6f of pixels as changed — the epsilon is not holding" % dr_changed)
		return
	var dr_mean: float = dr["mean"]
	if dr_mean <= 0.0:
		_fail("sub-epsilon drift reported a mean of 0 — the epsilon must not erase the measurement, only decline to call it a changed pixel")
		return

	# 6. A size mismatch is refused, not rescaled.
	var small := Image.create(W / 2, H / 2, false, Image.FORMAT_RGBA8)
	small.fill(Color(0.30, 0.30, 0.30))
	var mism: Dictionary = FrameDiff.compare_images(base, small)
	if mism["ok"]:
		_fail("a %dx%d frame compared against a %dx%d one instead of being refused — rescaling invents differences everywhere" %
			[W, H, W / 2, H / 2])
		return
	var reason: String = mism["reason"]
	if not reason.contains("size mismatch"):
		_fail("a size mismatch was refused for the wrong reason ('%s') — the refusal must name the actual cause" % reason)
		return

	print("TEST PASS — frame_diff measures localized change the spread guard cannot sample (%.2f%% of pixels, max %.3f), separates mean from max, holds its epsilon, and refuses mismatched sizes" %
		[got_fraction * 100.0, got_max])
	get_tree().quit(0)


## A uniform frame.
func _flat(c: Color) -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


## Paints the PATCH-sized square whose top-left is at `at`.
func _paint(img: Image, at: Vector2i, c: Color) -> void:
	for y in PATCH:
		for x in PATCH:
			img.set_pixel(at.x + x, at.y + y, c)


## The pixels frame_capture's spread guard actually samples, by the same
## arithmetic its _luma_spread_box uses.
func _grid_points() -> Array[Vector2i]:
	var pts: Array[Vector2i] = []
	var x0 := SAMPLE_X0 * W
	var y0 := SAMPLE_Y0 * H
	var span_x := (SAMPLE_X1 - SAMPLE_X0) * W
	var span_y := (SAMPLE_Y1 - SAMPLE_Y0) * H
	for gy in GRID_Y:
		for gx in GRID_X:
			pts.append(Vector2i(
				int(x0 + (gx + 0.5) * span_x / float(GRID_X)),
				int(y0 + (gy + 0.5) * span_y / float(GRID_Y))))
	return pts


func _inside_patch(p: Vector2i, at: Vector2i) -> bool:
	return p.x >= at.x and p.x < at.x + PATCH and p.y >= at.y and p.y < at.y + PATCH


## Finds a patch position inside the sampled box that no grid point touches.
## Searched rather than hardcoded: a hardcoded spot silently stops being a gap
## the moment the grid or the box changes, and the law would then pass while
## testing the opposite of its claim.
func _find_grid_gap() -> Vector2i:
	var pts := _grid_points()
	# Search inside the guard's own sampled box — a patch outside it would be
	# unsampled for the trivial reason that the guard ignores that band, which
	# is a much weaker statement than "it falls between the sample points".
	var lo_x := int(SAMPLE_X0 * W) + 1
	var hi_x := int(SAMPLE_X1 * W) - PATCH - 1
	var lo_y := int(SAMPLE_Y0 * H) + 1
	var hi_y := int(SAMPLE_Y1 * H) - PATCH - 1
	for y in range(lo_y, hi_y):
		for x in range(lo_x, hi_x):
			var at := Vector2i(x, y)
			var clear := true
			for p: Vector2i in pts:
				if _inside_patch(p, at):
					clear = false
					break
			if clear:
				return at
	return Vector2i(-1, -1)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
