class_name CaveTestSupport
extends RefCounted
## Independent flat contact surface used by both cave-foot talus paths.


static func flat_ground(_x: float, _z: float) -> float:
	return 0.0


static func flat_material(_x: float, _z: float) -> Dictionary:
	return {
		&"color": Color(0.30, 0.27, 0.23),
		&"roughness": 0.88,
		&"normal": Vector3.UP,
		&"height": 0.0,
	}
