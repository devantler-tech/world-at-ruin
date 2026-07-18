extends Node
## The cave capture vantages (tools/frame_capture.gd) are DERIVED from the
## procedural layout, so this test pins every derived point against the
## generator's own signed-density field — the same truth the hull mesh is
## marched from. A layout or generator change that would put the capture
## camera inside a wall (or out under the sky) fails HERE, by name, instead of
## surfacing as a mysterious black frame in the CI evidence job.
##
## Laws, each isolated:
##  1. Fixture precondition — the generator's own spawn reads as open air
##     under rock. If this fails the wiring is broken, not the vantages, and
##     the assertions below would be proving nothing.
##  2. Every derived eye and target sits in open air (density comfortably
##     negative — not grazing a wall).
##  3. Every derived eye is ENCLOSED: rock stands somewhere above it.
##  4. No degenerate look_at (eye and target coincide).
##  5. Controls — each predicate is proven falsifiable: a point outside the
##     massif is open air but NOT enclosed; a point inside the hull above the
##     chamber is enclosed-space rock, NOT open air.
##
## Run: godot --headless --path client res://tests/cave_capture_vantage_test.tscn

const FrameCapture := preload("res://tools/frame_capture.gd")

## Open-air margin in signed-density units (metres, before wall noise): the
## eye must sit clear of the surface, not graze it — torch flicker and wall
## undulation both live near the boundary.
const AIR_MARGIN := 0.3
## Enclosure probe: sample the density field straight up from the eye at this
## step, out to this range. The chamber roof (room radius + HULL_ROCK of 3.0m)
## is far thicker than the step, so a roof cannot be stepped over.
const UP_STEP := 0.5
const UP_RANGE := 16.0


func _ready() -> void:
	var lay: Dictionary = CaveSystemGen.layout(WorldGen.CAVE_SEED)
	var noise: FastNoiseLite = CaveSystemGen.make_noise(WorldGen.CAVE_SEED)

	# 1. Fixture precondition (a fixture failing for an easier reason than its
	# law proves nothing — assert the wiring before asserting the laws).
	var spawn_eye: Vector3 = (lay["spawn"] as Vector3) + Vector3.UP * 1.2
	if not _open_air(spawn_eye, lay, noise):
		_fail("fixture: the generator's own spawn does not read as open air — the field wiring is broken, not the vantages")
		return
	if not _under_rock(spawn_eye, lay, noise):
		_fail("fixture: the generator's own spawn is not under rock")
		return

	# 2–4. The derived vantages.
	var vants: Array = FrameCapture.cave_vantages(lay)
	if vants.size() < 2:
		_fail("expected the chamber and walk-out vantages, got %d" % vants.size())
		return
	for v: Array in vants:
		var vantage_name: String = v[0]
		var eye: Vector3 = v[1]
		var target: Vector3 = v[2]
		if not _open_air(eye, lay, noise):
			_fail("vantage '%s': eye %s is not in open air (density %.2f) — the capture camera would sit in rock" %
				[vantage_name, eye, CaveSystemGen.density(eye, lay, noise)])
			return
		if not _open_air(target, lay, noise):
			_fail("vantage '%s': target %s is not in open air — the shot would frame the inside of a wall" %
				[vantage_name, target])
			return
		if not _under_rock(eye, lay, noise):
			_fail("vantage '%s': eye %s has no rock above it — that is not a cave interior" %
				[vantage_name, eye])
			return
		if eye.distance_to(target) < 1.0:
			_fail("vantage '%s': eye and target nearly coincide — look_at would be degenerate" % vantage_name)
			return

	# 5a. Enclosure is falsifiable: open air outside the massif has no roof.
	var outdoor: Vector3 = (lay["mouth"] as Vector3) + Vector3(12.0, 3.0, 0.0)
	if not _open_air(outdoor, lay, noise):
		_fail("control fixture: the outdoor probe is not in open air — move it clear of the massif")
		return
	if _under_rock(outdoor, lay, noise):
		_fail("control: a point outside the massif reads as roofed — the enclosure check is vacuous")
		return

	# 5b. Open-air is falsifiable: the hull above the chamber is rock.
	var chamber: Dictionary = (lay["rooms"] as Array)[2]
	var in_rock: Vector3 = (chamber["center"] as Vector3) \
		+ Vector3.UP * ((chamber["r"] as float) + CaveSystemGen.HULL_ROCK * 0.5)
	if _open_air(in_rock, lay, noise):
		_fail("control: a point inside the hull reads as open air — the open-air check is vacuous")
		return

	print("TEST PASS — %d cave capture vantages sit in open air under rock (density-field-verified; enclosure and open-air checks each proven falsifiable by an isolated control)" % vants.size())
	get_tree().quit(0)


## Comfortably inside carved void (or outside air): negative density with a
## margin, so a vantage grazing a wall fails rather than flickering.
func _open_air(p: Vector3, lay: Dictionary, noise: FastNoiseLite) -> bool:
	return CaveSystemGen.density(p, lay, noise) < -AIR_MARGIN


## Whether rock stands somewhere above p — the density-field mirror of the
## capture tool's physics upward ray.
func _under_rock(p: Vector3, lay: Dictionary, noise: FastNoiseLite) -> bool:
	var h := UP_STEP
	while h <= UP_RANGE:
		if CaveSystemGen.density(p + Vector3.UP * h, lay, noise) > 0.1:
			return true
		h += UP_STEP
	return false


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
