extends Node
## Compare-and-swap test for the character recipe's write path (issue #469).
##
## character_lock_test pins what the write LOCK does; this pins what happens to
## the staleness the lock cannot see. The two failures are genuinely different,
## and the lock closes only one of them:
##
##  - Writers that never took the lock — a retained rollback build the updater
##    deliberately keeps runnable, cloud sync, a backup agent, a hand edit. Each
##    replaces user://character.json while a lock-aware client holds a recipe it
##    read before that write.
##  - Writers that DID take it, and cooperated perfectly. Two clients open the
##    character editor from the same saved recipe; A saves and releases; B then
##    acquires legitimately, can_write() accepts A's perfectly valid document,
##    and B's apply replaces A's character with one derived from a snapshot A had
##    already superseded. The writes serialised exactly as the lock intends. The
##    staleness is in the BASE B read, not in the ordering of the writes, so no
##    amount of locking detects it.
##
## Under the no-resets law that loss is permanent — there is no wipe to recover
## with, and the character is the thing the player looked at most.
##
## The guard is a compare-and-swap on the recipe's own BYTES: record an identity
## when the recipe is read, verify the file still carries it immediately before
## the rename, refuse when it does not. It keys on what the file IS rather than on
## who cooperated, which is why it sees both writers above. The vault solved the
## identical problem in #386 and the boot-recovery ledger in #453; this ports
## their shape rather than inventing a third one.
##
## A foreign writer is simulated by writing the file directly with FileAccess and
## never taking the lock. That is not an approximation — a rollback build, a sync
## daemon and a hand edit all produce exactly that: different bytes, no lock. It
## stands in for the cooperating-but-stale case too, because the code under test
## cannot tell the two apart: both present an identity the file no longer carries.
##
## What is pinned:
##  1. document_identity() is absent-vs-present, changes on any byte change, is
##     stable across re-reads, and never collides with any of the three sentinels.
##  2. A write landing between read and rename is DETECTED: the write refuses and
##     the other writer's recipe survives BYTE-INTACT.
##  3. The refusal is not vacuous — the identical call with a CURRENT identity
##     succeeds. Without this the whole file could pass by always refusing, which
##     detects nothing and breaks every real save.
##  4. Detection covers the absent -> created direction too: a client that read no
##     recipe must still refuse once one has appeared.
##  5. The refusal is ATTRIBUTABLE and, crucially, does NOT LATCH. A stale
##     identity is losable-and-retryable; the permanent refusal latch is not.
##     Latching here would lock the player out of their own character for the rest
##     of the session over a collision the next attempt resolves — the distinction
##     #423 established for lock contention, which this outcome joins rather than
##     blurs.
##  6. A refused write leaves no staging file behind.
##  7. save_to()/save_recipe() without an expectation stay a deliberate blind
##     replace, so fixture seeds and the existing refusal, lock and staging suites
##     are unaffected.
##
## The production path's threading is pinned in character_revert_boot_test, not
## here. A caller that passes IDENTITY_UNCHECKED writes correctly whenever nothing
## races it, so every assertion in THIS file still passes while the guard is
## absent from main.gd — the same ablation that was measured slipping through the
## vault's end-to-end coverage. Only the real scene's apply can tell the
## difference, which is why the expectation the production write ran under is
## asserted there.
##
## RESIDUAL, stated rather than glossed: verify-then-rename is two operations, so
## the window shrinks to the rename syscall rather than closing. Closing it needs
## an OS-level lock held across the rename, which Godot's FileAccess/DirAccess do
## not expose. The gain is a DETECTED refusal in place of a silent lost update.
##
## TWO PROPERTIES HERE ARE DELIBERATELY UNPINNED, and saying so is the point:
##  - document_identity() answering IDENTITY_UNREADABLE on a hash failure.
##    Provoking a genuine hash failure needs filesystem conditions a test cannot
##    portably create. What IS pinned is the constant staying distinct from ABSENT
##    and UNCHECKED (case 1), which is the part with a reachable lost update
##    behind it. The vault and the ledger carry the identical gap for the
##    identical reason.
##  - The caller capturing the identity BEFORE load_saved() rather than after.
##    Swapping those two lines leaves everything green, because nothing races the
##    load inside one process, so both orders hash the same bytes. Only a second
##    process writing between the load and the capture separates them. The
##    ordering is load-bearing all the same — captured after, an interleaved
##    foreign write becomes the expectation while the creator still opens on the
##    old recipe — so it is guarded by the comment at the call site in main.gd and
##    by review, not by this file.
##
## Everything runs against a throwaway path via WAR_SAVE_PATH, so the player's own
## character is never read or written (no-resets law — a test may never strand a
## character).
##
## Run: godot --headless --path client res://tests/character_cas_test.tscn

const PROBE := "user://character_cas_probe.json"

var _failed := false


