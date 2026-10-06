extends RefCounted
## Actual shipped world/controller evidence, entered through frame_capture so
## its save-isolation and windowed-render guards run before the game boots.

class CaptureSweep extends "res://tools/plate_crossing_sweep.gd":
	func _ready() -> void:
		pass  # Only the census/path queries run here; the capture drives motion.


func run(capture: Node, dir: String, main: Node) -> void:
	for _i in 150:
		await capture.get_tree().process_frame
	var world := main.get_node_or_null("World") as WorldGen
	var player := main.get_node_or_null("Wanderer") as Player
	if world == null or player == null or world.ground_plates_stats().is_empty():
		capture._fail("slab evidence needs the real World, Wanderer and WAR_GROUND_PLATES=1")
		return
	main.set_process(false)
	# Isolate the terrain crossing from roaming traffic, matching the physics
	# census. The world, player, rig and lighting still come from the real boot.
	for name in ["Npcs", "Creatures"]:
		var traffic := main.get_node_or_null(name)
		if traffic != null:
			main.remove_child(traffic)
			traffic.queue_free()
	await capture.get_tree().physics_frame
	for child in main.get_children():
		if child is CanvasLayer:
			child.visible = false
			child.set_process(false)
	player.set_physics_process(false)
	player.set_process(false)
	player.set_process_unhandled_input(false)
	player.set_character(CharacterFactory.load_recipe("res://recipes/wanderer.json"))
	player.control_enabled = true
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.far = 400.0
	capture.get_tree().root.add_child(cam)
	cam.make_current()
	world.set_ground_plates_enabled(false)
	var original := world.foliage_placements()
	world.set_ground_plates_enabled(true)
	var shrub := Vector3.INF
	for placement in original:
		var pos: Vector3 = placement["pos"]
		if int(placement["kind"]) == FoliageGen.Kind.ASH_SHRUB \
				and world.ground_plate_at(pos.x, pos.z) >= 0 \
				and Vector2(pos.x, pos.z).length() < Vector2(shrub.x, shrub.z).length():
			shrub = pos
	if not shrub.is_finite():
		capture._fail("no baseline shrub on a built slab — foliage evidence is vacuous")
		return
	var focus := Vector3(shrub.x, world.walkable_height_at(shrub.x, shrub.z), shrub.z)
	cam.global_position = focus + Vector3(-2.0, 1.4, 2.0)
	cam.look_at(focus + Vector3.UP * 0.2)
	world.freeze_capture_animation()
	for _i in 60:
		await capture.get_tree().process_frame
	if not await _shot(capture, cam, dir + "/foliage.png"):
		return
	var sweep := CaptureSweep.new()
	capture.add_child(sweep)
	sweep._world = world
	var lip := {}
	for c in sweep._cases():
		if (c[&"mid"] as Vector2).distance_to(Vector2(51.09569, -73.95025)) < 0.001:
			lip = c
			break
	if lip.is_empty():
		sweep.free()
		capture._fail("the photographed glancing regression lip disappeared")
		return
	var path: Array[Vector2] = sweep._path(lip, 45.0)
	sweep.free()
	if path.is_empty():
		capture._fail("the photographed glancing approach is no longer clear")
		return
	var mid: Vector2 = lip[&"mid"]
	var outward: Vector2 = lip[&"outward"]
	var along: Vector2 = lip[&"along"]
	var base := world.surface_height_at(mid.x, mid.y)
	cam.global_position = Vector3(mid.x + outward.x * 3.5 + along.x * 2.5, base + 2.0,
		mid.y + outward.y * 3.5 + along.y * 2.5)
	cam.look_at(Vector3(mid.x, base + 0.8, mid.y))
	player.global_position = Vector3(path[0].x, world.walkable_height_at(path[0].x, path[0].y) + 0.02, path[0].y)
	player.velocity = Vector3.ZERO
	player.face_toward(Vector3(path[1].x, player.global_position.y, path[1].y))
	var dt := 1.0 / Engine.physics_ticks_per_second
	for _i in 8:
		await capture.get_tree().physics_frame
		player._physics_process(dt)
	for _i in 60:
		await capture.get_tree().process_frame
	Input.action_press("move_forward")
	var trace: Array[String] = ["tick,x,y,z,on_floor"]
	var crossed := false
	for tick in 72:
		await capture.get_tree().physics_frame
		player._physics_process(dt)
		var pos := player.global_position
		trace.append("%d,%.6f,%.6f,%.6f,%s" % [tick, pos.x, pos.y, pos.z, player.is_on_floor()])
		if tick % 3 == 0 and not await _shot(capture, cam, "%s/crossing-%03d.png" % [dir, tick]):
			Input.action_release("move_forward")
			return
		if Vector2(pos.x, pos.z).distance_to(path[1]) < 0.3 and world.ground_plate_at(pos.x, pos.z) >= 0:
			crossed = true
			Input.action_release("move_forward")
	Input.action_release("move_forward")
	var file := FileAccess.open(dir + "/crossing.csv", FileAccess.WRITE)
	if file == null:
		capture._fail("could not write the photographed controller trace")
		return
	file.store_string("\n".join(trace) + "\n")
	print("SLAB CAPTURE: shrub=%s cover=%d crossed=%s final=%s floor=%s" % [shrub, world.visible_foliage_placements.size(), crossed, player.global_position, player.is_on_floor()])
	print("CAPTURE PASS: close foliage frame and 24 actual-controller frames written to ", dir)
	capture.get_tree().quit(0)


func _shot(capture: Node, cam: Camera3D, path: String) -> bool:
	cam.make_current()
	await RenderingServer.frame_post_draw
	var frame := capture.get_viewport().get_texture().get_image()
	if frame.is_empty() or frame.save_png(path) != OK:
		capture._fail("could not render and write slab evidence: " + path)
		return false
	return true
