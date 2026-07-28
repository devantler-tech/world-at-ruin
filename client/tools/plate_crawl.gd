extends Node
## Measures how hard the ground FLICKERS when the camera moves a fraction of a
## pixel (#306), so "it no longer crawls" is a number rather than an opinion.
##
## Crawling is a temporal artifact, so a still frame cannot evidence it. What it
## really is: a fragment decision with no width. Where the plate partition hands
## a fragment its owning cell outright, the substance and the slab mask are step
## functions of that cell, so a boundary is an edge of zero width. Slide the
## camera a quarter of a pixel and every pixel the boundary crosses does not
## shade — it SWAPS, by the whole contrast between two substances. Repeat at
## walking pace and that is the shimmer.
##
## So the measurement is exactly that: settle a frame, move the camera by a
## FRACTION OF ONE PIXEL of ground, settle again, and ask how far any pixel
## moved. A band-limited surface answers with roughly the fraction it was
## nudged. An unfiltered step answers with the full contrast.
##
## ## The control is built in, and it is the whole reason the number means
## ## anything
##
## The plate treatment is opt-in, so the SAME camera walk with `plates_enabled`
## off measures everything that is not the plates — geometry, the ash/rock
## contact, grain, and whatever the temporal passes have not settled. That is
## the noise floor, MEASURED rather than assumed, on this machine and this
## frame ([[war-cave-capture-noise-floor]]: a delta below an unmeasured floor is
## unfalsifiable). The plate contribution is the ON reading above the OFF one,
## and both halves come out of one world build under one set of lights, so the
## two cannot disagree about anything except the thing under test.
##
## A run therefore also fails when the floor is NOT quiet: if the off state
## already flickers as hard as the on state, this vantage cannot see plates at
## all and its verdict would be vacuous either way.
##
## ## What the control does NOT make portable — read this before quoting a number
##
## Everything above compares two readings taken seconds apart in one process, so
## it holds on any machine. The contribution's ABSOLUTE LEVEL does not. The same
## unmodified shader measures 0.0027 on one Apple Silicon Mac and 0.0074 on
## another at the same resolution, each reproducing to the digit, each with the
## control at 0.0000 (#439). Both are right; they are not the same number, and
## the cause is not established.
##
## So this tool reports the contribution and does not judge it, unless you set
## `WAR_CRAWL_MAX` to a budget you measured HERE. **To compare two builds, run
## both on one machine in one sitting and diff the readings** — never against a
## figure recorded elsewhere, including the reference in this file.
##
## Run (must be WINDOWED — a headless run renders nothing at all):
##   WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client --resolution 1280x720 res://tools/plate_crawl.tscn
##
## Add `WAR_CRAWL_MAX=<budget>` to turn the report into a pass/fail gate against
## a baseline of your own.
##
## Redirect all three save seams: this boots the real launch path, so an
## unredirected run writes the player's own save, vault and recovery ledger
## exactly as `frame_capture` warns.

## Where the camera stands and what it looks at. Chosen so the crop below is
## filled by ground at 20–45 m — the middle distance the artifact lives at. A
## plate is ~1.2 m across, which is ~26 px tall at 30 m in a 720-line frame: far
## too big to be dissolving into the distance mean, and far too small for its
## boundary to be anything but subpixel. Nearer than this the boundary resolves
## on its own; further and `plate_resolved` has already collapsed the plates to
## their mean and there is nothing left to alias.
const EYE := Vector3(34.0, 3.4, 26.0)
const TARGET := Vector3(2.0, 0.6, -6.0)
## Ground distance at the centre of the crop, metres. Used only to turn the
## camera's angular pixel size into a world step.
const CROP_DISTANCE := 30.0

## The crop, as fractions of the frame. Deliberately a band across the lower
## middle: it is ground all the way across at this vantage, so a rock silhouette
## or the horizon cannot contribute a hard edge that has nothing to do with
## plates. (The off-state control would absorb such an edge anyway, but keeping
## it out of the crop keeps the two readings close enough to compare directly.)
const CROP := Rect2(0.10, 0.58, 0.80, 0.30)

