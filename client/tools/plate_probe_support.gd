class_name PlateProbeSupport
extends RefCounted
## Shared edge sampling for physics observations, outside production geometry.
## Consumers choose edge lengths, probe offsets and their acceptance laws.


static func edge(a: Vector2, b: Vector2, centre: Vector2) -> Dictionary:
	var mid := (a + b) * 0.5
	var outward := Vector2(b.y - a.y, a.x - b.x).normalized()
	if outward.dot(mid - centre) < 0.0:
		outward = -outward
	return {&"mid": mid, &"outward": outward, &"along": (b - a).normalized()}
