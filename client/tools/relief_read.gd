extends Node
## Measures how much the crack RELIEF actually contributes to the image, as a
## function of distance (#306), so "the near-field read is not softened away" is
## a number rather than an opinion.
##
## `tools/plate_crawl` measures one half of #306: how hard the ground FLICKERS at
## medium distance. Every remaining candidate for removing that flicker works by
## fading the relief in NEARER, and the whole reason the issue stayed open after
## PR #398 is that the other half of the trade — what such a fade costs the seam
## read a player is close enough to see — had no measurement at all. A number on
## one side of a trade and a judgement on the other is not a trade that can be
## decided, so this supplies the missing side.
##
## ## What it measures, and why that is the relief rather than the plates
##
## The relief term perturbs the NORMAL: it tilts the surface into each seam so
## the light rakes across it. So its contribution to the frame is exactly the
## difference between the shipping build and the same build with `crack_relief`
## set to 0 — one uniform, one world, one set of lights, everything else held.
## That difference IS the read. If a candidate change leaves it unchanged at the
## distances a player reads seams at, the near-field is provably untouched; if it
## shrinks it, that is precisely the softening acceptance criterion 3 forbids.
##
## Note this is a DIFFERENT control from plate_crawl's. That tool toggles
## `plates_enabled` because it is asking what the whole treatment costs in
## stability. This one toggles `crack_relief` because it is asking what one term
## inside the treatment contributes to the read — the term every remaining
## candidate proposes to attenuate.
##
## ## Distance is varied by MOVING the camera, not by reading a depth buffer
##
## The fade being argued about is driven by `crack_fw * 1.2 / crack_width` — how
## far the seam has had to be stretched to stay a pixel wide — which grows with
## distance. So the honest probe is a distance sweep.
##
## Each sample puts the camera at an exact distance from ONE ground anchor along
## ONE fixed bearing, so the elevation angle is identical at every distance and
## the only thing that changes is how far away the ground is. Bands within a
## single frame were the obvious alternative and are worse: turning a screen row
## back into a ground distance needs a flat-plane assumption the Reach does not
## honour, so every distance label would carry the terrain's undulation as error.
## Here the distances are exact by construction.
##
## Run (must be WINDOWED — a headless run renders nothing at all):
##   WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client --resolution 1280x720 res://tools/relief_read.tscn
##
## Redirect all three save seams: this boots the real launch path, so an
## unredirected run writes the player's own save, vault and recovery ledger
## exactly as `frame_capture` and `plate_crawl` warn.

## Where to start looking for ground to measure: on the stretch plate_crawl
## itself photographs, about 25 m along its eye-to-target line. That tool's
## saved evidence shows plates and their seams filling this ground, which is the
## only direct evidence available that a patch of the Reach carries the
## treatment at all — and it keeps both halves of #306's evidence talking about
## the same stone.
##
## Picked this way because the plates are not everywhere: ash banks where the
## ground lies flat and rock is scoured bare on the steeper faces, so a point
## chosen for tidiness lands on sand. plate_crawl's own look-at target does —
## anchored there, the sweep's near sample carried 0.00031 covered fraction
## against a 0.00050 floor and the run correctly refused itself.
const SEARCH_CENTRE := Vector3(16.0, 1.8, 8.0)

## How far around SEARCH_CENTRE to look for exposed rock, and how finely.
const SEARCH_RADIUS := 12.0
const SEARCH_STEPS := 9

## How far above and below the search point to cast when finding the ground.
const SEARCH_RAY_UP := 30.0
const SEARCH_RAY_DOWN := 40.0

## The bearing the camera sits along, as a direction FROM the anchor. Normalised
## on use, so only the ratio matters: a y of 0.5 against a horizontal 0.85 puts
## the eye at roughly 30 degrees above the ground.
##
## That angle is a choice and it is the conservative one. A seam's screen
## footprint grows as the view flattens, so a grazing bearing reaches any given
## fade ratio at a much shorter distance and would make every candidate look like
## it softens the near field. Thirty degrees is about what the player's own
## camera holds, so the distances below mean what they say.
const BEARING := Vector3(0.6, 0.5, 0.6)

