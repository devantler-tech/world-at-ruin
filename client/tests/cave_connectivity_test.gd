extends Node
## Regression test for cave-system CONNECTIVITY (issues #84, #107) — the
## traversability guard the determinism test does not cover.
##
## The cave is the player's waking place. Its walkable void is carved as an SDF
## from rooms + tunnels, blended with a smooth-min and perturbed by wall noise.
## `cave_system_determinism_test` pins that the mesh is reproducible and its
## spine slopes are walkable; this pins that the cave is actually TRAVERSABLE —
## that a wanderer can reach every room and get out to open air. Under the
## no-resets law a player sealed into an unreachable pocket is trapped forever,
## so this must hold before the first player ever exists.
##
## #107 replaced the old one-cell grid erosion with the player's actual BODY.
## The erosion could only reject a gap narrower than the wanderer; it happily
## routed them through a crawlspace or across open air. The audit now walks a
## 0.4 m × 1.8 m capsule along floors that carry it, so what it certifies is a
## route the player can really take.
##
## What it proves:
##  1. On the shipped seeds, the walk from the waking chamber reaches the spawn
##     and every room, and finds a way out to open air.
##  2. The audit is deterministic (same seed ⇒ identical reachability).
##  3. The body it clears space for is the body the player actually has, and
##     the cell counts really follow from that body at this grid resolution.
##  4. It has teeth. Each law below gets its own control, isolated so that a
##     pass means the rule discriminates rather than the fixture being
##     unreachable for some unrelated reason — and each was RED-proven by
##     ablating that law alone and checking the failure names it:
##     - a rock wall severs the walk, and walking from inside rock reaches
##       nothing;
##     - a slit narrower than the wanderer does NOT connect, a wide channel does;
##     - a passage too LOW to stand up in does NOT connect, an otherwise
##       identical full-height one does;                          [#107: headroom]
##     - a span with nothing underneath does NOT connect, the same span with a
##       floor does;                                              [#107: support]
##     - a hall one cell lower IS reachable, two cells lower is not; [#107: step]
##     - a cave sealed in rock reports no way out, and boring a passage to the
##       edge of the box opens one;                               [#107: way out]
##     - a point buried in rock is not reachable even though rounding alone
##       would have certified it;                               [#107: borrowing]
##     - a pocket sealed above a corridor does not drop through the slab; [#107]
##     - a breach with no floor under it is not a way out;          [#107: exit]
##     - a ledge is not climbable with the ceiling low over the take-off.
##                                                                  [#107: rise]
##
## Pure logic only — no scene, no save, no boot — safe to run locally.
##
## Run: godot --headless --path client res://tests/cave_connectivity_test.tscn

var _failed := false

## Synthetic-fixture dimensions. The rock margin matters: out-of-range reads as
## VOID by design (the real audit pads its box into open air), so a fixture
## without a solid border would leak free headroom and support in from outside
## and quietly defeat the very controls below.
const _FX := Vector3i(13, 14, 9)
const _MARGIN := 3


