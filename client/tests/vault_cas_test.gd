extends Node
## Compare-and-swap test for the save vault's write path (issue #386).
##
## vault_lock_test pins what the write LOCK does; this pins what happens to the
## writers the lock cannot bind. A lock only binds writers that take it, so the
## retained and rollback builds the updater deliberately keeps runnable, cloud
## sync, a backup agent and a hand edit all walk straight through it. Each of
## them replaces user://vault.json while a lock-aware client is holding a
## document it read before that write, and the merge-then-rename that follows
## discards their progression without ever learning it existed. Under the
## no-resets law that loss is permanent.
##
## The guard is a compare-and-swap on the document's own BYTES: record an
## identity when the vault is read, verify the file still carries it immediately
## before the rename, refuse when it does not. It keys on what the file IS rather
## than on who cooperated, which is why it sees every writer above.
##
## A foreign writer is simulated by writing the file directly with FileAccess and
## never taking the lock. That is not an approximation — a rollback build, a sync
## daemon and a hand edit all produce exactly that: different bytes, no lock. The
## code under test cannot tell the difference.
##
## What is pinned:
##  1. document_identity() is absent-vs-present, changes on any byte change, is
##     stable across re-reads, and never collides with the opt-out sentinel.
##  2. A foreign writer between read and rename is DETECTED: the write refuses
##     and the foreign document survives BYTE-INTACT.
##  3. The refusal is not vacuous — the identical call with a CURRENT identity
##     succeeds. Without this the whole file could pass by always refusing.
##  4. Detection covers the absent -> created direction too: a writer that read
##     no vault must still refuse once one has appeared.
##  5. Refusing is session-only degradation, never a boot blocker: the vault
##     still READS, and it reads the foreign writer's document.
##  6. A refused write leaves no temp file behind.
##  7. save_to() stays a deliberate blind replace via the sentinel, so the
##     existing whole-document callers are unaffected.
##  8. The production read-modify-write threads a LIVE identity — proven both by
##     an uncontended persist still succeeding, and by replaying that helper's
##     exact sequence with a foreign write interposed.
##
## RESIDUAL, stated rather than glossed: verify-then-rename is two operations, so
## the window shrinks to the rename syscall rather than closing. Closing it needs
## an OS-level lock held across the rename, which Godot does not expose. Case 8's
## interposition also replays the helper's sequence rather than pausing inside a
## live call — landing a foreign write INSIDE one needs a second process, the
## same honesty vault_lock_test applies to simultaneous mkdir.
##
## Everything runs against a throwaway path via WAR_VAULT_PATH, so the player's
## own user://vault.json is never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_cas_test.tscn

const PROBE := "user://vault_cas_probe.json"


