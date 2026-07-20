extends Node
## Measures how much each captured frame CHANGED against the same vantage
## rendered from the merge base, so the evidence job reports the change under
## review rather than only "something rendered".
##
## Why this exists (#231): frame_capture's own guard is MIN_LUMA_SPREAD — a
## global min/max over a 16x12 grid of the whole frame. It answers "did
## anything render?" and is structurally incapable of answering "is the change
## under review present?".
##
## Reproduced first-hand while building this, on three captures off one
## checkout — fog off, fog off again, fog ON. The spread guard reported sunward
## 0.541 and crossfield 0.235 for ALL THREE, to three decimals, including the
## build whose fog is plainly visible in the frame. Compared against the base,
## the same sunward frame moves 0.01% of its pixels between the two identical
## builds and 21.01% with the fog on. The information was in the frames the
## whole time; the guard does not look for it. (#231 reports the same shape on
## #218's ash pools: three builds, one spread of 0.541.)
##
## REPORTING ONLY. This tool prints numbers and writes them next to each frame;
## it applies no threshold to them. A legitimate no-visual-change PR must not
## fail, and choosing a pass/fail band is a separate decision that needs a
## measured distribution first (#231 says so explicitly). What IS enforced here
## is the tool's own honesty: a run that can compare nothing fails loudly rather
## than reporting an empty set, because a comparison that silently measures zero
## frames would be the same self-attestation the evidence job exists to replace.
##
## Run:
##   WAR_DIFF_BASE=/tmp/shots-base WAR_DIFF_HEAD=/tmp/shots \
##     godot --headless --path client res://tools/frame_diff.tscn
##
## Headless is fine — unlike frame_capture this renders nothing, it only reads
## PNGs off disk.

## Largest single-channel difference (0-1) at which a pixel counts as CHANGED.
##
## Calibrated by measurement on this repo's own frames, not chosen by taste.
## Renders drift a little even with nothing changed — temporal antialiasing,
## volumetric fog reprojection, SDFGI convergence, wind-swayed foliage and
## animated torches all move pixels — so the floor has to clear that drift
## without swallowing a real change.
##
## Measured three ways. "Back-to-back" is two runs in one session off one
## checkout. "Across builds" is a base worktree vs this branch — what CI
## actually does — taken both locally and on the runner. "Fog on" switches the
## hollow fog on: a LOCALIZED volumetric change of the class #231 was filed
## about.
##
##   vantage        back-to-back    across builds (local / CI)    fog on
##   sunward               0.01%       0.02%  /  0.06%           21.01%
##   crossfield            0.03%       0.09%  /  0.03%            0.04%  <- fog not in view
##   shrine                0.03%       0.78%  /  0.37%            2.69%
##   cave-chamber          0.01%       7.01%  /  5.72%            4.19%
##   cave-walkout          9.05%      11.40%  / 25.20%           25.02%
##
## Three things in that table matter more than the epsilon itself.
##
## First, crossfield is a natural control: the fog is not in that view, so it
## stays at the floor while four other vantages move. The report localizes a
## change to the views that contain it.
##
## Second — and this CORRECTS a reading taken from the back-to-back column
## alone — the torch-lit cave vantages have a floor of roughly 5%-25%, not the
## 0.01% a back-to-back pair suggests. Two runs in one session land on the same
## torch animation phase and understate the drift by orders of magnitude, while
## the across-builds figures agree within their own spread on two different
## machines. Never calibrate a floor like this from repeated runs of ONE build.
##
## Third, cave-chamber's across-builds floor (5.72%-7.01%) is LARGER than the
## real change the fog makes in that same view (4.19%). A threshold there would
## be pure noise. So: this slice reports rather than judges, and any future gate
## has to be per-vantage, calibrated on CI rather than a workstation, and would
## start with the daylight vantages — sunward, crossfield and shrine all sit
## under 1% across builds. The numbers are comparable for the SAME vantage
## across builds, which is the comparison a reviewer makes; they are not
## comparable between vantages.
const CHANGED_EPS := 0.01

