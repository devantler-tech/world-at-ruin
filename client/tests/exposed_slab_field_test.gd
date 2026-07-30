extends Node
## Contract tests for the CPU-side exposed-slab field.
##
## The fixtures are measured from the shipping shader's arithmetic at a decided
## cell interior, one boundary, and one isolated triple junction. Expectations
## are literal rather than computed through a mirror of the production
## implementation. Source guards join those CPU fixtures to the shader code:
## either side drifting fails this test.
##
## Run:
## godot --headless --path client res://tests/exposed_slab_field_test.tscn

const FIELD_PATH := "res://scripts/exposed_slab_field.gd"
const PARTITION_PATH := "res://shaders/terrain_surface.gdshaderinc"
const GROUND_SHADER_PATH := "res://shaders/terrain.gdshader"
const NOISE_PATH := "res://shaders/noise.gdshaderinc"
const EPS := 0.000001
const WORLD_SIZE := 220.0
const EXPECTED_WORLD_CANDIDATES := 36_100
## An owner can meet any of the other 24 cells in its owner-relative 5×5
## window: two-apart cells can both occur in a fragment's local 3×3 search.
const EXPECTED_MAX_VERTICES := 24

var _failures: Array[String] = []


func _ready() -> void:
	if not FileAccess.file_exists(FIELD_PATH):
		_fail("%s is missing — no CPU slab field exists" % FIELD_PATH)
		_report()
		return
	var field_script := load(FIELD_PATH) as Script
	if field_script == null:
		_fail("%s does not load as a script" % FIELD_PATH)
		_report()
		return
	var field := field_script.new() as RefCounted
	if field == null:
		_fail("%s does not construct a RefCounted field" % FIELD_PATH)
		_report()
		return
	if not field.has_method("sample"):
		_fail("%s has no sample(seed, world_xz, region_context) API" % FIELD_PATH)
		_report()
		return
	if not field.has_method("polygon_for"):
		_fail("%s has no polygon_for(seeded_identity) API" % FIELD_PATH)
	if not field.has_method("candidate_identities"):
		_fail("%s has no candidate_identities(seed, world_size) API" % FIELD_PATH)
	if not _failures.is_empty():
		_report()
		return

	_test_shader_source_contract()
	_test_shader_interior_fixture(field)
	_test_shader_boundary_fixture(field)
	_test_shader_triple_fixture(field)
	_test_exposure_fixture(field)
	_test_smoothstep_precision_fixture(field)
	_test_seeded_identity(field)
	_test_region_context(field)
	_test_candidate_bound(field, field_script)
	_test_polygons(field, field_script)
	_report()


## A production change to the plate scale, hash constants/domain, nearest-cell
## search, substance bands, slab threshold, or exposure threshold breaks this
## fixture. The point is well inside its owning cell, so this is not a
## floating-point tie disguised as a parity test.
func _test_shader_interior_fixture(field: RefCounted) -> void:
	var context := {&"rock_mix": 0.0}
	var a := field.call("sample", 1409, Vector2(-13.75, -20.0), context) as Dictionary
	var b := field.call("sample", 1409, Vector2(-13.75, -20.0), context) as Dictionary
	if a != b:
		_fail("the same seed, position, and region context produced different samples")
		return
	if a.get(&"id") != Vector2i(-12, -18):
		_fail("shader interior fixture belongs to %s, expected (-12, -18)"
			% [a.get(&"id")])
	if a.get(&"substance") != &"basalt":
		_fail("shader interior fixture resolved substance %s, expected basalt"
			% [a.get(&"substance")])
	if a.get(&"exposed") != false:
		_fail("shader interior fixture is exposed, expected buried")
	var drift := float(a.get(&"drift", -1.0))
	if absf(drift - 0.64235711097717) > EPS:
		_fail("shader interior fixture drift %.9f != 0.642357111" % drift)


## Points on opposite sides of the bisector between shader cells (0, 0) and
## (1, 0). The 0.01 plate-uv inset is large enough not to encode a tie-breaking
## accident while still pinning the boundary's position.
func _test_shader_boundary_fixture(field: RefCounted) -> void:
	var context := {&"rock_mix": 0.0}
	var left := field.call(
		"sample", 1409, Vector2(0.885244, 0.457407), context) as Dictionary
	var right := field.call(
		"sample", 1409, Vector2(0.907955, 0.451256), context) as Dictionary
	if left.get(&"id") != Vector2i(0, 0):
		_fail("shader boundary fixture's left side belongs to %s, expected (0, 0)"
			% [left.get(&"id")])
	if right.get(&"id") != Vector2i(1, 0):
		_fail("shader boundary fixture's right side belongs to %s, expected (1, 0)"
			% [right.get(&"id")])
	if left.get(&"substance") != &"rock" or right.get(&"substance") != &"ferric":
		_fail("shader boundary substances are %s/%s, expected rock/ferric"
			% [left.get(&"substance"), right.get(&"substance")])