## How far to slide the camera between frames, as a fraction of one pixel of
## ground at CROP_DISTANCE. A quarter pixel is small enough that a correctly
## filtered surface must respond proportionally, and large enough to guarantee
## a zero-width edge crosses a pixel centre somewhere in a crop this size.
## CROP_DISTANCE is nominal: the crop spans a range of ground distances, so this
## is the scale of the step rather than an exact quarter pixel everywhere. It
## does not need to be exact — it needs to be SMALL, and identical between the
## two states, which it is.
const STEP_PIXELS := 0.25
## Number of camera positions per state. Four quarter-pixel steps walk the
## camera across a whole pixel, so every phase of the pixel grid is sampled and
## a boundary cannot hide by sitting still between samples.
const STEPS := 4

## Frames to let the world build before the first shot. Same reasoning as
## `frame_capture`: generation is synchronous but shaders, shadow cascades and
## SDFGI need frames.
const WARMUP_FRAMES := 150
## Frames to settle after each camera move. Volumetric fog reprojects temporally
## and SDFGI re-converges, so an early capture photographs a half-resolved frame
## — which would read as crawl that the shader had nothing to do with.
const SETTLE_FRAMES := 90

## A REFERENCE reading, not a limit, and deliberately not a gate by default.
##
## On the machine #398 was measured on, the ground flickered 0.0052 of the crop
## before the crack relief was made to dissolve on its own footprint and 0.0027
## after; zeroing `crack_relief` outright gives 0.0000, which is the floor the
## remaining work is against. **Those figures reproduced to the digit across
## repeat runs ON THAT MACHINE.** That is all they were ever evidence for, and
## the earlier wording here — "reproduced to the digit across repeat runs" with
## no such qualifier — read as a much stronger claim than it supports.
##
## The absolute level is NOT portable. The same unmodified shader measured
## 0.0074 on another Apple Silicon Mac at the same resolution, reproducing to
## the digit there too, with the plates-off control at 0.0000 in both places
## (#439). Both readings are internally consistent; they simply are not the same
## number. The cause is not established, so nothing here should pretend to
## normalise it away.
##
## Which is why this is not compared against anything unless the caller asks.
## A constant calibrated on one machine, applied everywhere, does not detect a
## regression — it reports one against code that is fine, and the failure text
## points confidently at the crack relief while doing it. That is worse than no
## gate, because it takes a reader through git history to disbelieve.
const REFERENCE_CONTRIBUTION := 0.0027
## The environment this reference was taken in, named so a reader can tell at a
## glance whether their own number is comparable.
const REFERENCE_ENVIRONMENT := "Apple M2 Pro, Metal, Forward+, 1280x720, no display scaling"
## Below this the off-state control is not quiet enough for the comparison to
## mean anything, and the run reports VACUOUS rather than a pass. The measured
## floor is 0.0000 — with the movers and the scenery hidden, a settled frame
## reproduces exactly — so anything at all here means something is moving in the
## crop that should not be, and the reading is about that instead.
const MAX_QUIET_FLOOR := 0.0010


## The lowest acceptable difference between the plates-off and plates-on frames.
## Below this the tool is not photographing the treatment at all — see the
## STATES-DIFFER check, and the silent wrong-view failure that motivated it.
const MIN_STATE_DIFFERENCE := 0.02
## A pixel counts as having flickered when it moves more than this in luma.
## Well above the frame's own settled reproducibility and well below the
## contrast between two substances, so it counts contacts rather than noise.
const FLICKER_STEP := 0.05

