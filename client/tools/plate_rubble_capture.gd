extends Node
## Same-build, close-range evidence for #549. This boots the shipped launch path
## and hides only its new cosmetic batch between the before/after arms.
## Must run windowed at 1280x720 with three distinct absolute save-seam paths
## and WAR_PLATE_RUBBLE_SHOT_DIR pointing at an owned output directory.

const SIZE := Vector2i(1280, 720)
const SETTLE := 60
const STEP := 0.02
const MIN_CHANGED := 0.0001

var _main: Node
var _world: WorldGen
var _cam: Camera3D
var _batch: MultiMeshInstance3D
var _dir := ""
var _failed := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("run windowed: headless cannot provide actual-change frames")
		return
	if not _isolated_paths() or OS.get_environment("WAR_GROUND_PLATES") != "1":
		_fail("redirect all three save seams and explicitly opt into WAR_GROUND_PLATES=1")
		return
	_dir = OS.get_environment("WAR_PLATE_RUBBLE_SHOT_DIR")
	if not _dir.is_absolute_path() or DirAccess.make_dir_recursive_absolute(_dir) != OK:
		_fail("WAR_PLATE_RUBBLE_SHOT_DIR must be an owned absolute output directory")
		return
	if Vector2i(get_viewport().get_visible_rect().size) != SIZE:
		_fail("pass --resolution 1280x720 for reproducible vantages")
		return
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	for _i in 150:
		await get_tree().process_frame
	_world = _main.get_node_or_null("World") as WorldGen
	if _world == null:
		_fail("the actual launch path built no WorldGen")
		return
	_batch = _world.get_node_or_null(WorldGen.GROUND_PLATE_RUBBLE_NODE) as MultiMeshInstance3D
	var records: Dictionary = _world.ground_plate_rubble
	var aprons: Array = records[&"aprons"]
	if _batch == null or aprons.is_empty() or _batch.multimesh.instance_count <= 0:
		_fail("the shipped opted-in world built no rubble to photograph")
		return
	FrameMetrics.quiet(_main, ["Wanderer", "Npcs", "Creatures", "Hud", "Replicas"])
	if _world.freeze_capture_animation() <= 0:
		_fail("the scenery animation pin reached no vegetation material")
		return
	var edge := {}
	var items: Array = records[&"placements"]
	var pools: Array = _main.call("hollow_fog_placements")
	var nearest := INF
	for apron: Dictionary in aprons:
		var centre := _apron_centre(apron, items)
		# The evidence must show a lip, not look through one of the actual
		# dense lowland pools. Their shipping nodes remain fully enabled.
		if _world.surface_height_at(centre.x, centre.y) < 1.5 \
				or _inside_pool(centre, pools):
			continue
		if centre.length_squared() < nearest:
			nearest = centre.length_squared()
			edge = apron
	if edge.is_empty():
		_fail("no actual rubble apron has a clear elevated capture vantage")
		return
	var centre := _apron_centre(edge, items)
	var outward: Vector2 = edge[&"outward"]
	var tangent := Vector2(-outward.y, outward.x)
	var target := Vector3(centre.x,
		_world.surface_height_at(centre.x, centre.y) + 0.06, centre.y)
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.far = 400.0
	get_tree().root.add_child(_cam)
	var report := {"source_identity": str(edge[&"identity"]),
		"source_edge": int(edge[&"edge_index"]), "ash_cover": float(edge[&"ash_cover"]),
		"edge_a": _xz(edge[&"a"]), "edge_b": _xz(edge[&"b"]),
		"aprons": aprons.size(), "placements": (records[&"placements"] as Array).size(),
		"placement_unit": "cluster_instances", "chunks_per_cluster": 4,
		"cluster_footprint_radius": ExposedSlabRubble.mesh_radius(_batch.multimesh.mesh),
		"selected_clusters": _apron_clusters(edge, items),
		"max_placements": ExposedSlabRubble.MAX_PLACEMENTS,
		"batch_surfaces": (_batch.multimesh.mesh as ArrayMesh).get_surface_count(),
		"views": []}
	for view: String in ["walking", "grazing"]:
		var eye_xz := centre + outward * (3.4 if view == "walking" else 1.8) \
			+ tangent * (1.1 if view == "walking" else 0.55)
		_cam.position = Vector3(eye_xz.x,
			_world.surface_height_at(eye_xz.x, eye_xz.y)
			+ (1.5 if view == "walking" else 0.60), eye_xz.y)
		_cam.look_at(target, Vector3.UP)
		_cam.current = true
		_main.call("_track_cave_atmosphere")
		if not bool(_main.call("freeze_first_run_backdrop_animation")):
			_fail("could not pin the shipping ash-pool phase")
			return
		_batch.visible = false
		var before := await _frame(view + "-before")
		var off_draws := _draws()
		var repeat := await _frame(view + "-before-repeat")
		_batch.visible = true
		var after := await _frame(view + "-after")
		var on_draws := _draws()
		_batch.visible = false
		var restored := await _frame(view + "-restored")
		if _failed:
			return
		var a := FrameMetrics.luma_buffer(before)
		var difference := FrameMetrics.changed_fraction(a, FrameMetrics.luma_buffer(after), STEP)
		var floor := maxf(FrameMetrics.changed_fraction(a, FrameMetrics.luma_buffer(repeat), STEP),
			FrameMetrics.changed_fraction(a, FrameMetrics.luma_buffer(restored), STEP))
		(report["views"] as Array).append({"name": view, "eye": str(_cam.position),
			"changed_fraction": difference, "control_fraction": floor,
			"draw_calls_before": off_draws, "draw_calls_after": on_draws})
		if difference < MIN_CHANGED or difference <= floor * 2.0 \
				or on_draws - off_draws > 1:
			_write_report(report)
			_fail("%s did not isolate visible rubble within one draw call: changed %.6f, control %.6f, draws %d" % [view, difference, floor, on_draws - off_draws])
			return
	_world.set_ground_plates_enabled(false)
	await _frame("plates-off")
	if _failed:
		return
	if _batch.visible:
		_fail("the plates-off control retained visible rubble")
		return
	_write_report(report)
	if _failed:
		return
	print("TEST PASS: rubble frames — %d edge aprons, %d cluster instances, two fixed close vantages, same-build hide/show/restore controls and plates-off" % [aprons.size(), (records[&"placements"] as Array).size()])
	get_tree().quit(0)


