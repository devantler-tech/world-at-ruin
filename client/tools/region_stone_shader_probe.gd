extends Node
## Windowed proof that the shared GPU profile evaluates the CPU region data.

const POINTS := [Vector2.ZERO, Vector2(-72.0, -4.0), Vector2(-92.0, -74.0),
	Vector2(49.5999, 34.0), Vector2(49.6001, 34.0), Vector2(100.0, -100.0)]


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("TEST FAIL: regional shader probe needs a renderer")
		get_tree().quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(8, 8)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
uniform vec2 probe_at;
#include "res://shaders/ground_stone_regions.gdshaderinc"
void fragment() { COLOR = vec4(regional_stone_thresholds(probe_at), 0.0, 1.0); }
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	var sites := GroundRegions.sites(1409, 220.0)
	GroundRegions.configure_stone(material, sites, true)
	var rect := ColorRect.new()
	rect.size = Vector2(8.0, 8.0)
	rect.material = material
	viewport.add_child(rect)
	var maximum := 0.0
	for point: Vector2 in POINTS:
		material.set_shader_parameter("probe_at", point)
		for _frame in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var pixel := viewport.get_texture().get_image().get_pixel(4, 4)
		var want := GroundRegions.stone_for(sites, point.x, point.y)
		var error := maxf(absf(pixel.r - want.x), absf(pixel.g - want.y))
		maximum = maxf(maximum, error)
		if error > 1.0 / 255.0 + 0.000001:
			print("TEST FAIL: GPU profile at %s gives %s, CPU %s" % [point, pixel, want])
			get_tree().quit(1)
			return
	print("TEST PASS: regional GPU/CPU profile — %d fixed points, maximum channel error %.9f within one RGB8 quantum" % [POINTS.size(), maximum])
	get_tree().quit(0)
