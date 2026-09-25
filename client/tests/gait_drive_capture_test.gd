extends Node
## Contract test for #516's controller-driven gait capture.
##
## The `gait_drive` scenario renders, so it only runs windowed. This headless
## test pins everything around it that can be pinned without a GPU: the plan
## covers both gaits and the sprint press between them, frames sit at distance
## marks, the metrics report known answers on constructed traces, the replay
## comparison refuses any difference, the committed drive line is still clear
## on a freshly generated world, and CI actually runs the scenario and
## publishes what it writes.
##
## Loaded dynamically, like the other capture contract tests, so a missing
## method fails with a sentence rather than a parse error.

const FRAME_CAPTURE_PATH := "res://tools/frame_capture.gd"
const CI_WORKFLOW_PATH := "res://../.github/workflows/ci.yaml"
const DT := 1.0 / 60.0
const HEADING := Vector3(0.0, 0.0, -1.0)

var _capture: GDScript


func _ready() -> void:
	_capture = load(FRAME_CAPTURE_PATH) as GDScript
	if _capture == null:
		_fail("could not load %s" % FRAME_CAPTURE_PATH)
		return
	if not _capture.source_code.contains("\"gait_drive\""):
		_fail("frame capture has no gait_drive scenario — no controller-driven gait evidence exists")
		return
	for method: String in [
		"gait_drive_plan",
		"gait_drive_marks",
		"gait_drive_length",
		"gait_drive_metrics",
		"gait_drive_report_line",
		"gait_drive_contact_line",
		"gait_drive_replay_mismatch",
		"gait_drive_fingerprint",
		"gait_drive_path_problems",
	]:
		if not _has_method(method):
			_fail("frame capture does not expose %s" % method)
			return
	if not _check_plan():
		return
	if not _check_marks():
		return
	if not _check_planted_gait():
		return
	if not _check_partial_slide():
		return
	if not _check_floating_gait():
		return
	if not _check_contact():
		return
	if not _check_uneven_crossings():
		return
	if not _check_sub_step_timing():
		return
	if not _check_frozen_legs():
		return
	if not _check_replay():
		return
	if not _check_fingerprint():
		return
	if not await _check_path():
		return
	if not _check_ci():
		return
	print("TEST PASS — gait_drive covers both gaits and the sprint press, measures known " +
		"cadence, slide, lift and contact, refuses a non-identical replay, and its lines are clear")
	get_tree().quit(0)


## Both gaits, measured, with the input edge between them driven by the real
## sprint action rather than posed.
func _check_plan() -> bool:
	var plan: Array = _capture.gait_drive_plan()
	var measured_walk := false
	var measured_run := false
	var pressed_after_walk := false
	for i in plan.size():
		var segment: Dictionary = plan[i]
		var sprint: bool = segment["sprint"]
		var stride := (WalkLocomotion.RUN_STRIDE_LENGTH_M if sprint
			else WalkLocomotion.STRIDE_LENGTH_M)
		if segment["measure"]:
			if sprint:
				measured_run = true
			else:
				measured_walk = true
			# Two cycles, so at least one WHOLE cycle falls between the first
			# and last step change once the partial steps at each edge are lost.
			if float(segment["distance"]) < 2.0 * stride - 0.001:
				return _fail("the measured %s covers %.2f m, under two of its %.2f m cycles" %
					[segment["label"], segment["distance"], stride])
			if not segment["follow"]:
				return _fail("the measured %s has no follow-camera frame" % segment["label"])
			if float(segment["frame_span"]) != stride:
				return _fail("the measured %s photographs %.2f m, not one %.2f m cycle" %
					[segment["label"], segment["frame_span"], stride])
		if i > 0 and sprint and not bool(plan[i - 1]["sprint"]):
			pressed_after_walk = true
	if not measured_walk or not measured_run:
		return _fail("the drive plan does not measure both gaits (walk %s, run %s)" %
			[measured_walk, measured_run])
	if not pressed_after_walk:
		return _fail("the drive plan never presses sprint from a walk — #496's input edge is not driven")
	return true


## Distance marks, evenly spaced across one cycle, starting at the segment's
## first step.
func _check_marks() -> bool:
	var segment := {"frames": 8, "frame_span": 2.4}
	var marks: Array = _capture.gait_drive_marks(segment)
	if marks.size() != 8:
		return _fail("expected 8 marks, got %d" % marks.size())
	if not is_zero_approx(float(marks[0])):
		return _fail("the first mark is %.3f m in, not at the segment start" % marks[0])
	for k in range(1, marks.size()):
		if absf(float(marks[k]) - float(marks[k - 1]) - 0.3) > 0.000001:
			return _fail("marks %d and %d are not 0.3 m apart" % [k - 1, k])
	return true


