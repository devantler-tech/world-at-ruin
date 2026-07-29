extends Node
## Pins the cave/terrain contact band's crack-relief guards to the ground's
## (#306).
##
## The relief term is authored twice. `shaders/terrain.gdshader` draws the
## ground; `shaders/cave_terrain_contact.gdshader` draws the band where the
## massif meets that ground, and it carries a hand-copy of the same block
## because the two shade different meshes. Both perturb the normal along the
## same seams, over surfaces that are adjacent on screen and are meant to read
## as one continuous floor.
##
## Restating a guard is how guards drift apart, and this pair drifts silently:
## nothing errors if the ground's relief stops at one slope and the contact
## band's stops at another. The seams simply rake differently either side of a
## line the player can see, and the shimmer this issue is about comes back in a
## strip around every cave mouth while the ground itself measures clean. That is
## a wrongness with no failure — visible only to someone standing at the contact
## and looking along it. This test is the join.
##
## Deliberately a SOURCE-TEXT check. Both quantities are fragment-local
## expressions inside a `plates_enabled` branch: they are never uniforms, so
## nothing can read them back from GDScript, and observing them needs a windowed
## GPU run of an opt-in treatment that `--headless` CI cannot do. Parsing the
## files is the only way to hold this where CI runs.
##
## Run: godot --headless --path client res://tests/crack_relief_parity_test.tscn

## The shader the relief is authored in, and the one that hand-copies it.
const GROUND_SHADER_PATH := "res://shaders/terrain.gdshader"
const CONTACT_SHADER_PATH := "res://shaders/cave_terrain_contact.gdshader"

## Both guards are matched on their own distinctive operand rather than on
## `grad`, because the relief block multiplies `grad` by a THIRD term
## (`smoothstep(0.30, 0.85, plate_fw)`, the whole-plate dissolve) which is a
## different guard with different constants. A pattern loose enough to catch
## that one would compare the wrong pair and pass while the seam guards drifted.
const FADE_PATTERN := \
	"1\\.0\\s*-\\s*smoothstep\\(\\s*([0-9.]+)\\s*,\\s*([0-9.]+)\\s*,\\s*crack_fw\\s*\\*"
const CEILING_PATTERN := \
	"grad_len\\s*>\\s*([0-9.]+)\\s*\\?\\s*grad\\s*\\*\\s*\\(\\s*([0-9.]+)\\s*/\\s*grad_len\\s*\\)"
## Matched on the call itself rather than on `crack_fw`, which by this point in
## both files is also the operand of the fade above and of the crack's own
## widening — a looser pattern would capture whichever of the three came first
## and compare the wrong quantity across the two files.
const EDGE_BLEND_PATTERN := \
	"terrain_plate_edge_blend\\(\\s*f1\\s*,\\s*f2\\s*,\\s*edge_fw\\s*\\*\\s*([0-9.]+)\\s*\\)"

## A screen-space derivative taken OF a crack quantity — the form this must not
## regress to. Deliberately anchored on the crack operand rather than on
## `dFdx` alone: both shaders legitimately take derivatives of other things
## (`fwidth(f2 - f1)` sets the albedo crack's width, `fwidth(ash_edge)` the ash
## contact), and a bare `dFdx` search would condemn those too.
const DIFFERENCED_CRACK_PATTERN := "dFd[xy]\\s*\\(\\s*crack"
## The closed-form separator, `normalize(uv - c2) - normalize(uv - c1)`, written
## as a pair of inversesqrt-scaled offsets so it is one expression rather than
## two normalize() calls the optimiser may fold. Matched on its SHAPE — two
## `inversesqrt(max(dot(...)))` scalings subtracted — so renaming the locals does
## not fail the test while removing the construction does.
const CLOSED_FORM_PATTERN := \
	"inversesqrt\\(\\s*max\\(\\s*dot\\([^)]*\\)[^)]*\\)\\s*\\)\\s*\\n?\\s*-\\s*\\w+\\s*\\*\\s*inversesqrt"

