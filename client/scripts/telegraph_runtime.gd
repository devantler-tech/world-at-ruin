class_name TelegraphRuntime
extends Node3D
## The in-world life of one telegraphed zone (issue #175, combat epic #9):
## ground presentation + the snapshot-at-resolution dodge law.
##
## `TelegraphCast` owns the clock and the shape; this node makes the promise
## VISIBLE and KEPT. From `begin` to resolution it paints the zone on the
## ground (a bordered danger shape) with a fill that grows from the origin as
## the cast progresses — the WildStar read: the border says WHERE, the fill
## says WHEN. At the resolution instant it reads the positions of everything
## in the `telegraph_targets` group EXACTLY ONCE, emits `resolved` with the
## nodes inside, flashes briefly, and frees itself.
##
## The dodge law is enforced by construction: no membership is evaluated and
## no position is cached at any other moment, so standing in the zone during
## the cast and stepping out before it lands means NOT HIT, and stepping in
## at the last instant means HIT. That is what dodging MEANS here, and the
## regression tests pin both directions.
##
## Damage, threat, and who casts are deliberately NOT here — this node stops
## at the `resolved` signal; the mob-AI and player-cast children consume it.
##
## Presentation notes: the ground mark is two `Decal`s (zone + fill) so it
## projects onto uneven terrain and cave floors rather than clipping through
## slopes like a flat quad would. Textures are baked once per `begin` from the
## SAME geometry predicate the resolution uses (`TelegraphCast.contains`'s
## underlying lib), so the painted shape can never lie about the resolved
## shape; per-frame updates only write decal `size` (no allocation churn). A
## cast is world-anchored: a moving caster begins a new cast, it never drags
## one. Readability is judged in the real lighting via the preview harness
## `client/scenes/telegraph.tscn` (see `telegraph_preview.gd`).

## Emitted exactly once, at the resolution instant, with the group members
## whose positions were inside the zone at that instant.
signal resolved(hits: Array[Node3D])

## Nodes that can be caught by a telegraph opt into this group. The coming
## combat children put the player and creatures here.
const TARGET_GROUP := "telegraph_targets"

## The genre-standard danger read: hot orange-red, high contrast against the
## ashen ground, and distinguishable by luminance alone (colour-blind safe).
const DANGER_COLOR := Color(1.0, 0.30, 0.08)
## Alpha of the zone interior wash / its bright border / the progress fill.
const INTERIOR_ALPHA := 0.22
const BORDER_ALPHA := 0.95
const FILL_ALPHA := 0.5
## Baked texture resolution per axis. 128 keeps the once-per-begin bake cheap
## while the decal filter keeps edges clean at gameplay scale.
const TEX_SIZE := 128
## Border thickness in texels (world thickness scales with the shape extent).
const BORDER_PX := 3
## Decal projection depth (m): covers this much slope/step under the origin.
const PROJECTION_DEPTH := 8.0
## Seconds the resolved flash stays before the node frees itself.
const LINGER := 0.12
## Emission drive for the decals — enough to glow in dark interiors without
## hazing daylight (the border alpha stays under the bloom threshold).
const EMISSION_ENERGY := 1.3

## When true (the default), the cast advances with the physics clock. Tests
## and replay-driven callers set this false and drive `advance` directly.
var auto_advance := true

var _cast: TelegraphCast
var _zone: Decal
var _fill: Decal
## Full footprint edge length (m): 2*radius for a circle, 2*range for a cone
## (the cone texture is authored apex-centred so fill growth scales about the
## apex — see `_bake_masks`).
var _extent := 0.0
var _after := 0.0


func _ready() -> void:
	set_physics_process(auto_advance)


func _physics_process(delta: float) -> void:
	advance(delta)


## Arm this node with a validated cast. Refuses loudly (returning false, with
## no children created) a null or already-resolved cast, a second begin, or a
## begin before the node is inside the tree (decals need world space, and the
## resolution needs the scene's target group). On success the zone mark is on
## the ground immediately with an empty fill.
func begin(cast: TelegraphCast) -> bool:
	if cast == null:
		push_error("TelegraphRuntime.begin: refusing a null cast (a factory refusal upstream?)")
		return false
	if cast.is_resolved:
		push_error("TelegraphRuntime.begin: refusing an already-resolved cast")
		return false
	if _cast != null:
		push_error("TelegraphRuntime.begin: this runtime already carries a cast — one node, one telegraph")
		return false
	if not is_inside_tree():
		push_error("TelegraphRuntime.begin: add the node to the tree before beginning a cast")
		return false
	_cast = cast
	_extent = (2.0 * cast.radius) if cast.shape == TelegraphCast.Shape.CIRCLE else (2.0 * cast.range_m)
	_build_decals()
	_update_fill()
	return true


## Consume `dt` seconds: advance the cast, grow the fill, and on the
## resolution instant snapshot the target group, emit `resolved`, then linger
## briefly and free. Safe to call with no cast armed (no-op). Invalid dt is
## refused loudly with no state change.
func advance(dt: float) -> void:
	if _cast == null:
		return
	if not is_finite(dt) or dt < 0.0:
		push_error("TelegraphRuntime.advance: dt must be finite and >= 0 (got %s)" % dt)
		return
	if _cast.is_resolved:
		_after += dt
		if _after >= LINGER and not is_queued_for_deletion():
			queue_free()
		return
	var crossed := _cast.advance(dt)
	_update_fill()
	if crossed:
		_resolve_now()


