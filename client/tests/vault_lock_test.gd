extends Node
## Contention test for the save vault's cross-process write lock (issue #262).
##
## save_vault_test pins the vault's single-writer behaviour; this pins what
## happens when there is MORE than one writer. The race it closes is
## check-then-act across a read-modify-write: two differently-versioned clients
## sharing one user:// directory each read the same document, each merge their
## own change, and the slower rename silently discards the faster writer's
## progression. Under the no-resets law that loss is permanent.
##
## A competing process is simulated by creating the lock directory directly.
## That is not an approximation of contention — the lock IS a directory, so a
## directory created by anything is byte-for-byte what a real competing client
## leaves behind, and the code under test cannot tell the difference. The one
## thing left unproven is that two simultaneous mkdir calls resolve to a single
## winner, which is the operating system's atomicity guarantee rather than ours.
##
## What is pinned:
##  1. The lock is a DIRECTORY, and exclusive-create is what decides the race.
##  2. A held lock makes a write refuse — and leave the vault BYTE-INTACT.
##  3. Refusing is session-only degradation, never a boot blocker: the vault
##     still reads while another writer holds the lock.
##  4. The lock is released after a successful write, and after a failed one —
##     a leaked lock would wedge the vault for the whole stale timeout.
##  5. Reentrancy: persist_*() holds the lock across its whole read-modify-write
##     and still calls save_to(), which takes the same lock. This must not
##     self-deadlock.
##  6. Stale recovery: a lock left by a crashed process is broken once it ages
##     past the timeout, so a crash cannot wedge the vault forever.
##  7. The timeout seam refuses malformed and negative values, so the shipped
##     window can never be shortened by a bad environment variable.
##
## Everything runs against a throwaway path via WAR_VAULT_PATH, so the player's
## own user://vault.json is never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_lock_test.tscn

const PROBE := "user://vault_lock_probe.json"


func _ready() -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, PROBE)

	# 1. The lock is a directory beside the vault. `mkdir` is the only atomic
	# exclusive-create Godot exposes; a plain file open would be check-then-act
	# again, so the SHAPE is load-bearing, not an implementation detail.
	var lock := SaveVault.lock_path(PROBE)
	if lock != PROBE + SaveVault.LOCK_SUFFIX:
		_fail("lock_path() did not sit beside the vault: %s" % lock)
		return
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("the first attunement did not persist")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock directory survived a successful write — it would wedge the vault")
		return

	var baseline := _read(PROBE)
	if baseline.is_empty():
		_fail("the probe vault is empty after a successful attunement")
		return

	# 2. A competing writer holds the lock: the write must refuse rather than
	# interleave, and must not touch the file on its way out.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer by taking the lock")
		return
	if SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("a discovery write SUCCEEDED while another writer held the lock — the race is open")
		return
	if _read(PROBE) != baseline:
		_fail("a refused write still modified the vault — it must be byte-intact")
		return
	if SaveVault.save_to(PROBE, SaveVault.empty()):
		_fail("a direct save_to() SUCCEEDED while another writer held the lock")
		return
	if _read(PROBE) != baseline:
		_fail("a refused direct save_to() still modified the vault")
		return

	# 3. Contention degrades to session-only; it never blocks a boot. Reading is
	# unaffected, which is what keeps a locked vault from stranding a player.
	var readable = SaveVault.load_saved()
	if readable is not Dictionary:
		_fail("the vault became unreadable while another writer held the lock — that blocks a boot")
		return
	if not SaveVault.is_attuned(readable, SaveVault.SHRINE_WARDENS):
		_fail("the readable vault lost its attunement under contention")
		return

	# 4. Release the competing hold; writes resume. This proves the refusal above
	# was the LOCK talking and not some unrelated failure that would have
	# refused anyway — without this the whole case could pass vacuously.
	DirAccess.remove_absolute(_abs(lock))
	if not SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("the write did not resume once the competing writer released the lock")
		return
	var after_release := _read(PROBE)
	if after_release == baseline:
		_fail("the resumed write did not actually change the vault")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock leaked after the resumed write")
		return

	# 5. A FAILED write must release too. An invalid document is refused by
	# validate() deep inside the locked section, which is exactly the kind of
	# early return that leaks a lock when release is not on a single path.
	if SaveVault.save_to(PROBE, { "version": 1, "bogus_field": true }):
		_fail("save_to() accepted an invalid document")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock LEAKED after a refused write — the vault would wedge until the timeout")
		return

	# 6. Reentrancy: persist_*() takes the lock, then calls save_to(), which
	# takes the same lock. If that nested acquire collided with our own
	# directory the write would refuse itself — a deadlock that is
	# indistinguishable from healthy contention, so it is pinned explicitly.
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("a reentrant persist -> save_to self-deadlocked on its own lock")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the reentrant write left the lock behind — release unbalanced its acquire")
		return

	# 7. Stale recovery: a crashed process leaves a lock nobody will ever
	# release. With the timeout seamed to 0 the very next write may break it, so
	# a crash cannot wedge the vault forever.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a crashed process's abandoned lock")
		return
	OS.set_environment(SaveVault.LOCK_STALE_ENV, "0")
	if SaveVault.lock_stale_seconds() != 0:
		_fail("the stale-timeout seam did not honour an explicit 0")
		return
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("an abandoned lock was never broken — a crash wedges the vault permanently")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the stale-break path left a lock behind")
		return

	# 8. The seam fails SAFE. A malformed or negative value must fall back to the
	# shipped window rather than shorten it — a 0-second window in the field
	# would let any live writer be robbed mid-write, which is the one loss this
	# lock exists to prevent.
	for bad: String in ["", "-1", "abc", "3.5"]:
		OS.set_environment(SaveVault.LOCK_STALE_ENV, bad)
		if SaveVault.lock_stale_seconds() != SaveVault.LOCK_STALE_SECONDS:
			_fail("the stale seam accepted %s instead of falling back to the shipped window" % (
				"an empty value" if bad.is_empty() else "'%s'" % bad))
			return
	OS.set_environment(SaveVault.LOCK_STALE_ENV, "")

	# 9. A live lock is NOT stolen, re-checked END TO END now that the seam has
	# been exercised and reset. Case 2 already proves freshness is respected, and
	# ablating the staleness rule fails there first — so this is a restatement
	# rather than a uniquely-caught bug. It is kept because it is the only case
	# that exercises the restored window through real writes rather than through
	# lock_stale_seconds() alone, which is what case 8 checks.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the freshness case")
		return
	if SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("a FRESH lock was broken — a live writer can be robbed mid-write")
		return
	DirAccess.remove_absolute(_abs(lock))

	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault write lock excludes a competing writer, releases on every path, recovers from a crash, and is never stolen while live")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	OS.set_environment(SaveVault.LOCK_STALE_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## The vault's bytes, or "" when absent. Byte comparison is deliberate: a
## refused write must leave the file untouched, and comparing parsed documents
## would hide a rewrite that happened to round-trip to the same state.
func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _cleanup() -> void:
	SaveVault.clear_locks_for_test()
	SaveVault.clear_refusals_for_test()
	DirAccess.remove_absolute(_abs(SaveVault.lock_path(PROBE)))
	for path: String in [PROBE, PROBE + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(_abs(path))