func _frame(name: String) -> Image:
	for _i in SETTLE:
		_cam.current = true
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image.save_png(_dir.path_join(name + ".png")) != OK:
		_fail("could not write the actual captured frame " + name)
	return image


func _write_report(report: Dictionary) -> void:
	var file := FileAccess.open(_dir.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		_fail("could not write the capture report")
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")


func _isolated_paths() -> bool:
	var seen: Array[String] = []
	for seam: String in ["WAR_SAVE_PATH", "WAR_VAULT_PATH", "WAR_BOOT_RECOVERY_PATH"]:
		var path := OS.get_environment(seam)
		if not path.is_absolute_path() or seen.has(path):
			return false
		seen.append(path)
	return true


func _draws() -> int:
	return int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))


func _xz(at: Vector2) -> Array[float]:
	return [at.x, at.y]


func _apron_centre(apron: Dictionary, items: Array) -> Vector2:
	var centre := Vector2.ZERO
	var start := int(apron[&"placement_start"])
	var count := int(apron[&"placement_count"])
	for i in range(start, start + count):
		var pos: Vector3 = (items[i] as Dictionary)["pos"]
		centre += Vector2(pos.x, pos.z)
	return centre / float(count)


func _apron_clusters(apron: Dictionary, items: Array) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var start := int(apron[&"placement_start"])
	var count := int(apron[&"placement_count"])
	for i in range(start, start + count):
		var item: Dictionary = items[i]
		records.append({"pos": str(item["pos"]), "scale": float(item["scale"])})
	return records


func _inside_pool(point: Vector2, pools: Array) -> bool:
	for pool: Dictionary in pools:
		var pos: Vector3 = pool["pos"]
		var extents: Vector3 = pool["extents"]
		var radius := maxf(extents.x, extents.z) + 4.0
		if point.distance_to(Vector2(pos.x, pos.z)) < radius:
			return true
	return false


func _fail(message: String) -> void:
	_failed = true
	print("TEST FAIL: slab rubble capture — " + message)
	get_tree().quit(1)
