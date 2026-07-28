extends Node
## Contract test for the kit-assembly primitives the two factories share (#276).
##
## `CharacterFactory` and `CreatureFactory` used to carry their own copies of
## `find_skeleton`, `find_skinned_mesh` and the uniform subtree scale. They now
## call one implementation in `KitAssembly`, so this pins what that shared
## implementation promises — and, just as importantly, what each factory asks it
## for.
##
## THE WIRING IS TESTED SEPARATELY FROM THE LOGIC, deliberately. The one
## behavioural difference between the two callers is that the humanoid kit
## parents equipment meshes onto the body skeleton and must skip them, while the
## creature kit has none. A test that only exercised `KitAssembly` directly would
## stay green if a factory passed the wrong prefix — the body mesh and the
## garment are both skinned meshes, so the mistake surfaces as the wrong one
## being returned, not as an error. Checks 4 and 5 therefore go through
## `CharacterFactory.find_skinned_mesh` / `CreatureFactory.find_skinned_mesh`.
##
## ORDER IS LOAD-BEARING: every mesh fixture below adds the `Equip_`-prefixed
## mesh FIRST. `find_skinned_mesh` returns the first match in child order, so an
## implementation that forgot to exclude the prefix would return the garment and
## fail loudly. Adding the body first would let a broken exclusion pass.
##
## Pure logic on synthetic nodes — no kit load, no scene, no save, no boot — so
## it is deterministic in CI and safe to run locally.
##
## Run: godot --headless --path client res://tests/kit_assembly_test.tscn

const EQUIP_PREFIX := "Equip_"


func _ready() -> void:
	if not _check_find_skeleton():
		return
	if not _check_find_skinned_mesh():
		return
	if not _check_scale_bone_subtree():
		return
	if not _check_factory_wiring():
		return

	print("TEST PASS — KitAssembly's skeleton lookup, body-mesh lookup and uniform subtree scale hold, "
		+ "and both factories ask for the exclusion their own kit needs (humanoid skips '%s', creature skips nothing)"
		% EQUIP_PREFIX)
	get_tree().quit(0)


## 1. The skeleton search: null in, null out; a skeleton answers as itself; a
##    nested skeleton is found through intermediate nodes; a subtree with none
##    returns null rather than something arbitrary.
func _check_find_skeleton() -> bool:
	if KitAssembly.find_skeleton(null) != null:
		_fail("find_skeleton(null) must be null so a failed kit load can chain straight in")
		return false

	var bare := Skeleton3D.new()
	if KitAssembly.find_skeleton(bare) != bare:
		_fail("find_skeleton must return a Skeleton3D passed directly to it")
		bare.free()
		return false
	bare.free()

	# Nested two levels deep, so a shallow-only search fails rather than passing
	# on a skeleton that happened to be the direct child.
	var root := Node3D.new()
	var middle := Node3D.new()
	var nested := Skeleton3D.new()
	root.add_child(middle)
	middle.add_child(nested)
	var found := KitAssembly.find_skeleton(root)
	if found != nested:
		_fail("find_skeleton must find a skeleton nested below intermediate nodes (got %s)" % str(found))
		root.free()
		return false
	root.free()

	var skeletonless := Node3D.new()
	skeletonless.add_child(Node3D.new())
	if KitAssembly.find_skeleton(skeletonless) != null:
		_fail("find_skeleton must return null for a subtree holding no Skeleton3D")
		skeletonless.free()
		return false
	skeletonless.free()
	return true


## 2. The body-mesh search: null skeleton, unskinned children, the prefix
##    exclusion, and the empty-prefix case that means "exclude nothing".
func _check_find_skinned_mesh() -> bool:
	if KitAssembly.find_skinned_mesh(null) != null:
		_fail("find_skinned_mesh(null) must be null")
		return false

	# An unskinned MeshInstance3D is not a body mesh, however it is named.
	var unskinned_only := Skeleton3D.new()
	unskinned_only.add_child(MeshInstance3D.new())
	if KitAssembly.find_skinned_mesh(unskinned_only) != null:
		_fail("find_skinned_mesh must ignore a MeshInstance3D carrying no skin")
		unskinned_only.free()
		return false
	unskinned_only.free()

	# NON-VACUITY: the fixture must really hold a skinned, prefixed mesh BEFORE
	# the body, or the exclusion check below proves nothing.
	var skeleton := _skeleton_with_equip_then_body()
	var equip: MeshInstance3D = skeleton.get_child(0)
	var body: MeshInstance3D = skeleton.get_child(1)
	if equip.skin == null or body.skin == null or not String(equip.name).begins_with(EQUIP_PREFIX):
		_fail("fixture is wrong: expected a skinned '%s…' mesh first and a skinned body second, "
			% EQUIP_PREFIX + "so an implementation that skipped the exclusion would return the garment")
		skeleton.free()
		return false

	if KitAssembly.find_skinned_mesh(skeleton, EQUIP_PREFIX) != body:
		_fail("find_skinned_mesh must skip meshes named '%s…' and return the body" % EQUIP_PREFIX)
		skeleton.free()
		return false

	# The creature path: an EMPTY prefix excludes NOTHING. Every string begins
	# with "", so an implementation applying the test unconditionally would
	# reject every mesh and return null — the creature kit would lose its hide.
	if KitAssembly.find_skinned_mesh(skeleton) != equip:
		_fail("an empty exclude_prefix must exclude nothing — it returned %s, not the first skinned mesh"
			% str(KitAssembly.find_skinned_mesh(skeleton)))
		skeleton.free()
		return false
	skeleton.free()
	return true


