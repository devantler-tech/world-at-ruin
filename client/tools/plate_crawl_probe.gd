extends Node
## Measures ground crawl (#306) — the shimmer a still frame cannot show.
##
## Crawling is TEMPORAL, so the committed capture vantages cannot carry evidence
## about it either way. This drives the camera sideways in sub-pixel steps and
## reports how the ground pixels respond. It runs windowed and is NOT part of
## the suite: like `frame_capture`, it needs a real GPU, and a headless run
## renders nothing.
##
##   WAR_GROUND_PLATES=1 WAR_SAVE_PATH=… WAR_VAULT_PATH=… \
##   WAR_BOOT_RECOVERY_PATH=… godot --path client res://tools/plate_crawl_probe.tscn
##
## READ THE TWO LINES DIFFERENTLY — this is the whole subtlety of the measure,
## and a single number is actively misleading here:
##
##   PROBE — how much the ground moves per step. A filtered surface is a
##     gradient, so it moves a little at MANY pixels; an aliased one is flat
##     over plate interiors and moves at NONE of them until an edge snaps. So a
##     LOWER PROBE number is evidence of aliasing, not of quality, and this line
##     is context rather than a verdict.
##   SNAP — per pixel, the largest single step it ever takes. A filtered edge
##     sliding under the camera spreads its change across the sweep; an aliased
##     edge holds still and then jumps the full contrast between two substances.
##     The tail (>0.20, >0.30) is the shimmer signature, and it is the only part
##     of either line that answers the question.
##
## Always run `WAR_GROUND_PLATES=0` as a control: the world animates (people,
## hounds, wind, torches) and that floor must be subtracted before any plate
## claim. It also proves a change touched only the plate path — the control is
## stable to ~0.0005 percentage points run over run.

const WARMUP := 30
const STEPS := 12

## Per-pixel luma-change thresholds, reported as a distribution.
const BUCKETS := [0.02, 0.05, 0.10, 0.15, 0.20, 0.30]

## ~0.25 px of image motion per step at the vantage's ~60 m depth, so every
## step is firmly sub-pixel and any large pixel change is aliasing, not parallax.
const STEP_M := 0.02

## crossfield: the medium-distance broad ground read where #306 reports crawl.
const EYE := Vector3(55.0, 11.0, 40.0)
const LOOK := Vector3(-10.0, 3.0, -20.0)

## Ground region of the 1600x900 frame: right of the creator panel, below the
## horizon. Measuring the whole frame would dilute the signal with sky and UI.
const X0 := 400
const X1 := 1590
const Y0 := 500
const Y1 := 890


func _ready() -> void:
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	var main: Node = load(main_scene).instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	if not main.is_inside_tree():
		print("PROBE FAIL — main scene never attached")
		get_tree().quit(1)
		return

	for i in WARMUP:
		await get_tree().process_frame

	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 68.0
	get_tree().root.add_child(cam)
	cam.global_position = EYE
	cam.look_at(LOOK, Vector3.UP)
	cam.make_current()

	# Slide along the camera's own right vector so every step is pure lateral
	# motion — a step with any depth component would change scale as well.
	var right := cam.global_transform.basis.x.normalized()

	var prev: Image = null
	var prev_luma := PackedFloat32Array()
	var pixel_peak := PackedFloat32Array()
	pixel_peak.resize((X1 - X0) * (Y1 - Y0))
	var mean_sum := 0.0
	var bucket_sum := PackedFloat64Array()
	bucket_sum.resize(BUCKETS.size())
	var worst := 0.0
	var pairs := 0
	for step in STEPS:
		cam.global_position = EYE + right * (STEP_M * float(step))
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var luma := _luma_plane(img)
		if prev_luma.size() > 0:
			var m := _luma_delta_stats(prev_luma, luma)
			mean_sum += float(m["mean"])
			var hist: Array = m["hist"]
			for i in BUCKETS.size():
				bucket_sum[i] += float(hist[i])
			worst = maxf(worst, float(m["max"]))
			pairs += 1
			# Per pixel, the LARGEST single step it ever takes. A correctly
			# filtered edge sliding under the camera spreads its change evenly
			# across the sweep, so this stays small; an aliased edge holds still
			# and then snaps the full contrast between two substances in one
			# step, which is exactly what reads as shimmer.
			for i in luma.size():
				var d := absf(luma[i] - prev_luma[i])
				if d > pixel_peak[i]:
					pixel_peak[i] = d
		prev_luma = luma
		prev = img

	# Report the whole DISTRIBUTION rather than one threshold. The two surfaces
	# fail differently and a single cutoff cannot separate them: a filtered
	# surface is a gradient, so many pixels slide a little on every step, while
	# an aliased one is flat over plate interiors and instead flips a few pixels
	# by the full contrast between two substances. A low threshold counts the
	# harmless sliding; only the tail is shimmer.
	var line := "PROBE pairs=%d step_m=%.3f mean=%.5f max=%.4f" % [
		pairs, STEP_M, mean_sum / float(pairs), worst]
	for i in BUCKETS.size():
		line += " >%.2f=%.4f%%" % [BUCKETS[i], 100.0 * bucket_sum[i] / float(pairs)]
	print(line)

	# THE discriminator: how many pixels ever SNAP, rather than slide.
	var snap := PackedFloat64Array()
	snap.resize(BUCKETS.size())
	for v in pixel_peak:
		for i in BUCKETS.size():
			if v > BUCKETS[i]:
				snap[i] += 1.0
	var snapline := "SNAP  per-pixel max single step, share of ground pixels:"
	for i in BUCKETS.size():
		snapline += " >%.2f=%.4f%%" % [
			BUCKETS[i], 100.0 * snap[i] / float(pixel_peak.size())]
	print(snapline)
	get_tree().quit(0)


func _luma_plane(img: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize((X1 - X0) * (Y1 - Y0))
	var k := 0
	for y in range(Y0, Y1):
		for x in range(X0, X1):
			var c := img.get_pixel(x, y)
			out[k] = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			k += 1
	return out


func _luma_delta_stats(a: PackedFloat32Array, b: PackedFloat32Array) -> Dictionary:
	var sum := 0.0
	var worst := 0.0
	var hist := PackedFloat64Array()
	hist.resize(BUCKETS.size())
	for i in a.size():
		var d := absf(a[i] - b[i])
		sum += d
		for k in BUCKETS.size():
			if d > BUCKETS[k]:
				hist[k] += 1.0
		worst = maxf(worst, d)
	for k in BUCKETS.size():
		hist[k] /= float(a.size())
	return {"mean": sum / float(a.size()), "hist": hist, "max": worst}