## The seam-variance cavity, which is hand-copied across the same pair and
## drifts the same silent way. Three quantities, each with its own failure:
##
## `AMP_CEILING_PATTERN` — the top-hat plateau the groove is integrated as. It
## must be the SAME number as the seam-slope ceiling, because it is the same
## physical bound read from the other side: the ceiling is what makes the
## applied profile a top hat, and `amp` is that top hat's height. Drift them and
## the integral stops describing the code it models, silently — the frame still
## renders and both files still agree with each other.
##
## `CAVITY_PATTERN` — the darkening's SHAPE. `1 / (1 + k*var)` saturates and is
## exactly 1.0 at zero variance, so the near field, the far field past the plate
## cutoff and the default-off path are untouched arithmetically rather than
## approximately. The obvious `1 - k*var` rewrite passes every frame a reviewer
## would look at and goes NEGATIVE on a high relief setting, which is a black
## seam rather than a dark one.
##
## `CAVITY_DEFAULT_PATTERN` — how hard that darkening pulls. It is a uniform, so
## unlike the roughness fold it replaced there is no derivable constant to
## check; what must hold is that the two files ship the SAME default, or the
## same sub-pixel seam is occluded harder on one side of every cave mouth than
## the other.
##
## `VAR_CUTOFF_PATTERN` — the plate-resolution cutoff, which must be SQUARED.
## Variance scales as the square of the amplitude it belongs to, so a single
## factor leaves the far field carrying a seam read the plates no longer justify.
const AMP_CEILING_PATTERN := \
	"plate_mask_relief\\s*,\\s*([0-9.]+)\\s*\\)"
const CAVITY_PATTERN := \
	"ALBEDO\\s*\\*=\\s*1\\.0\\s*/\\s*\\(\\s*1\\.0\\s*\\+\\s*seam_cavity\\s*\\*\\s*seam_var\\s*\\)"
const CAVITY_DEFAULT_PATTERN := \
	"uniform\\s+float\\s+seam_cavity\\s*:[^=]*=\\s*([0-9.]+)"
const VAR_CUTOFF_PATTERN := \
	"seam_slope_var\\s*\\*=\\s*plate_resolved\\s*\\*\\s*plate_resolved"


