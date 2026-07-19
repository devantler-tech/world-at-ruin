extends Node
## Behaviour test for the save vault (issue #249, parent #3) — the progression
## sibling of character_persistence_test. Where save_vault_guard_test pins the
## forward-only LAW against shipped fixtures, this pins the API's behaviour:
##  1. The path seam (WAR_VAULT_PATH) resolves and is inert when unset.
##  2. An empty vault is valid and carries the current version.
##  3. attune() is additive, idempotent, and does not mutate its input.
##  4. attune() preserves fields this build does not use (forward-compat).
##  5. Save → load round-trips an attunement.
##  6. persist_attunement() writes through the seam and accumulates.
##  7. Validation refuses each malformed shape, naming the reason.
##
## Everything runs against a throwaway path via the seam, so the player's own
## user://vault.json is never read or written (no-resets law).
##
## Run: godot --headless --path client res://tests/save_vault_test.tscn

const PROBE := "user://vault_behaviour_probe.json"


func _ready() -> void:
	_cleanup_probe()

	# 1. The seam: unset -> the shipped default; set -> the override.
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	if SaveVault.vault_path() != SaveVault.DEFAULT_PATH:
		_fail("unset WAR_VAULT_PATH did not resolve to the shipped default")
		return
	OS.set_environment(SaveVault.VAULT_PATH_ENV, PROBE)
	if SaveVault.vault_path() != PROBE:
		_fail("WAR_VAULT_PATH override was not honoured")
		return

	# 2. An empty vault is a valid document at the current version.
	var empty := SaveVault.empty()
	if SaveVault.validate(empty) != "":
		_fail("the empty vault does not validate: %s" % SaveVault.validate(empty))
		return
	if int(empty["version"]) != SaveVault.VAULT_VERSION:
		_fail("the empty vault is not at VAULT_VERSION")
		return
	if not SaveVault.attuned(empty).is_empty():
		_fail("a fresh vault already had an attunement")
		return

	# 3. attune() is additive, idempotent, and leaves its input alone.
	var once := SaveVault.attune(empty, SaveVault.SHRINE_WARDENS)
	if not SaveVault.is_attuned(once, SaveVault.SHRINE_WARDENS):
		_fail("attune() did not record the shrine")
		return
	if not SaveVault.attuned(empty).is_empty():
		_fail("attune() MUTATED its input — a caller's vault changed under it")
		return
	var twice := SaveVault.attune(once, SaveVault.SHRINE_WARDENS)
	if SaveVault.attuned(twice).size() != 1:
		_fail("attuning twice duplicated the entry (%d entries)" % SaveVault.attuned(twice).size())
		return

	# 4. A field this build does not use survives attune(). Simulates a vault
	# written by a client that shipped a field we then have to carry forward.
	var carried := { "version": SaveVault.VAULT_VERSION, "comment": "keep me", "attuned": ["some_future_shrine"] }
	var after := SaveVault.attune(carried, SaveVault.SHRINE_WARDENS)
	if String(after.get("comment", "")) != "keep me":
		_fail("attune() dropped a field it does not use")
		return
	if not SaveVault.is_attuned(after, "some_future_shrine"):
		_fail("attune() dropped an attunement name it does not know")
		return

	# 5. Save -> load round-trips.
	if not SaveVault.save_to(PROBE, once):
		_fail("saving a vault failed")
		return
	var loaded = SaveVault.load_from(PROBE)
	if loaded is not Dictionary:
		_fail("a saved vault did not load back")
		return
	if not SaveVault.is_attuned(loaded, SaveVault.SHRINE_WARDENS):
		_fail("the round-trip lost the attunement")
		return

	# 6. persist_attunement() goes through the seam and accumulates a second
	# name without losing the first.
	if not SaveVault.persist_attunement("second_shrine"):
		_fail("persist_attunement() failed")
		return
	var accumulated = SaveVault.load_saved()
	if accumulated is not Dictionary:
		_fail("the persisted vault did not load")
		return
	if not SaveVault.is_attuned(accumulated, SaveVault.SHRINE_WARDENS):
		_fail("persisting a second attunement LOST the first (no-resets law)")
		return
	if not SaveVault.is_attuned(accumulated, "second_shrine"):
		_fail("persist_attunement() did not record the second shrine")
		return

	# persist_attunement() must also work from nothing — a player's very first
	# attunement, with no vault on disk yet.
	_cleanup_probe()
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("the FIRST attunement could not be persisted with no vault present")
		return
	var first = SaveVault.load_saved()
	if first is not Dictionary or not SaveVault.is_attuned(first, SaveVault.SHRINE_WARDENS):
		_fail("the first attunement did not persist")
		return

	# 7. Validation refuses each malformed shape.
	var refusals := {
		"no version": {},
		"non-integer version": { "version": "1" },
		"zero version": { "version": 0 },
		"future version": { "version": SaveVault.VAULT_VERSION + 1 },
		"unknown field": { "version": 1, "loot": {} },
		"attuned not an array": { "version": 1, "attuned": {} },
		"attuned entry not a string": { "version": 1, "attuned": [7] },
	}
	for label: String in refusals:
		if SaveVault.validate(refusals[label]) == "":
			_fail("validation ACCEPTED a malformed vault: %s" % label)
			return

	# And it accepts the shapes it must: with and without the optional fields.
	if SaveVault.validate({ "version": 1 }) != "":
		_fail("validation refused a minimal valid vault")
		return
	if SaveVault.validate({ "version": 1, "comment": "x", "attuned": ["a"] }) != "":
		_fail("validation refused a fully-populated valid vault")
		return

	_cleanup_probe()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault seam, attunement, round-trip and refusals hold")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup_probe()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup_probe()


func _cleanup_probe() -> void:
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))
