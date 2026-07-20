extends Node
## Regression tests for the ground self-heal (first two player-reported bugs):
##  1. v0.1.1 — after a hard fall the wanderer tunneled into the terrain
##     trimesh and wedged there (stuck in the ground, unable to move).
##  2. v0.1.2 — the first fix compared against the smooth noise height and
##     used a slope-blind threshold, so normal walking rhythmically
##     false-positived and popped the wanderer upward ("bumping").
## Asserts BOTH directions: an embedded wanderer surfaces, and legitimate
## slope contact (origin slightly below the vertical surface height) is
## left alone.
##
## Run: godot --headless --path client res://tests/unstick_test.tscn

const UNIT_TICK := 20
const BURY_TICK := 25
const ASSERT_TICK := 60
const AT := Vector2(30.0, 30.0)
## Legit slope contact: a 0.4 m capsule on a ~45° slope puts its bottom tip
## ≈ 0.4 m below the vertical surface height. Must NOT trigger the clamp.
const SLOPE_CONTACT_DEPTH := 0.35

var _ticks := 0
var _main: Node
var _boot: IsolatedBoot

func _ready() -> void:
	# Booting the main scene runs the real launch path, which reads — and on the
	# first-run path writes — the player's save and vault. Go through
	# IsolatedBoot so it can only ever reach throwaway probes (#309).
	_boot = IsolatedBoot.new("user://unstick_boot_probe.json")
	_main = _boot.boot()
	if _main == null:
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	add_child(_main)

func _physics_process(_delta: float) -> void:
	if _main == null:
		return  # isolation refused the boot; _fail has already been reported
	_ticks += 1
	var player := _main.get_node_or_null("Wanderer") as Player
	var world := _main.get_node_or_null("World") as WorldGen
	if player == null or world == null:
		if _ticks > 10:
			_fail("main scene did not build a Wanderer and World")
		return
	var ground := world.surface_height_at(AT.x, AT.y)
	if _ticks == UNIT_TICK:
		# 1. Slope-contact must be tolerated (the v0.1.2 bumping bug) — even
		# when it persists well past the debounce window.
		player.global_position = Vector3(AT.x, ground - SLOPE_CONTACT_DEPTH, AT.y)
		for i in Player.EMBED_TICKS_TO_FIRE + 5:
			player._unstick_from_ground()
		if not is_equal_approx(player.global_position.y, ground - SLOPE_CONTACT_DEPTH):
			_fail("clamp fired on legitimate slope contact (%.2f below surface)" % SLOPE_CONTACT_DEPTH)
			return
		# 2. A deeply embedded wanderer must surface once embedding persists
		# past the debounce window.
		player.global_position = Vector3(AT.x, ground - 2.0, AT.y)
		for i in Player.EMBED_TICKS_TO_FIRE:
			player._unstick_from_ground()
		if not is_equal_approx(player.global_position.y, ground + 0.1):
			_fail("embedded wanderer not surfaced (y=%.2f, surface=%.2f)" % [player.global_position.y, ground])
			return
		# Reset for the integration pass below.
		player.global_position = Vector3(AT.x, ground + 1.0, AT.y)
		player.velocity = Vector3.ZERO
	elif _ticks == BURY_TICK:
		# 3. Integration: bury mid-simulation, the physics loop must recover.
		player.global_position = Vector3(AT.x, ground - 2.0, AT.y)
		player.velocity = Vector3.ZERO
	elif _ticks == ASSERT_TICK:
		var here := world.surface_height_at(player.global_position.x, player.global_position.z)
		if player.global_position.y < here - 0.55:
			_fail("wanderer still buried: y=%.2f surface=%.2f" % [player.global_position.y, here])
			return
		if not _boot.real_save_untouched():
			_fail("the boot test touched the player's real save or vault")
			return
		print("UNSTICK-TEST PASS (y=%.2f surface=%.2f)" % [player.global_position.y, here])
		get_tree().quit(0)

func _fail(message: String) -> void:
	if _boot != null:
		_boot.end()
	push_error("UNSTICK-TEST FAIL: " + message)
	get_tree().quit(1)