## The one place positions are read: the resolution instant.
func _resolve_now() -> void:
	var hits: Array[Node3D] = []
	for t: Node in get_tree().get_nodes_in_group(TARGET_GROUP):
		var n := t as Node3D
		if n != null and _cast.contains(n.global_position):
			hits.append(n)
	# Resolved flash: the fill snaps to the full zone for the linger beat.
	if _fill != null:
		_fill.size = Vector3(_extent, PROJECTION_DEPTH, _extent)
	resolved.emit(hits)


func _update_fill() -> void:
	if _fill == null or _cast == null:
		return
	# Growing-from-origin fill: the classic "how long do I have" read. Only
	# scalar `size` writes per frame — the texture is baked once at begin.
	var edge := maxf(_extent * _cast.progress(), 0.01)
	_fill.size = Vector3(edge, PROJECTION_DEPTH, edge)


func _build_decals() -> void:
	var masks := _bake_masks()
	_zone = _make_decal("Zone", masks[0], Vector3(_extent, PROJECTION_DEPTH, _extent))
	_fill = _make_decal("Fill", masks[1], Vector3(0.01, PROJECTION_DEPTH, 0.01))
	# The fill renders above the zone wash where they overlap.
	_fill.sorting_offset = 0.1


func _make_decal(node_name: String, tex: ImageTexture, size3: Vector3) -> Decal:
	var d := Decal.new()
	d.name = node_name
	d.texture_albedo = tex
	d.texture_emission = tex
	d.emission_energy = EMISSION_ENERGY
	d.size = size3
	add_child(d)
	d.global_position = _cast.origin_point
	# Rotate texture-up (-Z) onto the cast's planar facing so a cone opens the
	# way it will resolve. A circle is rotation-invariant; the shared rotation
	# keeps the two decals aligned either way.
	if _cast.shape == TelegraphCast.Shape.CONE:
		var dir := Vector2(_cast.facing.x, _cast.facing.z).normalized()
		d.global_rotation = Vector3(0.0, atan2(-dir.x, -dir.y), 0.0)
	return d


## Bake the zone and fill textures for the armed cast. Membership per texel
## goes through the SAME shared geometry predicate the resolution uses —
## origin-local, facing texture-up — so the painted shape IS the resolved
## shape; the border is then the inside texels with an outside texel within
## `BORDER_PX`. Returns [zone_texture, fill_texture].
func _bake_masks() -> Array[ImageTexture]:
	var half := _extent * 0.5
	var inside := PackedByteArray()
	inside.resize(TEX_SIZE * TEX_SIZE)
	var probe_facing := Vector3(0, 0, -1)
	for j in TEX_SIZE:
		for i in TEX_SIZE:
			var x := ((float(i) + 0.5) / float(TEX_SIZE) * 2.0 - 1.0) * half
			var z := ((float(j) + 0.5) / float(TEX_SIZE) * 2.0 - 1.0) * half
			var p := Vector3(x, 0.0, z)
			var hit := false
			if _cast.shape == TelegraphCast.Shape.CIRCLE:
				hit = Telegraph.in_circle(Vector3.ZERO, _cast.radius, p)
			else:
				hit = Telegraph.in_cone_scaled(Vector3.ZERO, probe_facing, _cast.range_m,
						_cast.cos_half_scaled, p)
			inside[j * TEX_SIZE + i] = 1 if hit else 0

	var zone_img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var fill_img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var clear := Color(0, 0, 0, 0)
	var interior := Color(DANGER_COLOR.r, DANGER_COLOR.g, DANGER_COLOR.b, INTERIOR_ALPHA)
	var border := Color(DANGER_COLOR.r, DANGER_COLOR.g, DANGER_COLOR.b, BORDER_ALPHA)
	var fill := Color(DANGER_COLOR.r, DANGER_COLOR.g, DANGER_COLOR.b, FILL_ALPHA)
	for j in TEX_SIZE:
		for i in TEX_SIZE:
			if inside[j * TEX_SIZE + i] == 0:
				zone_img.set_pixel(i, j, clear)
				fill_img.set_pixel(i, j, clear)
				continue
			fill_img.set_pixel(i, j, fill)
			zone_img.set_pixel(i, j, border if _is_border(inside, i, j) else interior)
	var out: Array[ImageTexture] = []
	out.append(ImageTexture.create_from_image(zone_img))
	out.append(ImageTexture.create_from_image(fill_img))
	return out


## An inside texel with any outside texel within BORDER_PX along an axis
## (texels past the texture edge count as outside, so a shape cropped by its
## own footprint still shows a rim).
func _is_border(inside: PackedByteArray, i: int, j: int) -> bool:
	for d in range(1, BORDER_PX + 1):
		for off: Vector2i in [Vector2i(d, 0), Vector2i(-d, 0), Vector2i(0, d), Vector2i(0, -d)]:
			var ni := i + off.x
			var nj := j + off.y
			if ni < 0 or ni >= TEX_SIZE or nj < 0 or nj >= TEX_SIZE:
				return true
			if inside[nj * TEX_SIZE + ni] == 0:
				return true
	return false