## NOTE: deliberately no luminance weights here. An earlier revision measured
## Rec. 709 luma to stay comparable with the spread figures frame_capture
## prints, and that was the wrong trade: comparability with a guard this tool
## exists to supplement is worth less than seeing hue change at all. See the
## per-pixel loop in compare_images() for the arithmetic and the worked example.


func _ready() -> void:
	var base_dir := OS.get_environment("WAR_DIFF_BASE")
	var head_dir := OS.get_environment("WAR_DIFF_HEAD")
	if base_dir.is_empty() or head_dir.is_empty():
		_fail("WAR_DIFF_BASE and WAR_DIFF_HEAD must both be set — nothing to compare")
		return

	var head_frames := _frames_in(head_dir)
	if head_frames.is_empty():
		_fail("no PNGs in the head directory '%s' — the capture step should have failed before this ran" % head_dir)
		return

	# Frames present in head but NOT in base are reported, never skipped
	# silently: a PR that ADDS a vantage has nothing to compare it against, and
	# saying so is the honest report. The same line would appear if a base
	# capture half-failed, which is exactly when a reader needs to know the
	# numbers below cover less than the frame set.
	var compared := 0
	var unmatched: Array[String] = []
	var incomparable: Array[String] = []

	# Frames the BASE has and the head does NOT are a removal, and they must be
	# named. `client/tools/` deliberately triggers this job so the capture tool
	# validates itself — so a tool change that drops one of the committed
	# vantages is exactly the regression this job should catch, and iterating
	# only the head list would let it pass silently as long as one other vantage
	# still compared.
	var removed: Array[String] = []
	for base_name: String in _frames_in(base_dir):
		if not FileAccess.file_exists("%s/%s.png" % [head_dir, base_name]):
			removed.append(base_name)
			print("DIFF %s — REMOVED: the base captured this vantage and the head did not" % base_name)

	for frame_name: String in head_frames:
		var base_path := "%s/%s.png" % [base_dir, frame_name]
		var head_path := "%s/%s.png" % [head_dir, frame_name]
		if not FileAccess.file_exists(base_path):
			unmatched.append(frame_name)
			print("DIFF %s — no base frame (new vantage, or the base capture did not produce it)" % frame_name)
			continue
		var base_img := Image.load_from_file(base_path)
		var head_img := Image.load_from_file(head_path)
		if base_img == null or head_img == null:
			incomparable.append(frame_name)
			print("DIFF %s — could not read one of the frames" % frame_name)
			continue
		var result := compare_images(base_img, head_img)
		if not result["ok"]:
			incomparable.append(frame_name)
			print("DIFF %s — %s" % [frame_name, result["reason"]])
			continue
		compared += 1
		var line := "changed %.2f%% of pixels, mean |dRGB| %.4f, max %.4f" % [
			(result["changed_fraction"] as float) * 100.0,
			result["mean"],
			result["max"],
		]
		print("DIFF %s — %s" % [frame_name, line])
		_append_note(head_dir, frame_name, line)

	# The non-vacuity floor. Everything above can report "nothing to compare"
	# on every single frame and still reach here having proved nothing at all —
	# a stale base directory, a path typo, or a base capture that wrote its
	# frames somewhere else all look identical to a clean no-op PR unless this
	# refuses. Fail closed: an evidence tool that measures nothing must say so.
	if compared == 0:
		_fail("compared 0 frames of %d (unmatched %d, incomparable %d) — the base render is missing or unreadable, so this run measured nothing" %
			[head_frames.size(), unmatched.size(), incomparable.size()])
		return

	print("DIFF PASS — compared %d of %d frames against the base (unmatched %d, incomparable %d, REMOVED %d)" %
		[compared, head_frames.size(), unmatched.size(), incomparable.size(), removed.size()])
	get_tree().quit(0)


