extends Node
## Rewind/replay uses speculative ticks, never sequence-as-tick arithmetic.

var _failed := false
var _type: Script
const SPEC := {"max_speed_mm_s": 4000, "min_x": -20000, "min_y": 0, "min_z": -20000,
	"max_x": 20000, "max_y": 4000, "max_z": 20000, "hold_ticks": 2,
	"collision_mode": "isolated_flat"}
const RIGHT := {"x": 1000, "z": 0, "sprint": true}


func _ready() -> void:
	if not _check(FileAccess.file_exists("res://scripts/predicted_movement.gd"), "bounded movement predictor is missing"):
		get_tree().quit(1)
		return
	_type = load("res://scripts/predicted_movement.gd")
	if not _check(_type != null and _type.can_instantiate(), "prediction script is invalid"):
		get_tree().quit(1)
		return
	_test_configuration()
	_test_hold_and_replay()
	_test_ownership()
	_test_correction()
	_test_refusals()
	_test_limits_and_reset()
	if not _failed:
		print("TEST PASS: bounded tick history, sent ownership, reconciliation and reset")
	get_tree().quit(1 if _failed else 0)


func _ack(sequence: int, tick: int, x: int = 0, y: int = 147, z: int = 0) -> Dictionary:
	return {"applied_sequence": sequence, "tick": tick, "x": x, "y": y, "z": z}


func _new(history_limit: int = 120, pending_limit: int = 64) -> Object:
	var predictor: Object = _type.new(history_limit, pending_limit)
	_check(predictor.configure(SPEC)["ok"] and predictor.seed(_ack(0, 10))["ok"], "fresh predictor refused")
	return predictor


func _test_configuration() -> void:
	var predictor: Object = _type.new()
	_check(not predictor.seed(_ack(0, 10))["ok"], "prediction seeded without configuration")
	predictor.reset()
	var input := SPEC.duplicate(true)
	_check(predictor.configure(input)["ok"], "valid predictor spec refused")
	input["max_speed_mm_s"] = 1
	_check(predictor.seed(_ack(0, 10))["ok"] and predictor.record_sent(1, RIGHT)["ok"], "configured prediction refused")
	predictor.step_tick()
	_check(predictor.state()["x"] == 133, "predictor configuration aliases input")
	_check(not predictor.configure(SPEC)["ok"], "live configuration changed")
	predictor.reset()
	_check(predictor.seed(_ack(0, 0))["ok"], "reset lost validated configuration")
	_check(not predictor.seed(_ack(0, 1))["ok"], "active seed replaced anchor")


func _test_hold_and_replay() -> void:
	var predictor := _new()
	_check(predictor.record_sent(1, RIGHT)["ok"], "successful send not recorded")
	predictor.step_tick()
	predictor.step_tick()
	predictor.step_tick()
	_check(predictor.state()["tick"] == 13 and predictor.state()["x"] == 266, "held input did not expire after two ticks")
	_check(predictor.history_count() == 3 and predictor.pending_count() == 1, "tick history conflated with sequence")
	var result: Dictionary = predictor.reconcile(_ack(1, 11, 133))
	_check(result["ok"] and result["correction"] == {"x": 0, "y": 0, "z": 0}, "zero correction moved prediction")
	_check(predictor.state()["x"] == 266 and predictor.history_count() == 2, "ACK discarded its later held tick")
	_check(predictor.pending_count() == 0, "ACK did not retire sent ownership")
	predictor.step_tick()
	_check(predictor.state()["x"] == 266, "ACK resurrected expired held input")
	var state: Dictionary = predictor.state()
	state["x"] = 999
	_check(predictor.state()["x"] == 266, "state read aliases authority")
	var history: Array = predictor.history()
	history[0]["velocity"]["x"] = 999
	_check(predictor.history()[0]["velocity"]["x"] == 4000, "history read aliases replay input")


func _test_ownership() -> void:
	var predictor := _new()
	for sequence: int in [1, 2, 3]:
		_check(predictor.record_sent(sequence, RIGHT)["ok"], "consecutive sent ownership refused")
	predictor.step_tick()
	_check(predictor.history_count() == 1 and predictor.pending_count() == 3, "three sends were treated as three ticks")
	_check(predictor.reconcile(_ack(3, 11, 133))["ok"] and predictor.pending_count() == 0, "cumulative ACK did not retire sends")
	_check(predictor.record_sent(4, RIGHT)["ok"], "retirement reused sequence")