func _ready() -> void:
	# --- the SHIPPED cave is walkable, plus extra seeds for breadth ---
	# WorldGen.CAVE_SEED is the cave the player actually wakes in: audit it by
	# reference, never by a literal, or changing the production seed would leave
	# CI certifying a cave nobody plays. The extra seeds are only samples.
	var seeds: Array[int] = [WorldGen.CAVE_SEED]
	for extra: int in [42, 43, 44]:
		if not seeds.has(extra):
			seeds.append(extra)
	for s: int in seeds:
		var r := CaveSystemGen.reachability(s)
		_check(r["start_passable"], true, "seed %d: the wanderer can stand where they wake" % s)
		_check(r["spawn_reachable"], true, "seed %d: the spawn is reachable on foot" % s)
		_check(r["mouth_open"], true, "seed %d: the wanderer can walk out to open air" % s)
		var rooms: Array = r["rooms_reachable"]
		_check(rooms.size() >= 3, true, "seed %d: it is a multi-room system" % s)
		for i in rooms.size():
			_check(rooms[i], true, "seed %d: room %d is reachable on foot" % [s, i])
		# Non-vacuous: a real walkable region exists, and it is a floor-hugging
		# shell rather than the whole cavity — if this ever approached `total`
		# the body model would have stopped constraining anything.
		var reached: int = r["reached"]
		var total: int = r["total"]
		_check(reached > 500, true, "seed %d: a substantial floor is walkable (%d cells)" % [s, reached])
		_check(reached * 10 < total, true,
			"seed %d: the walkable set is a floor, not the whole cavity (%d of %d)" % [s, reached, total])
		if _failed:
			return

	# --- determinism: the same seed audits identically ---
	var a := CaveSystemGen.reachability(42)
	var b := CaveSystemGen.reachability(42)
	_check(a["reached"] == b["reached"], true, "determinism: the walkable-cell count is stable")
	_check(a["mouth_open"] == b["mouth_open"] and a["rooms_reachable"] == b["rooms_reachable"], true,
		"determinism: the reachability flags are stable")
	if _failed:
		return

	# --- the modelled body is the real one ---
	if not _body_matches_the_player():
		return

	# --- teeth ---
	if not _rock_wall_severs_the_walk():
		return
	if not _clearance_rejects_a_slit():
		return
	if not _headroom_rejects_a_crawlspace():
		return
	if not _support_rejects_thin_air():
		return
	if not _a_drop_deeper_than_a_step_does_not_connect():
		return
	if not _a_sealed_cave_has_no_way_out():
		return
	if not _a_point_in_rock_cannot_borrow_next_doors_floor():
		return
	if not _a_pocket_above_a_slab_does_not_fall_through_it():
		return
	if not _a_breach_with_no_floor_is_not_a_way_out():
		return
	if not _a_ledge_under_a_low_ceiling_cannot_be_climbed():
		return

	print("TEST PASS — cave is walkable by the player's capsule (spawn, every room, and out to open air), deterministic; the walk stops at rock, at gaps narrower than the wanderer, at passages too low to stand in, and at spans with nothing underneath, and a sealed cave reports no way out")
	get_tree().quit(0)


## The audit's body constants must BE the player's capsule, and the cell counts
## must really follow from that capsule at CELL resolution. Both halves matter:
## the first stops the audit drifting away from the character it is clearing
## space for, the second stops CELL or the capsule changing without the derived
## cell counts following. GDScript cannot compute the counts in a const
## expression, so this is where that derivation is actually enforced.
func _body_matches_the_player() -> bool:
	var src := FileAccess.get_file_as_string("res://scripts/player.gd")
	_check(src.is_empty(), false, "body: player.gd is readable (the capsule's source of truth)")
	if _failed:
		return false
	# Pin the COLLISION capsule specifically. player.gd also builds a visual
	# CapsuleMesh at the same size (`cap`), so asserting the identity of the
	# `capsule` variable is what stops the guard passing on the placeholder mesh
	# if the collision shape alone ever changes.
	_check(src.contains("var capsule := CapsuleShape3D.new()"), true,
		"body: player.gd's `capsule` is the collision CapsuleShape3D")
	_check(src.contains("col.shape = capsule"), true,
		"body: that capsule is what the CollisionShape3D actually uses")
	_check(src.contains("capsule.radius = %s" % CaveSystemGen.BODY_RADIUS), true,
		"body: player.gd's capsule radius is %s, as the audit assumes" % CaveSystemGen.BODY_RADIUS)
	_check(src.contains("capsule.height = %s" % CaveSystemGen.BODY_HEIGHT), true,
		"body: player.gd's capsule height is %s, as the audit assumes" % CaveSystemGen.BODY_HEIGHT)

	_check(CaveSystemGen.BODY_CELLS == int(ceil(CaveSystemGen.BODY_HEIGHT / CaveSystemGen.CELL)), true,
		"body: BODY_CELLS is ceil(%s / %s)" % [CaveSystemGen.BODY_HEIGHT, CaveSystemGen.CELL])
	_check(CaveSystemGen.LATERAL_CELLS == int(ceil(CaveSystemGen.BODY_RADIUS / CaveSystemGen.CELL)), true,
		"body: LATERAL_CELLS is ceil(%s / %s)" % [CaveSystemGen.BODY_RADIUS, CaveSystemGen.CELL])
	return not _failed


