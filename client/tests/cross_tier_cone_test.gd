extends Node
## Cross-tier cone agreement — the client half (issue #118).
##
## A cone telegraph is the shape a player steps out of to dodge. The server
## resolves the hit and the client previews it, and if the two disagree the
## player dodges on screen and is hit anyway — the exact desync telegraph
## geometry exists to prevent.
##
## They used to derive the threshold independently: the server compared against
## a precomputed scaled cosine, this tier against `cos(deg_to_rad(half))`. Two
## derivations of the same wedge agree only up to quantization. Now ability data
## carries ONE integer threshold (`cos_half_scaled`) and both tiers consume it,
## so the wedges coincide by construction.
##
## This test reads the SAME committed fixture as
## server/sim/crosstier_cone_test.go, whose expectations were produced by an
## INDEPENDENT high-precision oracle rather than by either implementation. Both
## tiers are therefore checked against a third party — which is what makes a
## shared PASS evidence of agreement rather than of a shared bug.
##
## SCOPE, stated honestly: this proves the two tiers agree on probes that sit a
## clear margin off the wedge boundary. It does NOT claim bit-exact agreement on
## a point lying exactly on the edge — the server's predicate is exact integer
## math while Godot's vectors are 32-bit floats, so a knife-edge point is
## decided within each tier's own rounding. What the shared integer removes is
## the SYSTEMATIC divergence of two different wedges; float rounding at the
## boundary is a separate, far smaller effect (one quantum here is 1e-6 of
## cosine, comfortably coarser than float32 epsilon, so the quantization is the
## meaningful unit).
##
## Pure logic and a res:// read only — no scene, no save, no boot — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/cross_tier_cone_test.tscn

const FIXTURE := "res://tests/data/cross_tier_cone.json"

## Millimetres per metre. The fixture speaks the server's integer millimetres;
## this tier speaks metres.
const MM_PER_M := 1000.0

var _failed := false


func _ready() -> void:
	var fixture := _load_fixture()
	if fixture.is_empty():
		return

	if not _check_fixture_is_substantive(fixture):
		return
	if not _check_probes_agree(fixture):
		return
	if not _check_ceil_rounding_never_widens():
		return
	if not _check_threshold_is_consumed_not_derived():
		return

	print("TEST PASS — client cone resolution matches the shared cross-tier fixture (consumed threshold, ceil bias, no per-tier derivation)")
	get_tree().quit(0)


## Read and decode the shared fixture, failing loudly if it is missing or
## malformed. A missing fixture must never read as "nothing to check".
func _load_fixture() -> Dictionary:
	var file := FileAccess.open(FIXTURE, FileAccess.READ)
	if file == null:
		_fail("cannot open the shared cross-tier fixture %s — it is the anchor for both tiers" % FIXTURE)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		_fail("%s did not decode to a JSON object" % FIXTURE)
		return {}
	return parsed


## Non-vacuity floor, mirroring the Go half. A fixture that lost its cones or
## its expectations would turn every assertion below into a silent pass, and a
## fixture authored at a different scale would rescale every threshold on both
## tiers at once.
func _check_fixture_is_substantive(fixture: Dictionary) -> bool:
	if int(fixture.get("cos_scale", -1)) != Telegraph.COS_SCALE:
		_fail("fixture cos_scale is %s but Telegraph.COS_SCALE is %d — a mismatched scale silently rescales every threshold"
			% [fixture.get("cos_scale", "<missing>"), Telegraph.COS_SCALE])
		return false

	var cones: Variant = fixture.get("cones")
	if cones is not Array or (cones as Array).size() < 2:
		_fail("fixture must declare at least 2 cones (a wedge and a degenerate full disc)")
		return false

	var probes := 0
	var caught := 0
	for cone: Dictionary in cones:
		var list: Variant = cone.get("probes")
		if list is not Array or (list as Array).is_empty():
			_fail("cone '%s' has no probes" % cone.get("name", "<unnamed>"))
			return false
		for probe: Dictionary in list:
			probes += 1
			if bool(probe.get("expect_caught", false)):
				caught += 1

	if probes < 10:
		_fail("fixture has %d probes, want at least 10" % probes)
		return false
	# Both outcomes must appear, or a predicate stuck at a constant would
	# satisfy the entire fixture.
	if caught == 0 or caught == probes:
		_fail("fixture probes all expect the same outcome (%d/%d caught) — it cannot distinguish a correct predicate from a constant"
			% [caught, probes])
		return false
	return true