func _ready() -> void:
	var ground := _shader_source(GROUND_SHADER_PATH)
	var contact := _shader_source(CONTACT_SHADER_PATH)
	# MISSING-SOURCE GUARD. Every law below is "the two files agree about X", and
	# two files that cannot be read agree about everything — so a rename would
	# turn this test green while checking nothing. A guard that passes when its
	# subject is absent is worse than no guard.
	if ground == "":
		_fail("could not read %s — the shader this test pins the contact band against is missing or unreadable, so every law below would pass while checking nothing" % GROUND_SHADER_PATH)
		return
	if contact == "":
		_fail("could not read %s — the shader this test pins against the ground is missing or unreadable, so every law below would pass while checking nothing" % CONTACT_SHADER_PATH)
		return

	# 1. THE SEAM-SLOPE CEILING. The bound on how far the relief may tilt a
	# normal, which is what distinguishes an aliased fragment claiming an
	# impossible slope from a resolved seam. It decides how hard a seam rakes,
	# so a contact band with a different ceiling from the ground it blends into
	# lights its seams differently along the join.
	var ground_ceiling := _pair(ground, CEILING_PATTERN)
	if ground_ceiling.is_empty():
		_fail("no `grad_len > X ? grad * (X / grad_len)` in %s — the relief's seam-slope ceiling is gone, and the contact band has nothing left to match" % GROUND_SHADER_PATH)
		return
	var contact_ceiling := _pair(contact, CEILING_PATTERN)
	if contact_ceiling.is_empty():
		_fail("no `grad_len > X ? grad * (X / grad_len)` in %s — the contact band's relief has lost the seam-slope ceiling the ground still applies, so seams at the cave mouth may tilt further than the ground's" % CONTACT_SHADER_PATH)
		return

	# 1a. Each ceiling must be INTERNALLY consistent first. The value appears
	# twice in one expression — as the threshold and as the rescale numerator —
	# and editing one without the other does not fail, it changes the operator:
	# `grad_len > 0.4 ? grad * (1.5 / grad_len)` AMPLIFIES every gradient it was
	# meant to bound. Comparing the two files without this would happily agree
	# on a threshold while one of them multiplied by something else entirely.
	for named in [[GROUND_SHADER_PATH, ground_ceiling], [CONTACT_SHADER_PATH, contact_ceiling]]:
		var path: String = named[0]
		var pair: Array = named[1]
		if not is_equal_approx(pair[0], pair[1]):
			_fail("the seam-slope ceiling in %s rescales to %s but triggers at %s — a clamp whose two halves disagree does not bound the gradient, it rescales it by %s/%s" % [
				path, _num(pair[1]), _num(pair[0]), _num(pair[1]), _num(pair[0])
			])
			return

	if not is_equal_approx(ground_ceiling[0], contact_ceiling[0]):
		_fail("seam-slope ceiling disagrees: the ground stops the relief at %s but the contact band stops it at %s — seams would rake differently either side of every cave mouth" % [
			_num(ground_ceiling[0]), _num(contact_ceiling[0])
		])
		return

	# 2. THE FADE WINDOW. Where the relief dissolves as its own seam stops being
	# resolvable, expressed as a footprint ratio. It decides at what DISTANCE
	# seams stop being drawn at all, so a mismatch makes relief survive further
	# on one surface than the other — the contact band keeping grooves the
	# ground beside it has already given up, along the same sightline.
	var ground_fade := _pair(ground, FADE_PATTERN)
	if ground_fade.is_empty():
		_fail("no crack-footprint fade (`1.0 - smoothstep(a, b, crack_fw * ...)`) in %s — the relief's distance dissolve is gone, and the contact band has nothing left to match" % GROUND_SHADER_PATH)
		return
	var contact_fade := _pair(contact, FADE_PATTERN)
	if contact_fade.is_empty():
		_fail("no crack-footprint fade (`1.0 - smoothstep(a, b, crack_fw * ...)`) in %s — the contact band's relief has lost the distance dissolve the ground still applies" % CONTACT_SHADER_PATH)
		return
	if not is_equal_approx(ground_fade[0], contact_fade[0]) \
			or not is_equal_approx(ground_fade[1], contact_fade[1]):
		_fail("crack-footprint fade disagrees: the ground fades over (%s, %s) but the contact band fades over (%s, %s) — relief would outlive its seam on one surface and not the other" % [
			_num(ground_fade[0]), _num(ground_fade[1]),
			_num(contact_fade[0]), _num(contact_fade[1])
		])
		return

	# 3. THE PLATE-BOUNDARY FOOTPRINT. How wide a footprint the substance step
	# between two plates is averaged over (#306). It is the same hand-copied
	# pair as the guards above and drifts the same silent way, but it fails in
	# the opposite direction from them: too small a factor and the contact band
	# keeps a hard substance step the ground beside it has already filtered, so
	# the crawl comes back in a strip around every cave mouth; too large and the
	# band softens named substances the ground still draws at full contrast.
	# Either way the two surfaces disagree along a line the player can see,
	# which is exactly what this file exists to prevent.
	var ground_edge := _single(ground, EDGE_BLEND_PATTERN)
	if ground_edge < 0.0:
		_fail("no plate-boundary footprint (`terrain_plate_edge_blend(f1, f2, edge_fw * ...)`) in %s — the substance step is no longer averaged over the pixel drawing it, and the contact band has nothing left to match" % GROUND_SHADER_PATH)
		return
	var contact_edge := _single(contact, EDGE_BLEND_PATTERN)
	if contact_edge < 0.0:
		_fail("no plate-boundary footprint (`terrain_plate_edge_blend(f1, f2, edge_fw * ...)`) in %s — the contact band takes the owning plate's substance outright while the ground averages it, so plate contacts crawl at the cave mouth only" % CONTACT_SHADER_PATH)
		return
	if not is_equal_approx(ground_edge, contact_edge):
		_fail("plate-boundary footprint disagrees: the ground averages the substance step over %s of a footprint but the contact band uses %s — one surface filters a contact the other still steps across" % [
			_num(ground_edge), _num(contact_edge)
		])
		return

	# 4. THE GRADIENT IS TAKEN IN CLOSED FORM, on both surfaces. A screen-space
	# difference of the crack field is only a gradient while the crack is wider
	# than the quad differencing it, and `crack_width` is a constant in plate
	# units — so past a few metres of grazing ground the differenced form
	# returns sampling error rather than a slope, which is the shimmer #306 is
	# about (measured: 0.0054 -> 0.0037 of the ground crop on one machine in one
	# sitting, control unchanged at 0.0000).
	#
	# This is a REGRESSION guard, not a style preference. The differenced form
	# is the shorter-looking of the two and reads as the obvious way to take a
	# gradient, so "simplifying" back to it is a live risk — and it would fail
	# nothing else: the frame still renders, both shaders still agree with each
	# other, and the only symptom is ground that shimmers again at the distance
	# a player walks through. Checked on both files for the same reason every
	# other law here is: the contact band hand-copies this block.
	for named in [[GROUND_SHADER_PATH, ground], [CONTACT_SHADER_PATH, contact]]:
		var path: String = named[0]
		var src: String = named[1]
		if _matches(src, DIFFERENCED_CRACK_PATTERN):
			_fail("%s differences the crack field with dFdx/dFdy — past a few metres that step is thinner than the quad sampling it, so this returns sampling error rather than a slope and the ground shimmers again. Take the gradient in closed form from the plate centres instead." % path)
			return
		if not _matches(src, CLOSED_FORM_PATTERN):
			_fail("%s does not take the crack gradient in closed form — the `normalize(uv - c2) - normalize(uv - c1)` separator is gone, so the relief is no longer exact at distance" % path)
			return

	# 5. THE SEAM-VARIANCE CAVITY. The relief is filtered into two moments: the
	# mean tilt, which the normal carries, and the variance about it, which is
	# carried as occlusion because a pixel spanning a whole groove sees its two
	# walls cancel. The second half is what keeps a seam readable past the
	# distance the fade in law 2 has already closed, so a contact band that lost
	# it goes flat in a strip around every cave mouth while the ground beside it
	# still reads — visibly, and along exactly the join this file exists to hold.
	var ground_amp := _single(ground, AMP_CEILING_PATTERN)
	if ground_amp < 0.0:
		_fail("no top-hat amplitude (`min(... * plate_mask_relief, X)`) in %s — the groove is no longer integrated over the pixel, so the relief is point-sampled again and the contact band has nothing left to match" % GROUND_SHADER_PATH)
		return
	var contact_amp := _single(contact, AMP_CEILING_PATTERN)
	if contact_amp < 0.0:
		_fail("no top-hat amplitude (`min(... * plate_mask_relief, X)`) in %s — the contact band point-samples the groove while the ground integrates it, so seams crawl at the cave mouth only" % CONTACT_SHADER_PATH)
		return

	# 5a. Each amplitude must agree with THAT FILE'S OWN seam-slope ceiling
	# before the two files are compared. The top hat is only the right profile to
	# integrate because the ceiling clamps the raw slope flat across the groove
	# (measured: the raw peak is ~100x the ceiling at the shipped crack width, so
	# the clamp binds over 99% of it). If the plateau and the clamp are different
	# numbers, the closed form integrates a groove the shader does not draw.
	for named in [[GROUND_SHADER_PATH, ground_amp, ground_ceiling[0]], [CONTACT_SHADER_PATH, contact_amp, contact_ceiling[0]]]:
		var path: String = named[0]
		var amp: float = named[1]
		var ceiling: float = named[2]
		if not is_equal_approx(amp, ceiling):
			_fail("in %s the groove is integrated as a top hat of height %s but the seam-slope ceiling clamps it at %s — the top hat is the right profile only because the ceiling makes it one, so these are the same bound and the filter now models a groove the shader does not draw" % [
				path, _num(amp), _num(ceiling)
			])
			return

	if not is_equal_approx(ground_amp, contact_amp):
		_fail("top-hat amplitude disagrees: the ground integrates a groove of height %s but the contact band uses %s — the same seam would carry a different residual read either side of every cave mouth" % [
			_num(ground_amp), _num(contact_amp)
		])
		return

	# 5b. The cavity's SHAPE, on both files. `1 / (1 + k*var)` is exactly 1.0 at
	# zero variance, which is what makes the near field, the far field past the
	# plate cutoff and the whole default-off path untouched as arithmetic rather
	# than as an approximation.
	for named in [[GROUND_SHADER_PATH, ground], [CONTACT_SHADER_PATH, contact]]:
		var path: String = named[0]
		var src: String = named[1]
		if not _matches(src, CAVITY_PATTERN):
			_fail("%s does not carry the seam variance as a saturating cavity (`ALBEDO *= 1.0 / (1.0 + seam_cavity * seam_var)`) — the relief the normal cannot hold is being discarded rather than kept as occlusion, which is how a seam vanishes into the far field; a linear `1 - k*var` is not a substitute, it goes negative on a high relief setting" % path)
			return

	# 5c. And the same STRENGTH. The coefficient is a uniform rather than a
	# derived constant, so the law is agreement rather than a value: a pair that
	# differs occludes the same sub-pixel seam harder on one side of the join.
	var ground_cavity := _single(ground, CAVITY_DEFAULT_PATTERN)
	if ground_cavity < 0.0:
		_fail("no `seam_cavity` uniform default in %s — the cavity strength is unset, so the ground and the contact band have nothing to agree on" % GROUND_SHADER_PATH)
		return
	var contact_cavity := _single(contact, CAVITY_DEFAULT_PATTERN)
	if contact_cavity < 0.0:
		_fail("no `seam_cavity` uniform default in %s — the contact band cannot match the ground's cavity strength" % CONTACT_SHADER_PATH)
		return
	if not is_equal_approx(ground_cavity, contact_cavity):
		_fail("seam-cavity strength disagrees: the ground darkens an unresolved groove at %s but the contact band uses %s — the same seam is occluded harder on one side of every cave mouth than the other" % [
			_num(ground_cavity), _num(contact_cavity)
		])
		return

	# 5d. The cutoff must be SQUARED on both. `seam_slope_var *= plate_resolved`
	# alone is the easy edit to make and reads as equivalent; it is not, because
	# a variance scales as the square of the amplitude it is a variance of. The
	# symptom is a far field that keeps a seam read after the plates carrying it
	# have converged on their mean — nothing errors, the ground just will not go
	# quiet.
	for named in [[GROUND_SHADER_PATH, ground], [CONTACT_SHADER_PATH, contact]]:
		var path: String = named[0]
		var src: String = named[1]
		if not _matches(src, VAR_CUTOFF_PATTERN):
			_fail("%s does not take the plate-resolution cutoff on the seam variance SQUARED (`seam_slope_var *= plate_resolved * plate_resolved`) — a variance scales as the square of its amplitude, so a single factor leaves a seam read the plates no longer justify" % path)
			return

	print("TEST PASS — %s and %s apply the same crack-relief guards: seam-slope ceiling %s, crack-footprint fade over (%s, %s), plate-boundary footprint %s, gradient in closed form on both, seam variance integrated as a top hat of height %s and carried as a saturating cavity at strength %s with a squared plate cutoff" % [
		GROUND_SHADER_PATH, CONTACT_SHADER_PATH,
		_num(ground_ceiling[0]), _num(ground_fade[0]), _num(ground_fade[1]),
		_num(ground_edge), _num(ground_amp), _num(ground_cavity)
	])
	get_tree().quit(0)