## 3. The uniform subtree scale: the basis scales by the factor, the origin is
##    carried through untouched (moving a joint along its offset is a different
##    operation), and the result stays TRS-representable.
func _check_scale_bone_subtree() -> bool:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("root")
	var bone := skeleton.find_bone("root")
	if bone < 0:
		_fail("fixture is wrong: the test skeleton has no 'root' bone, so nothing below is exercised")
		skeleton.free()
		return false

	# A NON-ZERO origin and a rotated basis: with the origin at zero, "the origin
	# is untouched" would hold even for an implementation that scaled it too.
	var origin := Vector3(0.25, 1.5, -0.75)
	var basis := Basis(Vector3.UP, deg_to_rad(30.0))
	skeleton.set_bone_rest(bone, Transform3D(basis, origin))

	var factor := 2.0
	KitAssembly.scale_bone_subtree(skeleton, bone, factor)
	var scaled := skeleton.get_bone_rest(bone)

	if not scaled.origin.is_equal_approx(origin):
		_fail("scale_bone_subtree must leave the bone origin untouched (expected %s, got %s)"
			% [str(origin), str(scaled.origin)])
		skeleton.free()
		return false

	var expected_scale := basis.get_scale() * factor
	if not scaled.basis.get_scale().is_equal_approx(expected_scale):
		_fail("scale_bone_subtree must scale the rest basis by the factor (expected scale %s, got %s)"
			% [str(expected_scale), str(scaled.basis.get_scale())])
		skeleton.free()
		return false

	# Uniform means uniform: all three axes scale together, or the rest stops
	# being TRS-representable and reset_bone_poses() silently drops the shear.
	var axis_scale := scaled.basis.get_scale()
	if not (is_equal_approx(axis_scale.x, axis_scale.y) and is_equal_approx(axis_scale.y, axis_scale.z)):
		_fail("scale_bone_subtree must scale uniformly — got a non-uniform scale %s, which is not "
			% str(axis_scale) + "TRS-representable and would be silently dropped at reset_bone_poses()")
		skeleton.free()
		return false
	skeleton.free()
	return true


## 4+5. THE WIRING. Each factory's public entry point must ask for the exclusion
##      its own kit needs. This is what a direct KitAssembly test cannot see:
##      both meshes are skinned, so a factory passing the wrong prefix returns
##      the wrong mesh rather than failing.
func _check_factory_wiring() -> bool:
	var humanoid := _skeleton_with_equip_then_body()
	var human_body: MeshInstance3D = humanoid.get_child(1)
	if CharacterFactory.find_skinned_mesh(humanoid) != human_body:
		_fail("CharacterFactory.find_skinned_mesh must exclude '%s…' meshes — it returned the garment, "
			% EQUIP_PREFIX + "so a built character would morph and skin the wrong mesh")
		humanoid.free()
		return false
	humanoid.free()

	var creature := _skeleton_with_equip_then_body()
	var first: MeshInstance3D = creature.get_child(0)
	if CreatureFactory.find_skinned_mesh(creature) != first:
		_fail("CreatureFactory.find_skinned_mesh must exclude nothing — the creature kit parents no "
			+ "equipment, so excluding a prefix would drop the hide mesh")
		creature.free()
		return false
	creature.free()
	return true


## A skeleton whose FIRST skinned child is prefixed and whose second is the body.
## The order is what makes the exclusion checks falsifiable.
func _skeleton_with_equip_then_body() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var equip := MeshInstance3D.new()
	equip.name = EQUIP_PREFIX + "chest"
	equip.skin = Skin.new()
	skeleton.add_child(equip)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.skin = Skin.new()
	skeleton.add_child(body)
	return skeleton


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