## Two void halls split by a rock wall. Walking from hall A must stay in A, and
## walking from inside the wall itself must reach nothing.
func _rock_wall_severs_the_walk() -> bool:
	var f := _halls(_sealed())
	var from_a := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	_check(_reached(from_a, _floor_cell(4)), true, "teeth: hall A's own floor is walkable")
	_check(_reached(from_a, _floor_cell(8)), false, "teeth: hall B across the wall is NOT reached")

	var inside_rock := Vector3i(6, _MARGIN, 4)
	var from_rock := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, inside_rock)
	_check(_count(from_rock) == 0, true,
		"teeth: walking from inside rock reaches nothing (got %d)" % _count(from_rock))
	return not _failed


## Both states of the SIDEWAYS clearance rule on identical geometry: the halls
## are joined through the wall by either a one-cell slit (narrower than the
## wanderer ⇒ must NOT connect) or a three-cell channel (⇒ must connect).
func _clearance_rejects_a_slit() -> bool:
	var slit := _halls(_gap([4]))
	var wide := _halls(_gap([3, 4, 5]))
	_check(_walks_between(slit), false, "clearance: a one-cell slit does NOT connect the halls")
	_check(_walks_between(wide), true,
		"clearance: a three-cell channel DOES connect them (the rule is not blocking everything)")
	return not _failed


## Both states of the HEADROOM rule — the capability the old erosion lacked.
## The passage is full width in both, and differs only in ceiling height: one
## cell short of the wanderer's 1.8 m (a crawlspace ⇒ must NOT connect) versus
## exactly enough to stand up in (⇒ must connect). The old one-cell erosion
## passed BOTH of these, which is precisely why #107 exists.
func _headroom_rejects_a_crawlspace() -> bool:
	var low := _halls(_gap([3, 4, 5], CaveSystemGen.BODY_CELLS))
	var tall := _halls(_gap([3, 4, 5], CaveSystemGen.BODY_CELLS + 1))
	_check(_walks_between(low), false,
		"headroom: a passage one cell too low to stand in does NOT connect the halls")
	_check(_walks_between(tall), true,
		"headroom: the same passage at full standing height DOES connect them")
	return not _failed


