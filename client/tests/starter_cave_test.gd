extends Node
## Regression test for the starter cave in the open world (issue #24 stage 3):
##  1. The spawn point is inside the chamber, above the flattened clearing
##     terrain (the anti-embed safety net must never see it as buried).
##  2. The chamber is physically real: a ray down from the spawn hits a cave
##     floor above the terrain; a ray up hits the ceiling; a ray down from
##     high above the site hits the rock dome well above the clearing.
##  3. The wanderer stays put: after 40 physics ticks the player is still at
##     the spawn (the v0.1.x unstick net must not eject him from the cave).
##  4. The mouth is walkable: just outside the mouth, ground exists within a
##     step of the mouth floor (the threshold ramp).
##
## Run: godot --headless --path client res://tests/starter_cave_test.tscn

const ASSERT_TICK := 40

var _ticks := 0
var _main: Node
var _spawn := Vector3.ZERO


func _ready() -> void:
	# Hermetic: the first-run character creator must be exercised too, so the
	# test always boots without a saved character.
	_backup_live_save()
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
	var site := Vector3(WorldGen.CAVE_SITE.x, 0, WorldGen.CAVE_SITE.y)

	# 1. Spawn inside the chamber, above the terrain heightfield.
	if Vector2(spawn.x - site.x, spawn.z - site.z).length() > WorldGen.CAVE_RADIUS:
		_fail("spawn is outside the chamber footprint: %s" % spawn)
		return
	var terrain := world.surface_height_at(spawn.x, spawn.z)
	if terrain <= WorldGen.NO_GROUND or spawn.y <= terrain:
		_fail("spawn (y=%.2f) is not above the terrain (%.2f) — the unstick net would fire" % [spawn.y, terrain])
		return

	# 2. Chamber physicality.
	var space := get_viewport().find_world_3d().direct_space_state
	var floor_hit := _ray(space, spawn, spawn + Vector3.DOWN * 5.0)
	if floor_hit.is_empty():
		_fail("no cave floor under the spawn")
		return
	var floor_y := (floor_hit["position"] as Vector3).y
	if floor_y <= terrain:
		_fail("cave floor (%.2f) is not above terrain (%.2f)" % [floor_y, terrain])
		return
	if _ray(space, spawn, spawn + Vector3.UP * 12.0).is_empty():
		_fail("no cave ceiling above the spawn — chamber is not enclosed")
		return
	var dome_hit := _ray(space, site + Vector3(0, 40, 0), site + Vector3(0, -40, 0))
	if dome_hit.is_empty():
		_fail("nothing above the cave site")
		return
	var dome_y := (dome_hit["position"] as Vector3).y
	if dome_y < world.surface_height_at(site.x, site.z) + 3.0:
		_fail("no rock dome above the clearing (hit y=%.2f)" % dome_y)
		return

	# 3. The wanderer stays put (creator holds input; physics keeps running).
	if player.global_position.distance_to(_spawn) > 2.0:
		_fail("wanderer moved from spawn %s to %s — ejected from the cave?" % [_spawn, player.global_position])
		return

	# 4. Walkable mouth: ground within a step just outside the mouth.
	var mouth_dir := (Vector3.ZERO - site).normalized()
	var outside := site + mouth_dir * (WorldGen.CAVE_RADIUS + 1.2)
	var mouth_hit := _ray(space, outside + Vector3(0, 6, 0), outside + Vector3(0, -6, 0))
	if mouth_hit.is_empty():
		_fail("no ground just outside the mouth")
		return
	var step := absf((mouth_hit["position"] as Vector3).y - floor_y)
	if step > 1.2:
		_fail("mouth threshold is a %.2f m cliff" % step)
		return

	_restore_live_save()
	print("TEST PASS — spawn %s, floor %.2f, terrain %.2f, dome %.2f, mouth step %.2f" %
		[spawn, floor_y, terrain, dome_y, step])
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
## put it back whatever happens.
const BACKUP := "user://character.json.test-backup"


func _backup_live_save() -> void:
	if FileAccess.file_exists(CharacterStore.PATH):
		DirAccess.copy_absolute(
			ProjectSettings.globalize_path(CharacterStore.PATH),
			ProjectSettings.globalize_path(BACKUP))


func _restore_live_save() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))