func _ready() -> void:
	_cleanup()
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, PROBE)

	# 1. The identity primitive itself. Everything below compares two of these, so
	# a constant-valued or always-empty identity would make every later case pass
	# while detecting nothing.
	if CharacterStore.document_identity(PROBE) != CharacterStore.IDENTITY_ABSENT:
		_fail("an absent recipe did not report the absent identity")
		return
	var wanderer := _wanderer()
	if wanderer.is_empty():
		return
	if not CharacterStore.save_to(PROBE, wanderer):
		_fail("the first recipe write did not persist")
		return
	var first := CharacterStore.document_identity(PROBE)
	if first == CharacterStore.IDENTITY_ABSENT:
		_fail("a present recipe reported the absent identity")
		return
	if first == CharacterStore.IDENTITY_UNCHECKED:
		_fail("a real identity collided with the opt-out sentinel — the CAS would silently never run")
		return
	if first == CharacterStore.IDENTITY_UNREADABLE:
		_fail("a readable recipe reported the unreadable identity")
		return
	if CharacterStore.document_identity(PROBE) != first:
		_fail("the identity of an unchanged recipe was not stable — every write would refuse")
		return
	# The three sentinels must stay pairwise distinct. Collapsing ABSENT and
	# UNREADABLE is a lost update rather than a refusal: a client that read no
	# recipe expects absence, and a recipe that has appeared since but cannot be
	# hashed would compare EQUAL to that expectation and be replaced.
	if CharacterStore.IDENTITY_ABSENT == CharacterStore.IDENTITY_UNREADABLE:
		_fail("the absent and unreadable identities are the same value — an unhashable recipe would be overwritten by a first-run write")
		return
	if CharacterStore.IDENTITY_UNCHECKED == CharacterStore.IDENTITY_ABSENT:
		_fail("the opt-out sentinel collides with the absent identity — 'no expectation' would be indistinguishable from 'expected nothing'")
		return

	# A byte change must move it. An edited recipe is a same-version, same-shape,
	# still-readable write — exactly the case the acceptance re-check cannot see
	# and only the bytes distinguish.
	var edited := _with_weight(wanderer, 0.42)
	if not CharacterStore.save_to(PROBE, edited, first):
		_fail("a write presenting the current identity refused — the guard rejects every write, not just racing ones")
		return
	var second := CharacterStore.document_identity(PROBE)
	if second == first:
		_fail("the identity did not change when the recipe's bytes did — a foreign write would compare equal and be overwritten")
		return

	# 2. Another writer lands between this client's read and its rename. `second`
	# is the identity this client read; the foreign bytes are what is on disk now.
	var foreign := _with_weight(wanderer, 0.77)
	if not _foreign_write(PROBE, foreign):
		_fail("could not simulate a foreign writer")
		return
	var foreign_bytes := _read(PROBE)
	var stale_ok := CharacterStore.save_to(PROBE, _with_weight(wanderer, 0.15), second)
	if stale_ok:
		_fail("a write presenting a STALE identity overwrote another writer's recipe — the character is lost permanently")
		return
	if _read(PROBE) != foreign_bytes:
		_fail("the refused write still modified the recipe — the bytes must be left exactly as the other writer left them")
		return

	# 5. The refusal must be attributable, and it must NOT latch. A stale identity
	# is losable-and-retryable; latching would lock the creator shut for the
	# session over a collision the next attempt resolves.
	if CharacterStore.last_refusal() != CharacterStore.REFUSAL_STALE:
		_fail("the compare-and-swap refusal did not report itself as stale — a caller cannot tell it from contention or an unacceptable recipe; got: '%s'" % CharacterStore.last_refusal())
		return
	if CharacterStore.REFUSAL_STALE == CharacterStore.REFUSAL_LOCK:
		_fail("the stale and lock refusals are the same value — the two outcomes are indistinguishable to a caller")
		return
	if CharacterStore.REFUSAL_STALE == CharacterStore.REFUSAL_UNACCEPTABLE:
		_fail("the stale and unacceptable refusals are the same value — a retryable outcome would be treated as permanent")
		return
	if CharacterStore.is_refused(PROBE):
		_fail("a stale-identity refusal LATCHED the path — the creator would lock shut for the session over a retryable collision")
		return
	if not CharacterStore.can_write(PROBE):
		_fail("the path stopped being writable after a stale refusal — the next attempt could never resolve the collision")
		return

	# 6. A refused write leaves no staging file. Staging names carry a per-attempt
	# stamp and are never reclaimed by being overwritten, so a refusal branch that
	# forgets to remove its stage leaks a file on every occurrence.
	var leftovers := _staging_leftovers()
	if not leftovers.is_empty():
		_fail("a refused compare-and-swap left %d staging file(s) behind: %s" % [leftovers.size(), str(leftovers)])
		return

	# The recipe must still READ after a refusal, and it must read the FOREIGN
	# writer's document rather than ours — that is what main.gd puts back on the
	# player's body when the apply does not land.
	var after = CharacterStore.load_from(PROBE)
	if after is not Dictionary:
		_fail("the recipe stopped reading after a refused write")
		return
	if not is_equal_approx(float((after as Dictionary)["shapes"]["torso_muscle"]), 0.77):
		_fail("the recipe did not read back the foreign writer's document after the refusal")
		return

	# 3. The refusal is not vacuous: the SAME call, with the identity the recipe
	# actually carries now, must succeed.
	var current := CharacterStore.document_identity(PROBE)
	if not CharacterStore.save_to(PROBE, _with_weight(wanderer, 0.15), current):
		_fail("a write presenting the CURRENT identity refused — the guard rejects every write, not just racing ones")
		return
	if CharacterStore.last_refusal() != CharacterStore.REFUSAL_NONE:
		_fail("a successful write still reported a refusal reason: '%s'" % CharacterStore.last_refusal())
		return
	var settled = CharacterStore.load_from(PROBE)
	if settled is not Dictionary or not is_equal_approx(float((settled as Dictionary)["shapes"]["torso_muscle"]), 0.15):
		_fail("the accepted write did not reach disk")
		return

	# 4. The absent -> created direction. A client that loaded no recipe expects
	# absence; another writer creating one before its rename must refuse, or a
	# first run silently discards a character that was already there.
	_remove(PROBE)
	CharacterStore.clear_refusals_for_test()
	if CharacterStore.document_identity(PROBE) != CharacterStore.IDENTITY_ABSENT:
		_fail("a removed recipe did not report the absent identity")
		return
	if not _foreign_write(PROBE, foreign):
		_fail("could not simulate a writer creating the recipe after a first-run read")
		return
	var appeared_bytes := _read(PROBE)
	if CharacterStore.save_to(PROBE, wanderer, CharacterStore.IDENTITY_ABSENT):
		_fail("a first-run write overwrote a recipe that appeared after its read")
		return
	if _read(PROBE) != appeared_bytes:
		_fail("the refused first-run write still modified the recipe that had appeared")
		return

	# 7. save_to()/save_recipe() without an expectation are still a blind
	# whole-document replace. The sentinel is the opt-out for callers that never
	# read first, and it must remain usable — a CAS applied silently to every write
	# would break every seed and the existing refusal, lock and staging suites.
	if not CharacterStore.save_to(PROBE, wanderer):
		_fail("save_to() no longer performs a blind replace")
		return
	if not CharacterStore.save_recipe(_with_weight(wanderer, 0.31)):
		_fail("save_recipe() no longer performs a blind replace")
		return
	var blind = CharacterStore.load_saved()
	if blind is not Dictionary or not is_equal_approx(float((blind as Dictionary)["shapes"]["torso_muscle"]), 0.31):
		_fail("the blind replace did not take effect through the whole-game path")
		return

	_cleanup()
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	print("TEST PASS — character writes compare-and-swap on the recipe's bytes, so a stale base is detected and refused instead of silently overwriting a newer character")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _wanderer() -> Dictionary:
	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable")
		return {}
	var copy: Dictionary = (recipe as Dictionary).duplicate(true)
	copy.erase("comment")
	if not (copy.get("shapes", {}) as Dictionary).has("torso_muscle"):
		_fail("the wanderer preset has no 'torso_muscle' shape — this test distinguishes documents by it")
		return {}
	return copy


