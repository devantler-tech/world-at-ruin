extends Node
## The telegraph runtime's dodge law and presentation structure (issue #175).
##
## The one law that makes telegraphed combat FAIR is snapshot-at-resolution:
## the hit set is read from positions at the resolution instant and at no
## other moment. This scene pins it in both directions with four targets in
## one cast:
##   - a DODGER inside during the cast who steps out before it lands → safe,
##   - a LATECOMER outside during the cast who steps in at the end → hit,
##   - a VICTIM who stands in it throughout → hit,
##   - a BYSTANDER far away throughout → safe.
## Every fixture position is precondition-asserted against the shared
## geometry lib, and the dodger's mid-cast position is asserted INSIDE — the
## discriminating fact: an implementation that samples at begin (or
## accumulates membership during the cast) hits the dodger and fails here.
##
## Presentation is asserted structurally (decals exist, sized to the shape,
## fill grows monotonically with progress, resolution flashes full, the node
## frees itself after the linger); whether it READS well is the preview
## harness's judgement call (`scenes/telegraph.tscn`), not a headless test's.
##
## Expected ERROR lines in the log are the begin/advance refusal paths being
## loud — the exit code and PASS marker are the verdict.
##
## Run: godot --headless --path client res://tests/telegraph_runtime_test.tscn

const CENTRE := Vector3(0, 0, 0)
const RADIUS := 3.0
const CAST_TIME := 1.0
const INSIDE_A := Vector3(1, 0, 0)
const INSIDE_B := Vector3(-1, 0, 1)
const OUTSIDE_A := Vector3(9, 0, 0)
const OUTSIDE_B := Vector3(0, 0, -12)

var _failed := false
var _resolutions := 0
var _last_hits: Array[Node3D] = []


func _ready() -> void:
	_begin_refusals()
	if _failed:
		return
	_dodge_law_and_presentation()
	if not _failed:
		print("TEST PASS — telegraph runtime dodge law and presentation structure hold")
		get_tree().quit(0)


func _begin_refusals() -> void:
	print("telegraph_runtime_test: the ERROR lines below are expected refusals.")
	var out_of_tree := TelegraphRuntime.new()
	out_of_tree.auto_advance = false
	var cast := TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)
	if out_of_tree.begin(cast):
		_fail("begin must refuse a runtime that is not in the tree")
		out_of_tree.free()
		return
	out_of_tree.free()

	var runtime := TelegraphRuntime.new()
	runtime.auto_advance = false
	add_child(runtime)
	if runtime.begin(null):
		_fail("begin must refuse a null cast")
		return
	var resolved_cast := TelegraphCast.circle(CENTRE, RADIUS, 0.25)
	resolved_cast.advance(1.0)
	if runtime.begin(resolved_cast):
		_fail("begin must refuse an already-resolved cast")
		return
	if not runtime.begin(TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)):
		_fail("a valid begin was refused")
		return
	if runtime.begin(TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)):
		_fail("a second begin on an armed runtime must be refused")
		return
	# A refused dt must not advance the armed cast.
	runtime.advance(-1.0)
	var fill := runtime.get_node("Fill") as Decal
	if fill == null:
		_fail("an armed runtime must carry a Fill decal")
		return
	if fill.size.x > 0.011:
		_fail("a refused negative dt advanced the fill (size.x %f)" % fill.size.x)
		return
	runtime.queue_free()


func _dodge_law_and_presentation() -> void:
	# Fixture preconditions straight from the shared geometry lib: the test is
	# meaningless if a position is not where the scenario says it is.
	if not Telegraph.in_circle(CENTRE, RADIUS, INSIDE_A) \
			or not Telegraph.in_circle(CENTRE, RADIUS, INSIDE_B):
		_fail("fixture precondition broken: an INSIDE position is not inside")
		return
	if Telegraph.in_circle(CENTRE, RADIUS, OUTSIDE_A) \
			or Telegraph.in_circle(CENTRE, RADIUS, OUTSIDE_B):
		_fail("fixture precondition broken: an OUTSIDE position is not outside")
		return

	var dodger := _target("Dodger", INSIDE_A)
	var latecomer := _target("Latecomer", OUTSIDE_A)
	var victim := _target("Victim", INSIDE_B)
	var bystander := _target("Bystander", OUTSIDE_B)

	var runtime := TelegraphRuntime.new()
	runtime.auto_advance = false
	add_child(runtime)
	runtime.resolved.connect(func(hits: Array[Node3D]) -> void:
		_resolutions += 1
		_last_hits = hits)

	if not runtime.begin(TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)):
		_fail("the dodge-law cast failed to begin")
		return

	# --- presentation: armed state ---
	var zone := runtime.get_node("Zone") as Decal
	var fill := runtime.get_node("Fill") as Decal
	if zone == null or fill == null:
		_fail("an armed runtime must carry Zone and Fill decals")
		return
	var extent := 2.0 * RADIUS
	if absf(zone.size.x - extent) > 0.001 or absf(zone.size.z - extent) > 0.001:
		_fail("the zone decal must span the full shape footprint (got %s)" % zone.size)
		return
	if fill.size.x > 0.011:
		_fail("the fill must start empty (got %s)" % fill.size)
		return

	# --- mid-cast: the discriminating moment ---
	runtime.advance(0.6)
	if _resolutions != 0:
		_fail("resolved fired before cast_time elapsed")
		return
	if not Telegraph.in_circle(CENTRE, RADIUS, dodger.global_position):
		_fail("discriminating fact broken: the dodger must be INSIDE mid-cast (a begin-snapshot implementation would hit them)")
		return
	var mid_fill := fill.size.x
	if absf(mid_fill - extent * 0.6) > 0.05:
		_fail("the fill must track progress (at 60%% got size.x %f of %f)" % [mid_fill, extent])
		return

	# The dodge and the late step-in, before the resolution instant.
	dodger.global_position = OUTSIDE_A
	latecomer.global_position = INSIDE_A

	runtime.advance(0.4)

	# --- resolution: exactly once, from resolution-instant positions only ---
	if _resolutions != 1:
		_fail("resolved must fire exactly once at the crossing (fired %d times)" % _resolutions)
		return
	if _last_hits.has(dodger):
		_fail("DODGE LAW BROKEN: a target that stepped out before resolution was hit")
		return
	if not _last_hits.has(latecomer):
		_fail("DODGE LAW BROKEN: a target inside at the resolution instant was spared")
		return
	if not _last_hits.has(victim):
		_fail("a target inside throughout must be hit")
		return
	if _last_hits.has(bystander):
		_fail("a target outside throughout must be safe")
		return
	if _last_hits.size() != 2:
		_fail("expected exactly 2 hits, got %d" % _last_hits.size())
		return

	# --- after resolution: flash, no re-fire, then free ---
	if absf(fill.size.x - extent) > 0.001:
		_fail("the resolved flash must fill the whole zone (got %s)" % fill.size)
		return
	runtime.advance(0.05)
	if _resolutions != 1:
		_fail("advancing a resolved runtime must never re-resolve")
		return
	runtime.advance(TelegraphRuntime.LINGER)
	if not runtime.is_queued_for_deletion():
		_fail("the runtime must free itself after the linger")
		return


func _target(target_name: String, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = target_name
	add_child(n)
	n.add_to_group(TelegraphRuntime.TARGET_GROUP)
	n.global_position = at
	return n


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
