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
##  4. It has teeth, in four independent both-states controls — each isolating
##     ONE law, so a pass means the rule discriminates rather than the fixture
##     being unreachable for some unrelated reason:
##     - a rock wall severs the walk, and walking from inside rock reaches
##       nothing;
##     - a slit narrower than the wanderer does NOT connect, a wide channel does;
##     - a passage too LOW to stand up in does NOT connect, an otherwise
##       identical full-height one does;                          [#107: headroom]
##     - a span with nothing underneath does NOT connect, the same span with a
##       floor does.                                              [#107: support]
##
## Pure logic only — no scene, no save, no boot — safe to run locally.
##
## Run: godot --headless --path client res://tests/cave_connectivity_test.tscn

var _failed := false

## Synthetic-fixture dimensions. The rock margin matters: out-of-range reads as
## VOID by design (the real audit pads its box into open air), so a fixture
## without a solid border would leak free headroom and support in from outside
## and quietly defeat the very controls below.
const _FX := Vector3i(13, 9, 7)
const _MARGIN := 2


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
	if not _a_sealed_cave_has_no_way_out():
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
	var from_a := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(3))
	_check(_reached(from_a, _floor_cell(3)), true, "teeth: hall A's own floor is walkable")
	_check(_reached(from_a, _floor_cell(9)), false, "teeth: hall B across the wall is NOT reached")

	var inside_rock := Vector3i(6, _MARGIN, 3)
	var from_rock := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, inside_rock)
	_check(_count(from_rock) == 0, true,
		"teeth: walking from inside rock reaches nothing (got %d)" % _count(from_rock))
	return not _failed


## Both states of the SIDEWAYS clearance rule on identical geometry: the halls
## are joined through the wall by either a one-cell slit (narrower than the
## wanderer ⇒ must NOT connect) or a three-cell channel (⇒ must connect).
func _clearance_rejects_a_slit() -> bool:
	var slit := _halls(_gap([3]))
	var wide := _halls(_gap([2, 3, 4]))
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
	var low := _halls(_gap([2, 3, 4], CaveSystemGen.BODY_CELLS - 1))
	var tall := _halls(_gap([2, 3, 4], CaveSystemGen.BODY_CELLS))
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
	var floored := _halls(_gap([2, 3, 4]))
	var chasm := _halls(_gap([2, 3, 4]), true)
	_check(_walks_between(chasm), false,
		"support: a span with nothing underneath does NOT connect the halls")
	_check(_walks_between(floored), true,
		"support: the same span with a floor DOES connect them")

	# The controlling difference really is support, not some accident of shape:
	# as pure free space the chasm span is still an open corridor.
	var air := CaveSystemGen.flood_passable(chasm, _FX.x, _FX.y, _FX.z, _floor_cell(3))
	_check(_reached(air, _floor_cell(9)), true,
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
	var seen := CaveSystemGen.flood_walkable(sealed, _FX.x, _FX.y, _FX.z, _floor_cell(3))
	_check(CaveSystemGen._walks_out(sealed, _FX.x, _FX.y, _FX.z, seen), false,
		"way out: a cave sealed in rock reports NO way out")

	var bored := _halls(_sealed())
	for x in range(_MARGIN, _FX.x):
		for y in range(_MARGIN, _MARGIN + CaveSystemGen.BODY_CELLS + 1):
			for z in range(_FX.z - _MARGIN, _FX.z):
				_put(bored, Vector3i(x, y, z), -1.0)
	var out_seen := CaveSystemGen.flood_walkable(bored, _FX.x, _FX.y, _FX.z, _floor_cell(3))
	_check(CaveSystemGen._walks_out(bored, _FX.x, _FX.y, _FX.z, out_seen), true,
		"way out: boring a passage to the edge of the box DOES open one")
	return not _failed


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
func _halls(link: Callable, hollow_below: bool = false) -> PackedFloat32Array:
	var f := _rock()
	for x in range(_MARGIN, 6):
		_carve_column(f, x)
	for x in range(7, _FX.x - _MARGIN):
		_carve_column(f, x)
	link.call(f, hollow_below)
	return f


## A hall column: full standing height above the floor, full width.
func _carve_column(f: PackedFloat32Array, x: int) -> void:
	for y in range(_MARGIN, _MARGIN + CaveSystemGen.BODY_CELLS + 1):
		for z in range(_MARGIN, _FX.z - _MARGIN + 1):
			_put(f, Vector3i(x, y, z), -1.0)


## No link at all: the wall at x = 6 stays solid.
func _sealed() -> Callable:
	return func(_f: PackedFloat32Array, _hollow: bool) -> void: pass


## A link through the wall at x = 6 over the given z rows, [param height] cells
## tall from the floor up. Defaults to exactly enough to stand in.
func _gap(z_rows: Array, height: int = CaveSystemGen.BODY_CELLS) -> Callable:
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
				for y in range(_MARGIN - CaveSystemGen.SUPPORT_CELLS, _MARGIN):
					_put(f, Vector3i(x, y, z), -1.0)


## Can the wanderer walk from deep in hall A to deep in hall B?
func _walks_between(f: PackedFloat32Array) -> bool:
	var seen := CaveSystemGen.flood_walkable(f, _FX.x, _FX.y, _FX.z, _floor_cell(3))
	return _reached(seen, _floor_cell(9))


## A cell on the hall floor at the given x, in the middle row.
func _floor_cell(x: int) -> Vector3i:
	return Vector3i(x, _MARGIN, 3)


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
