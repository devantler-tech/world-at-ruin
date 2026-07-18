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
## Baked texture resolution per axis scales with the shape so texels stay
## near `TEXEL_TARGET_M` — a big cone at 128 rendered visible scalloping at
## grazing angles — bounded so the once-per-begin bake stays cheap.
const TEXEL_TARGET_M := 0.07
const TEX_MIN := 128
const TEX_MAX := 256
## Border band thickness as a fraction of the shape extent, clamped to
## [0.2 m, 0.5 m] so small casts keep a visible rim and huge ones stay a line.
const BORDER_WIDTH_FRACTION := 0.045
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


## Bake the zone and fill textures for the armed cast. Per texel, WHETHER the
## point is inside goes through the SAME shared geometry predicate the
## resolution uses — origin-local, facing texture-up — so the painted shape
## IS the resolved shape by construction. HOW FAR the point sits from the
## boundary is then exact planar distance math, and the alphas ramp on that
## distance: a one-texel feather at the rim (anti-aliasing — the first
## capture pass failed the at-a-glance bar on binary stair-steps) and a
## `BORDER_WIDTH_FRACTION` bright band feathering into the interior wash.
## The bake runs once per begin; casters that spam one shape should cache
## and reuse textures — a follow-up for the first caster child.
## Returns [zone_texture, fill_texture].
func _bake_masks() -> Array[ImageTexture]:
	var half := _extent * 0.5
	var tex_size := clampi(int(ceil(_extent / TEXEL_TARGET_M)), TEX_MIN, TEX_MAX)
	var texel_w := _extent / float(tex_size)
	var band_w := clampf(_extent * BORDER_WIDTH_FRACTION, 0.2, 0.5)
	var zone_img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	var fill_img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	var clear := Color(0, 0, 0, 0)
	for j in tex_size:
		for i in tex_size:
			var x := ((float(i) + 0.5) / float(tex_size) * 2.0 - 1.0) * half
			var z := ((float(j) + 0.5) / float(tex_size) * 2.0 - 1.0) * half
			var sdf := _edge_sdf(x, z)
			# Outer-rim coverage: 0 outside, 1 inside, feathered ~2.5 texels
			# each side of the true edge (alpha 0.5 exactly on the boundary) —
			# wide enough that the ramp spans several texels and the edge
			# reads smooth even where the decal sampler resolves nearest.
			var c := smoothstep(-2.5 * texel_w, 2.5 * texel_w, sdf)
			if c <= 0.0:
				zone_img.set_pixel(i, j, clear)
				fill_img.set_pixel(i, j, clear)
				continue
			fill_img.set_pixel(i, j, _danger(FILL_ALPHA * c))
			# Bright border band just inside the boundary, feathered into the wash.
			var band := 1.0 - smoothstep(band_w, band_w + texel_w, sdf)
			zone_img.set_pixel(i, j, _danger(lerpf(INTERIOR_ALPHA, BORDER_ALPHA, band) * c))
	# Mipmaps matter twice: the decal filter's mipmap modes expect them, and
	# without them the marks shimmer under minification at distance.
	zone_img.generate_mipmaps()
	fill_img.generate_mipmaps()
	var out: Array[ImageTexture] = []
	out.append(ImageTexture.create_from_image(zone_img))
	out.append(ImageTexture.create_from_image(fill_img))
	return out


func _danger(alpha: float) -> Color:
	return Color(DANGER_COLOR.r, DANGER_COLOR.g, DANGER_COLOR.b, alpha)


## Signed distance from an origin-local point (cone opening toward -Z, the
## texture-up frame) to the shape boundary: positive inside, negative
## outside. The SIGN is the shared geometry predicate's verdict — presentation
## can never disagree with resolution about what is inside — and only the
## MAGNITUDE (how far from the edge, for the alpha ramps) is computed here:
## exact distance to the arc and, for the cone, to the mirrored bounding ray
## segment (clamping to the apex handles wide cones where the nearest
## boundary of an on-axis point is the apex itself).
func _edge_sdf(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var d := p.length()
	if _cast.shape == TelegraphCast.Shape.CIRCLE:
		return _cast.radius - d
	var inside := Telegraph.in_cone_scaled(Vector3.ZERO, Vector3(0, 0, -1), _cast.range_m,
			_cast.cos_half_scaled, Vector3(x, 0.0, z))
	var half_angle := acos(clampf(float(_cast.cos_half_scaled) / float(Telegraph.COS_SCALE), -1.0, 1.0))
	# Mirror to one side; the bounding ray leaves the apex at half_angle from -Z.
	var q := Vector2(absf(x), z)
	var ray_dir := Vector2(sin(half_angle), -cos(half_angle))
	var t := clampf(q.dot(ray_dir), 0.0, _cast.range_m)
	var to_ray := (q - ray_dir * t).length()
	if inside:
		return minf(_cast.range_m - d, to_ray)
	# Outside, the nearest wedge point lies on a bounding ray segment — or,
	# ONLY for points beyond the arc that are still angularly within the
	# wedge, radially back on the arc. Measuring the arc for angularly-outside
	# points would paint a phantom ring at `range_m` all the way around (the
	# arc is not a boundary where the wedge does not reach).
	var magnitude := to_ray
	if d > _cast.range_m and d > 0.0 and (-z / d) >= cos(half_angle):
		magnitude = minf(magnitude, d - _cast.range_m)
	return -magnitude
