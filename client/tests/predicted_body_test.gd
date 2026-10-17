extends Node
## #812: the player's planar body under WAR_PREDICTED_MOVEMENT, over the
## scripted transport fake — switch gating, the written-sample log, zero /
## decaying / snapping corrections, display-rate interpolation and the
## render-only hop (#814). Flag-off behaviour is pinned by the unchanged
## locomotion and capture suites; this suite proves an inactive prediction
## leaves the local physics in charge.

const Movement = preload("res://tests/zone_movement_test.gd")
const URL := "wss://zone.example/zone"
const ENVS := [PredictedBody.ENV, PredictedBody.MOVEMENT_ENV, "WAR_ZONE_TOKEN", "WAR_ZONE_TLS_SERVER_NAME"]
const STEP := PredictedBody.STEP_SEC
# One sprinting tick at the demo zone's 4 m/s cap: 4000 / 30, truncated.
const TICK_MM := 133
var _failed := false
var _helper := Movement.new()


func _ready() -> void:
	var env := TestEnvironment.snapshot(ENVS)
	OS.set_environment("WAR_ZONE_TOKEN", "fixture-token")
	OS.unset_environment("WAR_ZONE_TLS_SERVER_NAME")
	_test_switch()
	OS.set_environment(PredictedBody.MOVEMENT_ENV, "1")
	OS.set_environment(PredictedBody.ENV, "1")
	_test_sent_log()
	_test_corrections()
	_test_refusals()
	_test_silence_hitch_and_drawn_error()
	_test_hop_leaves_planar_prediction()
	_test_inactive_prediction_keeps_local_physics()
	TestEnvironment.restore(env)
	_helper.free()
	if not _failed:
		print("TEST PASS predicted_body")
		get_tree().quit(0)


func _test_switch() -> void:
	OS.unset_environment(PredictedBody.ENV)
	OS.unset_environment(PredictedBody.MOVEMENT_ENV)
	_check(not PredictedBody.is_enabled(), "prediction on by default")
	OS.set_environment(PredictedBody.ENV, "1")
	_check(not PredictedBody.is_enabled(), "prediction enabled without the v3 movement switch")
	OS.set_environment(PredictedBody.MOVEMENT_ENV, "1")
	_check(PredictedBody.is_enabled(), "both switches did not enable prediction")
	OS.set_environment(PredictedBody.ENV, "true")
	_check(not PredictedBody.is_enabled(), "a non-1 value enabled prediction")


func _test_sent_log() -> void:
	# The bare sender, not the connection: a failed write also fails the
	# connection, which discards its sender, so only this proves the log itself
	# records nothing the transport refused (ADR 0026).
	var refusing: Movement.Transport = Movement.Transport.new()
	refusing.write_result = FAILED
	var sender := ZoneMovement.new()
	sender.queue(Vector2.RIGHT, true)
	var refused := sender.pump(refusing, 0)
	_check(refused.get("error") == "movement_write" and sender.take_sent().is_empty(), "a failed write was logged as sent")
	var accepting: Movement.Transport = Movement.Transport.new()
	var written := ZoneMovement.new()
	written.queue(Vector2.RIGHT, true)
	written.pump(accepting, 0)
	_check(written.take_sent().size() == 1, "a successful write was not logged")
	var transport: Movement.Transport = Movement.Transport.new()
	var connection := _live(transport)
	connection.queue_movement(Vector2.RIGHT, true)
	connection.poll(0)
	var sent := connection.take_sent_movement()
	_check(sent.size() == 1 and sent[0] == {"sequence": 1, "sample": {"x": 1000, "z": 0, "sprint": true}},
		"written sample log differs: %s" % [sent])
	_check(connection.take_sent_movement().is_empty(), "taking the log did not empty it")
	var movement := ZoneMovement.new()
	var bulk: Movement.Transport = Movement.Transport.new()
	for index: int in range(ZoneMovement.MAX_PENDING + 2):
		movement.queue(Vector2.LEFT, false)
		movement.pump(bulk, index * ZoneMovement.INTERVAL_USEC)
		movement.acknowledge({"applied_sequence": index + 1, "tick": index + 1, "x": 0, "y": 0, "z": 0})
	var bounded := movement.take_sent()
	_check(bounded.size() == ZoneMovement.MAX_PENDING and bounded[0]["sequence"] == 3,
		"untaken sent log is unbounded or kept the wrong end")