## A fixed isolated triple junction from the shader partition's existing
## continuity fixture. Four 0.01 plate-uv probes surround three decided owners.
func _test_shader_triple_fixture(field: RefCounted) -> void:
	var context := {&"rock_mix": 0.0}
	var fixtures := [
		[Vector2(11.814926, 14.060237), Vector2i(9, 12), &"basalt"],
		[Vector2(11.838456, 14.060237), Vector2i(10, 11), &"basalt"],
		[Vector2(11.826691, 14.048471), Vector2i(9, 11), &"pale"],
		[Vector2(11.826691, 14.072001), Vector2i(9, 12), &"basalt"],
	]
	var owners: Dictionary = {}
	for fixture in fixtures:
		var result := field.call("sample", 1409, fixture[0], context) as Dictionary
		var expected_id: Vector2i = fixture[1]
		var expected_substance: StringName = fixture[2]
		if result.get(&"id") != expected_id:
			_fail("shader triple fixture at %s belongs to %s, expected %s"
				% [fixture[0], result.get(&"id"), expected_id])
		if result.get(&"substance") != expected_substance:
			_fail("shader triple fixture for %s resolved %s, expected %s"
				% [expected_id, result.get(&"substance"), expected_substance])
		owners[expected_id] = true
	if owners.size() != 3:
		_fail("shader triple fixture pins %d owners, expected exactly three"
			% owners.size())


func _test_exposure_fixture(field: RefCounted) -> void:
	var result := field.call(
		"sample", 1409, Vector2(-99.0, -100.0), {&"rock_mix": 0.0}) as Dictionary
	if result.get(&"id") != Vector2i(-84, -86):
		_fail("exposed fixture belongs to %s, expected (-84, -86)"
			% [result.get(&"id")])
	if result.get(&"substance") != &"basalt":
		_fail("exposed fixture resolved %s, expected basalt"
			% [result.get(&"substance")])
	if result.get(&"exposed") != true:
		_fail("shader exposure fixture is buried, expected exposed")
	var drift := float(result.get(&"drift", -1.0))
	if absf(drift - 0.50994616746902) > EPS:
		_fail("shader exposure fixture drift %.9f != 0.509946167" % drift)


## This threshold-neighbour was evaluated independently with binary32 shader
## operations. Float64 smoothstep rounds the sheet to 0.5 and buries the slab;
## the shader rounds it one ULP lower before adding rock_mix and exposes it.
func _test_smoothstep_precision_fixture(field: RefCounted) -> void:
	var result := field.call("sample", 1409, Vector2(-100.0, -110.0), {
		&"rock_mix": 0.06429079174995,
		&"exposure_width": 0.20760688185692,
	}) as Dictionary
	var drift := float(result.get(&"drift", -1.0))
	if absf(drift - 0.45215979218483) > EPS:
		_fail("smoothstep precision fixture drift %.9f != 0.452159792" % drift)
	if result.get(&"exposed") != true:
		_fail("binary32 smoothstep fixture is buried, expected exposed")


## The shipping shader's cells are world-coordinate based, so changing the
## world seed must not silently move them. The composite identity still carries
## the seed so caches and generated geometry cannot mix two worlds.
func _test_seeded_identity(field: RefCounted) -> void:
	var a := field.call(
		"sample", 1409, Vector2.ZERO, {&"rock_mix": 0.0}) as Dictionary
	var b := field.call(
		"sample", 1410, Vector2.ZERO, {&"rock_mix": 0.0}) as Dictionary
	if a.get(&"id") != Vector2i.ZERO or b.get(&"id") != Vector2i.ZERO:
		_fail("changing the seed moved the shipping shader cell at world origin")
	if a.get(&"identity") != Vector3i(1409, 0, 0):
		_fail("seeded plate identity is %s, expected (1409, 0, 0)"
			% [a.get(&"identity")])
	if b.get(&"identity") != Vector3i(1410, 0, 0):
		_fail("alternate seeded plate identity is %s, expected (1410, 0, 0)"
			% [b.get(&"identity")])


