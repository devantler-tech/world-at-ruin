class_name PredictedMovement
extends RefCounted
## Latent isolated-zone speculation. v3 does not attest input receipt timing.
## The caller records only successfully sent input; no transport is owned here.

const MAX_HISTORY := 120
const MAX_PENDING := 64
const MAX_COUNTER := 9223372036854775807
const Ground = preload("res://scripts/ground_step.gd")

var _history_limit: int
var _pending_limit: int
var _spec: Dictionary = {}
var _anchor: Dictionary = {}
var _position: Dictionary = {}
var _tick := 0
var _sequence := 0
var _pending: Array[Dictionary] = []
var _history: Array[Dictionary] = []
var _held := {"x": 0, "y": 0, "z": 0}
var _held_sequence := 0
var _remaining := 0
var _fault := ""


func _init(history_limit: int = MAX_HISTORY, pending_limit: int = MAX_PENDING) -> void:
	_history_limit = history_limit
	_pending_limit = pending_limit


func configure(spec: Dictionary) -> Dictionary:
	if not _spec.is_empty() or not _fault.is_empty():
		return _refuse("prediction_configuration")
	if _history_limit < 1 or _history_limit > MAX_HISTORY or _pending_limit < 1 or _pending_limit > MAX_PENDING:
		return _refuse("prediction_limits")
	var validated := Ground.validate_spec(spec)
	if not validated["ok"]:
		return _refuse(validated["error"])
	_spec = validated["spec"]
	return {"ok": true}


func seed(ack: Dictionary) -> Dictionary:
	if not _fault.is_empty() or _spec.is_empty() or not _anchor.is_empty():
		return _refuse("prediction_seed")
	if not _valid_ack(ack) or ack["applied_sequence"] != 0:
		return _refuse("prediction_seed")
	_anchor = ack.duplicate(true)
	_position = _ack_position(ack)
	_tick = ack["tick"]
	return {"ok": true}


func record_sent(sequence: int, sample: Dictionary) -> Dictionary:
	if not _ready():
		return _refuse("prediction_inactive")
	if _sequence == MAX_COUNTER or sequence != _sequence + 1:
		return _refuse("prediction_sequence")
	if _pending.size() >= _pending_limit:
		return _refuse("prediction_pending")
	var converted := Ground.direction_velocity(sample, _spec)
	if not converted["ok"]:
		return _refuse(converted["error"])
	_sequence = sequence
	_pending.append({"sequence": sequence, "sample": sample.duplicate(true)})
	_held = converted["velocity"]
	_held_sequence = sequence
	_remaining = _spec["hold_ticks"]
	return {"ok": true}


func step_tick() -> Dictionary:
	if not _ready():
		return _refuse("prediction_inactive")
	if _tick == MAX_COUNTER or _history.size() >= _history_limit:
		return _refuse("prediction_history")
	var velocity: Dictionary = _held if _remaining > 0 else {"x": 0, "y": 0, "z": 0}
	var stepped := Ground.step(_position, velocity, _spec)
	if not stepped["ok"]:
		return _refuse(stepped["error"])
	_tick += 1
	_position = stepped["position"]
	_history.append({"tick": _tick, "sequence": _held_sequence if _remaining > 0 else 0,
		"velocity": velocity.duplicate(true)})
	if _remaining > 0:
		_remaining -= 1
	return {"ok": true, "state": state()}


func reconcile(ack: Dictionary) -> Dictionary:
	if not _ready() or not _valid_ack(ack):
		return _refuse("prediction_ack")
	if ack["applied_sequence"] > _sequence or ack["applied_sequence"] < _anchor["applied_sequence"] or ack["tick"] < _anchor["tick"]:
		return _refuse("prediction_ack_order")
	if ack["tick"] == _anchor["tick"] and ack != _anchor:
		return _refuse("prediction_ack_order")
	var future: Array[Dictionary] = []
	for entry: Dictionary in _history:
		if entry["tick"] > ack["tick"]:
			future.append(entry)
	if ack["tick"] < _tick and (future.is_empty() or future[0]["tick"] != ack["tick"] + 1):
		return _refuse("prediction_replay_gap")
	var replayed := _ack_position(ack)
	var completed: int = ack["tick"]
	for entry: Dictionary in future:
		if completed == MAX_COUNTER or entry["tick"] != completed + 1:
			return _refuse("prediction_replay_gap")
		var stepped := Ground.step(replayed, entry["velocity"], _spec)
		if not stepped["ok"]:
			return _refuse(stepped["error"])
		replayed = stepped["position"]
		completed = entry["tick"]
	var correction := {"x": replayed["x"] - _position["x"],
		"y": replayed["y"] - _position["y"], "z": replayed["z"] - _position["z"]}
	# No partial mutation precedes the complete validation and replay above.
	if ack["tick"] > _tick:
		# A catch-up supplies position, not the remaining server hold phase.
		_remaining = 0
		_held_sequence = 0
		_held = {"x": 0, "y": 0, "z": 0}
	_anchor = ack.duplicate(true)
	_position = replayed
	_tick = completed
	_history = future
	while not _pending.is_empty() and _pending[0]["sequence"] <= ack["applied_sequence"]:
		_pending.pop_front()
	return {"ok": true, "state": state(), "correction": correction}


func reset() -> void:
	_anchor = {}
	_position = {}
	_tick = 0
	_sequence = 0
	_pending.clear()
	_history.clear()
	_held = {"x": 0, "y": 0, "z": 0}
	_held_sequence = 0
	_remaining = 0
	_fault = ""


func state() -> Dictionary:
	if _anchor.is_empty():
		return {}
	return {"tick": _tick, "applied_sequence": _anchor["applied_sequence"],
		"x": _position["x"], "y": _position["y"], "z": _position["z"]}


func history() -> Array[Dictionary]:
	return _history.duplicate(true)


func history_count() -> int:
	return _history.size()


func pending_count() -> int:
	return _pending.size()


func fault() -> String:
	return _fault


func _ready() -> bool:
	return _fault.is_empty() and not _anchor.is_empty()


func _valid_ack(ack: Dictionary) -> bool:
	if ack.size() != 5 or not ack.has_all(["applied_sequence", "tick", "x", "y", "z"]):
		return false
	for key: String in ack:
		if typeof(ack[key]) != TYPE_INT:
			return false
	return ack["applied_sequence"] >= 0 and ack["tick"] >= 0 and Ground.valid_position(_ack_position(ack), _spec)


static func _ack_position(ack: Dictionary) -> Dictionary:
	return {"x": ack["x"], "y": ack["y"], "z": ack["z"]}


func _refuse(error_class: String) -> Dictionary:
	if _fault.is_empty():
		_fault = error_class
	return {"ok": false, "error": _fault}
