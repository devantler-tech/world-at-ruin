extends Node
## Regression test for plate contacts that crawl under a quarter-pixel camera
## step (#306).
##
## Rendering the real surface is unavailable in headless CI, so this test takes
## the constants from the two production shaders and evaluates the reconstruction
## they describe. The luma contrast is the largest pair in the shipped named
## palette (pale stone against basalt), the camera step is plate_crawl's 0.25 px,
## and the cavity model is the shader's saturating `1 / (1 + k * variance)`.
## Source guards bind those behavioral checks to both the ground and cave-contact
## shaders; the windowed plate_crawl sequence remains the fixed-GPU proof.
##
## Mutation caught: restoring the old half-footprint contact, the single-pixel
## cavity moment, or the old cavity energy makes a quarter-pixel step exceed the
## same 0.05 luma line plate_crawl uses.
##
## Run: godot --headless --path client res://tests/plate_temporal_reconstruction_test.tscn

const GROUND_SHADER := "res://shaders/terrain.gdshader"
const CONTACT_SHADER := "res://shaders/cave_terrain_contact.gdshader"
const SURFACE_INCLUDE := "res://shaders/terrain_surface.gdshaderinc"

const EDGE_SCALE_PATTERN := \
	"terrain_plate_edge_blend\\(\\s*f1\\s*,\\s*f2\\s*,\\s*edge_fw\\s*\\*\\s*([0-9.]+)\\s*\\)"
const CAVITY_SCALE_PATTERN := \
	"cavity_h\\s*=\\s*max\\(\\s*seam_h\\s*\\*\\s*([0-9.]+)"
const CAVITY_DEFAULT_PATTERN := \
	"uniform\\s+float\\s+seam_cavity\\s*:[^=]*=\\s*([0-9.]+)"
const CAVITY_CALL := \
	"terrain_plate_cavity_spread(s_sep, seam_h, cw_relief)"

const ROCK := Vector3(0.30, 0.27, 0.25)
const BASALT := Vector3(0.22, 0.21, 0.22)
const FERRIC := Vector3(0.42, 0.26, 0.18)
const PALE := Vector3(0.54, 0.51, 0.45)

const CAMERA_STEP := 0.25
const FLICKER_STEP := 0.05
const CRACK_TO_PIXEL := 0.032 / 0.05
const AMP_SQUARED := 0.4 * 0.4
const RELIEF_SQUARED := 1.1 * 1.1
const SAMPLE_STEP := 0.001

var _failures: PackedStringArray = []


func _ready() -> void:
	var ground := _source(GROUND_SHADER)
	var contact := _source(CONTACT_SHADER)
	var surface := _source(SURFACE_INCLUDE)
	if ground.is_empty() or contact.is_empty() or surface.is_empty():
		_fail("a production shader could not be read — the temporal reconstruction test would be vacuous")
		_report()
		return

	_check_edge_reconstruction(ground, contact)
	_check_cavity_reconstruction(ground, contact, surface)
	_report()


func _check_edge_reconstruction(ground: String, contact: String) -> void:
	var control := _max_edge_step(0.5)
	if control <= FLICKER_STEP:
		_fail("the old half-footprint control moves only %.5f luma — the probe cannot reproduce the crawl it claims to catch" % control)
		return

	var ground_scale := _single_number(ground, EDGE_SCALE_PATTERN, GROUND_SHADER)
	var contact_scale := _single_number(contact, EDGE_SCALE_PATTERN, CONTACT_SHADER)
	if is_nan(ground_scale) or is_nan(contact_scale):
		return
	if not is_equal_approx(ground_scale, contact_scale):
		_fail("plate reconstruction differs across the cave contact: ground %.3f, contact %.3f" % [ground_scale, contact_scale])
		return

	var step := _max_edge_step(ground_scale)
	if step > FLICKER_STEP:
		_fail(("the shipped pale/basalt contact moves %.5f luma under a quarter-pixel step "
			+ "(max %.5f) — its %.2f-footprint reconstruction still crawls")
			% [step, FLICKER_STEP, ground_scale])
		return
	print("EDGE TEMPORAL half-footprint control %.5f -> shipped %.5f" % [control, step])


