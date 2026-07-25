extends Node3D
## Regression test for ash pooling inside sealed rock (issue #238).
##
## `Main._build_environment` thickens the air toward the ground so ash gathers in
## the Reach's hollows (#211). Depth fog cannot see what is above it, so the same
## term filled the starter cave — a sealed chamber the weather has no way into.
## Measured on the committed seed with the torch flicker pinned (#321), the veil
## held the darkest pixel in `cave-chamber` at 0.117 and the frame to 12.5% of
## the value range; cleared, 0.006 and 22.7%.
##
## [CaveAtmosphere] answers "how much sky is above this point?" and fades the ash
## out with cover. The laws below are what make that safe. Two of them are the
## ones that would have caught the first attempt at this fix, which tested DEPTH
## BELOW TERRAIN and was a measured no-op: the starter cave is carved inside a
## massif standing ON the terrain, so the heightfield there reads about 3.6 m
## below the camera and the chamber is open air by any depth measure. Law 5
## proves a real roof reads as covered; law 6 proves the same point reads as open
## with the roof gone.
##
## Run: godot --headless --path client res://tests/cave_atmosphere_test.tscn

## What #211 shipped, restated here rather than read from the module under test.
## Asserting the constant equals itself would pass for any value at all,
## including one that silently regraded every outdoor frame in the game.
const SHIPPED_SURFACE_DENSITY := 0.06

## Tolerance for float comparison — far narrower than any difference these laws
## distinguish.
const EPS := 1.0e-6


func _ready() -> void:
	# LAW 1 — the open Reach is graded exactly as it shipped. This module exists
	# to subtract weather from caves; a change that also lightened the surface
	# would be a different, unrequested art change riding along.
	if absf(CaveAtmosphere.SURFACE_HEIGHT_DENSITY - SHIPPED_SURFACE_DENSITY) > EPS:
		_fail("SURFACE_HEIGHT_DENSITY must stay %f — it grades every outdoor frame"
			% SHIPPED_SURFACE_DENSITY)
		return
	if absf(CaveAtmosphere.height_density(0.0) - SHIPPED_SURFACE_DENSITY) > EPS:
		_fail("open sky must return the shipped density, got %f"
			% CaveAtmosphere.height_density(0.0))
		return

	# LAW 2 — full cover is fully clear. Not "nearly zero": a residual veil is
	# exactly the defect, so an asymptotic fade would leave it in place forever.
	if absf(CaveAtmosphere.height_density(1.0)) > EPS:
		_fail("full cover must be free of pooled ash, got %f" % CaveAtmosphere.height_density(1.0))
		return

	# LAW 3 — partial cover is a real ramp, strictly between the two ends. This
	# is what forbids a hard flip at the cave mouth, which pops visibly as a
	# player walks under the lip.
	var half := CaveAtmosphere.height_density(0.5)
	if half <= EPS or half >= SHIPPED_SURFACE_DENSITY - EPS:
		_fail("half cover must be strictly between clear and full, got %f" % half)
		return
	var previous := SHIPPED_SURFACE_DENSITY + EPS
	for step in 21:
		var d := CaveAtmosphere.height_density(float(step) / 20.0)
		if d > previous + EPS:
			_fail("density rose with cover at %d/20 (%f after %f)" % [step, d, previous])
			return
		previous = d

	# LAW 4 — a fraction outside 0..1 cannot drive the fog negative. Godot
	# renders a negative fog density as an ever-thickening black rather than as
	# an error, so an unclamped caller bug would look like an art regression
	# nobody could trace.
	for bad: float in [-1.0, -0.001, 1.001, 12.0, INF, -INF]:
		var d := CaveAtmosphere.height_density(bad)
		if d < -EPS or d > SHIPPED_SURFACE_DENSITY + EPS or is_nan(d):
			_fail("fraction %f escaped the clamp and returned %f" % [bad, d])
			return

	# The probe pattern is what turns a flip into a fade, so pin its shape: more
	# than one ray, all of them level with the eye (a probe that started above or
	# below it would sample a different point than the one being lit), and a real
	# horizontal spread. A single centre ray passes every law above and still
	# pops at the mouth.
	var offsets := CaveAtmosphere.probe_offsets()
	if offsets.size() < 2:
		_fail("a single probe cannot fade — the mouth would flip, got %d" % offsets.size())
		return
	var spread_seen := false
	for offset: Vector3 in offsets:
		if absf(offset.y) > EPS:
			_fail("probes must stay level with the eye, got y=%f" % offset.y)
			return
		if Vector2(offset.x, offset.z).length() > EPS:
			spread_seen = true
	if not spread_seen:
		_fail("every probe sits on the eye — the pattern has no spread to fade across")
		return

	# LAW 5 — a real roof reads as covered. Physics, not arithmetic: this is the
	# law the first attempt at this fix failed, and no amount of pure-function
	# testing would have shown it.
	var roof := _slab(Vector3(0.0, 8.0, 0.0), Vector3(60.0, 1.0, 60.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var covered := CaveAtmosphere.sky_blocked_fraction(space, Vector3.ZERO)
	if absf(covered - 1.0) > EPS:
		_fail("a slab overhead must read as fully covered, got %f" % covered)
		return
	if absf(CaveAtmosphere.height_density(covered)) > EPS:
		_fail("under a full roof the ash must clear entirely")
		return

	# LAW 6 — and the SAME point reads as open once the roof is gone. Without
	# this pairing law 5 would also pass on a probe that reports "covered"
	# unconditionally, which is precisely a fix that switches the Reach's
	# weather off everywhere.
	roof.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	space = get_world_3d().direct_space_state
	var open := CaveAtmosphere.sky_blocked_fraction(space, Vector3.ZERO)
	if absf(open) > EPS:
		_fail("with nothing overhead the sky must read as open, got %f" % open)
		return
	if absf(CaveAtmosphere.height_density(open) - SHIPPED_SURFACE_DENSITY) > EPS:
		_fail("under open sky the surface grade must come back exactly")
		return

	# LAW 7 — a roof narrower than the probe spread reads as PARTIAL cover, which
	# is the mouth case the spread exists for. A pattern whose probes all sat at
	# the eye would report this as fully covered and pop.
	var lip := _slab(Vector3(0.0, 8.0, 0.0), Vector3(2.0, 1.0, 2.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	space = get_world_3d().direct_space_state
	var partial := CaveAtmosphere.sky_blocked_fraction(space, Vector3.ZERO)
	lip.queue_free()
	if partial <= EPS or partial >= 1.0 - EPS:
		_fail("a narrow lip must read as partial cover, got %f" % partial)
		return

	print("TEST PASS — ash clears under rock, returns under open sky, and fades across a lip")
	get_tree().quit(0)


## A static box collider centred at `at`, so the probes have real geometry to
## hit rather than a stubbed space state.
func _slab(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	add_child(body)
	return body


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