var _cam: Camera3D
var _main: Node
## First settled frame of each state, kept only to prove the two differ.
var _reference := {}


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("run WINDOWED — a headless run renders nothing and would report a "
			+ "perfectly stable frame because there is no frame")
		return

	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	for _i in WARMUP_FRAMES:
		await get_tree().process_frame

	var mat := _terrain_material()
	if mat == null:
		_fail("no terrain ShaderMaterial under World/Terrain — nothing to measure")
		return
	_quiet_the_world()

	_cam = Camera3D.new()
	_cam.fov = 68.0
	_cam.far = 400.0
	get_tree().root.add_child(_cam)
	_cam.current = true

	# One world, one set of lights, two states — so the only difference between
	# the two readings is the uniform under test.
	var off := await _walk(mat, false)
	var on := await _walk(mat, true)
	if off < 0.0 or on < 0.0:
		return

	var contribution := on - off
	var budget := _requested_budget()
	print("CRAWL off=%.4f on=%.4f contribution=%.4f (%s)"
		% [off, on, contribution,
			("budget %.4f from WAR_CRAWL_MAX" % budget) if budget >= 0.0
				else "no budget set — reporting only"])

	# STATES DIFFER — the plates must actually be in this frame. Toggling the
	# uniform changes what the ground is made of, so two identical frames mean
	# the tool is photographing something the treatment does not touch and every
	# number above is about that something instead.
	#
	# This check exists because the tool DID report a clean pass while doing
	# exactly that: the player's camera had quietly taken `current` back, so all
	# eight frames were the same view of the starter cave's interior, the crawl
	# came out at a perfect 0.0000, and nothing else in the run objected. A
	# measurement that reads best when it is broken needs an explicit guard, not
	# a plausible-looking number.
	var state_difference := _worst_move(_reference[false], _reference[true])
	if state_difference < MIN_STATE_DIFFERENCE:
		_fail(("VACUOUS — the plates-off and plates-on frames differ by only %.4f (need %.4f), so "
			+ "this crop does not contain the plate treatment and neither reading is about it")
			% [state_difference, MIN_STATE_DIFFERENCE])
		return

	# Non-vacuity: a floor as loud as the subject means this vantage cannot see
	# the plates, and both a pass and a fail would be meaningless.
	if off > MAX_QUIET_FLOOR:
		_fail(("VACUOUS — the plates-off control already flickers %.4f (max %.4f), so this "
			+ "vantage cannot isolate the plate contribution") % [off, MAX_QUIET_FLOOR])
		return
	# Everything above this line is machine-INDEPENDENT: each of those checks
	# compares two readings taken seconds apart in one process, so a GPU that
	# simply answers differently cannot trip them. They stay hard failures.
	#
	# The contribution is not like that. It is an absolute level, and the same
	# unmodified shader measures 0.0027 on one Mac and 0.0074 on another (#439).
	# So the tool does not judge it unless the caller supplies a budget measured
	# in the SAME environment — which is the only comparison that means anything.
	print("CRAWL reference %.4f on %s — comparable only on a like environment"
		% [REFERENCE_CONTRIBUTION, REFERENCE_ENVIRONMENT])
	if budget < 0.0:
		print(("CRAWL REPORT — %.4f of the ground flickers under a %.2f-pixel step. No verdict: "
			+ "set WAR_CRAWL_MAX to a budget measured on THIS machine to gate on it. To compare "
			+ "two builds, run both here and diff these numbers — never against a recorded "
			+ "constant.") % [contribution, STEP_PIXELS])
		get_tree().quit(0)
		return
	if contribution > budget:
		_fail(("%.4f of the ground flickers under a %.2f-pixel camera step, above the %.4f budget "
			+ "YOU supplied via WAR_CRAWL_MAX — so this is a regression against your own baseline, "
			+ "not against a recorded constant. Something in the plate path is being drawn "
			+ "narrower than the pixel drawing it; measured, that has been the crack RELIEF, so "
			+ "check what it dissolves on before looking anywhere else")
			% [contribution, STEP_PIXELS, budget])
		return

	print(("CRAWL PASS — %.4f of the ground flickers under a %.2f-pixel step, within the %.4f "
		+ "budget supplied via WAR_CRAWL_MAX") % [contribution, STEP_PIXELS, budget])
	get_tree().quit(0)


## Walks the camera STEPS sub-pixel positions and returns the WORST luma move any
## crop pixel made between consecutive positions. Returns -1.0 after failing.
func _walk(mat: ShaderMaterial, plates: bool) -> float:
	mat.set_shader_parameter("plates_enabled", plates)
	var step := _world_per_pixel() * STEP_PIXELS
	var right := (TARGET - EYE).normalized().cross(Vector3.UP).normalized()

	var worst := 0.0
	var peak := 0.0
	var previous := PackedFloat32Array()
	for i in STEPS:
		_cam.global_position = EYE + right * (float(i) * step)
		_cam.look_at(TARGET, Vector3.UP)
		for _f in SETTLE_FRAMES:
			# Re-assert every frame, exactly as frame_capture does: the player's
			# own camera otherwise takes `current` back and the tool measures the
			# view from inside the starter cave instead of the vantage it names.
			# That failure is SILENT and it reads as a pass — every frame is then
			# identical, so the crawl figure comes out at a perfect 0.0000.
			_cam.current = true
			await get_tree().process_frame
		if i == 0:
			_save_frame(plates)
			_reference[plates] = _crop_luma()
		var current := _crop_luma()
		if current.is_empty():
			_fail("the crop sampled no pixels — the viewport is smaller than the crop")
			return -1.0
		if not previous.is_empty():
			worst = maxf(worst, _flicker_fraction(previous, current))
			peak = maxf(peak, _worst_move(previous, current))
		previous = current
	# A frame that photographed nothing is perfectly stable, so guard the
	# measurement the way frame_capture guards its own: no spread, no evidence.
	var spread := _spread(previous)
	if spread < 0.02:
		_fail(("the crop spans only %.4f luma with plates %s — it photographed a flat "
			+ "surface, and a flat surface cannot crawl whatever the shader does")
			% [spread, "on" if plates else "off"])
		return -1.0
	print("  walk plates=%s flicker=%.4f peak=%.4f spread=%.4f"
		% [plates, worst, peak, spread])
	return worst