func _test_region_context(field: RefCounted) -> void:
	var point := Vector2(-88.0, -100.0)
	var buried := field.call(
		"sample", 1409, point, {&"rock_mix": 0.0}) as Dictionary
	var regional := field.call(
		"sample", 1409, point, {&"rock_mix": 1.0}) as Dictionary
	if buried.get(&"id") != Vector2i(-76, -85):
		_fail("region-context fixture belongs to %s, expected (-76, -85)"
			% [buried.get(&"id")])
	if buried.get(&"exposed") != false or regional.get(&"exposed") != true:
		_fail("rock_mix 0/1 resolved exposure %s/%s, expected false/true"
			% [buried.get(&"exposed"), regional.get(&"exposed")])
	var footprint_point := Vector2(-13.0, 48.0)
	var close := field.call("sample", 1409, footprint_point, {
		&"rock_mix": 0.3,
		&"exposure_width": 0.035,
	}) as Dictionary
	var wide := field.call("sample", 1409, footprint_point, {
		&"rock_mix": 0.3,
		&"exposure_width": 0.25,
	}) as Dictionary
	var default_width := field.call("sample", 1409, footprint_point, {
		&"rock_mix": 0.3,
	}) as Dictionary
	var clamped_low := field.call("sample", 1409, footprint_point, {
		&"rock_mix": 0.3,
		&"exposure_width": 0.001,
	}) as Dictionary
	var clamped_high := field.call("sample", 1409, footprint_point, {
		&"rock_mix": 0.3,
		&"exposure_width": 1.0,
	}) as Dictionary
	if close.get(&"id") != Vector2i(-12, 40):
		_fail("exposure-width fixture belongs to %s, expected (-12, 40)"
			% [close.get(&"id")])
	if close.get(&"exposed") != false or wide.get(&"exposed") != true:
		_fail("exposure_width 0.035/0.25 resolved %s/%s, expected false/true"
			% [close.get(&"exposed"), wide.get(&"exposed")])
	if absf(float(default_width.get(&"exposure_width")) - 0.035) > EPS \
			or absf(float(clamped_low.get(&"exposure_width")) - 0.035) > EPS:
		_fail("default/low exposure widths are %s/%s, expected 0.035/0.035"
			% [default_width.get(&"exposure_width"),
				clamped_low.get(&"exposure_width")])
	if absf(float(clamped_high.get(&"exposure_width")) - 0.25) > EPS:
		_fail("high exposure width is %s, expected the shader ceiling 0.25"
			% [clamped_high.get(&"exposure_width")])
	if default_width.get(&"exposed") != close.get(&"exposed") \
			or clamped_low.get(&"exposed") != close.get(&"exposed") \
			or clamped_high.get(&"exposed") != wide.get(&"exposed"):
		_fail("exposure-width default/clamps do not preserve the bounded decisions")


func _test_candidate_bound(field: RefCounted, field_script: Script) -> void:
	var constants := field_script.get_script_constant_map()
	if constants.get(&"MAX_CANDIDATES_220M") != EXPECTED_WORLD_CANDIDATES:
		_fail("220 m candidate bound is %s, expected %d"
			% [constants.get(&"MAX_CANDIDATES_220M"), EXPECTED_WORLD_CANDIDATES])
	if constants.get(&"MAX_VERTICES_PER_POLYGON") != EXPECTED_MAX_VERTICES:
		_fail("polygon vertex bound is %s, expected %d"
			% [constants.get(&"MAX_VERTICES_PER_POLYGON"), EXPECTED_MAX_VERTICES])

	var identities := field.call(
		"candidate_identities", 1409, WORLD_SIZE) as Array[Vector3i]
	if identities.size() != EXPECTED_WORLD_CANDIDATES:
		_fail("220 m candidate generation returned %d identities, expected %d"
			% [identities.size(), EXPECTED_WORLD_CANDIDATES])
		return
	if identities.front() != Vector3i(1409, -95, -95):
		_fail("first 220 m candidate is %s, expected (1409, -95, -95)"
			% [identities.front()])
	if identities.back() != Vector3i(1409, 94, 94):
		_fail("last 220 m candidate is %s, expected (1409, 94, 94)"
			% [identities.back()])
	var fresh := field_script.new() as RefCounted
	var rebuilt := fresh.call(
		"candidate_identities", 1409, WORLD_SIZE) as Array[Vector3i]
	if identities != rebuilt:
		_fail("two fresh fields produced different 220 m candidate identities")
	for identity in identities:
		if identity.x != 1409:
			_fail("candidate %s lost the requested world seed" % [identity])
			break


