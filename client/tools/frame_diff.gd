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
## Measured three ways, ALL RE-TAKEN after the metric became chroma-aware (the
## earlier luma-only figures are not comparable and have been dropped).
## "Back-to-back" is two runs in one session off one checkout. "Across builds"
## is a base worktree vs this branch — what CI actually does. "Fog on" switches
## the hollow fog on: a LOCALIZED volumetric change of the class #231 names.
##
##   vantage        back-to-back    across builds    fog on
##   sunward               0.02%           0.02%     22.57%
##   crossfield            0.04%           0.17%      0.05%   <- fog not in view
##   shrine                0.03%           3.03%      2.81%
##   cave-chamber          0.58%          31.18%     25.09%
##   cave-walkout         35.66%          33.57%     44.60%
##
## Four things in that table matter more than the epsilon itself.
##
## First, crossfield is a natural control: the fog is not in that view, so it
## holds at the floor while other vantages move. The report localizes a change
## to the views that actually contain it.
##
## Second, never calibrate a floor from BACK-TO-BACK runs of one build. Two runs
## in one session land on the same torch animation phase: cave-chamber reads
## 0.58% back-to-back and 31.18% across independent builds. Comparing separate
## builds is the honest measurement because it is what CI performs.
##
## Third — and this is the cost of seeing hue at all — the torch-lit vantages
## are NOISE-DOMINATED. cave-chamber's across-builds floor (31.18%) EXCEEDS the
## real change the fog makes in that same view (25.09%), and shrine's floor
## (3.03%) exceeds its own signal (2.81%). Animated torch light genuinely
## recolours those frames between any two renders, and a chroma-aware metric is
## right to say so; no metric can separate "the torch moved" from "the art
## changed" when both recolour the same pixels. The luma-only metric looked
## calmer here only because it was blind to the colour change it was measuring.
##
## Fourth, therefore: this slice REPORTS and does not judge, and only sunward
## and crossfield are candidates for a future gate — they hold at 0.02%-0.17%
## across builds while sunward moves 22.57% on a real change, a separation of
## three orders of magnitude. Any gate must be per-vantage and calibrated on CI.
## The numbers are comparable for the SAME vantage across builds, which is the
## comparison a reviewer makes; they are not comparable between vantages.
##
## ## The first_run_* set (#519, part of #485)
##
## Those frames are mostly a LIVE 3D PORTRAIT — the creator's panel takes the
## left band only, and 29 bodies breathe in shot. Until #519 the breath ran on
## accumulated wall-clock time while the capture settled a fixed number of
## FRAMES, so the pose at the shutter depended on render speed. Two runs of
## IDENTICAL code, same machine:
##
##   frame                   unpinned    pinned
##   first_run_elder           53.74%     0.47%
##   first_run_villager        46.63%     0.01%
##   first_run_brute           31.67%     0.01%
##   first_run_base_layer      24.21%     0.60%
##   first_run_head_clothing   19.18%     0.01%
##   first_run                 16.70%     0.01%
##   first_run_lower           14.13%     0.00%
##   first_run_wanderer         9.18%     0.01%
##   first_run_advanced_1       3.62%     0.01%
##   first_run_head_armor       3.01%     0.01%
##   first_run_outfit           2.58%     0.01%
##
## ⚠️ THE PINNED COLUMN IS NOT A CI FLOOR, and must not be used as one. It is
## two runs on ONE machine — precisely the back-to-back shape the second lesson
## above warns reads too low. It establishes that the breath clock was the
## DOMINANT source and that it is gone. The independent-build floor it defers to
## is the next section.
##
## ## The independent-build floor for `first_run_*` (#485): THERE ISN'T ONE
##
## Measured on CI as #485 requires — three independent builds of a
## capture-tool-only PR (#495, `client/tools/frame_capture.gd`), which cannot
## change what the creator draws. Per-vantage changed-pixel fraction, and the
## MAX each vantage reached across the three:
##
##   frame                    2a5ddb5   333a035   efca51d       MAX
##   first_run_advanced_2       0.00%    39.40%     6.99%     39.40%
##   first_run_head_armor       0.02%    27.91%     2.39%     27.91%
##   first_run_advanced_3       2.17%    28.14%     0.39%     28.14%
##   first_run_wanderer         0.78%    25.12%    25.82%     25.82%
##   first_run_head_clothing    0.01%    23.41%     0.02%     23.41%
##   first_run_lower            0.00%     5.25%    23.36%     23.36%
##   first_run_base_layer      19.31%    14.41%     1.12%     19.31%
##   first_run_villager         0.01%    17.58%     1.49%     17.58%
##   first_run_brute            3.16%    10.33%     2.85%     10.33%
##   first_run_outfit           0.01%     7.16%     0.07%      7.16%
##   first_run                  0.01%     6.34%     0.78%      6.34%
##   first_run_elder            0.02%     4.12%     0.10%      4.12%
##   first_run_advanced_1       0.01%     2.52%     0.04%      2.52%
##   ---- world vantages, same three builds ----
##   shrine                     0.37%     1.59%     3.81%      3.81%
##   cave-chamber               0.20%     0.49%     0.41%      0.49%
##   crossfield                 0.10%     0.26%     0.18%      0.26%
##   bonepale                   0.14%     0.20%     0.16%      0.20%
##   sunward                    0.13%     0.15%     0.17%      0.17%
##   cave-walkout               0.13%     0.00%     0.00%      0.13%
##
## Two things in that table settle the question #485 asked.
##
## First, the variance is NOT PER-VANTAGE, so a per-vantage floor cannot
## express it. A different subset blows up in each build — base_layer in the
## first, advanced_2/head_armor/head_clothing in the second, lower/wanderer in
## the third — while the same vantage reads at the floor in the other two.
##
## Second, the floor it would need EXCEEDS THE SIGNAL. The highest reading here
## is 39.40% on a build that cannot have changed the creator; the real creator
## change #485 records on #320 read 36.59%. That is the torch-lit shape again —
## noise above signal — so no threshold on the whole frame can separate them,
## and `first_run_*` is not a gate candidate. Only sunward and crossfield are.
##
## ## Where that residual actually is (#485): the BACKDROP, not the subject
##
## Localized between two of those builds whose first-run rendering code is
## behaviourally identical — both files that differ change COMMENT PROSE only,
## one inside `_capture_mouth` and one in a cave-vantage test, and the first-run
## path executes neither — by splitting each frame at the panel's own band
## (`UI_SAMPLE_X0/X1`,
## 0.02-0.30 of width) and counting changed pixels on each side:
##
##   frame                     whole    panel band    world band
##   first_run_lower          40.46%         0.00%        56.22%
##   first_run_wanderer       35.02%         0.01%        48.65%
##   first_run_advanced_2     34.48%         0.00%        47.91%
##   first_run_head_armor     18.04%         0.01%        25.07%
##   first_run_base_layer      9.96%         0.01%        13.83%
##
## The panel holds at 0.00%-0.01% on every first-run frame. Rendering the mask
## shows the rest: the CHARACTER PORTRAIT is clean too — its silhouette, face
## and clothing carry no changed pixels, and neither do the four preset
## thumbnails inside the panel. What moves is the terrain behind them, and
## nearly all of it.
##
## So both subjects these frames exist to evidence — the panel and the body —
## already repeat across independent builds. The number printed for them does
## not, because it is dominated by a live backdrop that no first-run PR is
## about. A reviewer reading 40% is reading scenery.
##
## The backdrop is unpinned by construction: `_shoot` pins the breath and
## nothing else, while the cave scenario calls `freeze_flicker()` and the
## light-response scenario freezes its animation. Fixing that is #556.
##
## ## The cave-mouth vantage (#495)
##
## The entrance grammar — two jamb slabs, six flanking boulders and the massif
## face over the bore — was photographed by NOTHING: on #492 an entrance-rock
## recolour moved all six committed vantages by 0.01%-0.29%, their noise floor.
## `cave-walkout` sounds like the missing shot and is not; it looks out from
## INSIDE the chamber. Re-running that isolation with the exterior vantage
## added, one machine, entrance rock recoloured (0.41, 0.36, 0.30) ->
## (0.30, 0.34, 0.42):
##
##   vantage         repeat run    entrance rock recoloured
##   cave-mouth           0.01%                      13.64%   <- the new frame
##   crossfield           0.16%                       0.13%
##   sunward              0.12%                       0.09%
##   shrine               0.08%                       0.12%
##   bonepale             0.08%                       0.11%
##   cave-walkout         0.00%                       0.10%
##   cave-chamber         0.02%                       0.05%
##
## The load-bearing comparison is DOWN the second column, not across the row:
## it is one arm, so it needs no cross-run calibration and is not exposed to the
## back-to-back lesson above. In the build that recoloured the entrance rock the
## new vantage moves 13.64% of its pixels (mean |dRGB| 0.0114) while every older
## vantage stays inside the 0.05%-0.13% band it occupies when nothing changed —
## two orders of magnitude, and the localization property crossfield
## demonstrates for fog, now holding for the doorway.
##
## ⚠️ The first column is NOT a CI floor either, for the same reason the pinned
## breath column is not: two runs on one machine. It is here to show the frame
## is reproducible at all (this vantage pins the torch flicker, so it is not
## noise-dominated the way the interior ones were before #321) — not to license
## a gate. A gate still needs the independent-build measurement #485 asks for.
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

	# Frames that produced NO comparison get their own marker line, on the same
	# reasoning as REMOVED above. The per-frame lines are already honest, but
	# they sit in a 25-row table under a PASS verdict and nothing acts on them:
	# the workflow greps for `REMOVED:` alone. So a PR can be told PASS while a
	# whole scenario carried no comparison at all — measured on #455, where 6 of
	# 25 frames went uncompared and the job raised not one annotation.
	var uncompared_report := uncompared_line(unmatched, incomparable)
	if uncompared_report != "":
		print(uncompared_report)

	print("DIFF PASS — compared %d of %d frames against the base (unmatched %d, incomparable %d, REMOVED %d)" %
		[compared, head_frames.size(), unmatched.size(), incomparable.size(), removed.size()])
	get_tree().quit(0)


