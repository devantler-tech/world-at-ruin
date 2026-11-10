class_name PredictedBody
extends RefCounted
## The player's planar position under WAR_PREDICTED_MOVEMENT (#812).
##
## Composes the latent `PredictedMovement` into something a body can follow:
## fixed 30 Hz ticks from a frame-time accumulator, interpolation between the
## two newest predicted ticks, and reconciliation corrections presented as a
## visual offset that decays to zero over `CORRECTION_DECAY_SEC`. A correction
## larger than the capsule radius snaps instead. Nonvisual and transport-free:
## the caller hands in the newest own ACK and the samples the transport wrote,
## and the player owns everything vertical, including the render-only hop
## (#814). Any predictor refusal latches `fault()` and the caller stops using
## the body; nothing here guesses past a refusal.

## Requires WAR_ZONE_MOVEMENT=1 too: prediction has nothing to predict on v2.
const ENV := "WAR_PREDICTED_MOVEMENT"
const MOVEMENT_ENV := "WAR_ZONE_MOVEMENT"
const STEP_SEC := 1.0 / GroundStep.TICK_HZ
const CORRECTION_DECAY_SEC := 0.1
## The player's capsule radius (player.gd), in millimetres.
const SNAP_MM := 400
const MM_PER_M := 1000.0
## A long hitch steps at most this many ticks in one frame; the next ACK catches
## the prediction up instead of replaying a backlog the player never saw.
const MAX_STEPS_PER_FRAME := 6
## Run-ahead (#1461): the prediction leads each ACK's tick by the measured
## round trip less the tick the zone spends applying an intent, so the zone
## applies each intent at about the tick the client predicted it. Half the
## 120-tick replay window keeps room for the ticks stepped between ACKs.
const MAX_LEAD_TICKS := 60
## Margin before an over-long lead is pulled back, so one tick of round-trip
## jitter does not renumber the history on every ACK.
const LEAD_SLACK := 1
## Fixture configuration (ADR 0026): wire v3 does not carry a zone's movement
## facts, so these mirror the demo zone — `sim.DemoBounds`, the demo actor's
## 4 m/s cap and `zone -movement-hold-ticks`' default of 3. Carrying them on the
## wire belongs with platform serving (#569).
const DEMO_ZONE_SPEC := {
	"max_speed_mm_s": 4000,
	"min_x": -20000, "min_y": 0, "min_z": -20000,
	"max_x": 20000, "max_y": 4000, "max_z": 20000,
	"hold_ticks": 3,
	"collision_mode": "isolated_flat",
}

var _predictor := PredictedMovement.new()
var _configured := false
var _seeded := false
var _last_ack: Dictionary = {}
var _accumulator := 0.0
var _previous := Vector3.ZERO
var _current := Vector3.ZERO
var _offset_start := Vector3.ZERO
var _offset_age := CORRECTION_DECAY_SEC
var _snaps := 0
var _last_correction := Vector3.ZERO
## Local send clock: seconds of frame time since the body was created or reset.
var _clock := 0.0
## Sent sequence -> `_clock` when it was written, until an ACK applies it.
var _sent_at: Dictionary = {}
var _applied := 0
var _round_trip := -1
var _fault := ""


static func is_enabled() -> bool:
	return OS.get_environment(ENV) == "1" and OS.get_environment(MOVEMENT_ENV) == "1"


func configure(spec: Dictionary = DEMO_ZONE_SPEC) -> bool:
	var result := _predictor.configure(spec)
	if not result["ok"]:
		return _refuse(result)
	_configured = true
	return true


## True once the first own ACK has anchored the prediction and nothing refused.
## Producing input before this would send sequences the predictor never saw.
func is_active() -> bool:
	return _seeded and _fault.is_empty()


## One rendered frame, in the order the connection's poll produced them: the
## newest own ACK (folded before sending), then the samples just written, then
## `delta` seconds of fixed ticks.
func advance(ack: Dictionary, sent: Array[Dictionary], delta: float) -> void:
	if not _fault.is_empty() or not _configured:
		return
	if not ack.is_empty() and ack != _last_ack:
		if not _fold(ack):
			return
	if not _seeded:
		if not sent.is_empty():
			_refuse({"error": "prediction_unseeded_send"})
		return
	for entry: Dictionary in sent:
		var recorded := _predictor.record_sent(entry["sequence"], entry["sample"])
		if not recorded["ok"]:
			_refuse(recorded)
			return
		_sent_at[entry["sequence"]] = _clock
	_clock += maxf(delta, 0.0)
	_accumulator += maxf(delta, 0.0)
	var steps := 0
	while _accumulator >= STEP_SEC:
		if steps == MAX_STEPS_PER_FRAME:
			_accumulator = fmod(_accumulator, STEP_SEC)
			break
		if _predictor.history_count() >= PredictedMovement.MAX_HISTORY:
			# The zone has been silent for the whole replay window. Hold the
			# prediction where it is; the next ACK catches it up, while stepping
			# on would latch a history refusal for the rest of the connection.
			_accumulator = minf(_accumulator, STEP_SEC)
			break
		var stepped := _predictor.step_tick()
		if not stepped["ok"]:
			_refuse(stepped)
			return
		_previous = _current
		_current = _metres(stepped["state"])
		_accumulator -= STEP_SEC
		steps += 1
	_offset_age = minf(_offset_age + maxf(delta, 0.0), CORRECTION_DECAY_SEC)