func _test_corrections() -> void:
	var transport: Movement.Transport = Movement.Transport.new()
	var connection := _live(transport)
	var body := PredictedBody.new()
	_check(body.configure(), "demo zone specification refused")
	_check(not body.is_active(), "prediction active before an own ACK")
	transport.packets.append(_ack(0, 1, 0))
	connection.poll(0)
	body.advance(connection.movement_state(), connection.take_sent_movement(), 0.0)
	_check(body.is_active() and body.display_position() == Vector3.ZERO, "first own ACK did not anchor the body")

	# One sprinting intent, written, then one fixed tick.
	connection.queue_movement(Vector2.RIGHT, true)
	connection.poll(0)
	body.advance(connection.movement_state(), connection.take_sent_movement(), STEP)
	_check(_mm(body.predicted_position().x) == TICK_MM, "one tick did not move by the integer step")

	# Zero correction: the authoritative tick agrees, so nothing on screen moves.
	var before := body.display_position()
	transport.packets.append(_ack(1, 2, TICK_MM))
	connection.poll(40000)
	body.advance(connection.movement_state(), connection.take_sent_movement(), 0.0)
	_check(body.display_position().is_equal_approx(before) and body.correction_offset() == Vector3.ZERO and body.snap_count() == 0,
		"zero correction moved the drawn body")

	# Display-rate interpolation stays between the two newest predicted ticks.
	body.advance(connection.movement_state(), [], STEP)
	var low := minf(body.predicted_position().x - body.planar_velocity().x * STEP, body.predicted_position().x)
	var high := maxf(body.predicted_position().x - body.planar_velocity().x * STEP, body.predicted_position().x)
	body.advance(connection.movement_state(), [], STEP * 0.5)
	var drawn := body.interpolated_position().x
	_check(drawn >= low - 0.000001 and drawn <= high + 0.000001 and not is_equal_approx(drawn, high),
		"interpolated position %f left the newest tick pair [%f, %f]" % [drawn, low, high])

	# A small correction keeps the drawn body in place, then decays to zero.
	var predicted_tick: int = _mm(body.predicted_position().x)
	before = body.display_position()
	transport.packets.append(_ack(1, 3, predicted_tick - 50))
	connection.poll(80000)
	body.advance(connection.movement_state(), connection.take_sent_movement(), 0.0)
	_check(body.display_position().is_equal_approx(before) and body.snap_count() == 0,
		"small correction jumped the drawn body")
	_check(is_equal_approx(body.correction_offset().x, 0.05), "small correction offset %f" % body.correction_offset().x)
	body.advance(connection.movement_state(), [], 0.05)
	_check(is_equal_approx(body.correction_offset().x, 0.025), "correction did not decay linearly")
	body.advance(connection.movement_state(), [], 0.05)
	_check(body.correction_offset() == Vector3.ZERO, "correction outlived 100 ms")

	# Larger than the capsule radius: one-frame snap, no lingering offset.
	var settled: int = _mm(body.predicted_position().x)
	var tick: int = connection.movement_state()["tick"] + 1
	transport.packets.append(_ack(1, tick, settled + 1000))
	connection.poll(120000)
	body.advance(connection.movement_state(), connection.take_sent_movement(), 0.0)
	_check(body.snap_count() == 1 and body.correction_offset() == Vector3.ZERO, "large correction did not snap")
	_check(_mm(body.display_position().x) >= settled + 1000 - TICK_MM, "snap did not move the drawn body")
	_check(body.fault().is_empty(), "correction path refused: %s" % body.fault())


func _test_refusals() -> void:
	var early := PredictedBody.new()
	early.configure()
	early.advance({}, [{"sequence": 1, "sample": {"x": 0, "z": 0, "sprint": false}}], STEP)
	_check(not early.is_active() and early.fault() == "prediction_unseeded_send", "a send before anchoring was accepted")
	var late := PredictedBody.new()
	late.configure()
	late.advance({"applied_sequence": 4, "tick": 9, "x": 0, "y": 0, "z": 0}, [], STEP)
	_check(not late.is_active() and not late.fault().is_empty(), "a mid-stream ACK anchored the prediction")
	var outside := PredictedBody.new()
	_check(not outside.configure({}), "an empty specification was accepted")
	var reset := PredictedBody.new()
	reset.configure()
	reset.advance({"applied_sequence": 0, "tick": 1, "x": 0, "y": 0, "z": 0}, [], 0.0)
	reset.reset()
	_check(not reset.is_active(), "reset kept the anchor")
	reset.advance({"applied_sequence": 0, "tick": 7, "x": 5, "y": 0, "z": 0}, [], 0.0)
	_check(reset.is_active() and _mm(reset.predicted_position().x) == 5, "reset could not re-anchor")


