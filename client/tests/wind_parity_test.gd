extends Node
## Pins [Wind] to the shader the wind actually came from (#233).
##
## The wind's facts were born as uniform defaults in
## `shaders/foliage.gdshader`, where nothing but the GPU could read them. #233
## needed a second system — the drifting ash — to blow on the SAME wind, and a
## shader uniform is not reachable from GDScript, so [Wind] restates those facts
## in code.
##
## Restating a fact is how facts drift apart. Nothing would fail if the shader's
## direction changed and the ash kept blowing the old way: the scrub would lean
## one way, the ash would move another, and the world would quietly stop
## agreeing with itself — a wrongness with no error, visible only to someone who
## stood still and watched both at once. This test is the join. It reads the
## shader's own source text and refuses any disagreement.
##
## Deliberately a SOURCE-TEXT check rather than a rendering one. The values
## being compared are shader uniform defaults, which are only observable through
## a render, and volumetrics and MultiMesh are both unreadable under
## `--headless`. Parsing the file is the only way to hold this where CI runs.

## The shader the wind is authored in.
const FOLIAGE_SHADER_PATH := "res://shaders/foliage.gdshader"

## Each law below isolates ONE restated fact, so a failure names which fact
## drifted rather than reporting that something, somewhere, disagrees. Values
## are compared NUMERICALLY, never as source text: `1.0` and `1.00` are the same
## direction, and a test that called them different would fail on a reformat
## while a real divergence still slipped past.