## The shader's source text, or "" if it cannot be read.
func _shader_source(path: String) -> String:
	var shader := load(path) as Shader
	if shader == null:
		return ""
	return shader.code


## The first two capture groups of [param pattern] in [param text] as floats, or
## an empty array if it does not match. Values are compared NUMERICALLY: `0.4`
## and `0.40` are the same slope, and a test that called them different would
## fail on a reformat while a real divergence still slipped past.
func _pair(text: String, pattern: String) -> Array:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return []
	var m := re.search(text)
	if m == null:
		return []
	return [float(m.get_string(1)), float(m.get_string(2))]


## The first capture group of [param pattern] in [param text] as a float, or
## -1.0 if it does not match. Negative is unambiguous here: every quantity this
## file pins is a footprint or a slope, and none of them can be below zero.
func _single(text: String, pattern: String) -> float:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return -1.0
	var m := re.search(text)
	if m == null:
		return -1.0
	return float(m.get_string(1))


## Whether [param pattern] occurs anywhere in [param text]. A compile failure
## reports NO match, which would make a malformed pattern silently pass every
## law that uses it — so callers must treat "absent" as the failing side for the
## construction they require, which the closed-form check does.
func _matches(text: String, pattern: String) -> bool:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return false
	return re.search(text) != null


## A float rendered so the two sides of a mismatch message are directly
## comparable.
func _num(value: float) -> String:
	return String.num(value, 2)


func _fail(message: String) -> void:
	# The runner refuses any log containing this token (#313).
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
