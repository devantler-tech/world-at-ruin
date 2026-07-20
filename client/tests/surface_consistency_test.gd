extends Node
## Asserts WorldGen.surface_height_at agrees with the PHYSICS mesh the
## wanderer actually stands on: raycasts the collision world straight down at
## seeded sample points and compares. Any disagreement beyond tolerance means
## the analytic lookup has drifted from the real triangles — the root cause
## behind ground-clamp false positives (v0.1.2 "bumping" bug).
##
## Run: godot --headless --path client res://tests/surface_consistency_test.tscn

const SAMPLES := 200
const TOLERANCE := 0.1
const RAY_TOP := 60.0
const RAY_BOTTOM := -60.0

var _ticks := 0
var _main: Node
var _boot: IsolatedBoot

func _ready() -> void:
	# Booting the main scene runs the real launch path, which reads — and on the
	# first-run path writes — the player's save and vault. Go through
	# IsolatedBoot so it can only ever reach throwaway probes (#309).
	_boot = IsolatedBoot.new("user://surface_consistency_boot_probe.json")
	_main = _boot.boot()
	if _main == null:
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	add_child(_main)

func _physics_process(_delta: float) -> void:
	if _main == null:
		return  # isolation refused the boot; _fail has already been reported
	_ticks += 1
	if _ticks != 10:
		return
	var world := _main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("main scene did not build a World")
		return
	var space := get_viewport().find_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260716
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var checked := 0
	for i in SAMPLES:
		var x := rng.randf_range(-WorldGen.SIZE / 2.0 + 1.0, WorldGen.SIZE / 2.0 - 1.0)
		var z := rng.randf_range(-WorldGen.SIZE / 2.0 + 1.0, WorldGen.SIZE / 2.0 - 1.0)
		var deviation := _deviation_at(space, world, x, z)
		if deviation < 0.0:
			continue  # Ray hit a ruin above the terrain — skip the sample.
		checked += 1
		if deviation > worst:
			worst = deviation
			worst_at = Vector2(x, z)
	# The exact spot the spawn-time false positive fired at (game-run5 log).
	var spawn_dev := _deviation_at(space, world, 10.7, 14.7)
	print("surface-consistency: %d samples, worst |dev|=%.3f at (%.1f, %.1f); spawn-spot dev=%.3f" %
		[checked, worst, worst_at.x, worst_at.y, spawn_dev])
	if worst > TOLERANCE or (spawn_dev >= 0.0 and spawn_dev > TOLERANCE):
		_fail("surface_height_at disagrees with the physics mesh (worst %.3f m)" % worst)
		return
	if not _boot.real_save_untouched():
		_fail("the boot test touched the player's real save or vault")
		return
	print("SURFACE-TEST PASS")
	get_tree().quit(0)

## |raycast hit − analytic surface| at (x, z), or -1.0 when the sample is
## unusable (no hit, or the ray hit ruin geometry above the terrain).
func _deviation_at(space: PhysicsDirectSpaceState3D, world: WorldGen, x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(x, RAY_TOP, z), Vector3(x, RAY_BOTTOM, z))
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		print("  [debug] (%.1f, %.1f): NO HIT, analytic=%.2f" % [x, z, world.surface_height_at(x, z)])
		return -1.0
	if hit["collider"] != world.get_node("TerrainBody"):
		return -1.0  # Landed on a ruin/shrine/body above the terrain — skip.
	var measured: float = (hit["position"] as Vector3).y
	return absf(measured - world.surface_height_at(x, z))

func _fail(message: String) -> void:
	if _boot != null:
		_boot.end()
	push_error("SURFACE-TEST FAIL: " + message)
	get_tree().quit(1)
