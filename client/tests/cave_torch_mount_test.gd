extends Node
## Regression test: the starter cave's torches are BRACKETED TO THE ROCK.
##
## They used to be pushed a fixed 1.5 m sideways off the walkable spine, which
## is not where the wall is — tunnels are r≈2.15–2.6 m before wall noise, and
## the spine's waypoints are room centres where the rock is up to a 5.6 m room
## radius away. Every torch hung in mid-air; the ones at waypoints hung in the
## middle of an open chamber.
##
##  1. Every torch is anchored: rock within MAX_ANCHOR m behind its backplate.
##  2. No torch is stranded in open space (the old bug, stated as its own
##     assertion so a regression names itself).
##  3. The system still lights the way down: torches in at least half the
##     spine's segments, so anchoring never silently skips the cave dark.
##
## Run: godot --headless --path client res://tests/cave_torch_mount_test.tscn

const SEED := 42
## A mounted torch backs onto rock within a few cm; this is the tolerance for
## the coarse probe plus the backplate inset, not a licence to float.
const MAX_ANCHOR := 0.35
## Beyond this a torch is unambiguously stranded in open air.
const FLOATING := 0.75


func _ready() -> void:
	var lay := CaveSystemGen.layout(SEED)
	var noise := CaveSystemGen.make_noise(SEED)

	var cave := CaveSystemGen.new()
	cave.seed_value = SEED
	add_child(cave)

	var torches := _torches(cave)
	if torches.is_empty():
		_fail("the cave built no torches at all")
		return

	var worst := 0.0
	var floating := 0
	for t: Node3D in torches:
		# Probe from the torch back along its own mount normal: the direction
		# its backplate faces is the wall it claims to be bolted to.
		var back := -_facing(t)
		var d := CaveSystemGen.wall_distance(t.position, back, lay, noise, 12.0)
		if d < 0.0:
			_fail("torch at %s backs onto no rock at all within 12 m — floating" % t.position)
			return
		worst = maxf(worst, d)
		if d > FLOATING:
			floating += 1

	if floating > 0:
		_fail("%d of %d torches float in open space (worst gap %.2f m)"
			% [floating, torches.size(), worst])
		return
	if worst > MAX_ANCHOR:
		_fail("a torch sits %.2f m off its wall (limit %.2f m) — not bracketed"
			% [worst, MAX_ANCHOR])
		return

	# Anchoring must not have thinned the lighting to nothing.
	var segments: int = (lay["path"] as Array).size() - 1
	if torches.size() < segments:
		_fail("only %d torches for %d spine segments — the way down goes dark"
			% [torches.size(), segments])
		return

	print("TEST PASS — %d torches, worst anchor gap %.3f m" % [torches.size(), worst])
	get_tree().quit(0)


## The torches are the built children carrying an OmniLight3D.
func _torches(cave: CaveSystemGen) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for child in cave.get_children():
		if child is Node3D and _light_of(child) != null:
			out.append(child as Node3D)
	return out


func _light_of(n: Node) -> OmniLight3D:
	for c in n.get_children():
		if c is OmniLight3D:
			return c as OmniLight3D
	return null


## The mount normal: the torch leans out of its wall, so the horizontal
## component of its shaft direction points away from the rock it hangs on.
func _facing(t: Node3D) -> Vector3:
	var light := _light_of(t)
	var lean := light.position
	var flat := Vector3(lean.x, 0.0, lean.z)
	if flat.length() < 0.001:
		return Vector3.RIGHT
	return flat.normalized()


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
