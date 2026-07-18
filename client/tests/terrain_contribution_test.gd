extends Node
## Regression test for the frame capture's terrain-contribution control (#150).
##
## The capture's structural guards prove the terrain exists, is visible, is in
## front of the camera and would be drawn — none of them proves its material
## lands PIXELS. A fully transparent material, or a shader discarding every
## fragment, passes them all while the frame shows sky. The control closes that
## gap by measurement (hide the terrain; the frame must change where bare
## terrain was), and this test pins its two halves headlessly:
##
##  1. DESIGNATION, against the REAL generated world: at the committed
##     contribution vantage the bare-terrain sample floor holds (otherwise the
##     control would fail every healthy capture), and the designation is
##     falsifiable — a sky-facing camera designates nothing, so the floor has
##     teeth.
##  2. VERDICT, on synthetic frames (rendering is unavailable headless; the
##     verdict is a pure function so it can be pinned without a GPU):
##       - ground-to-sky change at the samples PASSES;
##       - a hidden frame identical to the live one — the transparent-material
##         signature — FAILS;
##       - wind-touched samples (moving across the LIVE pair) vouch for
##         NOTHING, in either direction;
##       - the sample floor, the quiet floor, the exact fraction threshold,
##         a mismatched frame size and an out-of-frame sample each fail by
##         name (non-vacuity: the floors are real lines, not vibes).
##
## Run: godot --headless --path client res://tests/terrain_contribution_test.tscn

const FrameCapture := preload("res://tools/frame_capture.gd")

## The viewport size the designation grid is projected onto. Any fixed size
## works — designation only needs rays through a grid — but using the shipped
## resolution keeps the sample geometry identical to the real capture's.
const VIEW := Vector2(1600.0, 900.0)