## The same recipe with one shape moved. Same version, same shape, still valid and
## still readable — so the acceptance re-check accepts it and ONLY the bytes tell
## two of these apart. A document this build could not read would be caught by
## can_write() and would prove nothing about the compare-and-swap.
func _with_weight(recipe: Dictionary, weight: float) -> Dictionary:
	var copy := recipe.duplicate(true)
	(copy["shapes"] as Dictionary)["torso_muscle"] = weight
	return copy


## Replace the recipe WITHOUT taking the lock and without going through
## CharacterStore — a pre-lock retained build, a rollback build, cloud sync, a
## backup agent or a hand edit. Serialised exactly as the store would, so the
## result is a document the store accepts on every check except the identity.
func _foreign_write(path: String, recipe: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(recipe, "  "))
	file.close()
	return true


## The recipe's bytes, or "" when absent. Byte comparison is deliberate: a refused
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


## Every staging file beside the probe. Staging paths carry a per-attempt stamp,
## so they cannot be reconstructed by name — scan the directory for the prefix.
func _staging_leftovers() -> Array:
	var parent := PROBE.get_base_dir()
	var prefix := PROBE.get_file() + CharacterStore.WRITE_TMP_SUFFIX
	var found: Array = []
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			found.append(parent.path_join(entry))
	return found


func _cleanup() -> void:
	FileLock.clear_for_test()
	CharacterStore.clear_refusals_for_test()
	var lock := FileLock.path_for(PROBE)
	DirAccess.remove_absolute(_abs(lock + "/" + FileLock.OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))
	for path: String in [PROBE, PROBE + ".tmp"]:
		_remove(path)
	for leftover: String in _staging_leftovers():
		_remove(leftover)