## Long ACK silence holds the prediction instead of latching a refusal; a hitch
## steps a bounded number of ticks; small corrections that pile up past the
## capsule radius snap like one large correction.
func _test_silence_hitch_and_drawn_error() -> void:
	var quiet := PredictedBody.new()
	quiet.configure()
	quiet.advance(_own(0, 1, 0), [], 0.0)
	var predictor: PredictedMovement = quiet.get("_predictor")
	quiet.advance(_own(0, 1, 0), [], 1.0)
	_check(predictor.state()["tick"] == 1 + PredictedBody.MAX_STEPS_PER_FRAME, "a hitch stepped an unbounded backlog")
	for _frame: int in range(80):
		quiet.advance(_own(0, 1, 0), [], 0.1)
	_check(quiet.is_active() and quiet.fault().is_empty() and predictor.history_count() == PredictedMovement.MAX_HISTORY,
		"eight silent seconds latched a refusal: '%s'" % quiet.fault())
	quiet.advance(_own(0, 400, 500), [], 0.0)
	_check(quiet.is_active() and _mm(quiet.predicted_position().x) == 500 and predictor.state()["tick"] >= 400,
		"the first ACK after silence did not catch the prediction up: %s %s" % [quiet.fault(), predictor.state()])

	var drifting := PredictedBody.new()
	drifting.configure()
	drifting.advance(_own(0, 1, 0), [], 0.0)
	drifting.advance(_own(0, 1, 0), [{"sequence": 1, "sample": {"x": 1000, "z": 0, "sprint": true}}], STEP * 4)
	var at := _mm(drifting.predicted_position().x)
	drifting.advance(_own(1, 5, at - 150), [], 0.0)
	drifting.advance(_own(1, 6, at - 300), [], 0.0)
	_check(drifting.snap_count() == 0 and is_equal_approx(drifting.correction_offset().x, 0.3), "two small corrections did not add up")
	drifting.advance(_own(1, 7, at - 450), [], 0.0)
	_check(drifting.snap_count() == 1 and drifting.correction_offset() == Vector3.ZERO,
		"a drawn error wider than the body did not snap")


static func _own(sequence: int, tick: int, x: int) -> Dictionary:
	return {"applied_sequence": sequence, "tick": tick, "x": x, "y": 0, "z": 0}


## A hop in the middle of a correction leaves the planar result identical (#814).
func _test_hop_leaves_planar_prediction() -> void:
	var plain := _player_run(false)
	var hopping := _player_run(true)
	_check(plain["predicted"] == hopping["predicted"], "a hop changed the reconciled prediction")
	_check(is_equal_approx(plain["drawn"].x, hopping["drawn"].x) and is_equal_approx(plain["drawn"].z, hopping["drawn"].z),
		"a hop moved the drawn planar position")
	_check(hopping["drawn"].y > plain["drawn"].y + 0.1, "the hop did not lift the drawn body")


func _player_run(hop: bool) -> Dictionary:
	var player := Player.new()
	add_child(player)
	player.set_physics_process(false)
	player.ground_height_provider = func(_x: float, _z: float) -> float: return 0.0
	var body := PredictedBody.new()
	body.configure()
	player.predicted = body
	var sample := {"x": 1000, "z": 0, "sprint": true}
	body.advance({"applied_sequence": 0, "tick": 1, "x": 0, "y": 0, "z": 0}, [], 0.0)
	body.advance({"applied_sequence": 0, "tick": 1, "x": 0, "y": 0, "z": 0}, [{"sequence": 1, "sample": sample}], STEP * 2)
	# A correction below the capsule radius is mid-decay when the hop starts.
	body.advance({"applied_sequence": 1, "tick": 2, "x": TICK_MM - 60, "y": 0, "z": 0}, [], STEP * 0.5)
	if hop:
		player.start_hop()
	for _frame: int in range(4):
		player.call("_predicted_physics", 1.0 / 60.0)
		body.advance({"applied_sequence": 1, "tick": 2, "x": TICK_MM - 60, "y": 0, "z": 0}, [], 1.0 / 60.0)
	player.apply_predicted()
	var result := {"predicted": body.predicted_position(), "drawn": player.global_position}
	player.free()
	return result


func _test_inactive_prediction_keeps_local_physics() -> void:
	var player := Player.new()
	add_child(player)
	player.set_physics_process(false)
	var body := PredictedBody.new()
	body.configure()
	player.predicted = body
	player.global_position = Vector3(3, 2, 1)
	_check(not player.is_predicted(), "an unanchored prediction claimed the body")
	player.apply_predicted()
	_check(player.global_position == Vector3(3, 2, 1), "an inactive prediction moved the body")
	player.predicted = null
	_check(not player.is_predicted() and player.planar_intent() == Vector2.ZERO, "flag-off player reports prediction or input")
	player.free()


func _live(transport: Movement.Transport) -> ZoneConnection:
	var connection := ZoneConnection.new(transport)
	connection.connect_to(URL)
	transport.packets.append(_helper._join())
	connection.poll(0)
	return connection


func _ack(sequence: int, tick: int, x: int) -> PackedByteArray:
	return _helper._ack(sequence, tick, x)


static func _mm(metres: float) -> int:
	return roundi(metres * PredictedBody.MM_PER_M)


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
		get_tree().quit(1)
	return condition