func _ready() -> void:
	# ── 1. Designation against the real world ────────────────────────────────
	var world := WorldGen.new()
	world.name = "World"
	add_child(world)
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 68.0
	add_child(cam)

	var vantage := _contribution_vantage()
	if vantage.is_empty():
		_fail("the contribution vantage '%s' is not in VANTAGES — the control would never run" %
			FrameCapture.CONTRIB_VANTAGE)
		return
	cam.global_position = vantage[1]
	cam.look_at(vantage[2], Vector3.UP)
	# Colliders register with the physics space a tick after add_child.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var pts := FrameCapture.designate_terrain_points(cam, world, VIEW)
	if pts.size() < FrameCapture.CONTRIB_MIN_POINTS:
		_fail("the contribution vantage designates only %d bare-terrain samples — under the capture's floor of %d, so the control would fail on a HEALTHY world" %
			[pts.size(), FrameCapture.CONTRIB_MIN_POINTS])
		return
	# Falsifiability: a camera framing only sky designates nothing, so the
	# floor genuinely fires when no terrain is in frame.
	cam.global_position = Vector3(0.0, 250.0, 0.0)
	cam.look_at(Vector3(10.0, 500.0, 0.0), Vector3.UP)
	var sky_pts := FrameCapture.designate_terrain_points(cam, world, VIEW)
	if not sky_pts.is_empty():
		_fail("a sky-facing camera designated %d terrain samples — the designation is not measuring the view" % sky_pts.size())
		return

	# ── 2. Verdict on synthetic frames ───────────────────────────────────────
	var ground := Color(0.40, 0.35, 0.30)
	var sky := Color(0.60, 0.70, 0.90)
	var wind_a := Color(0.20, 0.60, 0.25)
	var wind_b := Color(0.70, 0.50, 0.20)
	var samples := _grid_samples(60)

	# Real contribution: hiding the terrain turns every quiet sample into sky.
	var v := FrameCapture.terrain_contribution_verdict(
		samples, _flat(ground), _flat(ground), _flat(sky))
	if not bool(v["ok"]):
		_fail("a ground-to-sky change at every sample must PASS (got: %s)" % str(v["reason"]))
		return

	# The transparent-material signature: the hidden frame is identical to the
	# live one — the exact failure #150 names. It must FAIL.
	v = FrameCapture.terrain_contribution_verdict(
		samples, _flat(ground), _flat(ground), _flat(ground))
	if bool(v["ok"]):
		_fail("a hidden frame identical to the live one must FAIL — that is the transparent-material case the control exists to catch")
		return

	# Wind discount, damning direction: 30 of 60 samples move across the live
	# pair AND move again in the hidden frame — motion that must vouch for
	# nothing. The 30 quiet samples do not change, so the verdict must fail
	# on contribution with every noisy sample excluded from the count.
	var live_b := _flat(ground)
	var hidden := _flat(ground)
	for i in 30:
		var p := samples[i]
		live_b.set_pixel(p.x, p.y, wind_a)
		hidden.set_pixel(p.x, p.y, wind_b)
	v = FrameCapture.terrain_contribution_verdict(samples, _flat(ground), live_b, hidden)
	if bool(v["ok"]):
		_fail("wind-touched samples vouched for the terrain — the noise reference must discount them")
		return
	if int(v["quiet"]) != 30 or int(v["contributing"]) != 0:
		_fail("expected 30 quiet / 0 contributing with 30 wind-touched samples, got %d / %d — the discount is not sample-wise" %
			[int(v["quiet"]), int(v["contributing"])])
		return

	# Wind discount, healthy direction: the SAME 30 noisy samples, but now the
	# quiet 30 all turn to sky — wind must not poison a real contribution.
	var hidden_sky := _flat(ground)
	for i in 30:
		hidden_sky.set_pixel(samples[i].x, samples[i].y, wind_b)
	for i in range(30, 60):
		hidden_sky.set_pixel(samples[i].x, samples[i].y, sky)
	v = FrameCapture.terrain_contribution_verdict(samples, _flat(ground), live_b, hidden_sky)
	if not bool(v["ok"]):
		_fail("30 quiet samples all turning to sky must PASS despite 30 wind-touched ones (got: %s)" % str(v["reason"]))
		return

	# The exact fraction threshold is a real line: with 30 quiet samples,
	# ceil(30 * floor) contributing passes and one fewer fails.
	var need := int(ceilf(FrameCapture.CONTRIB_MIN_FRACTION * 30.0))
	v = FrameCapture.terrain_contribution_verdict(
		samples, _flat(ground), live_b, _quiet_sky_count(ground, sky, wind_b, samples, need))
	if not bool(v["ok"]):
		_fail("%d of 30 quiet samples contributing meets the %.0f%% floor and must PASS (got: %s)" %
			[need, FrameCapture.CONTRIB_MIN_FRACTION * 100.0, str(v["reason"])])
		return
	v = FrameCapture.terrain_contribution_verdict(
		samples, _flat(ground), live_b, _quiet_sky_count(ground, sky, wind_b, samples, need - 1))
	if bool(v["ok"]):
		_fail("%d of 30 quiet samples contributing is under the %.0f%% floor and must FAIL" %
			[need - 1, FrameCapture.CONTRIB_MIN_FRACTION * 100.0])
		return

	# The sample floor fires on a short designation.
	var few: Array[Vector2i] = []
	few.assign(samples.slice(0, FrameCapture.CONTRIB_MIN_POINTS - 1))
	v = FrameCapture.terrain_contribution_verdict(few, _flat(ground), _flat(ground), _flat(sky))
	if bool(v["ok"]):
		_fail("%d samples is under the %d floor and must FAIL" %
			[few.size(), FrameCapture.CONTRIB_MIN_POINTS])
		return

	# The quiet floor fires when everything moves: every sample noisy means
	# the measurement is impossible, and impossible must never read as pass.
	var all_windy := _flat(ground)
	for p in samples:
		all_windy.set_pixel(p.x, p.y, wind_a)
	v = FrameCapture.terrain_contribution_verdict(samples, _flat(ground), all_windy, _flat(sky))
	if bool(v["ok"]):
		_fail("a live pair with every sample moving must FAIL — nothing quiet is measurable")
		return

	# Mismatched frame sizes and an out-of-frame sample are contract breaches,
	# never passes.
	v = FrameCapture.terrain_contribution_verdict(
		samples, _flat(ground), _flat(ground), Image.create(8, 8, false, Image.FORMAT_RGBA8))
	if bool(v["ok"]):
		_fail("mismatched control-frame sizes must FAIL")
		return
	var stray: Array[Vector2i] = []
	stray.assign(samples)
	stray[0] = Vector2i(4000, 4000)
	v = FrameCapture.terrain_contribution_verdict(stray, _flat(ground), _flat(ground), _flat(sky))
	if bool(v["ok"]):
		_fail("a sample outside the frame must FAIL, not read whatever memory says")
		return

	print("TEST PASS — the terrain-contribution control designates the real world and its verdict holds on both sides")
	get_tree().quit(0)


## The committed vantage the control runs at, straight out of the tool's own
## table — if the tool renames or drops it, this test fails by name instead of
## the control silently never running.
func _contribution_vantage() -> Array:
	for v: Array in FrameCapture.VANTAGES:
		if v[0] == FrameCapture.CONTRIB_VANTAGE:
			return v
	return []


## A hidden frame in which exactly `count` of the 30 quiet samples (indices
## 30..59) turned to sky, the noisy 30 moved as wind does, and the rest stayed
## ground — the knob the threshold-pinning cases turn.
func _quiet_sky_count(ground: Color, sky: Color, wind: Color, samples: Array[Vector2i], count: int) -> Image:
	var img := _flat(ground)
	for i in 30:
		img.set_pixel(samples[i].x, samples[i].y, wind)
	for i in range(30, 30 + count):
		img.set_pixel(samples[i].x, samples[i].y, sky)
	return img


## A flat single-colour frame.
func _flat(colour: Color) -> Image:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	return img


## `count` distinct in-frame sample points on a grid.
func _grid_samples(count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in count:
		out.append(Vector2i(2 + (i % 10) * 6, 2 + int(i / 10.0) * 6))
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
