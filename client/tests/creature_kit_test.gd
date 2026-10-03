extends Node
## Regression test for the creature kit (creature system pilot, issue #24):
## the committed ash-hound GLB must match its committed structural contract
## (ash_hound_report.txt), morph composition must be deterministic, and every
## shape that ever shipped must still be present.
##  1. The kit loads; it carries a Skeleton3D with the contracted bone count
##     and a skinned body mesh.
##  2. Morph shapes: exactly the contracted names, in order (recipes key on
##     these names forever — the no-resets law), and every shipped shape
##     (tests/data/shipped_creature_shapes.txt) is still present.
##  3. CPU morph mix (base + Σ w·delta) with fixed weights ⇒ identical
##     fingerprint twice; different weights ⇒ different; all-zero ⇒ the base.
##
## Run: godot --headless --path client res://tests/creature_kit_test.tscn

const KIT_SCENE := "res://assets/characters/creature_kit/ash_hound.glb"
const KIT_REPORT := "res://assets/characters/creature_kit/ash_hound_report.txt"
const SHIPPED_SHAPES := "res://tests/data/shipped_creature_shapes.txt"

const WEIGHTS_A := { "body_heavy": 0.8, "legs_long": 0.6, "tail_high": 0.4 }
const WEIGHTS_B := { "body_gaunt": 0.9, "snout_long": 1.0, "ears_alert": 0.5 }


func _ready() -> void:
	var fixture := KitTestSupport.load_contract(KIT_SCENE, KIT_REPORT)
	if not String(fixture["problem"]).is_empty():
		_fail(fixture["problem"])
		return
	var report: Dictionary = fixture["report"]
	var kit: Node = fixture["kit"]
	var mesh: Mesh = fixture["mesh"]

	var contracted: PackedStringArray = report["shapes"].split(",")
	var shape_problem := KitTestSupport.shape_contract_problem(mesh, contracted, "morph")
	if not shape_problem.is_empty():
		_fail(shape_problem)
		return

	# Forward-only: every shape that ever shipped is still present.
	var present := {}
	for i in mesh.get_blend_shape_count():
		present[String(mesh.get_blend_shape_name(i))] = true
	for shipped_shape in _shipped_shapes():
		if not present.has(shipped_shape):
			_fail("SHIPPED SHAPE '%s' VANISHED from the kit (no-resets law)" % shipped_shape)
			return

	var mix := KitTestSupport.mix_contract(mesh, WEIGHTS_A, WEIGHTS_B)
	if not String(mix["problem"]).is_empty():
		_fail(mix["problem"])
		return
	var fp_a1: String = mix["fingerprint"]

	kit.free()
	print("TEST PASS — ash hound kit v%s, %s bones, %d morphs, mix=%s" % [
		report["kit_version"], report["bones"], contracted.size(), fp_a1])
	get_tree().quit(0)


func _shipped_shapes() -> PackedStringArray:
	return LedgerTestSupport.names(SHIPPED_SHAPES)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