func _test_polygons(field: RefCounted, field_script: Script) -> void:
	var identities := field.call(
		"candidate_identities", 1409, WORLD_SIZE) as Array[Vector3i]
	var fresh := field_script.new() as RefCounted
	var origin_identity := Vector3i(1409, 0, 0)
	var origin := field.call(
		"polygon_for", origin_identity) as PackedVector2Array
	var rebuilt := fresh.call(
		"polygon_for", origin_identity) as PackedVector2Array
	if origin != rebuilt:
		_fail("two fresh fields produced different polygon vertices for (0, 0)")
	var alternate_seed := field.call(
		"polygon_for", Vector3i(1410, 0, 0)) as PackedVector2Array
	if origin != alternate_seed:
		_fail("changing the seed moved the current world-coordinate shader polygon")

	# The fixed shader boundary must be an edge of both cells' geometry.
	var boundary := Vector2(0.896599, 0.454331)
	for identity in [Vector3i(1409, 0, 0), Vector3i(1409, 1, 0)]:
		var polygon := field.call("polygon_for", identity) as PackedVector2Array
		if _distance_to_edges(boundary, polygon) > 0.00001:
			_fail("shader boundary fixture is not on polygon %s" % [identity])

	# The three fixed shader owners must share the pinned triple vertex.
	var triple := Vector2(11.826691, 14.060237)
	for identity in [
		Vector3i(1409, 9, 12),
		Vector3i(1409, 10, 11),
		Vector3i(1409, 9, 11),
	]:
		var polygon := field.call("polygon_for", identity) as PackedVector2Array
		if _distance_to_vertices(triple, polygon) > 0.0002:
			_fail("shader triple fixture is not a vertex of polygon %s" % [identity])

	# Check the complete, explicitly bounded 220 m candidate set rather than a
	# favourable sample. This is also a performance guard: no nodes, resources,
	# meshes, or draw calls are created for a candidate—only packed vertices.
	for identity in identities:
		var polygon := field.call("polygon_for", identity) as PackedVector2Array
		if polygon.size() < 3 or polygon.size() > EXPECTED_MAX_VERTICES:
			_fail("polygon %s has %d vertices, expected 3..%d"
				% [identity, polygon.size(), EXPECTED_MAX_VERTICES])
			return
		var centroid := Vector2.ZERO
		for vertex in polygon:
			if not is_finite(vertex.x) or not is_finite(vertex.y):
				_fail("polygon %s contains non-finite vertex %s" % [identity, vertex])
				return
			centroid += vertex
		centroid /= float(polygon.size())
		var area := _signed_area(polygon)
		if not is_finite(area) or area <= EPS:
			_fail("polygon %s has non-positive or non-finite signed area %.9f"
				% [identity, area])
			return
		var expected_cell := Vector2i(identity.y, identity.z)
		for index in polygon.size():
			var next := (index + 1) % polygon.size()
			var edge_midpoint := (polygon[index] + polygon[next]) * 0.5
			var inside_probe := edge_midpoint.lerp(centroid, 0.001)
			var sample := field.call(
				"sample", identity.x, inside_probe, {&"rock_mix": 0.0}) as Dictionary
			if sample.get(&"id") != expected_cell:
				_fail("polygon %s edge %d enters shader cell %s at %s"
					% [identity, index, sample.get(&"id"), inside_probe])
				return


func _signed_area(polygon: PackedVector2Array) -> float:
	var twice_area := 0.0
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		twice_area += polygon[index].cross(polygon[next])
	return twice_area * 0.5


func _distance_to_edges(point: Vector2, polygon: PackedVector2Array) -> float:
	var nearest := INF
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		var edge := polygon[next] - polygon[index]
		var length_squared := edge.length_squared()
		if length_squared <= 0.0:
			continue
		var t := clampf((point - polygon[index]).dot(edge) / length_squared, 0.0, 1.0)
		nearest = minf(nearest, point.distance_to(polygon[index] + edge * t))
	return nearest


func _distance_to_vertices(point: Vector2, polygon: PackedVector2Array) -> float:
	var nearest := INF
	for vertex in polygon:
		nearest = minf(nearest, point.distance_to(vertex))
	return nearest


