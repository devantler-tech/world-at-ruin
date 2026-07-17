extends Node
## Regression test for the starter cave system in the open world (issue #24,
## WoW-style redirect): the wanderer wakes UNDERGROUND in a real system.
##  1. The spawn is inside the system's protected footprint (the anti-embed
##     net stands down there) with solid floor below and ceiling above.
##  2. The wanderer stays put for 40 physics ticks — the unstick net must
##     not eject him from below the heightfield (the v0.1.5 net exemption).
##  3. The spine is walkable: consecutive path waypoints see each other
##     (no collapsed tunnel), and the mouth opens to the sky at grade.
##
## Run: godot --headless --path client res://tests/starter_cave_test.tscn

const ASSERT_TICK := 40

var _ticks := 0
var _main: Node
var _spawn := Vector3.ZERO


func _ready() -> void:
	# Hermetic: always exercise the first-run character creator too.
	if not _backup_live_save():
		_fail("could not back up the live character save — refusing to touch it")
		return
	CharacterStore.clear()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	if world == null or player == null:
		if _ticks > 10:
			_fail("main scene did not build a World and Wanderer")
		return
	if _ticks == 1:
		_spawn = player.global_position
	if _ticks != ASSERT_TICK:
		return

	var spawn := world.cave_spawn_point()
	if not world.cave_protects(spawn.x, spawn.z):
		_fail("spawn is outside the cave's protected footprint: %s" % spawn)
		return

	var space := get_viewport().find_world_3d().direct_space_state
	var floor_hit := _ray(space, spawn, spawn + Vector3.DOWN * 4.0)
	if floor_hit.is_empty():
		_fail("no cave floor under the spawn")
		return
	if _ray(space, spawn, spawn + Vector3.UP * 15.0).is_empty():
		_fail("no ceiling above the spawn — the chamber is not enclosed")
		return

	if player.global_position.distance_to(_spawn) > 2.0:
		_fail("wanderer moved from spawn %s to %s — ejected from the cave?" % [_spawn, player.global_position])
		return

	# Spine walkability: each consecutive pair of waypoints sees the other.
	var lay := CaveSystemGen.layout(WorldGen.CAVE_SEED)
	var to_world := world.cave_to_world()
	var path: Array = lay["path"]
	var floors: PackedFloat32Array = lay["floors"]
	for i in path.size() - 1:
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var wa := to_world * Vector3(a.x, floors[i] + 1.3, a.z)
		var wb := to_world * Vector3(b.x, floors[i + 1] + 1.3, b.z)
		var hit := _ray(space, wa, wb)
		if not hit.is_empty():
			_fail("tunnel %d is blocked at %s" % [i, hit["position"]])
			return

	# The mouth opens at grade. The hull may roof the walk-out as a rock
	# porch, so measure at WALKING height: the doorway must be clear straight
	# out, and the ground under the porch must sit near mouth level.
	var mouth_world: Vector3 = to_world * (lay["mouth"] as Vector3)
	var out_dir := (to_world.basis * Vector3.RIGHT).normalized()
	var head := mouth_world + Vector3(0, 1.2, 0)
	var out_hit := _ray(space, head, head + out_dir * 8.0)
	if not out_hit.is_empty():
		_fail("the doorway is blocked walking out at %s" % out_hit["position"])
		return
	var probe := mouth_world + out_dir * 4.0
	var ground_hit := _ray(space, probe + Vector3(0, 1.7, 0), probe + Vector3(0, -8, 0))
	if ground_hit.is_empty():
		_fail("no ground outside the mouth")
		return
	var step := absf((ground_hit["position"] as Vector3).y - mouth_world.y)
	if step > 2.5:
		_fail("mouth is a %.2f m cliff above the ground outside" % step)
		return

	_restore_live_save()
	print("TEST PASS — spawn %s, mouth %s, outside step %.2f" % [spawn, mouth_world, step])
	get_tree().quit(0)


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))


func _fail(message: String) -> void:
	_restore_live_save()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)

## The test exercises the first-run creator by clearing the save — but a
## LIVE character save is player state (no-resets law): back it up first and
## put it back whatever happens. CRASH-SAFE: a stale backup from a killed
## run is restored (never clobbered) before a new backup is taken, the copy
## is verified before anything destructive runs, and tree teardown restores
## too.
const BACKUP := "user://character.json.test-backup"


func _exit_tree() -> void:
	_restore_live_save()


func _backup_live_save() -> bool:
	if FileAccess.file_exists(BACKUP):
		# A previous run died before restoring: put the original back first.
		_restore_live_save()
	if not FileAccess.file_exists(CharacterStore.PATH):
		return true
	return DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP)) == OK


func _restore_live_save() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))