## Metres from the anchor, one capture pair each. Doubling rather than stepping:
## the fade is driven by a ratio that scales with distance, so equal ratios want
## equal multiples.
##
## It starts at 6 m rather than at the player's feet because that is where this
## vantage measurably stops carrying seams: at 3 m the sweep reported 0.00000
## covered fraction against a crop spread of 0.78, so the frame was full of
## well-lit ground with no plate contact in it. Six metres is still far inside
## the range the shipping fade leaves at full strength, so the near end of this
## sweep is a distance whose relief no candidate is proposing to touch — which is
## what makes it a control rather than a gap.
const DISTANCES: Array[float] = [6.0, 12.0, 24.0, 48.0]

## The crop, as fractions of the frame — the lower band, which is ground at every
## distance in the sweep because the camera looks down at the anchor.
##
## Deliberately WIDE, which is the opposite of what plate_crawl needs and for a
## reason specific to this measurement. A tight centred box was the first cut and
## it failed at the near end: a plate is about 1.2 m across, so at 3 m a box
## covering a third of the frame fits INSIDE one, and the tool reported
## 0.00000 coverage — no seams, therefore no relief, therefore a "softened" read
## — when what it had actually photographed was the middle of a single slab. A
## band this size spans several plates at 3 m, so there is always a seam in it.
##
## Sky at the top of the far frames dilutes the coverage fraction, and that is
## acceptable: the question this tool answers is whether a candidate shader holds
## the read AT A GIVEN DISTANCE against main, so the two readings being compared
## share whatever the crop contains.
const CROP := Rect2(0.05, 0.40, 0.90, 0.55)

## Frames to let the world build before the first shot. Same reasoning as
## `frame_capture` and `plate_crawl`: generation is synchronous but shaders,
## shadow cascades and SDFGI need frames.
const WARMUP_FRAMES := 150
## Frames to settle after each camera move or uniform change. Volumetric fog
## reprojects temporally and SDFGI re-converges, so an early capture photographs
## a half-resolved frame — which would read as a relief difference the shader had
## nothing to do with.
const SETTLE_FRAMES := 90

## A pixel counts as carrying relief when switching the term off moves its luma
## more than this. Low, because relief is a normal perturbation seen through the
## atmosphere rather than an albedo mark, and the question here is whether the
## read SURVIVES rather than whether it dominates. Above the frame's own 8-bit
## quantum (1/255 = 0.0039) by a comfortable margin, so a pixel has to actually
## move rather than round differently.
const READ_STEP := 0.01

## Below this covered fraction the near sample is not photographing seams at all
## and the sweep has no control. Reported as VACUOUS rather than as a pass.
##
## The number is set from what the two failure states actually measure, not from
## taste. A crop with no seam in it — the near end of an earlier sweep, which sat
## inside a single plate — reads exactly 0.00000, while every crop that does
## carry seams has measured 0.00031 to 0.00091 across two anchors and four
## distances. So this floor sits between an empty reading and the bottom of the
## real range, which is the boundary it exists to detect.
##
## It is deliberately NOT a quality bar. Seams are thin lines over broad plates,
## so even a frame full of well-read cracks covers well under a percent of it,
## and a floor set anywhere inside the real range would reject honest vantages
## for being ordinary. What it must catch is a crop that has no seams to measure.
const MIN_COVERAGE := 0.0002

