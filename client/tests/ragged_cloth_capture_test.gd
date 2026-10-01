extends Node
## The close-inspection plan is fixed and distinct from established cameras.
## This tests the production plan, including front/rear and gameplay distance.


## Check production camera offsets and challenge the garment-only metric with
## synthetic positive and negative controls before accepting the capture plan.
func _ready() -> void:
	var script := load("res://tools/frame_capture.gd") as GDScript
	var capture := script.new() as Node
	if not capture.has_method("ragged_cloth_capture_plan"):
		_fail("actual capture tool has no ragged-cloth inspection plan")
		capture.free()
		return
	var plan: Array = capture.call("ragged_cloth_capture_plan")
	if plan.size() != 3 or plan[0][0] != "cloth_front" or plan[1][0] != "cloth_rear" or plan[2][0] != "cloth_gameplay":
		_fail("fixed inspection plan must include front, rear and gameplay range")
	elif Vector3(plan[0][1]).z * Vector3(plan[1][1]).z >= 0.0:
		_fail("front and rear cameras must face opposite garment panels")
	elif Vector3(plan[2][1]).distance_to(plan[2][2]) < 2.5:
		_fail("gameplay camera must inspect minified threads from beyond close range")
	else:
		if not _pixel_controls(capture):
			capture.free()
			return
		print("TEST PASS — ragged-cloth evidence frames both panels and gameplay range")
		get_tree().quit(0)
	capture.free()


## Only actual garment marker pixels may contribute to the read. An unrelated
## background change must measure zero, while a changed garment must not.
func _pixel_controls(capture: Node) -> bool:
	var mask := Image.create(8, 8, false, Image.FORMAT_RGB8)
	mask.fill(Color.BLACK)
	if not capture.call("ragged_cloth_pixels", mask).is_empty():
		_fail("an absent garment must produce no mask points")
		return false
	mask.set_pixel(2, 2, Color.MAGENTA)
	var points: Array[Vector2i] = capture.call("ragged_cloth_pixels", mask)
	if points != [Vector2i(2, 2)]:
		_fail("mask sampling must name only the drawn garment pixel")
		return false
	var a := Image.create(8, 8, false, Image.FORMAT_RGB8)
	a.fill(Color.BLACK)
	var b := a.duplicate() as Image
	b.set_pixel(4, 4, Color.WHITE)
	if capture.call("ragged_cloth_difference", a, b, points) != 0.0:
		_fail("background-only changes must not masquerade as material detail")
		return false
	b.set_pixel(2, 2, Color.WHITE)
	if capture.call("ragged_cloth_difference", a, b, points) < 0.9:
		_fail("the evidence metric must detect a changed garment")
		return false
	return true


## Fail through the canonical scene-runner marker as well as the exit status.
func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — " + message)
	get_tree().quit(1)
