extends Node
## Regression test for the volumetric-fog GPU capability gate (issue #158).
##
## Godot's froxel volumetrics allocate an R32_Uint atomic storage image; on
## adapters without that format+usage the whole frame fails to composite. The
## law under test: volumetrics are enabled ONLY where the device affirmatively
## reports support, the fallback is a clean affirmative OFF, and the gate
## never half-applies — a disabled Environment keeps its volumetric parameters
## exactly as they were.
##
## Both states of the gate are covered here (feature-flag-first): the disabled
## path as the headless/CI machine genuinely takes it, the enabled path via
## apply()'s seam. The integration proof for the disabled path is CI's own
## frame capture: its runner lacks the format, so a green capture IS the
## fallback rendering correctly.
##
## Run: godot --headless --path client res://tests/volumetrics_test.tscn

func _ready() -> void:
	# LAW 1 — no rendering device means no volumetrics, unconditionally. This
	# is the branch every headless run (this one included) and every renderer
	# without a RenderingDevice takes.
	if Volumetrics.supported(null):
		_fail("supported(null) must be false — no device, nothing to enable on")
		return

	# LAW 2 — the live probe agrees with the live device. Headless has no
	# rendering device, so here the probe must refuse; on a windowed run the
	# probe must answer exactly what the device answers for the exact
	# format+usage the froxel volumetrics allocate.
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	if rd == null:
		if Volumetrics.probe():
			_fail("probe() must be false when no rendering device exists")
			return
	else:
		var device_says: bool = rd.texture_is_format_supported_for_usage(
			RenderingDevice.DATA_FORMAT_R32_UINT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
		)
		if Volumetrics.probe() != device_says:
			_fail("probe() must report exactly what the device reports")
			return

	# LAW 3 — apply(false) affirmatively disables and touches nothing else,
	# even on an Environment where volumetrics were previously enabled with
	# non-default parameters (the never-half-applied contract).
	var env := Environment.new()
	env.volumetric_fog_enabled = true
	var before_density: float = env.volumetric_fog_density
	var before_albedo: Color = env.volumetric_fog_albedo
	var before_anisotropy: float = env.volumetric_fog_anisotropy
	var before_length: float = env.volumetric_fog_length
	var before_ambient: float = env.volumetric_fog_ambient_inject
	var before_sky: float = env.volumetric_fog_sky_affect
	Volumetrics.apply(env, false)
	if env.volumetric_fog_enabled:
		_fail("apply(false) must disable volumetric fog")
		return
	if env.volumetric_fog_density != before_density \
			or env.volumetric_fog_albedo != before_albedo \
			or env.volumetric_fog_anisotropy != before_anisotropy \
			or env.volumetric_fog_length != before_length \
			or env.volumetric_fog_ambient_inject != before_ambient \
			or env.volumetric_fog_sky_affect != before_sky:
		_fail("apply(false) must leave every volumetric parameter untouched")
		return

	# LAW 4 — apply(true) enables AND applies the full tuned set: enabling
	# with Godot's defaults is not the shipped look, so a missing write here
	# is a real defect, not a cosmetic one.
	Volumetrics.apply(env, true)
	if not env.volumetric_fog_enabled:
		_fail("apply(true) must enable volumetric fog")
		return
	# Environment stores these as 32-bit floats, so a 64-bit GDScript literal
	# does not survive the write exactly — compare approximately.
	if not is_equal_approx(env.volumetric_fog_density, Volumetrics.DENSITY) \
			or not env.volumetric_fog_albedo.is_equal_approx(Volumetrics.ALBEDO) \
			or not is_equal_approx(env.volumetric_fog_anisotropy, Volumetrics.ANISOTROPY) \
			or not is_equal_approx(env.volumetric_fog_length, Volumetrics.LENGTH) \
			or not is_equal_approx(env.volumetric_fog_ambient_inject, Volumetrics.AMBIENT_INJECT) \
			or not is_equal_approx(env.volumetric_fog_sky_affect, Volumetrics.SKY_AFFECT):
		_fail("apply(true) must apply the complete tuned parameter set")
		return

	# LAW 5 — the gate is re-entrant in both directions: a later apply(false)
	# on the same Environment (e.g. a future settings change) must win.
	Volumetrics.apply(env, false)
	if env.volumetric_fog_enabled:
		_fail("apply(false) after apply(true) must disable volumetric fog")
		return

	# LAW 6 — the tuned constants stay inside the ranges the shipped look
	# reasons about: a subtle volume UNDER Godot's 0.05 default density (the
	# depth fog already carries distance haze), forward scattering, and a
	# volume that ends before the depth fog's far field.
	if Volumetrics.DENSITY <= 0.0 or Volumetrics.DENSITY >= 0.05:
		_fail("DENSITY must be a subtle positive volume below Godot's default")
		return
	if Volumetrics.ANISOTROPY <= 0.0 or Volumetrics.ANISOTROPY > 0.9:
		_fail("ANISOTROPY must forward-scatter without going degenerate")
		return
	if Volumetrics.LENGTH <= 0.0:
		_fail("LENGTH must be a positive volume extent")
		return

	# LAW 7 — the capture marker is a MACHINE CONTRACT, not a log pleasantry
	# (#232). CI's frame-capture job parses this line to record, in the evidence
	# artifact, whether the published frames depict the enabled volumetric path
	# or the height-fog fallback. If the token or the verdict field drifts, the
	# job can no longer tell — and a green capture over fallback frames goes
	# back to reading as evidence of a volumetric change. Pinned here because
	# the workflow's grep cannot defend itself.
	var on_line: String = Volumetrics.marker(true)
	var off_line: String = Volumetrics.marker(false)
	for line: String in [on_line, off_line]:
		if not line.begins_with(Volumetrics.CAPTURE_MARKER + " "):
			_fail("marker() must start with CAPTURE_MARKER and a space — CI greps for it")
			return
	# The second whitespace-separated field is what CI reads as the verdict.
	if on_line.split(" ")[1] != "on":
		_fail("marker(true)'s second field must be exactly 'on' — CI parses it")
		return
	if off_line.split(" ")[1] != "off":
		_fail("marker(false)'s second field must be exactly 'off' — CI parses it")
		return
	# The two states must be distinguishable, or the verdict carries no
	# information at all.
	if on_line == off_line:
		_fail("marker() must report the two probe states differently")
		return

	print("TEST PASS — volumetrics enable only where the GPU supports them (gate holds)")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
