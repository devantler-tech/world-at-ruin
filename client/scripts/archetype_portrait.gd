class_name ArchetypePortrait
extends SubViewportContainer
## One archetype rendered to a thumbnail, so the roster reads as a choice of
## characters rather than a list of names to imagine (#293).
##
## The portrait is RENDERED from the archetype's own recipe every time the
## creator opens — never a committed image. A recipe change therefore cannot
## leave a stale portrait behind, which is the same non-staleness rule the
## shape sliders already follow by reading the live mesh rather than a
## hand-maintained list.
##
## Cost is bounded two ways, because the creator opens over a live world and
## must not stall on first run:
##
##  1. `setup()` builds only the empty viewport rig. The body — the expensive
##     half — is built by `realize()`, which the creator calls for at most ONE
##     portrait per frame (see `next_unrealized`).
##  2. Nothing in a portrait moves, so the viewport renders a single frame and
##     then stops. A standing thumbnail costs one frame, not one per frame.

const RECIPE_DIR := "res://recipes/"

## Thumbnail size. Tall rather than square: the subject is a standing body
## framed head-and-shoulders, and a square crop wastes half its width on
## backdrop.
const SIZE := Vector2i(76, 100)

## Where the camera looks, as a fraction of the body's own height measured DOWN
## from the crown, and how far back it stands, as a multiple of that height.
## Both are derived from the built body rather than fixed distances so a taller
## archetype (the brute) is framed the same way instead of being cropped by a
## camera pinned to the wanderer's proportions.
const FOCUS_DROP := 0.17
const CAMERA_DISTANCE := 0.62

var preset_name := ""
var is_realized := false

var _viewport: SubViewport
var _body: Node3D


## Where an archetype's recipe lives. The single place the roster and its
## portraits agree on a filename — so a portrait can never be rendered from a
## different recipe than the button beside it applies.
static func recipe_path(preset: String) -> String:
	return RECIPE_DIR + preset + ".json"


## The next portrait still needing its body built, or null when every one is
## done. The creator calls this once per frame, which is what makes the roster
## cost one character build per frame instead of four in the opening frame.
static func next_unrealized(portraits: Array) -> ArchetypePortrait:
	for portrait: ArchetypePortrait in portraits:
		if not portrait.is_realized:
			return portrait
	return null


## Builds the empty viewport rig — camera, key light, backdrop, but no body.
## Cheap enough to run for every archetype in the frame the creator opens.
func setup(p_preset_name: String) -> void:
	preset_name = p_preset_name
	stretch = true
	custom_minimum_size = Vector2(SIZE.x, SIZE.y)
	# The button beside the portrait owns the input for this archetype. Without
	# this the container would swallow clicks aimed at the choice it depicts.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_viewport = SubViewport.new()
	_viewport.size = SIZE
	# Its OWN world. The creator runs over the live Reach, so a portrait sharing
	# the main world would render the terrain, the ash and the player's own body
	# standing in it — the archetype would be somewhere in that frame rather
	# than being the subject of it.
	_viewport.own_world_3d = true
	# Held disabled until there is something to photograph; realize() flips it
	# to UPDATE_ONCE. Rendering an empty world first would spend a frame on a
	# picture of nothing.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var backdrop := WorldEnvironment.new()
	backdrop.environment = _environment()
	_viewport.add_child(backdrop)

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.9, 0.78)
	key.light_energy = 1.6
	_viewport.add_child(key)
	key.rotation_degrees = Vector3(-24.0, 36.0, 0.0)


## Builds the archetype's body into the viewport and renders it once. Returns
## false when the recipe could not be loaded.
##
## Marks itself realized either way: a missing recipe is a bug to see as an
## empty portrait, not a reason for the creator to retry the same failing build
## on every frame for as long as the screen is open.
func realize() -> bool:
	if is_realized:
		return _body != null
	is_realized = true

	var recipe: Variant = CharacterFactory.load_recipe(recipe_path(preset_name))
	if not (recipe is Dictionary):
		return false

	_body = CharacterFactory.build(recipe)
	if _body == null:
		return false
	_viewport.add_child(_body)

	var cam := Camera3D.new()
	cam.fov = 30.0
	_viewport.add_child(cam)
	_frame(cam, _body)
	cam.make_current()

	# One frame is the whole cost: a portrait is a standing body that never
	# moves. UPDATE_ONCE renders the next frame and then disables itself.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	return true


## The viewport the archetype is rendered into. Exposed so the portrait's
## structure can be asserted without a GPU — a headless run builds this tree
## correctly but cannot read a pixel out of it.
func viewport() -> SubViewport:
	return _viewport


## The body being depicted, or null when realize() has not run or failed.
func body() -> Node3D:
	return _body


## Head-and-shoulders, measured off the body's own bounds.
func _frame(cam: Camera3D, body_node: Node3D) -> void:
	var bounds := _bounds(body_node)
	var height := maxf(bounds.size.y, 0.1)
	var centre := bounds.get_center()
	var crown := bounds.position.y + bounds.size.y
	var focus := Vector3(centre.x, crown - height * FOCUS_DROP, centre.z)
	var distance := height * CAMERA_DISTANCE
	# Slightly off-axis and a touch above: a dead-on level shot reads as a
	# passport photo, and the reference set's character-select screens are all
	# three-quarter views.
	cam.position = focus + Vector3(distance * 0.42, distance * 0.10, distance)
	cam.look_at(focus, Vector3.UP)


## The built body's extent, unioned over every mesh it carries so an equipped
## piece cannot leave the frame cropped where the bare body would have fit.
func _bounds(body_node: Node3D) -> AABB:
	var out := AABB()
	var seeded := false
	for mesh: MeshInstance3D in _meshes(body_node):
		var box := mesh.get_aabb()
		box = mesh.global_transform * box
		if seeded:
			out = out.merge(box)
		else:
			out = box
			seeded = true
	if not seeded:
		# Nothing to measure — fall back to a standing adult's rough extent so
		# the camera still points somewhere sensible rather than at the origin.
		return AABB(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 1.8, 0.8))
	return out


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out


## A flat backdrop in the panel's own darkest tone, with enough ambient fill
## that the side away from the key light still reads as a body rather than a
## silhouette.
func _environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = UiTheme.ASH_DEEP
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.44, 0.5)
	env.ambient_light_energy = 0.7
	return env
