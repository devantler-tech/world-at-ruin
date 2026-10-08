extends Node
## Actual launch-path evidence: two committed near-field vantages, neutral-profile
## ablation and unchanged repeat floor. Never judges taste or GPU activation.

const VIEWS := [
	["bonepale", Vector2(-68.0, -2.0), Vector2(-72.0, -4.0)],
	["cinderreach", Vector2(-86.0, -69.0), Vector2(-92.0, -74.0)],
]
const SETTLE := 60

var _main: Node
var _world: WorldGen
var _cam: Camera3D
var _dir := ""
var _failed := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("run windowed: headless renders no evidence")
		return
	if OS.get_environment("WAR_GROUND_PLATES") != "1" \
			or Vector2i(get_viewport().get_visible_rect().size) != Vector2i(1280, 720):
		_fail("opt into ground plates and pass --resolution 1280x720")
		return
	var paths: Array[String] = []
	for seam: String in ["WAR_SAVE_PATH", "WAR_VAULT_PATH", "WAR_BOOT_RECOVERY_PATH"]:
		var path := OS.get_environment(seam)
		if not path.is_absolute_path() or paths.has(path):
			_fail("redirect all three save seams to distinct owned absolute paths")
			return
		paths.append(path)
	_dir = OS.get_environment("WAR_REGION_STONE_SHOT_DIR")
	if not _dir.is_absolute_path() or DirAccess.make_dir_recursive_absolute(_dir) != OK:
		_fail("set an owned absolute WAR_REGION_STONE_SHOT_DIR")
		return
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	for _i in 150:
		await get_tree().process_frame
	_world = _main.get_node("World") as WorldGen
	FrameMetrics.quiet(_main, ["Wanderer", "Npcs", "Creatures", "Hud", "Replicas"])
	if _world.freeze_capture_animation() <= 0:
		_fail("no scenery material was pinned")
		return
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 400.0
	get_tree().root.add_child(_cam)
	_world.set_ground_plates_enabled(true, false)
	var neutral_count := _counts()
	var report := {"seed": WorldGen.WORLD_SEED, "neutral_built": neutral_count,
		"views": [], "pixel_step": 0.02}
	for view: Array in VIEWS:
		var name: String = view[0]
		var eye: Vector2 = view[1]
		var target: Vector2 = view[2]
		if _world.region_name_at(target.x, target.y) != StringName(name):
			_fail("the fixed %s vantage stands in another region" % name)
			return
		_cam.position = Vector3(eye.x, _world.surface_height_at(eye.x, eye.y) + 1.7, eye.y)
		_cam.look_at(Vector3(target.x,
			_world.surface_height_at(target.x, target.y) + 0.05, target.y), Vector3.UP)
		_cam.current = true
		_main.call("_track_cave_atmosphere")
		if not bool(_main.call("freeze_first_run_backdrop_animation")):
			_fail("the shipping ash-pool phase was not pinned")
			return
		_world.set_ground_plates_enabled(true, false)
		var before := await _frame(name + "-neutral")
		var repeat := await _frame(name + "-neutral-repeat")
		_world.set_ground_plates_enabled(true, true)
		var after := await _frame(name + "-regional")
		report["regional_built"] = _counts()
		_world.set_ground_plates_enabled(true, false)
		var restored := await _frame(name + "-restored")
		if _failed:
			return
		var base := FrameMetrics.luma_buffer(before)
		var changed := FrameMetrics.changed_fraction(base, FrameMetrics.luma_buffer(after), 0.02)
		var floor := maxf(FrameMetrics.changed_fraction(base, FrameMetrics.luma_buffer(repeat), 0.02),
			FrameMetrics.changed_fraction(base, FrameMetrics.luma_buffer(restored), 0.02))
		(report["views"] as Array).append({"name": name, "eye": str(_cam.position),
			"target": str(target), "changed_fraction": changed, "control_fraction": floor})
		if changed < 0.005 or changed <= floor * 2.0:
			_fail("%s cannot distinguish the regional treatment from its control: %.6f/%.6f"
				% [name, changed, floor])
			return
	_world.set_ground_plates_enabled(false, true)
	var off_regional := await _frame("plates-off-regional")
	_world.set_ground_plates_enabled(false, false)
	var off_neutral := await _frame("plates-off-neutral")
	if _failed:
		return
	var off_change := FrameMetrics.changed_fraction(FrameMetrics.luma_buffer(off_neutral),
		FrameMetrics.luma_buffer(off_regional), 0.02)
	report["plates_off_changed_fraction"] = off_change
	if off_change != 0.0:
		_fail("regional profiles changed the plates-off rendered control")
		return
	var file := FileAccess.open(_dir.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		_fail("cannot write the capture report")
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	print("TEST PASS: regional stone capture — two fixed region vantages, neutral/repeat/restore controls and plates-off arms")
	get_tree().quit(0)


func _counts() -> Dictionary:
	var counts := {}
	var field := ExposedSlabField.new()
	for top: Dictionary in _world.ground_plate_tops():
		var at := field.site_for(top[&"identity"])
		var name := _world.region_name_at(at.x, at.y)
		counts[name] = int(counts.get(name, 0)) + 1
	return counts


func _frame(name: String) -> Image:
	for _i in SETTLE:
		_cam.current = true
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	if frame.save_png(_dir.path_join(name + ".png")) != OK:
		_fail("cannot save actual frame " + name)
	return frame


func _fail(message: String) -> void:
	_failed = true
	print("TEST FAIL: regional stone capture — " + message)
	get_tree().quit(1)