## The shared contract: every probe must resolve exactly as the independent
## oracle says, using the threshold the fixture carries rather than any angle
## this tier works out for itself.
func _check_probes_agree(fixture: Dictionary) -> bool:
	for cone: Dictionary in fixture["cones"]:
		var apex := _vec_m(cone["apex_mm"])
		var facing := _vec_m(cone["facing_mm"])
		var range_m := float(cone["range_mm"]) / MM_PER_M
		var cos_half_scaled := int(cone["cos_half_scaled"])
		for probe: Dictionary in cone["probes"]:
			var point := _vec_m(probe["point_mm"])
			var expected := bool(probe["expect_caught"])
			var actual := Telegraph.in_cone_scaled(apex, facing, range_m, cos_half_scaled, point)
			if actual != expected:
				_fail("cone '%s' probe %s [%s]: in_cone_scaled returned %s, the shared fixture expects %s"
					% [cone.get("name", "<unnamed>"), point, probe.get("note", ""), actual, expected])
				return false
	return true


## The rounding DIRECTION is the safety property behind the whole contract: a
## larger cosine is a NARROWER wedge, so converting an author's degrees with a
## ceil guarantees the shared threshold never describes a wedge WIDER than the
## angle written. The residual disagreement can then only spare a player the
## client drew as hit, never hit one it drew as safe.
##
## Asserted as a property across many angles rather than at one hand-picked
## value, so it cannot pass by coincidence.
func _check_ceil_rounding_never_widens() -> bool:
	for deg: float in [0.0, 1.0, 7.5, 15.0, 30.0, 45.0, 60.0, 89.0, 90.0, 120.0, 179.0, 180.0]:
		var scaled := Telegraph.cos_half_scaled_from_deg(deg)
		var exact := cos(deg_to_rad(deg))
		var quantized := float(scaled) / float(Telegraph.COS_SCALE)
		if quantized < exact - 1e-9:
			_fail("cos_half_scaled_from_deg(%s) = %d quantizes to %s, BELOW cos = %s — a lower cosine is a WIDER wedge, the one direction the bias forbids"
				% [deg, scaled, quantized, exact])
			return false
		# A ceil must also stay within one quantum, or it is not a rounding.
		if quantized > exact + 1.0 / float(Telegraph.COS_SCALE) + 1e-9:
			_fail("cos_half_scaled_from_deg(%s) = %d is more than one quantum above cos = %s — that is not a ceil"
				% [deg, scaled, exact])
			return false
	# The clamp mirrors in_cone: 180 deg is a full disc, 0 deg a degenerate ray.
	if Telegraph.cos_half_scaled_from_deg(180.0) != -Telegraph.COS_SCALE:
		_fail("a 180 deg half-angle must quantize to -COS_SCALE (a full disc)")
		return false
	if Telegraph.cos_half_scaled_from_deg(0.0) != Telegraph.COS_SCALE:
		_fail("a 0 deg half-angle must quantize to +COS_SCALE")
		return false
	return true


## The property that makes the shared integer worth carrying: resolution must
## read the threshold it is GIVEN. If two different thresholds produced the same
## answer for a point between them, the field would be decorative and a genuine
## divergence could hide behind a green fixture.
func _check_threshold_is_consumed_not_derived() -> bool:
	var apex := Vector3.ZERO
	var fwd := Vector3(0, 0, -1)
	# ~31 deg off axis: inside a 45 deg wedge, outside a 15 deg one.
	var probe := Vector3(12.0, 0, -20.0)
	if not Telegraph.in_cone_scaled(apex, fwd, 30.0, 707107, probe):
		_fail("the 45 deg wedge must catch a point ~31 deg off axis")
		return false
	if Telegraph.in_cone_scaled(apex, fwd, 30.0, 965926, probe):
		_fail("the 15 deg wedge must NOT catch a point ~31 deg off axis — the threshold is being ignored")
		return false
	return true


## A fixture point in millimetres as a client-space Vector3 in metres.
func _vec_m(mm: Dictionary) -> Vector3:
	return Vector3(
		float(mm["x"]) / MM_PER_M,
		float(mm["y"]) / MM_PER_M,
		float(mm["z"]) / MM_PER_M)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