## A foot that holds the ground: no slide, no lift, and the cadence, speed and
## cycle the trace was built with.
func _check_planted_gait() -> bool:
	var trace := _synthetic(6.0, 0.2, 1.2, 1.0, 0.0, 0.0)
	var m := _metrics(trace)
	if not m["ok"]:
		return _fail("a planted gait was refused: %s" % m["reason"])
	if absf(float(m["cadence_spm"]) - 300.0) > 0.5:
		return _fail("a 0.2 s step read %.2f steps/min, not 300" % m["cadence_spm"])
	if absf(float(m["speed_mps"]) - 6.0) > 0.0001:
		return _fail("a 6 m/s body read %.4f m/s" % m["speed_mps"])
	if absf(float(m["cycle_m"]) - 2.4) > 0.005:
		return _fail("a 2.4 m cycle read %.3f m" % m["cycle_m"])
	if float(m["slide_ratio"]) > 0.001:
		return _fail("a foot that holds the ground read %.0f%% slide" %
			(float(m["slide_ratio"]) * 100.0))
	if absf(float(m["lift_mean_m"])) > 0.0001:
		return _fail("a grounded foot read %.4f m of lift" % m["lift_mean_m"])
	var line: String = _capture.gait_drive_report_line("walk", m)
	if not line.contains("300 steps/min"):
		return _fail("the report line does not state the cadence: %s" % line)
	return true


## Half the ground held: the nearest foot moves at half the body's speed.
func _check_partial_slide() -> bool:
	var m := _metrics(_synthetic(6.0, 0.2, 1.2, 0.5, 0.0, 0.0))
	if not m["ok"]:
		return _fail("a half-sliding gait was refused: %s" % m["reason"])
	if absf(float(m["slide_ratio"]) - 0.5) > 0.001:
		return _fail("a foot moving at half body speed read %.0f%% slide" %
			(float(m["slide_ratio"]) * 100.0))
	return true


## A body that never sets a foot down reads as lift, not as a clean step.
func _check_floating_gait() -> bool:
	var m := _metrics(_synthetic(6.0, 0.2, 1.2, 1.0, 0.05, 0.0))
	if not m["ok"]:
		return _fail("a floating gait was refused: %s" % m["reason"])
	if absf(float(m["lift_mean_m"]) - 0.05) > 0.0001:
		return _fail("a body held 5 cm up read %.4f m of lift" % m["lift_mean_m"])
	return true


