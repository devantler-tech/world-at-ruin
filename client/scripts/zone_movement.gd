class_name ZoneMovement
extends RefCounted
## Connection-owned nonvisual movement state. No prediction or physics here.

const INTERVAL_USEC := 33334  # never faster than 30 Hz
const MAX_PENDING := 64
const MAX_OUTBOUND_BYTES := MAX_PENDING * WireCodec.INTENT_FRAME_SIZE
const DEADLINE_USEC := 2000000
const MAX_SEQUENCE := 9223372036854775807

var _sample: Dictionary = {}
var _pending: Array[Dictionary] = []
var _sequence := 0
var _last_send := -INTERVAL_USEC
var _last_clock := -1
var _blocked_since := -1
var _own: Dictionary = {}


func queue(direction: Vector2, sprint: bool) -> bool:
	if not direction.is_finite():
		return false
	# Scaling first avoids float overflow while normalizing huge finite input.
	var largest := maxf(absf(direction.x), absf(direction.y))
	var planar := direction
	if largest > 1.0:
		planar /= largest
	if planar.length_squared() > 1.0:
		planar = planar.normalized()
	# Truncation toward zero keeps the quantized direction inside the circle.
	_sample = {"x": int(planar.x * 1000.0), "z": int(planar.y * 1000.0), "sprint": sprint}
	return true


## Empty result means no fault, including ordinary backpressure. Sequence is
## consumed only once the binary write succeeds. Samples are never replayed.
func pump(transport: Object, now_usec: int) -> Dictionary:
	if now_usec < 0 or now_usec < _last_clock:
		return {}
	_last_clock = now_usec
	if _blocked_since >= 0 and now_usec - _blocked_since >= DEADLINE_USEC:
		return _refuse("movement_deadline", "movement transport deadline expired before recovery")
	if not _pending.is_empty() and now_usec - int(_pending[0]["sent_at"]) >= DEADLINE_USEC:
		return _refuse("movement_deadline", "movement acknowledgement deadline expired")
	if _sample.is_empty() or now_usec - _last_send < INTERVAL_USEC:
		return {}
	var buffered: int = transport.call("get_current_outbound_buffered_amount")
	if buffered < 0 or buffered > MAX_OUTBOUND_BYTES:
		return _refuse("movement_buffer", "transport reports an invalid outbound byte count")
	if _pending.size() >= MAX_PENDING or buffered > MAX_OUTBOUND_BYTES - WireCodec.INTENT_FRAME_SIZE:
		return _blocked(now_usec)
	if _sequence == MAX_SEQUENCE:
		return _refuse("movement_sequence", "movement sequence exhausted; reconnect required")
	var next := _sequence + 1
	var encoded := WireCodec.encode_intent(next, _sample["x"], _sample["z"], _sample["sprint"])
	if not encoded["ok"]:
		return encoded
	var result: int = transport.call("put_packet", encoded["bytes"])
	if result != OK:
		return _refuse("movement_write", "binary movement write failed")
	_sequence = next
	_pending.append({"sequence": next, "sent_at": now_usec})
	_last_send = now_usec
	_blocked_since = -1
	_sample = {}
	return {}


func acknowledge(ack: Dictionary) -> Dictionary:
	var sequence: int = ack["applied_sequence"]
	if sequence > _sequence:
		return _refuse("movement_ack_sequence", "server acknowledged unsent input")
	if not _own.is_empty():
		if sequence < int(_own["applied_sequence"]) or int(ack["tick"]) < int(_own["tick"]):
			return _refuse("movement_ack_order", "own acknowledgement regressed")
		if int(ack["tick"]) == int(_own["tick"]) and ack != _own:
			return _refuse("movement_ack_order", "own state changed at the same completed tick")
	_own = ack.duplicate(true)
	while not _pending.is_empty() and int(_pending[0]["sequence"]) <= sequence:
		_pending.pop_front()
	return {}


func own_state() -> Dictionary:
	return _own.duplicate(true)


func pending_count() -> int:
	return _pending.size()


func _blocked(now_usec: int) -> Dictionary:
	if _blocked_since < 0:
		_blocked_since = now_usec
	if now_usec - _blocked_since >= DEADLINE_USEC:
		return _refuse("movement_deadline", "movement transport remained blocked")
	return {}


static func _refuse(error_class: String, detail: String) -> Dictionary:
	return {"ok": false, "error": error_class, "detail": detail}