func _ready() -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, PROBE)

	# 1. The identity primitive itself. Everything below is a comparison of two of
	# these, so a constant-valued or always-empty identity would make every later
	# case pass while detecting nothing.
	if SaveVault.document_identity(PROBE) != SaveVault.IDENTITY_ABSENT:
		_fail("an absent vault did not report the absent identity")
		return
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("the first attunement did not persist")
		return
	var first := SaveVault.document_identity(PROBE)
	if first == SaveVault.IDENTITY_ABSENT:
		_fail("a present vault reported the absent identity")
		return
	if first == SaveVault.IDENTITY_UNCHECKED:
		_fail("a real identity collided with the opt-out sentinel — CAS would silently never run")
		return
	if SaveVault.document_identity(PROBE) != first:
		_fail("the identity of an unchanged vault was not stable — every write would refuse")
		return

	# A byte change must move it. Discoveries merge into the document, so this is
	# a same-version, same-shape, still-readable write — exactly the case the
	# readability re-check cannot see and only the bytes distinguish.
	if not SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("the discovery write did not persist")
		return
	var second := SaveVault.document_identity(PROBE)
	if second == first:
		_fail("the identity did not change after the document changed — CAS would never fire")
		return

	# 2. THE RACE. Read the vault, let a foreign writer replace it, then complete
	# the write. The foreign document is readable and same-version, so nothing
	# else in the write path objects to replacing it.
	var expected := SaveVault.document_identity(PROBE)
	var current = SaveVault.load_or_empty()
	if current is not Dictionary:
		_fail("the probe vault did not read back for the race case")
		return
	var foreign := SaveVault.record_discoveries(
		SaveVault.empty(), [SaveVault.DISCOVERY_WARDENS_SHRINE])
	if not _foreign_write(PROBE, foreign):
		_fail("could not simulate a foreign writer")
		return
	var foreign_bytes := _read(PROBE)
	if SaveVault.replace_if_unchanged(
			PROBE, SaveVault.attune(current, SaveVault.SHRINE_WARDENS), expected):
		_fail("a write over a FOREIGN writer's vault SUCCEEDED — its progression is silently lost")
		return
	if _read(PROBE) != foreign_bytes:
		_fail("a refused write still modified the foreign writer's vault — it must be byte-intact")
		return

	# 3. Non-vacuous control. The SAME call, differing only in that the identity
	# is current, must succeed. Without this, an implementation that refused every
	# write — or one whose identity never matched anything — would pass case 2.
	var fresh := SaveVault.document_identity(PROBE)
	var reread = SaveVault.load_or_empty()
	if reread is not Dictionary:
		_fail("the foreign vault did not read back for the control case")
		return
	if not SaveVault.replace_if_unchanged(
			PROBE, SaveVault.attune(reread, SaveVault.SHRINE_WARDENS), fresh):
		_fail("a write with a CURRENT identity was refused — CAS refuses everything")
		return
	var merged = SaveVault.load_saved()
	if merged is not Dictionary:
		_fail("the vault did not read back after the control write")
		return
	# The control write merged onto the foreign document, so BOTH survive. That is
	# what the refusal in case 2 was protecting: read the winner, then merge.
	if not SaveVault.is_attuned(merged, SaveVault.SHRINE_WARDENS):
		_fail("the control write did not record its own attunement")
		return
	if not SaveVault.recognises_discovery(SaveVault.DISCOVERY_WARDENS_SHRINE):
		_fail("the shrine discovery is not a recognised name — the fixture is wrong")
		return
	if not merged["discoveries"].has(SaveVault.DISCOVERY_WARDENS_SHRINE):
		_fail("the control write discarded the foreign writer's discovery")
		return

	# 4. The absent -> created direction. A writer that read NO vault expects
	# absence; if one has appeared since, replacing it destroys a document this
	# process never saw. "Expected nothing" therefore has to be a real
	# expectation, not a synonym for "no expectation".
	_remove(PROBE)
	SaveVault.clear_refusals_for_test()
	var absent := SaveVault.document_identity(PROBE)
	if absent != SaveVault.IDENTITY_ABSENT:
		_fail("a removed vault did not report the absent identity")
		return
	if not _foreign_write(PROBE, foreign):
		_fail("could not simulate a vault appearing under an absent expectation")
		return
	var appeared_bytes := _read(PROBE)
	if SaveVault.replace_if_unchanged(PROBE, SaveVault.empty(), absent):
		_fail("a write expecting NO vault replaced one that had appeared — its progression is lost")
		return
	if _read(PROBE) != appeared_bytes:
		_fail("the refused absent-expectation write still modified the vault")
		return

	# 5. Session-only degradation. A refused write must never block a boot, and
	# what still reads must be the FOREIGN writer's document — refusing is only
	# correct because their state is the one that survives.
	var readable = SaveVault.load_saved()
	if readable is not Dictionary:
		_fail("the vault became unreadable after a refused write — that blocks a boot")
		return
	if not readable["discoveries"].has(SaveVault.DISCOVERY_WARDENS_SHRINE):
		_fail("the surviving vault is not the foreign writer's document")
		return

	# 6. No temp file survives a refusal. A stranded vault.json.tmp would be
	# mistaken for a crashed write and is exactly the litter the lock path is
	# careful to avoid.
	if FileAccess.file_exists(PROBE + ".tmp"):
		_fail("a refused write left its temp file behind")
		return

	# 7. save_to() is still a blind whole-document replace. The sentinel is the
	# opt-out for callers that never read first, and it must remain usable — a CAS
	# that silently applied to every write would break every fixture seed.
	if not SaveVault.save_to(PROBE, SaveVault.empty()):
		_fail("save_to() no longer performs a blind replace")
		return
	var blanked = SaveVault.load_saved()
	if blanked is not Dictionary or not blanked["attuned"].is_empty():
		_fail("the blind replace did not take effect")
		return

	# 8. The production read-modify-write threads a LIVE identity. Two halves,
	# because neither alone is sufficient:
	#
	# (a) An uncontended persist still succeeds. This is what fails if a helper
	#     passes a stale or wrongly-ordered identity — every write would refuse.
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("an uncontended persist_attunement() refused — the helper's identity is wrong")
		return
	if not SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("an uncontended persist_discoveries() refused — the helper's identity is wrong")
		return
	var settled = SaveVault.load_saved()
	if settled is not Dictionary or not SaveVault.is_attuned(settled, SaveVault.SHRINE_WARDENS):
		_fail("the uncontended persists did not reach disk")
		return

	# (b) The helper's sequence, replayed with a foreign write interposed at the
	#     one point a second process could land one. capture-identity, load,
	#     merge, replace — the same four steps _persist_discoveries_locked runs,
	#     in the same order. Pausing inside a live call would need a second
	#     process; replaying it exercises the same guard with the same semantics.
	var helper_expected := SaveVault.document_identity(PROBE)
	var helper_current = SaveVault.load_or_empty()
	if helper_current is not Dictionary:
		_fail("the vault did not read back for the helper-sequence case")
		return
	if not _foreign_write(PROBE, foreign):
		_fail("could not simulate a foreign writer during the helper sequence")
		return
	var during_bytes := _read(PROBE)
	var helper_next := SaveVault.record_discoveries(
		helper_current, [SaveVault.DISCOVERY_STARTER_CAVE])
	if SaveVault.replace_if_unchanged(PROBE, helper_next, helper_expected):
		_fail("the helper's own sequence overwrote a foreign writer — the identity is not threaded")
		return
	if _read(PROBE) != during_bytes:
		_fail("the refused helper write still modified the vault")
		return

	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault writes compare-and-swap on the document's bytes, so a writer that never took the lock is detected and refused instead of silently overwritten")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## Replace the vault WITHOUT taking the lock and without going through SaveVault
## — a pre-lock rollback build, cloud sync, a backup agent or a hand edit. The
## document is valid and same-version on purpose: an unreadable one would be
## caught by the readability re-check, and would prove nothing about CAS.
func _foreign_write(path: String, doc: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(doc, "  "))
	file.close()
	return true


## The vault's bytes, or "" when absent. Byte comparison is deliberate: a refused
## write must leave the file untouched, and comparing parsed documents would hide
## a rewrite that happened to round-trip to the same state.
func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(_abs(path))


func _cleanup() -> void:
	SaveVault.clear_locks_for_test()
	SaveVault.clear_refusals_for_test()
	var lock := SaveVault.lock_path(PROBE)
	DirAccess.remove_absolute(_abs(lock + "/" + SaveVault.LOCK_OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))
	for path: String in [PROBE, PROBE + ".tmp"]:
		_remove(path)