## The uncompared frames' own verdict line, or "" when every frame compared.
##
## Covers BOTH ways a frame can reach the summary without a measurement, because
## a reader cannot act on the difference and the consequence is identical:
##   * `unmatched`    — the base never produced that frame.
##   * `incomparable` — both frames exist but one is unreadable, or the pair was
##     refused (the size mismatch that display clamping causes). Reporting only
##     the first would leave this class buried under PASS, which is the very
##     problem this marker exists to fix.
##
## Uppercase `UNCOMPARED:` with a colon is the greppable token, chosen so it
## cannot collide with the lowercase `unmatched %d` / `incomparable %d` the PASS
## summary prints on EVERY run — a token matching both would warn on every clean
## PR, which is as useless as warning on none. `frame_diff_test.gd` pins that
## separation.
##
## Returns "" rather than a "0 uncompared" line for the same reason: a clean run
## must leave the workflow's grep with nothing to find.
static func uncompared_line(unmatched: Array[String], incomparable: Array[String]) -> String:
	var parts: Array[String] = []
	if not unmatched.is_empty():
		parts.append("no base frame: %s" % ", ".join(unmatched))
	if not incomparable.is_empty():
		parts.append("unreadable or refused: %s" % ", ".join(incomparable))
	if parts.is_empty():
		return ""
	return "DIFF UNCOMPARED: %d frame(s) carry no base comparison and are NOT evidence for this PR — %s" % [
		unmatched.size() + incomparable.size(),
		"; ".join(parts),
	]


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