## Per-pixel luminance comparison of two frames.
##
## Per-PIXEL on purpose: frame_capture's spread guard samples a 16x12 grid, and
## a localized effect — a fog pool, a light, a decal, one surface's material —
## can miss every one of those 192 points entirely. Walking the whole frame is
## what makes a localized change visible to the report at all.
##
## Static and pure so the test can drive it on constructed images without
## rendering anything.
##
## Returns {ok, reason, mean, max, changed_fraction, pixels}.
static func compare_images(base: Image, head: Image) -> Dictionary:
	var out := {"ok": false, "reason": "", "mean": 0.0, "max": 0.0, "changed_fraction": 0.0, "pixels": 0}
	if base.get_width() != head.get_width() or base.get_height() != head.get_height():
		# A real case, not a theoretical one: a hosted runner clamps the window
		# to what its display allows, so a base and head captured on differently
		# sized displays produce differently sized frames. Rescaling one to fit
		# would invent pixel differences everywhere and report a huge change for
		# a PR that changed nothing, which is worse than declining to measure.
		out["reason"] = "size mismatch (base %dx%d, head %dx%d) — not comparable without rescaling, which would invent differences" % [
			base.get_width(), base.get_height(), head.get_width(), head.get_height()]
		return out
	var pixels := base.get_width() * base.get_height()
	if pixels == 0:
		out["reason"] = "empty frame"
		return out

	# Convert once to a known layout and walk the bytes. get_pixel() over 1.4M
	# pixels is minutes of GDScript; this is seconds.
	var b := base.duplicate() as Image
	var h := head.duplicate() as Image
	b.convert(Image.FORMAT_RGBA8)
	h.convert(Image.FORMAT_RGBA8)
	var bd := b.get_data()
	var hd := h.get_data()
	if bd.size() != hd.size():
		out["reason"] = "frame buffers differ in size after conversion"
		return out

	var total := 0.0
	var worst := 0.0
	var changed := 0
	var i := 0
	while i < bd.size():
		# Largest single-channel difference, NOT a luminance difference.
		#
		# Luminance alone is BLIND TO HUE, and not marginally: Rec. 709 weights
		# make pure red (255,0,0) and a dark green (0,76,0) differ by 0.0006 —
		# so recolouring an entire frame from red to green would report as
		# UNCHANGED under a luma-only test, well below any sane epsilon. On this
		# repo that is the common case rather than an exotic one: the open art
		# work is about ground palette, cave hue variety and colour grading, and
		# the art-direction reference set explicitly measures hue span alongside
		# value range. A change report blind to colour would have quietly given
		# every one of those PRs a confident 0%.
		#
		# Max-channel is deliberately NOT a perceptual metric. This reports how
		# much the image DATA moved, which is the honest thing for evidence; a
		# perceptual distance would additionally encode assumptions about
		# viewing conditions that a reviewer opening a PNG does not share.
		var dr := absf(float(hd[i]) - float(bd[i]))
		var dg := absf(float(hd[i + 1]) - float(bd[i + 1]))
		var db := absf(float(hd[i + 2]) - float(bd[i + 2]))
		var d := maxf(dr, maxf(dg, db)) / 255.0
		total += d
		if d > worst:
			worst = d
		if d > CHANGED_EPS:
			changed += 1
		i += 4

	out["ok"] = true
	out["mean"] = total / float(pixels)
	out["max"] = worst
	out["changed_fraction"] = float(changed) / float(pixels)
	out["pixels"] = pixels
	return out


## The frame names (basenames without .png) present in a directory.
static func _frames_in(dir_path: String) -> Array[String]:
	var names: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return names
	for f: String in d.get_files():
		if f.ends_with(".png"):
			names.append(f.get_basename())
	# Sorted so the report reads the same way run to run.
	names.sort()
	return names


## Appends the comparison to the frame's own note, so the uploaded artifact
## carries what the log knows — a reviewer opening the frames does not have the
## job log beside them. Best-effort: a note that cannot be written must never
## fail a comparison that succeeded.
func _append_note(dir: String, frame: String, line: String) -> void:
	var path := "%s/%s.txt" % [dir, frame]
	var existing := ""
	if FileAccess.file_exists(path):
		var r := FileAccess.open(path, FileAccess.READ)
		if r != null:
			existing = r.get_as_text()
			r.close()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("could not write the diff note for %s" % frame)
		return
	if not existing.is_empty():
		f.store_string(existing)
		if not existing.ends_with("\n"):
			f.store_string("\n")
	f.store_line("vs base: %s" % line)
	f.close()


func _fail(message: String) -> void:
	push_error(message)
	print("DIFF FAIL — %s" % message)
	get_tree().quit(1)