## Both states of the FLOOR SUPPORT rule — the other capability the old erosion
## lacked. Identical full-height, full-width passages; the only difference is
## whether the rock beneath the passage is there. A span over nothing is free
## space a body fits in, so it still floods as OPEN SPACE — that contrast is the
## point: the walk rejects it, the volume test does not.
func _support_rejects_thin_air() -> bool:
	var floored := _halls(_gap([3, 4, 5]))
	var chasm := _halls(_gap([3, 4, 5]), true)
	_check(_walks_between(chasm), false,
		"support: a span with nothing underneath does NOT connect the halls")
	_check(_walks_between(floored), true,
		"support: the same span with a floor DOES connect them")

	# The controlling difference really is support, not some accident of shape:
	# as pure free space the chasm span is still an open corridor.
	var air := CaveSystemGen.flood_passable(chasm, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	_check(_reached(air, _floor_cell(8)), true,
		"support: the chasm IS connected as free space — only the walk rejects it")
	return not _failed


## Both states of the WAY OUT — without this the way-out check could simply
## always say yes, and every seed above would pass while proving nothing. A
## cave with no opening must report no way out; boring a full-height shaft from
## the hall to the edge of the box must make one appear.
##
## The escape is checked from the wanderer's own walkable region, so this also
## pins that reaching open air means WALKING to the threshold rather than the
## flood leaving the box — which, being grounded, it never can.
func _a_sealed_cave_has_no_way_out() -> bool:
	var sealed := _halls(_sealed())
	var seen := CaveSystemGen.flood_walkable(sealed, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	_check(CaveSystemGen._walks_out(sealed, _FX.x, _FX.y, _FX.z, seen), false,
		"way out: a cave sealed in rock reports NO way out")

	var bored := _halls(_sealed())
	for x in range(_MARGIN, _FX.x):
		for y in range(_MARGIN, _MARGIN + CaveSystemGen.BODY_CELLS + 1):
			for z in range(_FX.z - _MARGIN, _FX.z):
				_put(bored, Vector3i(x, y, z), -1.0)
	var out_seen := CaveSystemGen.flood_walkable(bored, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	_check(CaveSystemGen._walks_out(bored, _FX.x, _FX.y, _FX.z, out_seen), true,
		"way out: boring a passage to the edge of the box DOES open one")
	return not _failed


## Both states of the STEP rule, which is what support means in motion. With
## support required directly underfoot, an empty cell beneath a candidate simply
## means the real floor is lower — so the question is never "is there air below"
## but "can the wanderer get down to it". One cell is a step and must connect;
## two cells is a drop this model does not claim the player can take, and must
## not.
##
## This is a different law from the chasm control, which removes the floor
## entirely: here there is solid rock underfoot the whole way, at a depth that
## is either reachable or not.
func _a_drop_deeper_than_a_step_does_not_connect() -> bool:
	_check(_walks_between(_halls(_gap([3, 4, 5]), false, 1), 1), true,
		"step: a hall one cell lower IS reachable (the wanderer steps down)")
	_check(_walks_between(_halls(_gap([3, 4, 5]), false, 2), 2), false,
		"step: a hall two cells lower is NOT (the model does not claim falling)")
	return not _failed


## An audited point buried in rock must fail even when `cell_of` rounds it onto
## a walkable floor column. This is the guard the old `point_reached` carried:
## without judging the point at its own position in the SDF, the audit would
## certify a spawn or room that is embedded in — or walled off by — solid rock,
## by borrowing the verdict of the cavity next door.
##
## The control is only meaningful if such a point exists, so it FINDS one: a
## point whose own density is rock but whose rounded, ground-dropped cell is in
## the walkable set. That second assertion is the whole point — it says the
## audit would have said yes on rounding alone, and the density check is what
## says no.
func _a_point_in_rock_cannot_borrow_next_doors_floor() -> bool:
	var lay := CaveSystemGen.layout(42)
	var noise := CaveSystemGen.make_noise(42)
	var r := CaveSystemGen.reachability(42)
	var seen: PackedByteArray = r["seen"]
	var field: PackedFloat32Array = r["field"]
	var lo: Vector3 = r["lo"]
	var nx: int = r["nx"]
	var ny: int = r["ny"]
	var nz: int = r["nz"]

	var room: Dictionary = (lay["rooms"] as Array)[2]
	var centre := room["center"] as Vector3
	var base := Vector3(centre.x, (room["floor"] as float) + 0.3, centre.z)

	var buried := Vector3.ZERO
	var found := false
	for axis: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		for i in range(1, 300):
			var at := base + axis * (0.05 * i)
			if CaveSystemGen.density(at, lay, noise) < 0.0:
				continue
			# Rock. Would rounding alone have certified it?
			var c := CaveSystemGen.ground_cell(field, nx, ny, nz,
				CaveSystemGen.cell_of(at, lo, nx, ny, nz))
			if seen[CaveSystemGen._fi(c, ny, nz)] == 1:
				buried = at
				found = true
				break
		if found:
			break
	_check(found, true,
		"borrowing: a rock point that rounds onto a walkable column exists to test with")
	if _failed:
		return false

	_check(CaveSystemGen.walk_reached(buried, lay, noise, seen, field, lo, nx, ny, nz), false,
		"borrowing: a point inside rock is NOT reachable, though rounding alone would say it is")
	return not _failed



## A void pocket sealed above a walkable corridor by a rock slab must NOT drop
## through it. Dropping an audited point to the ground beneath it is what makes
## chamber centres judgeable, but a scan that passes through stone would certify
## a sealed pocket on the strength of the cave below it.
##
## The pocket is deliberately too SHORT to stand up in. That is what makes the
## control bite: a pocket the body fits in has a standing cell of its own, so
## the scan stops at once and never reaches the slab at all.
func _a_pocket_above_a_slab_does_not_fall_through_it() -> bool:
	var slab_y := _MARGIN + CaveSystemGen.BODY_CELLS + 1
	var pocket_y := slab_y + 1

	var f := _halls(_sealed())
	# Two levels only, with rock above: a pocket open to the top of the box would
	# borrow headroom from outside it and be standable after all.
	for x in range(_MARGIN, 6):
		for y in range(pocket_y, pocket_y + 2):
			for z in range(_MARGIN, _FX.z - _MARGIN + 1):
				_put(f, Vector3i(x, y, z), -1.0)
	var in_pocket := Vector3i(4, pocket_y + 1, 4)
	_check(CaveSystemGen.standing(f, _FX.x, _FX.y, _FX.z, Vector3i(4, pocket_y, 4)), false,
		"slab: the pocket really is too short to stand in (or the scan never runs)")
	_check(CaveSystemGen.ground_cell(f, _FX.x, _FX.y, _FX.z, in_pocket) == _floor_cell(4), false,
		"slab: a sealed pocket does NOT drop through the slab onto the hall floor")

	# The other state: carve the slab out and the same point DOES drop to the
	# hall floor — so the guard stops at rock rather than never dropping at all.
	for x in range(_MARGIN, 6):
		for y in range(_MARGIN, pocket_y):
			for z in range(_MARGIN, _FX.z - _MARGIN + 1):
				_put(f, Vector3i(x, y, z), -1.0)
	_check(CaveSystemGen.ground_cell(f, _FX.x, _FX.y, _FX.z, in_pocket) == _floor_cell(4), true,
		"slab: with the rock removed the same point DOES drop to the hall floor")
	return not _failed


## A body-sized breach through the mountain wall is only a way out if the
## wanderer can WALK it. A hole at head height over a missing floor is a view,
## not an exit — and the no-resets law cares about the difference.
func _a_breach_with_no_floor_is_not_a_way_out() -> bool:
	_check(_walks_out_of(_mountain(true)), true,
		"exit: a breach with a floor under it IS a way out")
	_check(_walks_out_of(_mountain(false)), false,
		"exit: the same breach with the floor carved away is NOT")
	return not _failed


## A hall, and a corridor breaching the +x wall to the edge of the box. When
## [param floored] is false the rock under the corridor is carved away, leaving
## the breach hanging — with rock still deeper down, so the audit knows it is
## inside the mountain and answerable for the floor.
func _mountain(floored: bool) -> PackedFloat32Array:
	var f := _rock()
	for x in range(_MARGIN, _FX.x):
		_carve_column(f, x, 0)
	if not floored:
		for x in range(6, _FX.x):
			for y in range(1, _MARGIN):
				for z in range(_MARGIN, _FX.z - _MARGIN + 1):
					_put(f, Vector3i(x, y, z), -1.0)
	return f


func _walks_out_of(f: PackedFloat32Array) -> bool:
	var seen := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	return CaveSystemGen._walks_out(f, _FX.x, _FX.y, _FX.z, seen)


## Both states of the RISE rule. The controller has no mantle logic, only a hop
## (player.gd: 7.2 m/s against 19.6 gravity clears 1.32 m, so one cell is easy).
## What a hop needs is somewhere to put the body on the way up.
##
## The low ceiling has to sit BEHIND the wanderer, over the cell they jump from.
## Putting it at the junction instead makes the ledge fail the ordinary sideways
## clearance rule, and the control then passes without the rise rule doing any
## work at all — which is exactly how the first version of this control fooled
## me.
func _a_ledge_under_a_low_ceiling_cannot_be_climbed() -> bool:
	_check(_climbs_the_ledge(false), false,
		"rise: a ledge is NOT climbable with the ceiling low over the take-off")
	_check(_climbs_the_ledge(true), true,
		"rise: the same ledge IS climbable once there is room to rise")
	return not _failed


## A lower hall and a ledge one cell up. The cell at the foot of the ledge is
## always full height; [param room_to_rise] decides whether the hall BEHIND it
## is, which is the only thing the rise rule can see.
func _climbs_the_ledge(room_to_rise: bool) -> bool:
	var f := _rock()
	var top := _MARGIN + CaveSystemGen.BODY_CELLS + 1
	var back_top := top + 1 if room_to_rise else top
	for x in range(_MARGIN, 6):
		_carve(f, x, _MARGIN, back_top)
	_carve(f, 6, _MARGIN, top + 1)
	for x in range(7, _FX.x - _MARGIN):
		_carve(f, x, _MARGIN + 1, top + 1)
	var seen := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	return _reached(seen, Vector3i(8, _MARGIN + 1, 4))


## Carve one column of cells over [param y0, y1) at full hall width.
func _carve(f: PackedFloat32Array, x: int, y0: int, y1: int) -> void:
	for y in range(y0, y1):
		for z in range(_MARGIN, _FX.z - _MARGIN + 1):
			_put(f, Vector3i(x, y, z), -1.0)


## Solid rock everywhere.
func _rock() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(_FX.x * _FX.y * _FX.z)
	f.fill(1.0)
	return f


## Carves the two halls into a solid block and applies [param link], which
## decides what (if anything) joins them through the wall at x = 6.
## When [param hollow_below] is set, the rock under the linking passage is
## removed as well, leaving the span hanging over a chasm.
func _halls(link: Callable, hollow_below: bool = false, b_drop: int = 0) -> PackedFloat32Array:
	var f := _rock()
	for x in range(_MARGIN, 6):
		_carve_column(f, x, 0)
	for x in range(7, _FX.x - _MARGIN):
		_carve_column(f, x, b_drop)
	link.call(f, hollow_below)
	return f


## A hall column: full standing height above the floor, full width, its floor
## [param drop] cells below the reference floor.
func _carve_column(f: PackedFloat32Array, x: int, drop: int) -> void:
	# The floor drops; the ceiling does not. Lowering both would pinch the
	# junction at head height and the control would fail on clearance rather
	# than on the step it is meant to isolate.
	for y in range(_MARGIN - drop, _MARGIN + CaveSystemGen.BODY_CELLS + 1):
		for z in range(_MARGIN, _FX.z - _MARGIN + 1):
			_put(f, Vector3i(x, y, z), -1.0)


## No link at all: the wall at x = 6 stays solid.
func _sealed() -> Callable:
	return func(_f: PackedFloat32Array, _hollow: bool) -> void: pass


## A link through the wall at x = 6 over the given z rows, [param height] cells
## tall from the floor up. Defaults to exactly enough to stand in — which is
## BODY_CELLS + 1 CARVED levels, because the field holds corner densities and
## the body's top boundary sample sits at the BODY_CELLS-th corner.
func _gap(z_rows: Array, height: int = CaveSystemGen.BODY_CELLS + 1) -> Callable:
	return func(f: PackedFloat32Array, hollow: bool) -> void:
		for z: int in z_rows:
			for y in range(_MARGIN, _MARGIN + height):
				_put(f, Vector3i(6, y, z), -1.0)
			if not hollow:
				continue
			# Take the floor out from under the whole span — including the hall
			# cells either side of the wall, so the wanderer cannot simply stand
			# at the lip and step across.
			for x: int in [5, 6, 7]:
				for y in range(0, _MARGIN):
					_put(f, Vector3i(x, y, z), -1.0)


## Can the wanderer walk from deep in hall A to deep in hall B?
func _walks_between(f: PackedFloat32Array, b_drop: int = 0) -> bool:
	var seen := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(4))
	return _reached(seen, _floor_cell(8) - Vector3i(0, b_drop, 0))


## A cell on the hall floor at the given x, in the middle row.
func _floor_cell(x: int) -> Vector3i:
	return Vector3i(x, _MARGIN, 4)


func _reached(seen: PackedByteArray, c: Vector3i) -> bool:
	return seen[CaveSystemGen._fi(c, _FX.y, _FX.z)] == 1


func _count(seen: PackedByteArray) -> int:
	var n := 0
	for i in seen.size():
		n += seen[i]
	return n


func _put(f: PackedFloat32Array, c: Vector3i, v: float) -> void:
	f[CaveSystemGen._fi(c, _FX.y, _FX.z)] = v


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_fail("%s — expected %s, got %s" % [label, expected, actual])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