var _cam: Camera3D
## The ground this sweep is taken from, chosen by _steepest_ground() rather than
## written down, because where the rock is exposed is a property of the world.
var _anchor := Vector3.ZERO
var _main: Node


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("run WINDOWED — a headless run renders nothing and would report a "
			+ "perfectly identical pair because there is no frame")
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

	# The treatment is opt-in and default-off, so it has to be asserted here or
	# every reading below would be of ground that has no plates and no seams.
	mat.set_shader_parameter("plates_enabled", true)
	var shipping_relief := _shipping_relief(mat)
	if shipping_relief <= 0.0:
		_fail("crack_relief ships at %.3f — there is no relief to measure, and every "
			% shipping_relief + "reading below would be the difference between two "
			+ "identical frames")
		return

	var anchor: Variant = await _steepest_ground()
	if anchor == null:
		_fail("no terrain collider answered a downward ray anywhere in the search "
			+ "square — there is no ground to stand this sweep on")
		return
	_anchor = anchor

	_cam = Camera3D.new()
	_cam.fov = 68.0
	_cam.far = 400.0
	get_tree().root.add_child(_cam)
	_cam.current = true

	var bearing := BEARING.normalized()
	var covers := PackedFloat32Array()
	var strengths := PackedFloat32Array()
	for distance in DISTANCES:
		_cam.global_position = _anchor + bearing * distance
		var lit := await _settled_luma(mat, shipping_relief)
		# Taken HERE, while the relief is still on. Reading the viewport after the
		# flat pass instead would save the relief-OFF frame under a name that says
		# lit — evidence that quietly depicts the opposite of its own caption.
		var lit_frame := get_viewport().get_texture().get_image()
		var flat := await _settled_luma(mat, 0.0)
		if lit.is_empty() or flat.is_empty():
			_fail("the crop sampled no pixels — the viewport is smaller than the crop")
			return
		var spread := _spread(lit)
		if spread < 0.02:
			_fail(("the crop spans only %.4f luma at %.0f m — it photographed a flat "
				+ "surface, and a flat surface carries no seam read whatever the shader does")
				% [spread, distance])
			return
		covers.append(_covered_fraction(lit, flat))
		strengths.append(_covered_strength(lit, flat))
		_save_evidence(lit_frame, lit, flat, distance)
		print("  relief d=%5.1fm covered=%.5f strength=%.5f spread=%.4f"
			% [distance, covers[covers.size() - 1], strengths[strengths.size() - 1], spread])

	# Restore the shipping value: a tool that leaves the material zeroed would
	# quietly poison anything sharing this process.
	mat.set_shader_parameter("crack_relief", shipping_relief)

	print("RELIEF_COVERED %s" % _row(covers))
	print("RELIEF_STRENGTH %s" % _row(strengths))

	# Non-vacuity, and it is the NEAREST sample that has to carry seams, not the
	# best one anywhere in the sweep.
	#
	# A peak-only guard was the first cut and it passes while reporting exactly
	# the failure the tool exists to detect: the near sample read 0.00000 — no
	# relief at the distance acceptance criterion 3 protects — and the run still
	# printed a verdict, because a far sample carried the peak. That is a
	# measurement that reads BEST when it is broken, which plate_crawl's own
	# STATES-DIFFER guard was added for after the same class of silent pass.
	# The near sample is the control every comparison leans on, so it is the one
	# that must be non-empty.
	if covers[0] < MIN_COVERAGE:
		_fail(("VACUOUS — the nearest sample (%.0f m) covers only %.5f of the crop "
			+ "(need %.5f), so the sweep has no near-field control and cannot say "
			+ "whether a change softens the read acceptance criterion 3 protects")
			% [DISTANCES[0], covers[0], MIN_COVERAGE])
		return

	print("RELIEF READ — near %.0f m covers %.5f at strength %.5f; far %.0f m covers %.5f"
		% [DISTANCES[0], covers[0], strengths[0],
			DISTANCES[DISTANCES.size() - 1], covers[covers.size() - 1]])
	get_tree().quit(0)


## The `crack_relief` value the game actually renders with.
##
## `ShaderMaterial.get_shader_parameter` returns only what the MATERIAL overrides
## and is null for every uniform left at the shader's own default — which is the
## case here, so reading it alone yields Nil and the sweep would measure the
## difference between relief-off and relief-off. The shipping value is the
## override when there is one and the shader's declared default otherwise, which
## is exactly what `shader_get_parameter_default` answers.
func _shipping_relief(mat: ShaderMaterial) -> float:
	var configured: Variant = mat.get_shader_parameter("crack_relief")
	if configured != null:
		return float(configured)
	if mat.shader == null:
		return 0.0
	var fallback: Variant = RenderingServer.shader_get_parameter_default(
		mat.shader.get_rid(), "crack_relief")
	return 0.0 if fallback == null else float(fallback)


