extends Node
## Behaviour test for unreadable-vault quarantine (issue #290) — the escape from
## the one way the vault's read-only latch could harm the player.
##
## The latch itself is correct and stays: a vault this build cannot read is never
## written over, because it may be a NEWER client's progression. But a document
## that does not PARSE is progression no client can recover, and latching it
## refuses every write for the life of the install — the player is told each
## session that the Reach may not remember, with no remedy inside the game.
##
## What this pins:
##  1. The wedge is real: a corrupt vault refuses writes before quarantine runs.
##  2. A stale corrupt vault is SET ASIDE — bytes preserved exactly, path freed,
##     the session latch cleared, and a real attunement persists afterwards.
##  3. A corrupt vault that was JUST written is left alone. This is the
##     truncated-newer-write case: a partial file a sync agent is about to
##     complete must not be mistaken for abandoned corruption.
##  4. A NEWER-version vault is never quarantined, however long it has sat. It
##     parses, so some client owns it — the protection #249 added must not
##     regress.
##  5. A valid vault is never touched.
##  6. Quarantine never overwrites an earlier quarantine: slots are allocated,
##     never reused.
##  7. A malformed window override keeps the SHIPPED window, so the age gate can
##     never be shortened by accident — the direction that could destroy state.
##  8. A zero-byte vault — the commonest corruption a crash or a full disk leaves
##     — is set aside like any other unreadable bytes, and saving works after.
##
## Everything runs through the WAR_VAULT_PATH seam against a throwaway path, so
## the player's own user://vault.json is never read, written or moved
## (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_quarantine_test.tscn

const PROBE := "user://vault_quarantine_probe.json"
const CORRUPT_BYTES := "{\"version\": 1, \"attu"
const SENTINEL_BYTES := "an earlier corruption, already preserved"


