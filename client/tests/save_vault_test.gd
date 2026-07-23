extends Node
## Behaviour test for the save vault (issue #249, parent #3) — the progression
## sibling of character_persistence_test. Where save_vault_guard_test pins the
## forward-only LAW against shipped fixtures, this pins the API's behaviour:
##  1. The path seam (WAR_VAULT_PATH) resolves and is inert when unset.
##  2. An empty vault stays v1 even after the v2 writer activates: unrelated
##     state is never rewritten merely to look current.
##  3. attune() is additive, idempotent, and does not mutate its input.
##  4. attune() preserves fields this build does not use (forward-compat).
##  5. A discovery write upgrades v1 to v2 without losing state, while an empty
##     discovery set leaves v1 alone and an existing v2 set only grows.
##  6. Save → load round-trips an attunement.
##  7. Both production persistence helpers write through the seam.
##  8. save_to() refuses to REPLACE an unreadable vault, leaves it byte-intact,
##     and cleans up its temp file.
##  9. Validation refuses each malformed shape, naming the reason.
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
	var vault_api := load("res://scripts/save_vault.gd") as Script

	# 2. The writer can now emit v2, but empty state remains v1. A schema version
	# describes fields actually present; it is not a "latest client" marker.
	var empty := SaveVault.empty()
	if SaveVault.validate(empty) != "":
		_fail("the empty vault does not validate: %s" % SaveVault.validate(empty))
		return
	if SaveVault.VAULT_VERSION != 2:
		_fail("the discovery writer is still capped at vault v%d; expected the baked v2 contract" % SaveVault.VAULT_VERSION)
		return
	if int(empty["version"]) != 1:
		_fail("an empty vault was churned to v%d even though it carries no v2 discovery state" % int(empty["version"]))
		return
	if SaveVault.VAULT_READ_VERSION != 2:
		_fail("the vault reader ceiling is v%d, expected v2" % SaveVault.VAULT_READ_VERSION)
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

	# 5. The baked v2 discovery shape remains readable, and an ordinary v2
	# attunement write-back preserves the discovery set byte-for-byte.
	var expanded := {
		"version": 2,
		"comment": "future discovery writer",
		"attuned": [SaveVault.SHRINE_WARDENS],
		"discoveries": ["starter_cave", "wardens_shrine"],
	}
	var expanded_reason := SaveVault.validate(expanded)
	if expanded_reason != "":
		_fail("the v2 discovery expansion was refused: %s" % expanded_reason)
		return
	var expanded_after := SaveVault.attune(expanded, "second_shrine")
	if expanded_after.get("discoveries", []) != expanded["discoveries"]:
		_fail("an ordinary v2 attunement write-back changed or dropped discovery state")
		return
	if not SaveVault.save_to(PROBE, expanded_after):
		_fail("saving an already-present v2 vault failed")
		return
	var expanded_loaded = SaveVault.load_from(PROBE)
	if expanded_loaded is not Dictionary:
		_fail("the re-saved v2 vault did not load")
		return
	if expanded_loaded.get("discoveries", []) != expanded["discoveries"]:
		_fail("the v2 discovery set did not survive a disk round-trip")
		return

	# The expansion must not leak into old state: loading and attuning a v1
	# document leaves it v1 and never invents the optional v2 field.
	var legacy := { "version": 1, "attuned": [SaveVault.SHRINE_WARDENS] }
	var legacy_after := SaveVault.attune(legacy, "second_shrine")
	if int(legacy_after.get("version", -1)) != 1 or legacy_after.has("discoveries"):
		_fail("an ordinary v1 attunement originated the v2 discovery shape without discovery state")
		return

	# The discovery writer is the ONLY operation that contracts a v1 document
	# to v2. It merges rather than replaces the append-only set, sorts it
	# deterministically, and preserves every unrelated field.
	if not vault_api.has_method("record_discoveries"):
		_fail("the baked discovery reader has no production record_discoveries() writer")
		return
	var discovered: Dictionary = vault_api.call(
		"record_discoveries",
		legacy,
		["wardens_shrine", "starter_cave", "wardens_shrine"])
	if int(discovered.get("version", -1)) != 2:
		_fail("recording a discovery did not contract the vault to v2")
		return
	if discovered.get("discoveries", []) != ["starter_cave", "wardens_shrine"]:
		_fail("the discovery writer did not produce one sorted append-only set: %s" % str(discovered))
		return
	if not SaveVault.is_attuned(discovered, SaveVault.SHRINE_WARDENS):
		_fail("contracting the discovery writer lost the v1 attunement")
		return
	var no_discoveries: Dictionary = vault_api.call("record_discoveries", legacy, [])
	if int(no_discoveries.get("version", -1)) != 1 or no_discoveries.has("discoveries"):
		_fail("recording no discoveries churned a v1 vault to v2")
		return
	var expanded_again: Dictionary = vault_api.call(
		"record_discoveries",
		expanded,
		["future_place", "starter_cave"])
	if expanded_again.get("discoveries", []) != [
		"future_place", "starter_cave", "wardens_shrine"]:
		_fail("a v2 discovery write replaced or duplicated accepted names: %s" % str(expanded_again))
		return
	if String(expanded_again.get("comment", "")) != "future discovery writer":
		_fail("a v2 discovery write dropped an unrelated accepted field")
		return
	var malformed_existing := {
		"version": 2,
		"attuned": [],
		"discoveries": [42],
	}
	var refused_discovery_write: Dictionary = vault_api.call(
		"record_discoveries", malformed_existing, ["starter_cave"])
	if not refused_discovery_write.is_empty():
		_fail("the discovery writer laundered malformed existing progression into a valid v2 vault")
		return

	# 6. Save -> load round-trips.
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

	# 7. persist_attunement() goes through the seam and accumulates a second
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

	# Discovery persistence goes through the same production seam and upgrades
	# the existing v1 vault without losing either attunement.
	if not vault_api.has_method("persist_discoveries"):
		_fail("the baked discovery reader has no production persist_discoveries() path")
		return
	if not bool(vault_api.call(
		"persist_discoveries", ["starter_cave", "wardens_shrine"])):
		_fail("persist_discoveries() failed")
		return
	var with_discoveries = SaveVault.load_saved()
	if with_discoveries is not Dictionary:
		_fail("the persisted discovery vault did not load")
		return
	if int(with_discoveries.get("version", -1)) != 2:
		_fail("the production discovery write did not stamp vault v2")
		return
	if with_discoveries.get("discoveries", []) != ["starter_cave", "wardens_shrine"]:
		_fail("the production discovery write did not survive its disk round-trip")
		return
	if not SaveVault.is_attuned(with_discoveries, SaveVault.SHRINE_WARDENS) \
			or not SaveVault.is_attuned(with_discoveries, "second_shrine"):
		_fail("the production discovery write lost existing attunements")
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
	if int(first.get("version", -1)) != 1 or first.has("discoveries"):
		_fail("a first attunement originated v2 despite carrying no discovery state")
		return

	# 8. save_to() itself refuses to REPLACE an unreadable vault, independently
	# of whatever the caller checked earlier. A caller's can_write() is a
	# point-in-time answer; everything between it and the rename is time in which
	# another process can land a vault this build cannot read. The re-check
	# immediately before the replace is what stops that write destroying it.
	_cleanup_probe()
	SaveVault.clear_refusals_for_test()
	var corrupt := "{ not json at all"
	var raw := FileAccess.open(PROBE, FileAccess.WRITE)
	if raw == null:
		_fail("could not stage the unreadable vault")
		return
	raw.store_string(corrupt)
	raw.close()
	if SaveVault.save_to(PROBE, SaveVault.attune(SaveVault.empty(), SaveVault.SHRINE_WARDENS)):
		_fail("save_to() REPLACED an unreadable vault — a newer client's progression would be destroyed")
		return
	var reread := FileAccess.open(PROBE, FileAccess.READ)
	if reread == null:
		_fail("save_to() removed the unreadable vault it refused to replace")
		return
	var still := reread.get_as_text()
	reread.close()
	if still != corrupt:
		_fail("save_to() altered the unreadable vault (%s)" % still)
		return
	# ...and it left no temp file behind.
	if FileAccess.file_exists(PROBE + ".tmp"):
		_fail("save_to() left its temp file behind after refusing")
		return
	_cleanup_probe()
	SaveVault.clear_refusals_for_test()

	# 8b. The data layer and the behaviour layer must not drift: every name
	# SaveVault claims to know must have a RespawnPoints branch, and vice versa.
	# Without this, a name could be added to the ledger and KNOWN_ATTUNEMENTS
	# while nothing ever restored it — every guard green, the attunement dead.
	var known := SaveVault.KNOWN_ATTUNEMENTS.duplicate()
	var resolvable := RespawnPoints.names().duplicate()
	known.sort()
	resolvable.sort()
	if known != resolvable:
		_fail(("KNOWN_ATTUNEMENTS and RespawnPoints.names() have drifted: %s vs %s — a name that "
			+ "cannot be resolved restores nothing, however green the ledger guards are")
			% [str(known), str(resolvable)])
		return

	# 9. Validation refuses each malformed shape.
	var refusals := {
		"no version": {},
		"non-integer version": { "version": "1" },
		"zero version": { "version": 0 },
		"future version": { "version": SaveVault.VAULT_READ_VERSION + 1 },
		"unknown field": { "version": 1, "loot": {} },
		"discoveries on v1": { "version": 1, "discoveries": [] },
		"attuned not an array": { "version": 1, "attuned": {} },
		"attuned entry not a string": { "version": 1, "attuned": [7] },
		"discoveries not an array": { "version": 2, "discoveries": {} },
		"discovery entry not a string": { "version": 2, "discoveries": [7] },
		"empty discovery name": { "version": 2, "discoveries": [""] },
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
	if SaveVault.validate({ "version": 2, "discoveries": ["starter_cave"] }) != "":
		_fail("validation refused a valid v2 discovery vault")
		return

	_cleanup_probe()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault seam, attunement, discovery contract, round-trip and refusals hold")
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
