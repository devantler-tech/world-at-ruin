extends Node
## Regression test for the Telegraph geometry library (issue #54).
##
## Telegraphs are the combat "signal in the ground": the server resolves a hit
## and the client previews it by asking the SAME question — is this point inside
## this shape? Both tiers must agree, so the predicate has to be exact at its
## edges, blind to height (a mark on the ground, not a volume), and safe on
## degenerate inputs (there is no undo in this game — a wrong hit-test is a
## permanent wrong outcome). This pins each shape's cardinal cases, its inclusive
## boundaries, the behind-caster refusals, and the planar (Y-invariance) law.
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally
## and deterministic in CI.
##
## Run: godot --headless --path client res://tests/telegraph_shapes_test.tscn

var _failed := false


func _ready() -> void:
	# --- circle: a filled disc; "step out of the circle" ---
	_check(Telegraph.in_circle(Vector3.ZERO, 5.0, Vector3(5, 0, 0)), true, "circle: on the +X edge is inside")
	_check(Telegraph.in_circle(Vector3.ZERO, 5.0, Vector3(0, 0, 5)), true, "circle: on the +Z edge is inside")
	_check(Telegraph.in_circle(Vector3.ZERO, 5.0, Vector3(5.001, 0, 0)), false, "circle: just past the edge is outside")
	_check(Telegraph.in_circle(Vector3.ZERO, 5.0, Vector3.ZERO), true, "circle: the centre is inside")
	_check(Telegraph.in_circle(Vector3.ZERO, 5.0, Vector3(0, 100, 4.9)), true, "circle: height is ignored")
	_check(Telegraph.in_circle(Vector3(10, 0, -10), 2.0, Vector3(11, 5, -9)), true, "circle: off-origin centre, inside")
	_check(Telegraph.in_circle(Vector3.ZERO, -1.0, Vector3.ZERO), false, "circle: negative radius catches nothing")
	if _failed:
		return

	# --- ring: a danger band with a safe hole and safety beyond the rim ---
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(3, 0, 0)), true, "ring: inside the band")
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(1, 0, 0)), false, "ring: inside the safe hole is outside")
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(6, 0, 0)), false, "ring: beyond the rim is outside")
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(2, 0, 0)), true, "ring: the inner edge is inside")
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(0, 0, 5)), true, "ring: the outer edge is inside")
	_check(Telegraph.in_ring(Vector3.ZERO, 5.0, 2.0, Vector3(3, 0, 0)), true, "ring: swapped radii behave the same")
	_check(Telegraph.in_ring(Vector3.ZERO, -1.0, 3.0, Vector3.ZERO), true, "ring: negative inner clamps to a filled disc")
	_check(Telegraph.in_ring(Vector3.ZERO, 2.0, 5.0, Vector3(0, 50, 3)), true, "ring: height is ignored")
	if _failed:
		return

	# --- cone: a sector you cast; facing world-forward (-Z), 45 deg half-angle ---
	var fwd := Vector3(0, 0, -1)
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, Vector3(0, 0, -5)), true, "cone: straight ahead is inside")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, Vector3.ZERO), true, "cone: the apex is inside")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, Vector3(0, 0, 5)), false, "cone: directly behind is outside")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, Vector3(0, 0, -11)), false, "cone: past the range is outside")
	# 44 deg inside, 46 deg outside — stay off the exact-edge float knife.
	var in44 := Vector3(sin(deg_to_rad(44.0)) * 5.0, 0, -cos(deg_to_rad(44.0)) * 5.0)
	var out46 := Vector3(sin(deg_to_rad(46.0)) * 5.0, 0, -cos(deg_to_rad(46.0)) * 5.0)
	var in44_left := Vector3(-sin(deg_to_rad(44.0)) * 5.0, 0, -cos(deg_to_rad(44.0)) * 5.0)
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, in44), true, "cone: just inside the angular edge (44 deg)")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, out46), false, "cone: just outside the angular edge (46 deg)")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, in44_left), true, "cone: symmetric on the other side")
	_check(Telegraph.in_cone(Vector3.ZERO, Vector3(0, 0, -3), 10.0, 45.0, Vector3(0, 0, -5)), true, "cone: unnormalised facing is fine")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 180.0, Vector3(0, 0, 5)), true, "cone: 180 deg half-angle is a full disc")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, 10.0, 45.0, Vector3(0, 99, -5)), true, "cone: height is ignored")
	_check(Telegraph.in_cone(Vector3.ZERO, fwd, -1.0, 45.0, Vector3(0, 0, -1)), false, "cone: negative range catches nothing")
	if _failed:
		return

	# --- rect: a beam from the caster; origin at ZERO, facing -Z, length 8, half-width 1.5 ---
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(0, 0, -4)), true, "rect: on the centre line is inside")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(1.5, 0, -4)), true, "rect: on the side edge is inside")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(1.6, 0, -4)), false, "rect: just past the side is outside")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(0, 0, 1)), false, "rect: behind the origin is outside")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(0, 0, -8)), true, "rect: the far edge is inside")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(0, 0, -8.01)), false, "rect: just past the far edge is outside")
	var right := Vector3(1, 0, 0)
	_check(Telegraph.in_rect(Vector3.ZERO, right, 8.0, 1.5, Vector3(4, 0, 0)), true, "rect: rotated beam, on the centre line")
	_check(Telegraph.in_rect(Vector3.ZERO, right, 8.0, 1.5, Vector3(4, 0, 1.5)), true, "rect: rotated beam, on the side edge")
	_check(Telegraph.in_rect(Vector3.ZERO, right, 8.0, 1.5, Vector3(4, 0, 1.6)), false, "rect: rotated beam, just past the side")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, 1.5, Vector3(0, 42, -4)), true, "rect: height is ignored")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, -1.0, 1.5, Vector3(0, 0, -1)), false, "rect: negative length catches nothing")
	_check(Telegraph.in_rect(Vector3.ZERO, fwd, 8.0, -1.0, Vector3.ZERO), false, "rect: negative width catches nothing")
	if _failed:
		return

	# --- the planar law: a swept height never changes membership for any shape ---
	var right2 := Vector3(1, 0, 0)
	for y: float in [-1000.0, -1.0, 0.0, 1.0, 1000.0]:
		var p := Vector3(3, y, 0)
		if not Telegraph.in_circle(Vector3.ZERO, 5.0, p) \
				or not Telegraph.in_cone(Vector3.ZERO, right2, 10.0, 45.0, p) \
				or not Telegraph.in_rect(Vector3.ZERO, right2, 8.0, 1.5, p):
			_fail("Y-invariance broke at y=%s" % y)
			return

	print("TEST PASS — telegraph geometry predicates hold (circle, ring, cone, rect; planar; degenerate-safe)")
	get_tree().quit(0)


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_fail("%s — expected %s, got %s" % [label, expected, actual])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
