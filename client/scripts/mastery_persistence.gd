class_name MasteryPersistence
extends RefCounted
## Saves each complete ledger transition before returning to play. Transient
## failures coalesce to the latest snapshot and retry without replaying awards.
## A competing mastery writer stops this owner's writes for the session: an
## economic snapshot cannot be rebased safely by max/union or blind replacement.

signal saving_failed(conflict: bool)

const RETRY_INITIAL_SECONDS := 1.0
const RETRY_MAX_SECONDS := 30.0

var _ledger: Mastery
var _expected: Variant
var _pending := false
var _stopped := false
var _retry_in := 0.0
var _retry_delay := RETRY_INITIAL_SECONDS
var _warning_shown := false


func _init(ledger: Mastery, expected: Variant) -> void:
	_ledger = ledger
	_expected = expected.duplicate(true) if expected is Dictionary else null
	_ledger.changed.connect(_changed)


func tick(delta: float) -> void:
	if not _pending or _stopped:
		return
	_retry_in = maxf(0.0, _retry_in - maxf(0.0, delta))
	if _retry_in == 0.0:
		_flush()


## One final attempt on a clean exit. Abrupt termination relies on the writes
## already completed synchronously by each mutation, never on this callback.
func flush() -> void:
	if _pending and not _stopped:
		_flush()


func _changed() -> void:
	if _stopped:
		return
	_pending = true
	# Further awards during a refusal must not bypass its backoff. The latest
	# snapshot includes them all when the next scheduled attempt can run.
	if _retry_in == 0.0:
		_flush()


func _flush() -> void:
	var snapshot := _ledger.snapshot()
	var result := SaveVault.persist_mastery(snapshot, _expected)
	if result == OK:
		_expected = snapshot
		_pending = false
		_retry_in = 0.0
		_retry_delay = RETRY_INITIAL_SECONDS
		return
	if result == ERR_BUSY:
		_retry_in = _retry_delay
		_retry_delay = minf(_retry_delay * 2.0, RETRY_MAX_SECONDS)
	else:
		_stopped = true
		_pending = false
	# A later conflict changes the recovery action: the player must reopen the
	# client. An earlier temporary-storage notice must not hide that distinction.
	if not _warning_shown or result == ERR_ALREADY_IN_USE:
		_warning_shown = true
		saving_failed.emit(result == ERR_ALREADY_IN_USE)