func _test_correction() -> void:
	var predictor := _new()
	predictor.record_sent(1, RIGHT)
	predictor.step_tick()
	predictor.step_tick()
	var result: Dictionary = predictor.reconcile(_ack(1, 11, -1000))
	_check(result["ok"] and result["correction"] == {"x": -1133, "y": 0, "z": 0}, "forced correction lost exact delta")
	_check(predictor.state()["x"] == -867 and predictor.state()["tick"] == 12, "rewind did not replay future held tick")
	_check(predictor.reconcile(_ack(1, 11, -1000))["ok"], "identical ACK refused")
	_check(predictor.reconcile(_ack(1, 20, 400))["ok"] and predictor.history_count() == 0 and predictor.state()["tick"] == 20, "authoritative catch-up fabricated history")
	predictor.step_tick()
	_check(predictor.state()["x"] == 400, "catch-up guessed unknown held phase")
	var active_hold := _new()
	_check(active_hold.record_sent(1, RIGHT)["ok"], "active hold send refused")
	_check(active_hold.step_tick()["ok"] and active_hold.state()["x"] == 133, "active hold tick refused")
	_check(active_hold.reconcile(_ack(1, 12, 400))["ok"], "active hold catch-up refused")
	_check(active_hold.history_count() == 0 and active_hold.pending_count() == 0, "catch-up retained past history or ownership")
	_check(active_hold.step_tick()["ok"] and active_hold.state()["x"] == 400, "catch-up retained unknown active hold")
	_check(active_hold.record_sent(2, RIGHT)["ok"], "fresh send after catch-up refused")
	_check(active_hold.step_tick()["ok"] and active_hold.state()["x"] == 533, "catch-up discarded fresh held input")


func _test_refusals() -> void:
	for ack: Dictionary in [_ack(2, 11), _ack(0, 9), _ack(-1, 11), _ack(0, -1),
		_ack(0, 11, 20001), {"applied_sequence": 0, "tick": 11, "x": 0.0, "y": 147, "z": 0},
		{"applied_sequence": 0, "tick": 11, "x": 0, "y": 147},
		{"applied_sequence": 0, "tick": 11, "x": 0, "y": 147, "z": 0, "extra": 1}]:
		var predictor := _new()
		predictor.record_sent(1, RIGHT)
		predictor.step_tick()
		var before: Dictionary = predictor.state()
		_check(not predictor.reconcile(ack)["ok"] and predictor.state() == before, "bad ACK mutated prediction")
		_check(not predictor.step_tick()["ok"] and not predictor.fault().is_empty(), "refusal did not fence prediction")
	var same := _new()
	_check(not same.reconcile(_ack(0, 10, 1))["ok"], "same-tick changed anchor admitted")
	var regressed := _new()
	regressed.record_sent(1, RIGHT)
	regressed.reconcile(_ack(1, 11, 133))
	_check(not regressed.reconcile(_ack(0, 12, 133))["ok"], "applied sequence regressed")
	var old := _new()
	old.step_tick()
	old.reconcile(_ack(0, 11))
	old.step_tick()
	_check(not old.reconcile(_ack(0, 10))["ok"], "lost replay window accepted")
	for sequence: int in [0, 2, -1]:
		var malformed := _new()
		_check(not malformed.record_sent(sequence, RIGHT)["ok"] and malformed.pending_count() == 0, "nonconsecutive sent sequence admitted")


func _test_limits_and_reset() -> void:
	var history := _new(2, 2)
	history.record_sent(1, RIGHT)
	history.step_tick()
	history.step_tick()
	var before: Dictionary = history.state()
	_check(not history.step_tick()["ok"] and history.history_count() == 2 and history.state() == before, "history overflow silently evicted replay")
	history.reset()
	_check(history.state().is_empty() and history.history_count() == 0 and history.pending_count() == 0 and history.fault().is_empty(), "reset inherited old prediction")
	history.seed(_ack(0, 100))
	history.step_tick()
	_check(history.state()["x"] == 0, "reconnect inherited held movement")
	var pending := _new(2, 2)
	pending.record_sent(1, RIGHT)
	pending.record_sent(2, RIGHT)
	_check(not pending.record_sent(3, RIGHT)["ok"] and pending.pending_count() == 2, "pending ownership overflowed")
	var maximum: Object = _type.new()
	maximum.configure(SPEC)
	maximum.seed(_ack(0, 9223372036854775807))
	_check(not maximum.step_tick()["ok"] and maximum.state()["tick"] == 9223372036854775807, "tick overflow wrapped")
	var invalid: Object = _type.new(121, 65)
	_check(not invalid.configure(SPEC)["ok"], "caller widened history bounds")


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
	return condition