func _ready() -> void:
	var source := _shader_source()
	if source == "":
		# MISSING-SOURCE GUARD. Without it this test's strongest property is
		# also its most fragile: every law below is "the shader says X", and a
		# shader that cannot be read says nothing at all — so a renamed or moved
		# file would turn the whole test green while checking nothing. A guard
		# that passes when its subject is absent is worse than no guard.
		_fail("could not read %s — the shader this test pins Wind against is missing or unreadable, so every law below would pass while checking nothing" % FOLIAGE_SHADER_PATH)
		return

	# 1. DIRECTION. The one fact that must match exactly: it is what makes this
	# one wind rather than two. The ash and the scrub may move at different
	# speeds and scales, but if they disagree about which way the wind blows,
	# the world contradicts itself on screen.
	var dir := _capture(source, "uniform\\s+vec3\\s+wind_dir\\s*=\\s*vec3\\(([^)]*)\\)")
	if dir == "":
		_fail("no `uniform vec3 wind_dir = vec3(...)` in %s — Wind.DIR restates a value the shader no longer declares" % FOLIAGE_SHADER_PATH)
		return
	var parts := dir.split(",")
	if parts.size() != 3:
		_fail("`wind_dir` in %s has %d components, not 3 — Wind.DIR cannot restate it" % [FOLIAGE_SHADER_PATH, parts.size()])
		return
	var shader_dir := Vector3(
		float(parts[0].strip_edges()),
		float(parts[1].strip_edges()),
		float(parts[2].strip_edges())
	)
	# Compared as a DIRECTION, not as three literals: the shader normalises
	# wind_dir before use, so what must agree is where the wind points, and a
	# rescaled but identical direction is not a divergence.
	if not shader_dir.normalized().is_equal_approx(Wind.axis()):
		_fail("wind direction disagrees: the shader blows %v (axis %v) but Wind.DIR is %v (axis %v) — the scrub and the ash would lean different ways" % [
			shader_dir, shader_dir.normalized(), Wind.DIR, Wind.axis()
		])
		return
	var got_dir := "%v" % shader_dir

	# 2. WAVELENGTH. Wind.WAVELENGTH is the SCRUB's scale; the ash rides the
	# same wind on its own (HollowFog.DRIFT_WAVELENGTH). Pinned anyway, because
	# it is a restated value like any other and the comment on Wind.WAVELENGTH
	# tells a reader it is the shader's number.
	var wavelength := _capture(source, "uniform\\s+float\\s+wind_wavelength\\s*=\\s*([0-9.]+)")
	if wavelength == "":
		_fail("no `uniform float wind_wavelength = ...` in %s — Wind.WAVELENGTH restates a value the shader no longer declares" % FOLIAGE_SHADER_PATH)
		return
	if not is_equal_approx(float(wavelength), Wind.WAVELENGTH):
		_fail("gust wavelength disagrees: the shader uses %s m/rad but Wind.WAVELENGTH is %s" % [wavelength, _num(Wind.WAVELENGTH)])
		return

	# 3. THE GUST CURVE. Wind.gust() is the GDScript statement of the shader's
	# `0.62 + 0.38 * sin(phase)`. Pinning both halves keeps the two from
	# diverging into different notions of how hard a gust blows.
	var bias := _capture(source, "float\\s+gust\\s*=\\s*([0-9.]+)\\s*\\+")
	var swing := _capture(source, "float\\s+gust\\s*=\\s*[0-9.]+\\s*\\+\\s*([0-9.]+)\\s*\\*\\s*sin")
	if bias == "" or swing == "":
		_fail("no `float gust = <bias> + <swing> * sin(...)` in %s — Wind.gust() restates a curve the shader no longer computes" % FOLIAGE_SHADER_PATH)
		return
	if not is_equal_approx(float(bias), Wind.GUST_BIAS):
		_fail("gust bias disagrees: the shader uses %s but Wind.GUST_BIAS is %s" % [bias, _num(Wind.GUST_BIAS)])
		return
	if not is_equal_approx(float(swing), Wind.GUST_SWING):
		_fail("gust swing disagrees: the shader uses %s but Wind.GUST_SWING is %s" % [swing, _num(Wind.GUST_SWING)])
		return

	# 4. THE CURVE NEVER INVERTS. GUST_BIAS - GUST_SWING < 0 would mean a strong
	# gust bends the scrub INTO the wind — which is what the bias exists to
	# prevent, and is unrecoverable from the sway alone once it happens.
	if Wind.GUST_BIAS - Wind.GUST_SWING < 0.0:
		_fail("Wind.GUST_BIAS (%s) minus GUST_SWING (%s) is negative — a gust would invert the thing it blows on" % [
			_num(Wind.GUST_BIAS), _num(Wind.GUST_SWING)
		])
		return

	# 5. THE PHASE LAW TRAVELS DOWNWIND. The shader's minus sign on the time
	# term is load-bearing and easy to lose: with a plus, points of constant
	# phase travel AGAINST wind_dir and the gusts visibly roll upwind. Held as
	# behaviour rather than as source text, because it is a property of
	# Wind.phase() that a reader of the sign alone cannot check.
	var downwind := Wind.axis() * 30.0
	var later := Wind.phase(downwind, Wind.WAVELENGTH, 1.0, 1.0)
	var now := Wind.phase(downwind, Wind.WAVELENGTH, 1.0, 0.0)
	if later >= now:
		_fail("Wind.phase does not advance downwind over time (%.3f -> %.3f) — the gusts roll upwind" % [now, later])
		return
	# A point further downwind is further along the same gust at any instant.
	if Wind.phase(downwind, Wind.WAVELENGTH, 1.0, 0.0) <= Wind.phase(Vector3.ZERO, Wind.WAVELENGTH, 1.0, 0.0):
		_fail("Wind.phase does not vary with position along the wind — every point would gust simultaneously, which reads as a global pulse rather than weather")
		return

	print("TEST PASS — Wind matches %s: dir vec3(%s), wavelength %s m/rad, gust %s + %s * sin, phase travels downwind" % [
		FOLIAGE_SHADER_PATH, got_dir, wavelength, bias, swing
	])
	get_tree().quit(0)


## The shader's source text, or "" if it cannot be read.
func _shader_source() -> String:
	var shader := load(FOLIAGE_SHADER_PATH) as Shader
	if shader == null:
		return ""
	return shader.code


## First capture group of [param pattern] in [param text], or "" if it does not
## match.
func _capture(text: String, pattern: String) -> String:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return ""
	var m := re.search(text)
	if m == null:
		return ""
	return m.get_string(1)


## A float rendered so the two sides of a mismatch message are directly
## comparable.
func _num(value: float) -> String:
	return String.num(value, 2)


func _fail(message: String) -> void:
	# The runner refuses any log containing this token (#313).
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
