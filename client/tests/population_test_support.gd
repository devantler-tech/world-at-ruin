class_name PopulationTestSupport
extends RefCounted
## Independent node-position observations for real population boot scenes.


static func placement_problem(subject: Node3D, expected: Vector3, world: WorldGen) -> String:
	var pos := subject.position
	if pos.distance_to(expected) > 0.001:
		return "%s stands at %s, recomputed layout says %s — placement is not deterministic" % [subject.name, pos, expected]
	if Vector2(pos.x, pos.z).length() < WorldGen.SHRINE_CLEAR_RADIUS:
		return "%s stands inside the shrine clearing" % subject.name
	if world.cave_protects(pos.x, pos.z):
		return "%s stands in a cave footprint" % subject.name
	var walkout := Geometry2D.get_closest_point_to_segment(
		Vector2(pos.x, pos.z), WorldGen.CAVE_SITE, Vector2.ZERO)
	if Vector2(pos.x, pos.z).distance_to(walkout) < NpcSpawner.WALKOUT_CLEARANCE - 0.001:
		return "%s blocks the cave walk-out line" % subject.name
	var ground: float = world.surface_height_at(pos.x, pos.z)
	if absf(pos.y - ground) > 0.001:
		return "%s floats: y=%f, ground=%f" % [subject.name, pos.y, ground]
	return ""
