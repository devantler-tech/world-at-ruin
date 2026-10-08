extends Node
## Catches ignored regional exposure, hard boundaries and region-dependent cell IDs.

var _failed := false


func _ready() -> void:
	var regions := load("res://scripts/ground_regions.gd") as Script
	if not regions.has_method("stone_for"):
		_fail("ground regions supply no stone profile")
		get_tree().quit(1)
		return
	var sites: Array[GroundRegions.Site] = [
		GroundRegions.Site.new(0.0, 0.0, 0),
		GroundRegions.Site.new(20.0, 0.0, 2),
	]
	var buried: Vector2 = regions.call("stone_for", sites, 0.0, 0.0)
	var scoured: Vector2 = regions.call("stone_for", sites, 20.0, 0.0)
	if not buried.is_equal_approx(Vector2(0.65, 0.42)) \
			or not scoured.is_equal_approx(Vector2(0.28, 0.20)):
		_fail("decided buried/scoured interiors do not retain their authored profiles")
	var meeting: Vector2 = regions.call("stone_for", sites, 10.0, 0.0)
	if not meeting.is_equal_approx(Vector2(0.465, 0.31)):
		_fail("the boundary must blend the two profiles once, in equal shares")
	var left: Vector2 = regions.call("stone_for", sites, 9.999, 0.0)
	var right: Vector2 = regions.call("stone_for", sites, 10.001, 0.0)
	if left.distance_to(right) > 0.0002:
		_fail("regional stone profile jumps at a boundary")
	# A duplicated site of the same substance must not double that region's vote.
	sites.append(GroundRegions.Site.new(0.0, 0.0, 0))
	var duplicate: Vector2 = regions.call("stone_for", sites, 10.0, 0.0)
	if not duplicate.is_equal_approx(meeting):
		_fail("two sites of the same region overweight their exposure profile")
	sites.remove_at(2)
	sites.append(GroundRegions.Site.new(10.0, sqrt(300.0), 1))
	var triple: Vector2 = regions.call("stone_for", sites, 10.0, sqrt(300.0) / 3.0)
	if triple.distance_to(Vector2(1.43 / 3.0, 0.30)) > 0.000001:
		_fail("a three-region meeting ignores a competing profile")
	# This real historical third-site seam must converge as the step shrinks.
	var dealt := GroundRegions.sites(1409, 220.0)
	var before: Vector2 = regions.call("stone_for", dealt, 49.5999, 34.0)
	var after: Vector2 = regions.call("stone_for", dealt, 49.6001, 34.0)
	if before.distance_to(after) > 0.00005:
		_fail("the third-site handover creates a stone profile seam")
	var field := ExposedSlabField.new()
	if field.rock_mix_for(0.30, 0.5, 0.035, buried.y) > 0.01 \
			or field.rock_mix_for(0.30, 0.5, 0.035, scoured.y) < 0.99:
		_fail("regional scouring does not expose the same held-drift slope")
	var buried_count := 0
	var scoured_count := 0
	for z in range(-25, 25):
		for x in range(-25, 25):
			var at := Vector2(x + 0.25, z + 0.25)
			var a := field.sample(1409, at, {&"exposed_threshold": buried.x})
			var b := field.sample(1409, at, {&"exposed_threshold": scoured.x})
			if a[&"identity"] != b[&"identity"] \
					or a[&"substance"] != b[&"substance"]:
				_fail("changing the region re-dealt the slab identity or substance")
			buried_count += int(a[&"exposed"])
			scoured_count += int(b[&"exposed"])
	if scoured_count < buried_count + 300:
		_fail("the same fixed field must expose materially more stone when scoured: %d/%d"
			% [buried_count, scoured_count])
	if not _failed:
		print("TEST PASS: regional stone profiles — decided interiors, continuous boundary, stable identities, distinct coverage %d/%d" % [buried_count, scoured_count])
	get_tree().quit(1 if _failed else 0)


func _fail(message: String) -> void:
	_failed = true
	print("TEST FAIL: " + message)