func _check_cavity_reconstruction(
		ground: String, contact: String, surface: String) -> void:
	for entry in [[GROUND_SHADER, ground], [CONTACT_SHADER, contact]]:
		if not String(entry[1]).contains(CAVITY_CALL):
			_fail("%s does not use the shared temporal cavity reconstruction — its unresolved seam is still sampled over one pixel" % String(entry[0]))

	var scale := _single_number(surface, CAVITY_SCALE_PATTERN, SURFACE_INCLUDE)
	var ground_gain := _single_number(
		ground, CAVITY_DEFAULT_PATTERN, GROUND_SHADER)
	var contact_gain := _single_number(
		contact, CAVITY_DEFAULT_PATTERN, CONTACT_SHADER)
	if is_nan(scale) or is_nan(ground_gain) or is_nan(contact_gain):
		return
	if not is_equal_approx(ground_gain, contact_gain):
		_fail("cavity energy differs across the cave contact: ground %.3f, contact %.3f" % [ground_gain, contact_gain])
		return

	var control := _max_cavity_step(1.0, 3.5)
	if control <= FLICKER_STEP:
		_fail("the one-pixel cavity control moves only %.5f luma — the probe cannot reproduce the unresolved-groove crawl" % control)
		return
	var step := _max_cavity_step(scale, ground_gain)
	if step > FLICKER_STEP:
		_fail(("the unresolved cavity moves %.5f luma under a quarter-pixel step "
			+ "(max %.5f) — %.2f footprints at gain %.2f are not temporally stable")
			% [step, FLICKER_STEP, scale, ground_gain])

	var control_energy := _cavity_energy(1.0, 3.5)
	var shipped_energy := _cavity_energy(scale, ground_gain)
	if shipped_energy < control_energy:
		_fail(("the temporal cavity retains only %.1f%% of the old seam energy — "
			+ "stability was bought by softening the protected read away")
			% (100.0 * shipped_energy / control_energy))
		return
	print("CAVITY TEMPORAL one-pixel control %.5f -> shipped %.5f; energy %.5f -> %.5f" % [control, step, control_energy, shipped_energy])


func _max_edge_step(scale: float) -> float:
	var lo := INF
	var hi := -INF
	for colour in [ROCK, BASALT, FERRIC, PALE]:
		var luma := _luma(colour)
		lo = minf(lo, luma)
		hi = maxf(hi, luma)
	var worst := 0.0
	for i in range(-4000, 4001):
		var x := float(i) * SAMPLE_STEP
		worst = maxf(worst, absf(
			_edge_luma(x + CAMERA_STEP, scale, lo, hi)
			- _edge_luma(x, scale, lo, hi)))
	return worst


func _edge_luma(x: float, scale: float, lo: float, hi: float) -> float:
	var neighbour := 0.5 * (
		1.0 - smoothstep(0.0, maxf(scale, 1e-6), absf(x)))
	return lerpf(lo, hi, neighbour) if x >= 0.0 \
		else lerpf(hi, lo, neighbour)


func _max_cavity_step(scale: float, gain: float) -> float:
	var worst := 0.0
	for i in range(0, 4001):
		var s := float(i) * SAMPLE_STEP
		worst = maxf(worst, absf(
			_cavity_luma(s + CAMERA_STEP, scale, gain)
			- _cavity_luma(s, scale, gain)))
	return worst


func _cavity_energy(scale: float, gain: float) -> float:
	var base := _luma(PALE)
	var sum := 0.0
	for i in range(0, 4001):
		var s := float(i) * SAMPLE_STEP
		sum += base - _cavity_luma(s, scale, gain)
	return sum * SAMPLE_STEP


func _cavity_luma(s: float, scale: float, gain: float) -> float:
	var seam_var := AMP_SQUARED * _cavity_spread(s, scale) * RELIEF_SQUARED
	return _luma(PALE) / (1.0 + gain * seam_var)


func _cavity_spread(s: float, scale: float) -> float:
	var h := maxf(scale, 1e-6)
	var half_h := 0.5 * h
	var prof := (minf(s + half_h, CRACK_TO_PIXEL)
		- minf(absf(s - half_h), CRACK_TO_PIXEL)) / h
	var covered := clampf(maxf(
		minf(s + half_h, CRACK_TO_PIXEL)
			- maxf(s - half_h, -CRACK_TO_PIXEL), 0.0) / h, 0.0, 1.0)
	return maxf(covered - prof * prof, 0.0)


func _luma(colour: Vector3) -> float:
	return colour.dot(Vector3(0.2126, 0.7152, 0.0722))


func _single_number(source: String, pattern: String, path: String) -> float:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		_fail("the test's regex did not compile for %s" % path)
		return NAN
	var matches := regex.search_all(source)
	if matches.size() != 1:
		_fail("expected exactly one temporal reconstruction value in %s, found %d" % [path, matches.size()])
		return NAN
	return float(matches[0].get_string(1))


func _source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


func _fail(message: String) -> void:
	_failures.append(message)


func _report() -> void:
	if _failures.is_empty():
		print("TEST PASS — plate contacts and unresolved cavities stay below the crawl threshold without losing seam energy")
		get_tree().quit(0)
		return
	for message in _failures:
		push_error(message)
		print("TEST FAIL — %s" % message)
	get_tree().quit(1)
