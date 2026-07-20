extends Node
## Regression test for the character creator's grouped shaping sections (#270).
##
## The creator used to place all 29 of the kit's shape sliders in one flat run,
## which is what made the first screen of the game read as a debug panel. They
## are now sorted into named sections. The risk that introduces is SILENT LOSS:
## a grouping that drops a shape costs the player a shaping option with nothing
## failing, and a kit that later gains a shape must not quietly stop offering
## it. So this pins the contract rather than the cosmetics:
##
##  1. Every shape the kit reports lands in exactly one section — none lost,
##     none duplicated.
##  2. Section order is the declared order, and empty sections are dropped.
##  3. A shape matching no declared prefix still appears, in the fallback
##     section — the non-staleness guarantee.
##  4. The live kit's real shape list produces more than one section (the
##     grouping actually fires on shipped data, rather than degenerating to
##     one bucket that happens to satisfy 1–3).
##
## Run: godot --headless --path client res://tests/creator_sections_test.tscn


func _ready() -> void:
	if not _placed_exactly_once():
		return
	if not _declared_order_and_no_empties():
		return
	if not _unknown_shape_survives():
		return
	if not _fires_on_the_real_kit():
		return
	print("TEST PASS — creator sections place every shape exactly once")
	get_tree().quit(0)


## 1. Nothing lost, nothing duplicated — over a list covering every declared
## section plus the fallback.
func _placed_exactly_once() -> bool:
	var names := PackedStringArray([
		"torso_vshape", "shoulders_broad", "belly", "neck_thick",
		"arms_muscle", "legs_heavy",
		"head_round", "chin_prominent", "jaw_wide", "nose_hump",
		"body_female", "body_aged",
		"phenotype_asian",
		"tail_length",
	])
	var seen := PackedStringArray()
	for group: Array in CharacterCreator.group_shape_names(names):
		for shape_name: String in group[1]:
			if shape_name in seen:
				return _fail("'%s' was placed in more than one section" % shape_name)
			seen.append(shape_name)
	if seen.size() != names.size():
		var lost := PackedStringArray()
		for shape_name: String in names:
			if not shape_name in seen:
				lost.append(shape_name)
		return _fail("%d of %d shapes were dropped: %s" % [lost.size(), names.size(), lost])
	return true


## 2. The sections come back in the order SHAPE_GROUPS declares, and a section
## with nothing in it is not rendered as an empty header.
func _declared_order_and_no_empties() -> bool:
	# Deliberately omits every LIMBS and FACE shape.
	var groups := CharacterCreator.group_shape_names(
		PackedStringArray(["phenotype_asian", "torso_broad", "body_slim"]))
	var titles := []
	for group: Array in groups:
		if (group[1] as PackedStringArray).is_empty():
			return _fail("section '%s' was rendered with no shapes in it" % group[0])
		titles.append(group[0])
	if titles != ["ARCHETYPE", "HERITAGE", "TORSO"]:
		return _fail("sections came back as %s, not in the declared order" % [titles])
	return true


## 3. A shape name the grouping has never heard of must still reach the player.
## This is what stops the creator going stale when the kit gains a shape — the
## same guarantee `_shape_names()` provides by reading the live mesh.
func _unknown_shape_survives() -> bool:
	var groups := CharacterCreator.group_shape_names(PackedStringArray(["wings_span"]))
	if groups.size() != 1:
		return _fail("an unknown shape produced %d sections, expected 1" % groups.size())
	if groups[0][0] != CharacterCreator.SHAPE_GROUP_FALLBACK:
		return _fail("an unknown shape landed in '%s', not the fallback section" % groups[0][0])
	if not "wings_span" in (groups[0][1] as PackedStringArray):
		return _fail("an unknown shape did not reach the player at all")
	return true


## 4. The three checks above all pass if the grouping put everything into one
## bucket. This one reads the SHIPPED kit and requires the split to be real —
## the difference between a grouping that works and a grouping that runs.
func _fires_on_the_real_kit() -> bool:
	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		return _fail("wanderer preset unreadable — cannot read the kit's shapes")
	var body := CharacterFactory.build(recipe)
	if body == null:
		return _fail("wanderer recipe failed to build — cannot read the kit's shapes")

	var mesh := _find_mesh(body)
	if mesh == null or mesh.mesh == null:
		body.free()
		return _fail("built character exposes no mesh — cannot read the kit's shapes")

	var names := PackedStringArray()
	for i in mesh.mesh.get_blend_shape_count():
		var shape_name := String(mesh.mesh.get_blend_shape_name(i))
		if not shape_name.begins_with(CharacterFactory.HIDE_SHAPE_PREFIX):
			names.append(shape_name)
	body.free()

	if names.size() < 20:
		return _fail("the kit reported only %d shapes — this test's premise is gone" % names.size())
	var groups := CharacterCreator.group_shape_names(names)
	if groups.size() < 4:
		return _fail("the shipped kit's %d shapes collapsed into %d section(s) — the panel is still a flat run"
			% [names.size(), groups.size()])
	var placed := 0
	var fallback := 0
	for group: Array in groups:
		placed += (group[1] as PackedStringArray).size()
		if group[0] == CharacterCreator.SHAPE_GROUP_FALLBACK:
			fallback = (group[1] as PackedStringArray).size()
	if placed != names.size():
		return _fail("the shipped kit lost shapes: %d in, %d placed" % [names.size(), placed])
	# Not a correctness failure — the fallback is the safety net and is allowed
	# to hold shapes — but a kit that is mostly unmatched means the declared
	# prefixes have drifted from the kit and want revisiting.
	if fallback > names.size() / 2:
		return _fail("%d of %d shipped shapes fell into the fallback — the declared prefixes have drifted"
			% [fallback, names.size()])
	print("  shipped kit: %d shapes → %d sections (%d unmatched)" % [names.size(), groups.size(), fallback])
	return true


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null \
			and (node as MeshInstance3D).mesh.get_blend_shape_count() > 0:
		return node
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _fail(message: String) -> bool:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false
