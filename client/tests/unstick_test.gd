extends Node
## Regression test for the first player-reported bug: after a hard fall the
## wanderer could tunnel into the terrain trimesh and wedge there, unable to
## move. The fix is an analytic ground clamp (the terrain is a pure
## heightfield, so below-ground is always invalid). This test buries the
## wanderer and asserts the clamp returns him to the surface within ticks.
##
## Run: godot --headless --path client res://tests/unstick_test.tscn

const BURY_TICK := 20
const ASSERT_TICK := 40
const BURY_AT := Vector2(30.0, 30.0)

var _ticks := 0
var _main: Node

func _ready() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)

func _physics_process(_delta: float) -> void:
	_ticks += 1
	var player := _main.get_node_or_null("Wanderer") as Player
	var world := _main.get_node_or_null("World") as WorldGen
	if player == null or world == null:
		if _ticks > 10:
			_fail("main scene did not build a Wanderer and World")
		return
	if _ticks == BURY_TICK:
		var ground := world.height_at(BURY_AT.x, BURY_AT.y)
		player.global_position = Vector3(BURY_AT.x, ground - 2.0, BURY_AT.y)
		player.velocity = Vector3.ZERO
	elif _ticks == ASSERT_TICK:
		var ground := world.height_at(player.global_position.x, player.global_position.z)
		if player.global_position.y >= ground - 0.2:
			print("UNSTICK-TEST PASS (y=%.2f ground=%.2f)" % [player.global_position.y, ground])
			get_tree().quit(0)
		else:
			_fail("wanderer still buried: y=%.2f ground=%.2f" % [player.global_position.y, ground])

func _fail(message: String) -> void:
	push_error("UNSTICK-TEST FAIL: " + message)
	get_tree().quit(1)
