extends Node
## Regression test for the character creator's archetype portraits (#293).
##
## The roster used to be four text buttons, so a player could only ever inspect
## the one body currently on screen. Each archetype now renders its own recipe
## into a thumbnail. Two things about that are worth pinning, and neither is
## the picture itself — a headless run builds this tree correctly but cannot
## read a pixel out of a SubViewport, the same limit MultiMesh and FogVolume
## already impose. So this pins the STRUCTURE and the COST:
##
##  1. Every archetype in the roster has a recipe at the path the portrait
##     renders from — the non-staleness guarantee. A portrait is generated from
##     the recipe every time, so it cannot go stale; what CAN go wrong is the
##     roster naming an archetype whose recipe is somewhere else, which shows
##     as one silently empty portrait rather than an error.
##  2. Every archetype actually builds a body — a skeleton and a skinned mesh.
##     One archetype failing to build is invisible: it renders as backdrop,
##     which looks like a portrait that has not had its turn yet.
##  3. Realizing is at-most-once, so a portrait cannot stack a second body on
##     top of the first and double its cost.
##  4. The roster hands back ONE portrait at a time and then stops. This is the
##     bounded-cost law: the creator opens over a live world, and building all
##     four bodies in the opening frame is the stall the screen must not have.
##  5. A portrait renders its own world. Without that it shares the main one and
##     silently photographs the Reach — terrain, ash and the player's own body —
##     with the archetype somewhere in the frame rather than being its subject.
##
## Run: godot --headless --path client res://tests/creator_portraits_test.tscn


func _ready() -> void:
	if not _every_archetype_has_a_recipe():
		return
	if not _every_archetype_builds_a_body():
		return
	if not _realizing_twice_builds_one_body():
		return
	if not _roster_hands_back_one_at_a_time():
		return
	if not _portrait_renders_its_own_world():
		return
	if not _portrait_settles_then_stops():
		return
	print("TEST PASS — every archetype renders its own portrait, one build per frame")
	get_tree().quit(0)


## 1. The roster and the portraits agree on where a recipe lives.
func _every_archetype_has_a_recipe() -> bool:
	# Non-vacuity floor: an empty roster would satisfy every check below by
	# having nothing to check.
	if CharacterCreator.PRESETS.is_empty():
		return _fail("the archetype roster is empty — every portrait guard below would pass vacuously")

	for preset_name: String in CharacterCreator.PRESETS:
		var path := ArchetypePortrait.recipe_path(preset_name)
		if not FileAccess.file_exists(path):
			return _fail("archetype '%s' has no recipe at %s — its portrait would render empty" % [preset_name, path])
	return true


## 2. Every archetype produces a real body, not an empty viewport.
func _every_archetype_builds_a_body() -> bool:
	var built := 0
	for preset_name: String in CharacterCreator.PRESETS:
		var portrait := ArchetypePortrait.new()
		add_child(portrait)
		portrait.setup(preset_name)

		if not portrait.realize():
			portrait.queue_free()
			return _fail("archetype '%s' built no body — its portrait would render as bare backdrop" % preset_name)

		var body := portrait.body()
		var skeleton := CharacterFactory.find_skeleton(body)
		if skeleton == null:
			portrait.queue_free()
			return _fail("archetype '%s' built a body with no skeleton" % preset_name)
		var mesh := CharacterFactory.find_skinned_mesh(skeleton)
		if mesh == null or mesh.mesh == null:
			portrait.queue_free()
			return _fail("archetype '%s' built a skeleton with no skinned mesh — nothing to photograph" % preset_name)

		built += 1
		portrait.queue_free()

	if built != CharacterCreator.PRESETS.size():
		return _fail("built %d bodies for %d archetypes" % [built, CharacterCreator.PRESETS.size()])
	return true


## 3. A second realize() is a no-op, not a second body in the same viewport.
func _realizing_twice_builds_one_body() -> bool:
	var portrait := ArchetypePortrait.new()
	add_child(portrait)
	portrait.setup(CharacterCreator.PRESETS[0])

	if not portrait.realize():
		portrait.queue_free()
		return _fail("the first realize() built nothing, so the idempotence check below would prove nothing")
	var first := portrait.body()
	var children := portrait.viewport().get_child_count()

	portrait.realize()
	var same_body := portrait.body() == first
	var same_children := portrait.viewport().get_child_count() == children
	portrait.queue_free()

	if not same_body:
		return _fail("realizing twice replaced the body — the first build was wasted work")
	if not same_children:
		return _fail("realizing twice added another node to the viewport — bodies would stack and double the cost")
	return true