## Sets the relief term, lets the frame settle, and returns the crop's luma.
func _settled_luma(mat: ShaderMaterial, relief: float) -> PackedFloat32Array:
	mat.set_shader_parameter("crack_relief", relief)
	for _f in SETTLE_FRAMES:
		# Re-assert every frame, exactly as frame_capture and plate_crawl do: the
		# player's own camera otherwise takes `current` back and the tool measures
		# the view from inside the starter cave instead of the vantage it names.
		# That failure is SILENT and it reads as a perfect pass — both states are
		# then the same view, so the contribution comes out at a flat 0.00000.
		_cam.current = true
		_cam.look_at(_anchor, Vector3.UP)
		await get_tree().process_frame
	return _crop_luma()


## Luma of every pixel in the crop, row-major. Read out of the raw buffer rather
## than through get_pixel(): the crop is tens of thousands of pixels and this
## runs twice per distance.
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


## What fraction of the crop the relief term touches at all — how much SEAM is
## visible.
##
## A whole-crop mean was the obvious statistic and is the wrong one, which is
## worth stating because plate_crawl's docstring argues for a threshold count
## over a mean on completely different grounds and the two must not be collapsed
## into each other. There the point is that crawl is an ALIASING artifact, so
## averaging hides it. Here the point is geometric: a seam is a thin line across
## a broad plate, so the pixels carrying relief are a fraction of a percent of
## the crop and a mean over everything divides the signal by the ground around
## it. Measured, that mean came out at 0.00005 on a frame whose seams are plainly
## visible — small enough to look like no relief at all.
func _covered_fraction(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var covered := 0
	for i in n:
		if absf(a[i] - b[i]) > READ_STEP:
			covered += 1
	return float(covered) / float(n)


## How hard the relief rakes the seams it does touch — the mean move over the
## covered pixels ALONE.
##
## Reported beside the coverage because the two fail differently and a single
## number cannot tell the two failures apart. A fade that dims every seam
## uniformly holds the coverage and drops the strength; one that erases the
## faintest seams outright drops the coverage and can leave the strength flat or
## even raise it, by dropping the weakest samples out of its own average. Both
## are the softening acceptance criterion 3 forbids, so both are watched.
func _covered_strength(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := mini(a.size(), b.size())
	var total := 0.0
	var covered := 0
	for i in n:
		var delta := absf(a[i] - b[i])
		if delta > READ_STEP:
			total += delta
			covered += 1
	return 0.0 if covered == 0 else total / float(covered)


## Writes what each distance was measured on to WAR_RELIEF_SHOT_DIR: the lit
## frame, and the relief's own contribution as an amplified difference image.
##
## The difference image is the point, and it is not a debug aid. Every number
## this tool prints is a claim about where the relief acts, and a coverage
## figure of a few per mille is equally consistent with "the seams are thin"
## and with "the crop is pointed at bare ground and caught a few stray pixels".
## Only the picture separates those, and a reader who cannot see the seams the
## claim is about has no reason to believe the claim
## ([[evidence-jobs-must-depict-the-change]] — evidence that cannot depict what
## it asserts is worse than none, because it still looks like proof).
func _save_evidence(frame: Image, lit: PackedFloat32Array, flat: PackedFloat32Array,
		distance: float) -> void:
	var dir := OS.get_environment("WAR_RELIEF_SHOT_DIR")
	if dir.is_empty():
		return
	if frame.save_png("%s/relief-%02.0fm-frame.png" % [dir, distance]) != OK:
		push_warning("could not write the %.0f m frame" % distance)

	# The difference, scaled so a move at the detection threshold is plainly
	# visible rather than one grey level off black.
	var w := int(CROP.size.x * float(frame.get_width()))
	var h := mini(int(CROP.size.y * float(frame.get_height())),
		int(float(lit.size()) / maxf(float(w), 1.0)))
	if w <= 0 or h <= 0:
		return
	var delta := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			var i := y * w + x
			if i >= lit.size() or i >= flat.size():
				continue
			var v := clampf(absf(lit[i] - flat[i]) / READ_STEP, 0.0, 1.0)
			delta.set_pixel(x, y, Color(v, v, v))
	if delta.save_png("%s/relief-%02.0fm-delta.png" % [dir, distance]) != OK:
		push_warning("could not write the %.0f m difference" % distance)


func _spread(v: PackedFloat32Array) -> float:
	var lo := 1.0
	var hi := 0.0
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo


## One tab-separated row of `<distance>=<value>`, so two runs of this tool can be
## diffed straight out of the logs without re-deriving which column is which.
func _row(values: PackedFloat32Array) -> String:
	var parts := PackedStringArray()
	for i in values.size():
		parts.append("%.0fm=%.5f" % [DISTANCES[i], values[i]])
	return " ".join(parts)


## Leaves the relief uniform as the ONLY thing that differs between two captures.
## Same reasoning as plate_crawl: the Reach is alive, and a walker crossing the
## crop between the two halves of a pair would move whole silhouettes of pixels —
## far more than a normal perturbation ever could, and it would all be attributed
## to the relief term.
func _quiet_the_world() -> void:
	var hidden: Array[String] = []
	for node_name in ["Wanderer", "Npcs", "Creatures", "Hud", "Replicas", "HollowFog"]:
		var node := _main.get_node_or_null(NodePath(node_name))
		if node != null and "visible" in node:
			node.set("visible", false)
			hidden.append(node_name)

	# Every 2D surface main has opened over the frame, matched by TYPE rather than
	# by name. On a first run that is the character creator, a panel across the
	# left third — and it is added with `add_child` without a name, so it appears
	# as `@CharacterCreator@nnn` and a name list silently misses it (this list did,
	# and the panel sat in three runs' worth of readings). It cannot carry relief
	# and never changes between the two halves of a pair, so it is dead weight in
	# the denominator: every covered fraction divided by a third more crop than
	# the ground actually occupies.
	for child in _main.get_children():
		if (child is CanvasLayer or child is Control) and not child.name in hidden:
			child.set("visible", false)
			hidden.append(String(child.name))

	# Everything in the world except the ground itself. A boulder or a scrub bush
	# is an opaque silhouette over the crop, and at 3 m one can cover most of it —
	# whereupon the pair differs by nothing, the mean reads 0.00000, and the
	# vacuity guard below would blame the shader for the bush.
	var world := _main.get_node_or_null("World")
	if world != null:
		for child in world.get_children():
			if child.name != "Terrain" and "visible" in child:
				child.set("visible", false)
				hidden.append(String(child.name))
	print("  quieted: %s" % ", ".join(hidden))


## The steepest patch of ground in the search square — which is where the plates
## are.
##
## Ash banks where the ground lies flat and rock is scoured bare on the steeper
## faces: `ash_edge` in terrain.gdshader is driven by slope, so slope is the
## cheapest honest proxy for "this fragment will carry plates" available without
## re-implementing the shader on the CPU. Choosing the anchor rather than writing
## one down also means the sweep follows the world when terrain generation
## changes, instead of silently measuring sand and reporting that the relief has
## gone — which is exactly what a hand-picked point did here.
##
## Returns null when nothing answered, so the caller fails loudly rather than
## sweeping around the origin.
func _steepest_ground() -> Variant:
	# The space state is only queryable on a physics frame; asking on a render
	# frame errors and returns nothing, which would read as "no ground anywhere".
	await get_tree().physics_frame
	var space := get_tree().root.world_3d.direct_space_state
	var best: Variant = null
	var best_slope := -1.0
	for ix in SEARCH_STEPS:
		for iz in SEARCH_STEPS:
			var fx := float(ix) / float(SEARCH_STEPS - 1) * 2.0 - 1.0
			var fz := float(iz) / float(SEARCH_STEPS - 1) * 2.0 - 1.0
			var probe := SEARCH_CENTRE + Vector3(fx, 0.0, fz) * SEARCH_RADIUS
			var query := PhysicsRayQueryParameters3D.create(
				probe + Vector3.UP * SEARCH_RAY_UP,
				probe + Vector3.DOWN * SEARCH_RAY_DOWN)
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				continue
			var normal: Vector3 = hit["normal"]
			var slope := 1.0 - absf(normal.dot(Vector3.UP))
			if slope > best_slope:
				best_slope = slope
				best = hit["position"]
	if best != null:
		print("  anchor %v slope=%.3f" % [best, best_slope])
	return best


func _terrain_material() -> ShaderMaterial:
	var terrain := _main.get_node_or_null("World/Terrain") as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		return null
	return terrain.mesh.surface_get_material(0) as ShaderMaterial


func _fail(message: String) -> void:
	push_error(message)
	print("RELIEF FAIL — %s" % message)
	get_tree().quit(1)