## Contact (#903): whether a foot holds the ground WHILE it is down, apart from
## how much of the stride it is down at all.
func _check_contact() -> bool:
	var planted := _metrics(_synthetic(6.0, 0.2, 1.2, 1.0, 0.0, 0.0))
	if absf(float(planted["contact_share"]) - 1.0) > 0.0001:
		return _fail("a gait with a foot always down read %.0f%% contact" % (float(planted["contact_share"]) * 100.0))
	if absf(float(planted["contact_slip_ratio"])) > 0.001:
		return _fail("a planted foot read %.1f%% contact slip" % (float(planted["contact_slip_ratio"]) * 100.0))
	var planted_line: String = _capture.gait_drive_contact_line("walk", planted)
	if not (planted_line.contains("for 100% of the stretch") and planted_line.contains("at 0% of body speed")):
		return _fail("the contact line does not state share and slip: %s" % planted_line)

	var half := _metrics(_synthetic(6.0, 0.2, 1.2, 0.5, 0.0, 0.0))
	if absf(float(half["contact_slip_ratio"]) - 0.5) > 0.001:
		return _fail("a down foot moving at half body speed read %.0f%% contact slip" %
			(float(half["contact_slip_ratio"]) * 100.0))

	var floating := _metrics(_synthetic(6.0, 0.2, 1.2, 1.0, 0.05, 0.0))
	if float(floating["contact_share"]) != 0.0 or float(floating["contact_slip_ratio"]) != -1.0:
		return _fail("a gait that never touches down read %.0f%% contact and %.2f slip" %
			[float(floating["contact_share"]) * 100.0, floating["contact_slip_ratio"]])
	var floating_line: String = _capture.gait_drive_contact_line("run", floating)
	if not floating_line.contains("no foot comes down to within 1 cm"):
		return _fail("a gait that never touches down is not named as such: %s" % floating_line)

	# A foot that brushes the ground on single samples was down, but never held
	# it across an interval: that is unmeasured slip, not a gait that floats.
	var brushing := _synthetic(6.0, 0.2, 1.2, 1.0, 0.05, 0.0)
	var brushing_lift: Array = brushing["lift_l"]
	for i in range(0, brushing_lift.size(), 3):
		brushing_lift[i] = 0.0
	var brushed := _metrics(brushing)
	var brushed_line: String = _capture.gait_drive_contact_line("run", brushed)
	if float(brushed["contact_share"]) <= 0.0 or float(brushed["contact_slip_ratio"]) != -1.0 \
			or not brushed_line.contains("never for two samples in a row"):
		return _fail("a foot down on isolated samples is not reported as unmeasured slip: %s" % brushed_line)

	# Sinking is still contact: a planted foot below its standing height is on
	# the ground, so it counts as down rather than escaping the slip figure.
	var sinking := _synthetic(6.0, 0.2, 1.2, 0.5, 0.0, 0.0)
	for key: String in ["lift_l", "lift_r"]:
		var lifts: Array = sinking[key]
		for i in lifts.size():
			if float(lifts[i]) == 0.0:
				lifts[i] = -0.05
	var sunk := _metrics(sinking)
	if absf(float(sunk["contact_share"]) - 1.0) > 0.0001 or absf(float(sunk["contact_slip_ratio"]) - 0.5) > 0.001:
		return _fail("a foot sunk 5 cm below its standing height escaped the contact figures (%.0f%% down, %.2f slip)" %
			[float(sunk["contact_share"]) * 100.0, sunk["contact_slip_ratio"]])

	# A run with airtime: the planted foot leaves the ground for the last 40% of
	# each step. While down it still holds perfectly, which the contact slip
	# must show — and which the nearest-foot slide, charging the airtime, does not.
	# That slide comes from the end of each flight, where the swinging foot sinks
	# below the lifted one and so becomes the nearest foot while it still moves.
	var trace := _synthetic(6.0, 0.2, 1.2, 1.0, 0.0, 0.0)
	var lift_l: Array = trace["lift_l"]
	var lift_r: Array = trace["lift_r"]
	for i in lift_l.size():
		var f := fposmod((0.03 * 0.2 + float(i) * DT) / 0.2, 1.0)
		if f > 0.6:
			if float(lift_l[i]) == 0.0:
				lift_l[i] = 0.05
			if float(lift_r[i]) == 0.0:
				lift_r[i] = 0.05
	var flight := _metrics(trace)
	if not flight["ok"]:
		return _fail("a gait with airtime was refused: %s" % flight["reason"])
	if absf(float(flight["contact_slip_ratio"])) > 0.001:
		return _fail("a foot that holds the ground while down, with airtime between, read %.1f%% contact slip" %
			(float(flight["contact_slip_ratio"]) * 100.0))
	if float(flight["contact_share"]) > 0.65 or float(flight["contact_share"]) < 0.55:
		return _fail("a foot down for 60%% of each step read %.0f%% contact" % (float(flight["contact_share"]) * 100.0))
	if float(flight["slide_ratio"]) < 0.05:
		return _fail(("the nearest-foot slide no longer charges airtime (%.0f%%) — this case no longer shows why " +
			"the contact figures exist") % (float(flight["slide_ratio"]) * 100.0))
	return true


## The standing pose leans on one leg, so the feet cross at uneven intervals.
## Timed over whole cycles the rate must still be exact.
func _check_uneven_crossings() -> bool:
	var m := _metrics(_synthetic(6.0, 0.2, 1.6, 1.0, 0.0, 0.08))
	if not m["ok"]:
		return _fail("an uneven gait was refused: %s" % m["reason"])
	if int(m["cycles"]) < 1:
		return _fail("an uneven gait was timed over no whole cycle")
	if absf(float(m["cadence_spm"]) - 300.0) > 0.5:
		return _fail("uneven crossings biased the cadence to %.2f steps/min" % m["cadence_spm"])
	return true


