extends Node
## Regression test for the humanoid kit (character system stage 1, issue #24):
## the committed kit GLB must match its committed structural contract
## (kit_report.txt), and morph composition must be deterministic.
##  1. The kit loads; it carries a Skeleton3D with the contracted bone count
##     and a skinned body mesh.
##  2. Blend shapes: exactly the contracted names, in order (recipes key on
##     these names forever — the no-resets law).
##  3. CPU morph mix (base + Σ w·delta) with fixed weights ⇒ identical
##     fingerprint twice; different weights ⇒ different fingerprint; all-zero
##     weights ⇒ the base geometry.
##
## Run: godot --headless --path client res://tests/humanoid_kit_test.tscn

const KIT_SCENE := "res://assets/characters/humanoid_kit/humanoid_base.glb"
const KIT_REPORT := "res://assets/characters/humanoid_kit/kit_report.txt"

const WEIGHTS_A := { "torso_vshape": 0.8, "arms_muscle": 0.6, "belly": -0.3, "head_square": 0.5 }
const WEIGHTS_B := { "torso_vshape": 0.2, "legs_heavy": 0.9, "nose_hump": 1.0 }


func _ready() -> void:
	var fixture := KitTestSupport.load_contract(KIT_SCENE, KIT_REPORT)
	if not String(fixture["problem"]).is_empty():
		_fail(fixture["problem"])
		return
	var report: Dictionary = fixture["report"]
	var kit: Node = fixture["kit"]
	var mesh: Mesh = fixture["mesh"]

	var contracted: PackedStringArray = report["shapes"].split(",")
	var shape_problem := KitTestSupport.shape_contract_problem(mesh, contracted, "blend shape")
	if not shape_problem.is_empty():
		_fail(shape_problem)
		return

	var fp_a1 := KitTestSupport.mix_fingerprint(mesh, WEIGHTS_A)
	var fp_a2 := KitTestSupport.mix_fingerprint(mesh, WEIGHTS_A)
	var fp_b := KitTestSupport.mix_fingerprint(mesh, WEIGHTS_B)
	var fp_zero := KitTestSupport.mix_fingerprint(mesh, {})
	var fp_base := KitTestSupport.hash_bytes(KitTestSupport.base_vertices(mesh).to_byte_array())
	if fp_a1 != fp_a2:
		_fail("same weights produced different mixes:\n  %s\n  %s" % [fp_a1, fp_a2])
		return
	if fp_a1 == fp_b:
		_fail("different weights produced identical mixes: %s" % fp_a1)
		return
	if fp_zero != fp_base:
		_fail("zero-weight mix differs from base geometry")
		return

	kit.free()
	print("TEST PASS — kit v%s, %s bones, %d shapes, mix=%s" % [report["kit_version"], report["bones"], contracted.size(), fp_a1])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