## Where the body is drawn this frame: between the two newest predicted ticks,
## plus whatever is left of the last correction's offset.
func display_position() -> Vector3:
	return interpolated_position() + correction_offset()


## The fixed-tick position at the display rate, without the correction offset.
func interpolated_position() -> Vector3:
	return _previous.lerp(_current, clampf(_accumulator / STEP_SEC, 0.0, 1.0))


func correction_offset() -> Vector3:
	return _offset_start * (1.0 - _offset_age / CORRECTION_DECAY_SEC)


## The newest predicted tick, metres.
func predicted_position() -> Vector3:
	return _current


## Planar travel over the newest tick, metres per second (X, Z).
func planar_velocity() -> Vector2:
	var moved := _current - _previous
	return Vector2(moved.x, moved.z) / STEP_SEC


func snap_count() -> int:
	return _snaps


## The newest ACK's change to the predicted tick, metres: the replay
## correction plus any ticks stepped or dropped to realign the lead.
func last_correction() -> Vector3:
	return _last_correction


## The newest measured round trip in fixed ticks, or -1 before one is measured.
func round_trip_ticks() -> int:
	return _round_trip


## Ticks the prediction currently runs past the newest ACK.
func lead_ticks() -> int:
	return _predictor.lead()


func fault() -> String:
	return _fault


## Forget the connection-scoped prediction; a reconnect seeds afresh.
func reset() -> void:
	_predictor.reset()
	_seeded = false
	_last_ack = {}
	_accumulator = 0.0
	_offset_start = Vector3.ZERO
	_offset_age = CORRECTION_DECAY_SEC
	_last_correction = Vector3.ZERO
	_clock = 0.0
	_sent_at.clear()
	_applied = 0
	_round_trip = -1
	_fault = ""


func _fold(ack: Dictionary) -> bool:
	if not _seeded:
		var seeded := _predictor.seed(ack)
		if not seeded["ok"]:
			return _refuse(seeded)
		_seeded = true
		_last_ack = ack.duplicate(true)
		_current = _metres(_predictor.state())
		_previous = _current
		return true
	var before := _predictor.state()
	var reconciled := _predictor.reconcile(ack)
	if not reconciled["ok"]:
		return _refuse(reconciled)
	_measure_round_trip(ack["applied_sequence"])
	var aligned := _align_lead()
	if not aligned["ok"]:
		return _refuse(aligned)
	_last_ack = ack.duplicate(true)
	var after := _predictor.state()
	var correction := {"x": after["x"] - before["x"], "y": after["y"] - before["y"], "z": after["z"] - before["z"]}
	var shift := Vector3(correction["x"], correction["y"], correction["z"]) / MM_PER_M
	_last_correction = shift
	# The tick pair moves with the prediction, so interpolation stays between
	# two predicted ticks of the same history.
	_previous += shift
	_current = _metres(after)
	# Keep the body where it was drawn and let the difference decay — unless
	# this correction, or the drawn error it adds to, is wider than the body.
	var drawn_error := correction_offset() - shift
	var planar_mm := Vector2(correction["x"], correction["z"]).length()
	if planar_mm > SNAP_MM or Vector2(drawn_error.x, drawn_error.z).length() * MM_PER_M > SNAP_MM:
		_snaps += 1
		_offset_start = Vector3.ZERO
		_offset_age = CORRECTION_DECAY_SEC
	elif shift != Vector3.ZERO:
		_offset_start = drawn_error
		_offset_age = 0.0
	return true


## The round trip of the newest sequence an ACK newly applied, against the
## frame time it was written at.
func _measure_round_trip(applied: int) -> void:
	if applied <= _applied:
		return
	_applied = applied
	if _sent_at.has(applied):
		_round_trip = roundi((_clock - float(_sent_at[applied])) / STEP_SEC)
	for sequence: int in _sent_at.keys():
		if sequence <= applied:
			_sent_at.erase(sequence)


## Keep the prediction ahead of the newest ACK by the round trip, so the zone
## applies each intent at about the tick it was predicted at. Both directions:
## after a catch-up the lead is run back up, and after a zone stall dropped
## ticks the numbering falls back to the zone's, so a stop is not overshot.
func _align_lead() -> Dictionary:
	if _round_trip < 0:
		return {"ok": true}
	var target := clampi(_round_trip - 1, 0, MAX_LEAD_TICKS)
	var lead := _predictor.lead()
	if lead < target or lead > target + LEAD_SLACK:
		return _predictor.realign(target)
	return {"ok": true}


static func _metres(state: Dictionary) -> Vector3:
	return Vector3(state["x"], state["y"], state["z"]) / MM_PER_M


func _refuse(result: Dictionary) -> bool:
	if _fault.is_empty():
		_fault = str(result.get("error", "prediction_refused"))
	return false