## At a run a step lasts 10.29 controller steps, so a crossing falls between
## two of them and timing it to the whole step is several percent out. The
## run's own step length, so the cadence has to come out at its 350.
func _check_sub_step_timing() -> bool:
	var step_s := WalkLocomotion.RUN_STRIDE_LENGTH_M / 2.0 / Player.SPRINT_SPEED
	var m := _metrics(_synthetic(Player.SPRINT_SPEED, step_s, 1.6, 1.0, 0.0, 0.0))
	if not m["ok"]:
		return _fail("a run-length step was refused: %s" % m["reason"])
	var expected := 60.0 / step_s
	if absf(float(m["cadence_spm"]) - expected) > 0.5:
		return _fail("a %.4f s step read %.2f steps/min, not %.2f — crossings are timed to the whole step" %
			[step_s, m["cadence_spm"], expected])
	return true


## Legs that never change which one leads are not being driven.
func _check_frozen_legs() -> bool:
	var body: Array = []
	var foot_l: Array = []
	var foot_r: Array = []
	var lifts: Array = []
	for i in 60:
		var at := HEADING * 6.0 * float(i) * DT
		body.append(at)
		foot_l.append(at + Vector3(-0.1, 0.0, -0.2))
		foot_r.append(at + Vector3(0.1, 0.0, 0.2))
		lifts.append(0.0)
	var m: Dictionary = _capture.gait_drive_metrics(body, foot_l, foot_r, lifts, lifts, HEADING, DT)
	if m["ok"]:
		return _fail("legs frozen in one stance were accepted as a gait")
	if not String(m["reason"]).contains("not alternating"):
		return _fail("frozen legs were refused for the wrong reason: %s" % m["reason"])
	var short: Dictionary = _capture.gait_drive_metrics(
		body, foot_l.slice(0, 10), foot_r, lifts, lifts, HEADING, DT)
	if short["ok"]:
		return _fail("channels of different lengths were accepted")
	return true


## Exact on purpose: two drives from one state on one machine share every bit.
func _check_replay() -> bool:
	var a := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0,
		16.0, 17.0, 18.0]
	if _capture.gait_drive_replay_mismatch(a, a.duplicate()) != "":
		return _fail("two identical traces were reported as different")
	var nudged := a.duplicate()
	nudged[10] = float(nudged[10]) + 0.000000001
	var verdict: String = _capture.gait_drive_replay_mismatch(a, nudged)
	if verdict.is_empty():
		return _fail("a trace that moved by a nanometre was accepted as a replay")
	if not verdict.contains("step 1"):
		return _fail("the mismatch names the wrong controller step: %s" % verdict)
	if _capture.gait_drive_replay_mismatch(a, a.slice(0, 9)) == "":
		return _fail("a shorter trace was accepted as a replay")
	return true


func _check_fingerprint() -> bool:
	var a := [0.5, 1.5, 2.5]
	var first: String = _capture.gait_drive_fingerprint(a)
	if first.length() != 64:
		return _fail("the fingerprint is not a SHA-256 hex digest: %s" % first)
	if _capture.gait_drive_fingerprint(a.duplicate()) != first:
		return _fail("one trace fingerprinted two ways")
	if _capture.gait_drive_fingerprint([0.5, 1.5, 2.5000001]) == first:
		return _fail("two different traces share a fingerprint")
	return true


## The committed line against a freshly generated world, with the people placed
## exactly where the game places them — and two negative controls so a check
## that could never fail cannot pass here.
func _check_path() -> bool:
	var world := WorldGen.new()
	add_child(world)
	for _i in 3:
		await get_tree().physics_frame
	var people: Array[Vector3] = []
	people.append_array(NpcSpawner.scatter_spots(world, NpcSpawner.SETTLEMENT_COUNT,
		NpcSpawner.RING_INNER, NpcSpawner.RING_OUTER, NpcSpawner.SETTLEMENT_POS_SEED))
	people.append_array(NpcSpawner.scatter_spots(world, NpcSpawner.DRIFTER_COUNT,
		NpcSpawner.DRIFT_INNER, NpcSpawner.DRIFT_OUTER, NpcSpawner.DRIFTER_POS_SEED))
	people.append_array(NpcSpawner.scatter_spots(world, CreatureSpawner.PACK_COUNT,
		CreatureSpawner.WILD_INNER, CreatureSpawner.WILD_OUTER, CreatureSpawner.PACK_POS_SEED))
	var terrain := world.get_node_or_null("TerrainBody") as CollisionObject3D
	if terrain == null:
		return _fail("the generated world has no TerrainBody to exclude from the obstacle sweep")
	var exclude: Array[RID] = [terrain.get_rid()]
	var space := get_viewport().world_3d.direct_space_state
	var problems: Array = _capture.gait_drive_path_problems(world, people, space, exclude)
	if not problems.is_empty():
		return _fail("the committed drive line is not clear: %s" % "; ".join(problems))

	var start: Vector2 = _capture.get_script_constant_map()["DRIVE_START"]
	var heading: Vector2 = _capture.get_script_constant_map()["DRIVE_HEADING"]
	var midway := start + heading * 6.0
	var crowded := people.duplicate()
	crowded.append(Vector3(midway.x, 0.0, midway.y))
	if (_capture.gait_drive_path_problems(world, crowded, space, exclude) as Array).is_empty():
		return _fail("a person standing on the line was not reported")

	var block := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 2.0, 1.0)
	shape.shape = box
	block.add_child(shape)
	add_child(block)
	block.global_position = Vector3(
		midway.x, world.surface_height_at(midway.x, midway.y) + 1.0, midway.y)
	for _i in 2:
		await get_tree().physics_frame
	var blocked: Array = _capture.gait_drive_path_problems(world, people, space, exclude)
	block.free()
	world.free()
	if blocked.is_empty():
		return _fail("a solid block on the line was not reported")
	return true