func _ready() -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, PROBE)

	# 1. The wedge this closes. A corrupt vault refuses writes, and the refusal
	#    latches for the session — which is exactly the permanent state #290
	#    reported when nothing ever clears it.
	_write(PROBE, CORRUPT_BYTES)
	if SaveVault.can_write(PROBE):
		_fail("a corrupt vault was considered writable — the read-only latch is not holding")
		return
	if not SaveVault.exists():
		_fail("the corrupt probe vault is not where the test wrote it")
		return

	# 2. Set aside once it is demonstrably not an in-flight write. The window is
	#    driven to 0 through the test-only seam so a just-written probe qualifies
	#    without sleeping, mirroring how vault_lock_test drives the stale lock.
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "0")
	var moved := SaveVault.quarantine_unreadable(PROBE)
	if moved.is_empty():
		_fail("a stale corrupt vault was not set aside — the player stays wedged")
		return
	if moved != PROBE + SaveVault.QUARANTINE_SUFFIX + "0":
		_fail("quarantine used an unexpected slot: %s" % moved)
		return
	if FileAccess.file_exists(PROBE):
		_fail("the corrupt vault is still in place after being set aside")
		return
	if _read(moved) != CORRUPT_BYTES:
		_fail("quarantine did not preserve the original bytes exactly")
		return

	# The latch must clear with it: the bytes are preserved elsewhere and the path
	# now holds nothing, so there is no longer progression to protect. Leaving it
	# set would keep the player wedged for the rest of the session anyway.
	if not SaveVault.can_write(PROBE):
		_fail("the session latch survived quarantine — the player stays wedged until a restart")
		return

	# And the whole point, end to end: progression persists again.
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("an attunement still would not persist after the corrupt vault was set aside")
		return
	var restored = SaveVault.load_saved()
	if restored is not Dictionary:
		_fail("the freshly started vault does not read back")
		return
	if not SaveVault.is_attuned(restored, SaveVault.SHRINE_WARDENS):
		_fail("the freshly started vault did not record the attunement")
		return

	# 3. RED-PROOF — a corrupt vault written moments ago is NOT set aside. This is
	#    the truncated-newer-write case the issue asked to be decided deliberately:
	#    a sync agent's partial file completes shortly after it appears, and
	#    quarantining it would let this build start a v1 vault a newer client then
	#    adopts as authoritative. Ablating the age gate (window 0) turns this case
	#    into a quarantine, which is what makes the gate load-bearing rather than
	#    decorative.
	_reset_state()
	_write(PROBE, CORRUPT_BYTES)
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "3600")
	if not SaveVault.quarantine_unreadable(PROBE).is_empty():
		_fail("a corrupt vault written seconds ago was set aside — an in-flight write can be eaten")
		return
	if _read(PROBE) != CORRUPT_BYTES:
		_fail("a fresh corrupt vault was modified even though it was not quarantined")
		return

	# 4. RED-PROOF — a NEWER-version vault is never set aside, at any age. It
	#    parses, so a client that understands it exists and its progression is
	#    real. This is the #249 protection the issue requires to stay green.
	_reset_state()
	_write(PROBE, JSON.stringify({ "version": SaveVault.VAULT_READ_VERSION + 7, "attuned": [] }))
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "0")
	if not SaveVault.quarantine_unreadable(PROBE).is_empty():
		_fail("a NEWER client's vault was set aside — quarantine must only take unparseable bytes")
		return
	if not FileAccess.file_exists(PROBE):
		_fail("a newer-version vault was moved")
		return
	if SaveVault.can_write(PROBE):
		_fail("a newer-version vault became writable — the downgrade protection regressed")
		return

	# 5. A valid vault is left exactly alone.
	_reset_state()
	var healthy := JSON.stringify(SaveVault.attune(SaveVault.empty(), SaveVault.SHRINE_WARDENS))
	_write(PROBE, healthy)
	if not SaveVault.quarantine_unreadable(PROBE).is_empty():
		_fail("a perfectly good vault was set aside")
		return
	if _read(PROBE) != healthy:
		_fail("a healthy vault's bytes changed")
		return

	# 6. Quarantine preserves, never deletes — including an earlier quarantine.
	#    An occupied slot is stepped over rather than overwritten.
	_reset_state()
	_write(PROBE + SaveVault.QUARANTINE_SUFFIX + "0", SENTINEL_BYTES)
	_write(PROBE, CORRUPT_BYTES)
	var second := SaveVault.quarantine_unreadable(PROBE)
	if second != PROBE + SaveVault.QUARANTINE_SUFFIX + "1":
		_fail("a second corruption did not take the next free slot: %s" % second)
		return
	if _read(PROBE + SaveVault.QUARANTINE_SUFFIX + "0") != SENTINEL_BYTES:
		_fail("quarantine overwrote bytes it had already preserved")
		return
	if _read(second) != CORRUPT_BYTES:
		_fail("the second quarantine did not preserve its bytes")
		return

	# 7. The window can never be SHORTENED by a malformed value. Negative,
	#    non-numeric and empty all fall through to the shipped default — the same
	#    fail-safe direction as the stale-lock window.
	_reset_state()
	for bad: String in ["-5", "banana", "", "2.5"]:
		OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, bad)
		if SaveVault.quarantine_min_age_seconds() != SaveVault.QUARANTINE_MIN_AGE_SECONDS:
			_fail("a malformed window override (%s) changed the quarantine window" % bad)
			return
	# And it holds behaviourally, not just arithmetically: a fresh corrupt vault
	# survives a malformed override.
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "-5")
	_write(PROBE, CORRUPT_BYTES)
	if not SaveVault.quarantine_unreadable(PROBE).is_empty():
		_fail("a malformed window override let a fresh corrupt vault be set aside")
		return

	# 8. The commonest corruption of all: a zero-byte file. A crash between
	#    creating the temp file and writing it, or a full disk, leaves nothing
	#    rather than half a document — and an empty file parses as no vault in any
	#    version, so it must be set aside like any other unreadable bytes.
	_reset_state()
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "0")
	_write(PROBE, "")
	if not FileAccess.file_exists(PROBE):
		_fail("the empty probe vault was not created")
		return
	var emptied := SaveVault.quarantine_unreadable(PROBE)
	if emptied.is_empty():
		_fail("a zero-byte vault was not set aside — the commonest corruption still wedges saving")
		return
	if FileAccess.file_exists(PROBE):
		_fail("the zero-byte vault is still in place after being set aside")
		return
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("progression still would not persist after a zero-byte vault was set aside")
		return

	_cleanup()
	_clear_env()
	print("TEST PASS — an unreadable vault is set aside, preserved, and never a newer client's")
	get_tree().quit(0)


## Drop every latched refusal and held lock between cases: one throwaway path
## carries several vault states through a single process, and a latch that
## outlived its case would make every later case read as refused.
func _reset_state() -> void:
	_cleanup()
	SaveVault.clear_refusals_for_test()
	SaveVault.clear_locks_for_test()


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("vault_quarantine_test: cannot write %s" % path)
		return
	file.store_string(text)
	file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _fail(message: String) -> void:
	_cleanup()
	_clear_env()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _clear_env() -> void:
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	OS.set_environment(SaveVault.QUARANTINE_MIN_AGE_ENV, "")


func _exit_tree() -> void:
	_cleanup()


func _cleanup() -> void:
	SaveVault.clear_locks_for_test()
	_remove(PROBE)
	_remove(PROBE + ".tmp")
	for index in range(SaveVault.QUARANTINE_MAX_SLOTS):
		_remove("%s%s%d" % [PROBE, SaveVault.QUARANTINE_SUFFIX, index])


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
