extends Node
## Regression test for #500: a replaced body must LEAVE THE TREE, not merely be
## scheduled for freeing.
##
## `queue_free()` defers removal to the end of the frame, so a caller that
## disposes a node with `queue_free()` alone leaves the outgoing node parented
## beside the incoming one for the rest of that frame. Both still render, and a
## consumer walking children sees two bodies where the game has one. The
## codebase's idiom is `remove_child()` before `queue_free()`, documented on
## `replica_view.gd`'s `_free_marker`.
##
## Two sites, asserted the same way:
##  1. `Player.set_character` — the shipping path, driven twice within ONE frame
##     so an accumulating parent is distinguishable from a merely-late one.
##  2. `RecipeGallery.rebuild` — the editor taste-gate harness.
##
## The counts are what separate fixed from broken rather than a number that
## would read the same either way: against the unfixed path `Visual` holds 3
## children (2 queued) after the first swap and 4 (3 queued) after the second.
##
## Run: godot --headless --path client res://tests/character_body_swap_test.tscn

const RECIPE_A := "res://recipes/wanderer.json"
const RECIPE_B := "res://recipes/brute.json"


func _ready() -> void:
	if not _player_swap_leaves_one_body():
		return
	if not _gallery_rebuild_does_not_accumulate():
		return
	print("TEST PASS — a replaced body leaves the tree at both swap sites")
	get_tree().quit(0)


## The shipping path: two swaps in one frame, each leaving exactly the new body.
func _player_swap_leaves_one_body() -> bool:
	var recipe_a = CharacterFactory.load_recipe(RECIPE_A)
	var recipe_b = CharacterFactory.load_recipe(RECIPE_B)
	if recipe_a == null or recipe_b == null:
		_fail("preset recipes unreadable")
		return false

	var player := Player.new()
	add_child(player)
	# Gravity and the respawn net would run against a floorless test scene; the
	# swap path under test does not depend on physics.
	player.set_physics_process(false)
	var visual := player.get_node_or_null("Visual")
	if visual == null:
		_fail("Player built no Visual node")
		return false

	# Baseline: the placeholder capsule and visor, both live. Pinned so a later
	# count of exactly 1 cannot pass by the node having been empty all along.
	if visual.get_child_count() != 2 or _queued(visual) != 0:
		var baseline := "placeholder baseline is %d children (%d queued), expected 2 live"
		_fail(baseline % [visual.get_child_count(), _queued(visual)])
		player.free()
		return false

	player.set_character(recipe_a)
	if not _holds_exactly_the_live_body(player, visual, "first swap"):
		player.free()
		return false

	# Same frame, no await: a queue_free'd node only leaves at the end of the
	# frame, so a second swap here is what exposes accumulation.
	player.set_character(recipe_b)
	if not _holds_exactly_the_live_body(player, visual, "second swap in the same frame"):
		player.free()
		return false

	player.free()
	return true


## `Visual` holds one child, it is not dying, and it is the body the player
## tracks — the last part proving the swap kept the NEW body rather than
## merely emptying the node.
func _holds_exactly_the_live_body(player: Player, visual: Node, label: String) -> bool:
	var children := visual.get_child_count()
	var queued := _queued(visual)
	if children != 1 or queued != 0:
		var shape := "%s: Visual holds %d children (%d queued for deletion), expected 1 live body"
		_fail(shape % [label, children, queued])
		return false
	var mesh := player.character_mesh()
	if mesh == null:
		_fail("%s: the tracked body carries no skinned mesh" % label)
		return false
	var survivor := visual.get_child(0)
	if survivor != mesh and not survivor.is_ancestor_of(mesh):
		_fail("%s: the surviving child is not the body the player tracks" % label)
		return false
	return true


## The editor taste-gate harness rebuilds in place; a second pass must replace
## its row rather than stack a dead one behind it.
func _gallery_rebuild_does_not_accumulate() -> bool:
	var gallery := RecipeGallery.new()
	add_child(gallery)  # _ready() builds the first pass
	var first := gallery.get_child_count()
	if first == 0 or _queued(gallery) != 0:
		_fail("gallery built nothing to rebuild: %d children, %d queued" % [first, _queued(gallery)])
		gallery.free()
		return false

	gallery.rebuild()
	var after := gallery.get_child_count()
	var queued := _queued(gallery)
	if after != first or queued != 0:
		var shape := "gallery rebuild left %d children (%d queued), expected %d live and 0 queued"
		_fail(shape % [after, queued, first])
		gallery.free()
		return false

	gallery.free()
	return true


func _queued(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child.is_queued_for_deletion():
			count += 1
	return count


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
