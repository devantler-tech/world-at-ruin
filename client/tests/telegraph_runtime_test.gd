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
	_shared_cast_and_cache()
	if _failed:
		return
	_spec_safety()
	if _failed:
		return
	_dodge_law_and_presentation()
	if _failed:
		return
	_full_disc_seam()
	if _failed:
		return
	_moving_parent()
	if _failed:
		return
	await _physics_order()
	if not _failed:
		print("TEST PASS — telegraph runtime dodge law and presentation structure hold")
		get_tree().quit(0)


## One cast is one telegraph: a second runtime must refuse an armed cast
## (a shared clock would advance twice). And identical shape parameters must
## reuse the cached mask textures (repeated casts must not re-bake), while a
## different shape must not.
func _shared_cast_and_cache() -> void:
	print("telegraph_runtime_test: the next ERROR line is the expected shared-cast refusal.")
	var a := TelegraphRuntime.new()
	a.auto_advance = false
	add_child(a)
	var b := TelegraphRuntime.new()
	b.auto_advance = false
	add_child(b)
	var shared := TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)
	if not a.begin(shared):
		_fail("the first runtime must arm a fresh cast")
		return
	if b.begin(shared):
		_fail("a cast armed by one runtime must be refused by another")
		return
	if not b.begin(TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)):
		_fail("an identical fresh cast must begin")
		return
	var zone_a := (a.get_node("Zone") as Decal).texture_albedo
	var zone_b := (b.get_node("Zone") as Decal).texture_albedo
	if zone_a != zone_b:
		_fail("identical shape parameters must reuse the cached textures (a re-bake per cast is the hitch the cache removes)")
		return
	var c := TelegraphRuntime.new()
	c.auto_advance = false
	add_child(c)
	if not c.begin(TelegraphCast.circle(CENTRE, RADIUS + 1.0, CAST_TIME)):
		_fail("a different-radius cast must begin")
		return
	if (c.get_node("Zone") as Decal).texture_albedo == zone_a:
		_fail("a different shape must not reuse another shape's textures")
		return
	a.queue_free()
	b.queue_free()
	c.queue_free()


## GDScript cannot make cast fields immutable, so `begin` re-validates the
## factory laws (a hand-built cast is refused) and runs on a PRIVATE spec
## copy — mutating the caller's instance after begin must change nothing.
func _spec_safety() -> void:
	print("telegraph_runtime_test: the next ERROR line is the expected hand-built-cast refusal.")
	var r := TelegraphRuntime.new()
	r.auto_advance = false
	add_child(r)
	var bad := TelegraphCast.new()
	bad.shape = TelegraphCast.Shape.CIRCLE
	bad.radius = 0.0
	bad.cast_time = 1.0
	if r.begin(bad):
		_fail("a hand-built cast violating the factory laws must be refused")
		return
	var spec := TelegraphCast.circle(CENTRE, RADIUS, 0.5)
	if not r.begin(spec):
		_fail("a valid spec was refused")
		return
	var target := _target("SpecTarget", Vector3(2, 0, 0))
	# Sabotage the caller's instance: shrink it and move it away entirely.
	spec.radius = 0.5
	spec.origin_point = Vector3(50, 0, 50)
	# Capture through member state — a GDScript lambda captures LOCALS by
	# value, so a `got = hits` into a local would write the closure's copy.
	_resolutions = 0
	_last_hits.clear()
	r.resolved.connect(func(hits: Array[Node3D]) -> void:
		_resolutions += 1
		_last_hits = hits)
	r.advance(0.5)
	if _resolutions != 1 or not _last_hits.has(target):
		_fail("SNAPSHOT LAW BROKEN: mutating the caller's cast after begin changed the resolved shape")
		return
	target.remove_from_group(TelegraphRuntime.TARGET_GROUP)
	target.queue_free()
	r.queue_free()


## A cast is world-anchored even when a caster parents the runtime under its
## own moving transform (`top_level`) — the painted zone must not drag.
func _moving_parent() -> void:
	var carrier := Node3D.new()
	add_child(carrier)
	var r := TelegraphRuntime.new()
	r.auto_advance = false
	carrier.add_child(r)
	if not r.begin(TelegraphCast.circle(CENTRE, RADIUS, CAST_TIME)):
		_fail("a runtime parented under a caster must still begin")
		return
	var zone := r.get_node("Zone") as Decal
	var before := zone.global_position
	carrier.global_position = Vector3(50, 0, 0)
	if not zone.global_position.is_equal_approx(before):
		_fail("WORLD ANCHOR BROKEN: moving the caster parent dragged the painted zone")
		return
	carrier.queue_free()


## The legal full-disc cone (cos_half_scaled == -COS_SCALE) has no angular
## boundary, so its zone texture must show interior wash along the +Z axis —
## the phantom radial border seam the SDF special-case removes.
func _full_disc_seam() -> void:
	var r := TelegraphRuntime.new()
	r.auto_advance = false
	add_child(r)
	if not r.begin(TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), 4.0, -Telegraph.COS_SCALE, 1.0)):
		_fail("a full-disc cone cast must be accepted")
		return
	var img := ((r.get_node("Zone") as Decal).texture_albedo as ImageTexture).get_image()
	var ts := img.get_width()
	# Just off the +Z axis, halfway to the rim: deep inside the disc.
	var px := img.get_pixel(ts / 2, (ts * 3) / 4)
	if px.a > 0.5:
		_fail("full-disc cone paints a radial border seam along +Z (alpha %f)" % px.a)
		return
	r.queue_free()


## Resolution must sample positions AFTER same-tick target movement. The
## runtime is added to the tree BEFORE the mover — the adversarial insertion
## order: at equal physics priority the runtime's callback would run first on
## the crossing tick and sample the mover's previous-tick position, so a
## last-instant dodge would depend on tree order. RESOLUTION_PHYSICS_PRIORITY
## is what makes this pass.
func _physics_order() -> void:
	for n: Node in get_tree().get_nodes_in_group(TelegraphRuntime.TARGET_GROUP):
		n.remove_from_group(TelegraphRuntime.TARGET_GROUP)
	_resolutions = 0
	_last_hits.clear()
	var runtime := TelegraphRuntime.new()
	add_child(runtime)
	runtime.resolved.connect(func(hits: Array[Node3D]) -> void:
		_resolutions += 1
		_last_hits = hits)
	var mover := Mover.new()
	add_child(mover)
	mover.add_to_group(TelegraphRuntime.TARGET_GROUP)
	mover.global_position = INSIDE_A
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	# Crosses on the 3rd physics tick — the same tick the mover steps out.
	if not runtime.begin(TelegraphCast.circle(CENTRE, RADIUS, 2.5 * dt)):
		_fail("the physics-order cast failed to begin")
		return
	for i in 6:
		await get_tree().physics_frame
	if _resolutions != 1:
		_fail("the physics-order cast must resolve exactly once (fired %d times)" % _resolutions)
		return
	if _last_hits.has(mover):
		_fail("PHYSICS ORDER BROKEN: resolution sampled the mover before its same-tick move — the dodge depended on tree insertion order")
		return
	mover.queue_free()


## A target that steps out of the zone on its third physics tick — the same
## tick the physics-order cast resolves.
class Mover:
	extends Node3D
	var calls := 0

	func _physics_process(_delta: float) -> void:
		calls += 1
		if calls == 3:
			global_position = Vector3(9, 0, 0)


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
	_resolutions = 0
	_last_hits.clear()
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
