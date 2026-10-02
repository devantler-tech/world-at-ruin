extends Node
## Broad relief must survive averaging away tiny yarns. Inspect the maps
## attached by the actual compositor, not the production fold formula.

var _failed := false


func _ready() -> void:
	var had_flag := OS.has_environment(RaggedCloth.FLAG_ENV)
	var prior := OS.get_environment(RaggedCloth.FLAG_ENV)
	OS.set_environment(RaggedCloth.FLAG_ENV, "1")
	var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	var saved: Dictionary = recipe.duplicate(true)
	var character := CharacterFactory.build(recipe)
	var garment := CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D
	var material := garment.get_active_material(0) as StandardMaterial3D
	var normal := material.normal_texture.get_image()
	var spread := _broad_spread(normal)
	print("GATHERED FOLDS — low-pass lateral normal spread=%.6f" % spread)
	_check(spread > 0.10, "hanging cloth needs broad fold lighting beyond its fine woven yarns")
	var source := garment.mesh.surface_get_material(0) as StandardMaterial3D
	var maps := RaggedCloth.make_maps(RaggedCloth._palette(source.albedo_texture))
	_check(normal.get_data() == maps[1].get_image().get_data(), "independent folds rebake every mip byte deterministically")
	var control := RaggedCloth.make_maps(RaggedCloth._palette(source.albedo_texture), true, false)
	_check(_broad_spread(control[1].get_image()) < 0.04, "the same yarns and sewing without folds cannot impersonate broad relief")
	var painted := Image.create(1024, 1024, false, Image.FORMAT_RGB8)
	painted.fill(Color(0.5, 0.5, 1.0))
	_check(_broad_spread(painted) == 0.0, "a colour-only painted fold with flat lighting fails the same measurement")
	_check(recipe == saved, "fold relief never changes a saved character")
	var point := Vector3(0.02, 0.888 - 0.0002, 0.12)
	var rate: float = (RaggedDrape._drape(point) - point).length() / 0.0002
	print("WAIST JOIN — front displacement rate=%.6f" % rate)
	_check(rate < 0.02, "front hanging drape must meet the pinned waist without an abrupt displacement slope")
	var frame: Basis = RaggedDrape._frame(Vector3(0.02, 0.888, 0.12))
	_check(frame.x.distance_to(Vector3.RIGHT) < 0.002 and frame.y.distance_to(Vector3.UP) < 0.002 and frame.z.distance_to(Vector3.BACK) < 0.002, "lighting frame also meets the pinned waist smoothly")
	_check(RaggedDrape._drape(Vector3(0.02, 0.888, 0.12)) == Vector3(0.02, 0.888, 0.12), "closed waist remains exactly pinned")
	character.free()
	if had_flag:
		OS.set_environment(RaggedCloth.FLAG_ENV, prior)
	else:
		OS.unset_environment(RaggedCloth.FLAG_ENV)
	if _failed:
		get_tree().quit(1)
	else:
		print("TEST PASS — actual ragged cloth has broad deterministic folds and a soft pinned front waist join")
		get_tree().quit(0)


## Average 24x24 pixel windows across the centre of the real hanging panel.
## This region excludes sewn reinforcement and both horizontal stitch rows.
func _broad_spread(map: Image) -> float:
	var low := INF
	var high := -INF
	for x in range(365, 662, 12):
		var total := 0.0
		for y in range(430, 454):
			for column in range(x - 12, x + 12):
				total += map.get_pixel(column, y).r
		var mean := total / (24.0 * 24.0)
		low = minf(low, mean)
		high = maxf(high, mean)
	return high - low


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