## Luma of every pixel in the crop, row-major. Read out of the raw buffer rather
## than through get_pixel(): the crop is ~200k pixels and this runs eight times.
func _crop_luma() -> PackedFloat32Array:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(CROP.position.x * float(w))
	var y0 := int(CROP.position.y * float(h))
	var x1 := mini(int((CROP.position.x + CROP.size.x) * float(w)), w)
	var y1 := mini(int((CROP.position.y + CROP.size.y) * float(h)), h)
	var out := PackedFloat32Array()
	if x1 <= x0 or y1 <= y0:
		return out
	var data := img.get_data()
	out.resize((x1 - x0) * (y1 - y0))
	var n := 0
	for y in range(y0, y1):
		var row := y * w
		for x in range(x0, x1):
			var o := (row + x) * 3
			out[n] = (float(data[o]) * 0.2126 + float(data[o + 1]) * 0.7152
				+ float(data[o + 2]) * 0.0722) / 255.0
			n += 1
	return out


## What FRACTION of the crop moved more than FLICKER_STEP between two frames.
##
## Not the maximum, which was the first thing tried and is the wrong statistic:
## it is decided by a single pixel, and there is always one pixel somewhere on a
## legitimately thin, high-contrast feature — a well-resolved crack a metre from
## the camera — that moves a lot under any camera step at all. That pixel sat at
## 0.16 whatever the shader did, so the maximum reported the same number for
## four different configurations and could not see changes the attribution pass
## proved were there.
##
## Crawl is not one pixel moving far, it is MANY pixels flipping at once, so
## count them. A mean would be wrong in the other direction — it averages a
## local artifact away against the calm ground around it and reports serenity
## while the contacts shimmer.
func _flicker_fraction(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var moved := 0
	for i in n:
		if absf(a[i] - b[i]) > FLICKER_STEP:
			moved += 1
	return float(moved) / float(n)


## The worst single-pixel move, kept as a reported diagnostic only. It is not the
## verdict, for the reason given above.
func _worst_move(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in mini(a.size(), b.size()):
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _spread(v: PackedFloat32Array) -> float:
	var lo := 1.0
	var hi := 0.0
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo


## Metres of ground per pixel at the crop's distance, from the camera's own
## vertical FOV so it stays correct if the resolution or FOV changes.
func _world_per_pixel() -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	return 2.0 * CROP_DISTANCE * tan(deg_to_rad(_cam.fov) * 0.5) / h


## Writes the frame each state was measured on, with the crop outlined, to
## WAR_CRAWL_SHOT_DIR. This is not a debug aid: a crawl figure is only worth as
## much as the crop it was taken over, so the evidence has to let a reader see
## that the measured band really is ground. A crop that had strayed onto a
## silhouette or the horizon would report a large, real, and entirely irrelevant
## number ([[evidence-jobs-must-depict-the-change]] — evidence that cannot
## depict its claim is worse than none, because it looks like proof).
func _save_frame(plates: bool) -> void:
	var dir := OS.get_environment("WAR_CRAWL_SHOT_DIR")
	if dir.is_empty():
		return
	var img := get_viewport().get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(CROP.position.x * float(w))
	var y0 := int(CROP.position.y * float(h))
	var x1 := mini(int((CROP.position.x + CROP.size.x) * float(w)), w) - 1
	var y1 := mini(int((CROP.position.y + CROP.size.y) * float(h)), h) - 1
	for x in range(x0, x1 + 1):
		img.set_pixel(x, y0, Color.RED)
		img.set_pixel(x, y1, Color.RED)
	for y in range(y0, y1 + 1):
		img.set_pixel(x0, y, Color.RED)
		img.set_pixel(x1, y, Color.RED)
	var path := "%s/plates-%s.png" % [dir, "on" if plates else "off"]
	if img.save_png(path) != OK:
		push_warning("could not write %s" % path)


## The flicker budget the CALLER supplied, or -1.0 when they supplied none.
##
## An env var rather than a constant because the only sound budget is one
## measured in the same environment it is applied to, and this file cannot know
## what that is. A malformed value is refused rather than silently read as 0.0,
## which would fail every run and look like a catastrophic regression.
func _requested_budget() -> float:
	var raw := OS.get_environment("WAR_CRAWL_MAX").strip_edges()
	if raw.is_empty():
		return -1.0
	if not raw.is_valid_float():
		push_warning("WAR_CRAWL_MAX=%s is not a number — ignoring it and reporting only" % raw)
		return -1.0
	var value := raw.to_float()
	# A negative budget is refused rather than accepted, because -1.0 is this
	# function's own "no budget" sentinel: taken at face value it would read as
	# unset and quietly report, and taken literally it would fail every possible
	# run. Neither is what someone typing a negative number meant.
	if value < 0.0:
		push_warning("WAR_CRAWL_MAX=%s is negative — ignoring it and reporting only" % raw)
		return -1.0
	return value


## Leaves the camera as the ONLY thing that differs between two captures.
##
## The Reach is alive: ash pools drift, two dozen people and eight hounds walk
## about, and the settle between captures is a second and a half of that. Their
## motion lands in the same crop and moves whole silhouettes of pixels, which is
## far more than a subpixel shading artifact ever could — measured, the first
## run of this tool reported a plates-OFF floor of 0.3555, and the non-vacuity
## check refused the reading rather than let a 0.0372 contribution read as a
## comfortable pass beneath a limit of 0.08.
##
## So the movers are hidden and the tree is paused. What stays is everything
## that decides how the GROUND is lit and shaded — the world mesh, the sun and
## the WorldEnvironment with its volumetric fog. Keeping the atmosphere is
## deliberate rather than convenient: it damps ground contrast to roughly a
## third ([[war-atmosphere-flattens-ground-albedo]]), so measuring through it is
## the conservative choice. A version of this that switched the fog off to get a
## cleaner signal would be measuring a frame no player will ever see, and would
## flatter the result.
func _quiet_the_world() -> void:
	# set() rather than a typed branch: these are a Node3D, a CanvasLayer and
	# plain Nodes, and `visible` lives on no common base class of the three. A
	# branch on CanvasItem/Node3D silently skips the HUD, which is a CanvasLayer
	# and draws OVER the whole frame.
	var hidden: Array[String] = []
	for node_name in ["Wanderer", "Npcs", "Creatures", "Hud", "Replicas", "HollowFog"]:
		var node := _main.get_node_or_null(NodePath(node_name))
		if node != null and "visible" in node:
			node.set("visible", false)
			hidden.append(node_name)
	# Hiding is enough and pausing the tree is NOT used: a hidden mover draws
	# nothing however far it walks, while `SceneTree.paused` stalled this tool's
	# own frame await and it never reached its first capture.

	# Everything in the world except the ground itself, for the same reason and
	# a sharper one. The metric is the WORST move any pixel makes, and a scrub
	# bush or a boulder is an opaque silhouette against the ground: slide the
	# camera a quarter pixel and its outline pixels swap between plant and
	# ground, which is a larger move than the shading artifact could ever be and
	# has nothing to do with the terrain shader. Measured with them in frame the
	# floor was 0.3555 — nine parts silhouette, and the non-vacuity check
	# correctly refused every reading taken that way.
	#
	# What remains is the terrain mesh, lit by the same sun and seen through the
	# same atmosphere. That is the surface this change is about, and its
	# stability is what the number now describes.
	var world := _main.get_node_or_null("World")
	if world != null:
		for child in world.get_children():
			if child.name != "Terrain" and "visible" in child:
				child.set("visible", false)
				hidden.append(String(child.name))
	print("  quieted: %s" % ", ".join(hidden))


func _terrain_material() -> ShaderMaterial:
	var terrain := _main.get_node_or_null("World/Terrain") as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		return null
	return terrain.mesh.surface_get_material(0) as ShaderMaterial


func _fail(message: String) -> void:
	push_error(message)
	print("CRAWL FAIL — %s" % message)
	get_tree().quit(1)