## Runtime GPU values are not readable in headless Godot. The fixed CPU
## fixtures therefore join to these whitespace-independent shader guards, the
## same pattern used by plate_junction_test for the fragment-only partition.
func _test_shader_source_contract() -> void:
	var partition := _source(PARTITION_PATH)
	var ground := _source(GROUND_SHADER_PATH)
	var noise := _source(NOISE_PATH)
	if partition.is_empty() or ground.is_empty() or noise.is_empty():
		_fail("shader parity source is unreadable (partition=%d ground=%d noise=%d bytes)"
			% [partition.length(), ground.length(), noise.length()])
		return
	var compact_partition := _compact_shader(partition)
	var compact_ground := _compact_shader(ground)
	var compact_noise := _compact_shader(noise)
	var partition_laws := [
		"returnfract(sin(dot(p,vec3(127.1,311.7,74.7)))*43758.5453);",
		"vec3u=f*f*(3.0-2.0*f);",
		"floatn000=terrain_hash3(i);",
		"floatn100=terrain_hash3(i+vec3(1.0,0.0,0.0));",
		"floatn010=terrain_hash3(i+vec3(0.0,1.0,0.0));",
		"floatn110=terrain_hash3(i+vec3(1.0,1.0,0.0));",
		"floatn001=terrain_hash3(i+vec3(0.0,0.0,1.0));",
		"floatn101=terrain_hash3(i+vec3(1.0,0.0,1.0));",
		"floatn011=terrain_hash3(i+vec3(0.0,1.0,1.0));",
		"floatn111=terrain_hash3(i+vec3(1.0,1.0,1.0));",
		"mix(mix(n000,n100,u.x),mix(n010,n110,u.x),u.y),mix(mix(n001,n101,u.x),mix(n011,n111,u.x),u.y),u.z);",
		"floatamp=0.5;",
		"floatsum=0.0;",
		"for(inti=0;i<3;i++){",
		"sum+=amp*terrain_value_noise(p);",
		"p*=2.03;",
		"amp*=0.5;",
		"returnterrain_fbm(vec3(xz.x,0.0,xz.y)*scale);",
		"for(intj=-1;j<=1;j++){",
		"for(inti=-1;i<=1;i++){",
		"vec2cell=base+vec2(float(i),float(j));",
		"terrain_hash3(vec3(cell,0.0)),terrain_hash3(vec3(cell,7.0)));",
		"vec2centre=cell+0.15+0.7*jitter;",
		"floatd=length(uv-centre);",
		"if(d<f1){",
		"f1=d;c1=centre;id=cell;",
		"floatpick=terrain_hash3(vec3(id*1.7,3.0));",
		"c=mix(c,basalt,step(0.38,pick));",
		"c=mix(c,ferric,step(0.66,pick));",
		"c=mix(c,pale,step(0.86,pick));",
	]
	for law in partition_laws:
		if not compact_partition.contains(law):
			_fail("shader partition parity law is missing: %s" % law)
	var ground_laws := [
		"uniformfloatdrift_scale=0.055;",
		"uniformfloatplate_scale=0.85;",
		"uniformfloatash_contact:hint_range(0.002,0.3)=0.035;",
		"vec2plate_uv=world_pos.xz*plate_scale;",
		"floatexposed_edge=drift-0.47;",
		"floatew=clamp(max(ash_contact,fwidth(exposed_edge)*1.2),ash_contact,max(ash_contact,0.25));",
		"floatsheet=clamp(smoothstep(-ew,ew,exposed_edge)+rock_mix,0.0,1.0);",
		"floatslab_pick=hash3(vec3(plate_id*2.3,19.0));",
		"floatis_slab=step(0.60,slab_pick);",
	]
	for law in ground_laws:
		if not compact_ground.contains(law):
			_fail("ground shader parity law is missing: %s" % law)
	var slab_hash_law := "returnfract(sin(dot(p,vec3(127.1,311.7,74.7)))*43758.5453);"
	if not (compact_ground + compact_noise).contains(slab_hash_law):
		_fail("ground slab hash parity law is missing from terrain/noise source")


func _source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _compact_shader(source: String) -> String:
	return source.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")


func _fail(message: String) -> void:
	_failures.append(message)


func _report() -> void:
	if _failures.is_empty():
		print("TEST PASS: exposed slab field")
		get_tree().quit(0)
		return
	for message in _failures:
		push_error(message)
		print("TEST FAIL: exposed slab field — %s" % message)
	get_tree().quit(1)