## 4. The bounded-cost law, isolated from the cost of a real build: the roster
## names ONE portrait per call and then stops.
func _roster_hands_back_one_at_a_time() -> bool:
	var portraits: Array[ArchetypePortrait] = []
	for preset_name: String in CharacterCreator.PRESETS:
		var portrait := ArchetypePortrait.new()
		add_child(portrait)
		# setup() only — this guard is about the ORDER work is handed out, not
		# about building bodies, and mixing the two would make a slow test that
		# fails for either reason.
		portrait.setup(preset_name)
		portraits.append(portrait)

	var handed: Array[ArchetypePortrait] = []
	for i in portraits.size():
		var next := ArchetypePortrait.next_unrealized(portraits)
		if next == null:
			_free_all(portraits)
			return _fail("the roster ran out after %d of %d portraits — the rest would stay empty forever" % [i, portraits.size()])
		if next in handed:
			_free_all(portraits)
			return _fail("the roster handed back the same portrait twice — it would rebuild one body forever and never reach the others")
		handed.append(next)
		# Stand in for the build the creator would run this frame.
		next.is_realized = true

	var drained: ArchetypePortrait = ArchetypePortrait.next_unrealized(portraits)
	_free_all(portraits)
	if drained != null:
		return _fail("the roster still offered work after every portrait was realized — the creator would rebuild forever")
	return true


## 5. A portrait is its own scene, not a window onto the live Reach.
func _portrait_renders_its_own_world() -> bool:
	var portrait := ArchetypePortrait.new()
	add_child(portrait)
	portrait.setup(CharacterCreator.PRESETS[0])
	var own := portrait.viewport().own_world_3d
	portrait.queue_free()
	if not own:
		return _fail("the portrait shares the main world — it would photograph the Reach with the archetype somewhere in it")
	return true


## 6. A portrait keeps rendering for a SHORT window and then stops for good.
##
## Both halves are load-bearing and each failed in a real way:
##
##  - Too FEW frames photographs a body whose equipment blend shapes have not
##    been applied yet. On CI that shipped a NUDE figure on the game's first
##    screen while the same recipe rendered dressed on the live body in the
##    very same capture — invisible locally, because a fast GPU settles inside
##    one frame. That is the bug this window exists to fix, and a headless run
##    cannot see it in pixels, so the WINDOW is what gets pinned.
##  - Never stopping would leave four 3D viewports redrawing forever behind a
##    screen whose subject does not move.
func _portrait_settles_then_stops() -> bool:
	var portrait := ArchetypePortrait.new()
	add_child(portrait)
	portrait.setup(CharacterCreator.PRESETS[0])

	if portrait.is_settled():
		portrait.queue_free()
		return _fail("a portrait reported settled before it had a body — the window would be skipped entirely")

	if not portrait.realize():
		portrait.queue_free()
		return _fail("the first realize() built nothing, so the settling window below would prove nothing")

	if portrait.viewport().render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		portrait.queue_free()
		return _fail("a freshly built portrait is not rendering — it would photograph an unsettled body")

	# One frame short of the window: still rendering.
	for i in ArchetypePortrait.SETTLE_FRAMES - 1:
		portrait._process(0.0)
	if portrait.is_settled():
		portrait.queue_free()
		return _fail("the portrait stopped rendering before its settling window elapsed")

	portrait._process(0.0)
	var settled := portrait.is_settled()
	var stopped := portrait.viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED
	portrait.queue_free()

	if not settled:
		return _fail("the portrait never reported settled — nothing would ever stop it rendering")
	if not stopped:
		return _fail("the portrait kept its viewport live after settling — four 3D viewports would redraw forever")
	return true


func _free_all(portraits: Array[ArchetypePortrait]) -> void:
	for portrait: ArchetypePortrait in portraits:
		portrait.queue_free()


func _fail(message: String) -> bool:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false