## CI must run the scenario with both opt-ins, require its own marker, and
## publish the frames and the summary.
func _check_ci() -> bool:
	var ci := FileAccess.get_file_as_string(CI_WORKFLOW_PATH)
	if ci.is_empty():
		return _fail("could not read %s" % CI_WORKFLOW_PATH)
	var at := ci.find("WAR_SCENARIO=gait_drive")
	if at < 0:
		return _fail("CI never runs the gait_drive scenario")
	var step := ci.substr(at, 2400)
	for needle: String in [
		"WAR_WALK_CYCLE=1",
		"WAR_RUN_CYCLE=1",
		"gait drive frames written",
		"BOOT_OK",
	]:
		if not step.contains(needle):
			return _fail("the CI gait_drive step does not carry %s" % needle)
	for needle: String in ["shots/gait-drive/*.png", "shots/gait-drive/*.txt"]:
		if not ci.contains(needle):
			return _fail("CI does not publish %s" % needle)
	return true


## A constructed straight drive along -z. Each step lasts `step_s`; the planted
## foot's ground speed is `(1 - hold)` of the body's, so `hold` 1 is a foot that
## holds its place and 0.5 one that slides at half speed. `float_m` raises the
## planted foot, and `offset_m` shifts the left foot forward so the feet cross
## at uneven intervals, like a body leaning on one leg.
func _synthetic(
		speed: float,
		step_s: float,
		seconds: float,
		hold: float,
		float_m: float,
		offset_m: float) -> Dictionary:
	var body: Array = []
	var foot_l: Array = []
	var foot_r: Array = []
	var lift_l: Array = []
	var lift_r: Array = []
	var stride := speed * step_s
	# Starts 0.03 of a step in so no sample lands exactly on a crossing.
	var t0 := 0.03 * step_s
	var samples := int(seconds / DT)
	for i in samples:
		var t := t0 + float(i) * DT
		var at := HEADING * speed * t
		var u := t / step_s
		var k := int(floor(u))
		var f := u - float(k)
		# +z is behind the body. The planted foot runs front to back, the
		# other back to front, each by `hold` of a full step.
		var planted := hold * stride * (f - 0.5)
		var left_planted := k % 2 == 0
		var rel_l := planted if left_planted else -planted
		var rel_r := -rel_l
		foot_l.append(at + Vector3(-0.1, 0.0, rel_l - offset_m))
		foot_r.append(at + Vector3(0.1, 0.0, rel_r))
		var swing_lift := 0.02 + 0.1 * sin(PI * f)
		lift_l.append(float_m if left_planted else float_m + swing_lift)
		lift_r.append(float_m + swing_lift if left_planted else float_m)
		body.append(at)
	return {"body": body, "foot_l": foot_l, "foot_r": foot_r, "lift_l": lift_l, "lift_r": lift_r}


func _metrics(trace: Dictionary) -> Dictionary:
	return _capture.gait_drive_metrics(
		trace["body"], trace["foot_l"], trace["foot_r"], trace["lift_l"], trace["lift_r"],
		HEADING, DT)


func _has_method(method: String) -> bool:
	for info: Dictionary in _capture.get_script_method_list():
		if String(info["name"]) == method:
			return true
	return false


func _fail(message: String) -> bool:
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false
