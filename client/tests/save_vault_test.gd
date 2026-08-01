extends Node
## Behaviour test for the save vault (issue #249, parent #3) — the progression
## sibling of character_persistence_test. Where save_vault_guard_test pins the
## forward-only LAW against shipped fixtures, this pins the API's behaviour:
##  1. The path seam (WAR_VAULT_PATH) resolves and is inert when unset.
##  2. An empty vault stays v1 even after the v4 writer activates: unrelated
##     state is never rewritten merely to look current, and discovery-only
##     state remains v2.
##  3. attune() is additive, idempotent, and does not mutate its input.
##  4. attune() preserves fields this build does not use (forward-compat).
##  5. A discovery write upgrades v1 to v2 without losing state, while an empty
##     discovery set leaves v1 alone and an existing v2 set only grows.
##  6. Save → load round-trips an attunement.
##  7. All production persistence helpers write through the seam.
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

	# 2. The writer remains on its retained v4 quest contract while the reader
	# expands through v5 mastery. Empty state remains v1: a schema version
	# describes fields actually present; it is not a "latest client" marker.
	var empty := SaveVault.empty()
	if SaveVault.validate(empty) != "":
		_fail("the empty vault does not validate: %s" % SaveVault.validate(empty))
		return
	if SaveVault.VAULT_VERSION != 4:
		_fail("the quest-progress writer is capped at vault v%d; expected the retained v4 contract" % SaveVault.VAULT_VERSION)
		return
	if int(empty["version"]) != 1:
		_fail("an empty vault was churned to v%d even though it carries no v2 discovery state" % int(empty["version"]))
		return
	if SaveVault.VAULT_READ_VERSION != 5:
		_fail("the vault reader ceiling is v%d, expected the v5 mastery expansion"
			% SaveVault.VAULT_READ_VERSION)
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

	# The future v3 reward-claim shape is readable now, and an ordinary
	# attunement write-back preserves both earlier progression sections and the
	# new append-only claim set exactly.
	var reward_expanded := {
		"version": 3,
		"comment": "future exploration reward writer",
		"attuned": [SaveVault.SHRINE_WARDENS],
		"discoveries": ["starter_cave", "wardens_shrine"],
		"reward_claims": ["future_place", "starter_cave"],
	}
	var reward_expanded_reason := SaveVault.validate(reward_expanded)
	if reward_expanded_reason != "":
		_fail("the v3 reward-claim expansion was refused: %s" % reward_expanded_reason)
		return
	var reward_expanded_after := SaveVault.attune(reward_expanded, "second_shrine")
	if reward_expanded_after.get("reward_claims", []) != reward_expanded["reward_claims"]:
		_fail("an ordinary v3 attunement write-back changed or dropped reward claims")
		return
	if reward_expanded_after.get("discoveries", []) != reward_expanded["discoveries"]:
		_fail("an ordinary v3 attunement write-back changed or dropped discovery state")
		return
	if not SaveVault.save_to(PROBE, reward_expanded_after):
		_fail("saving an already-present v3 vault failed")
		return
	var reward_expanded_loaded = SaveVault.load_from(PROBE)
	if reward_expanded_loaded is not Dictionary:
		_fail("the re-saved v3 vault did not load")
		return
	if reward_expanded_loaded.get("reward_claims", []) != reward_expanded["reward_claims"]:
		_fail("the v3 reward-claim set did not survive a disk round-trip")
		return
	var reward_expanded_discovery_write: Dictionary = vault_api.call(
		"record_discoveries", reward_expanded, ["wardens_shrine"])
	if int(reward_expanded_discovery_write.get("version", -1)) != 3:
		_fail("an ordinary discovery write downgraded an already-present v3 vault")
		return
	if reward_expanded_discovery_write.get("reward_claims", []) != reward_expanded["reward_claims"]:
		_fail("an ordinary discovery write changed or dropped v3 reward claims")
		return

	# The future v4 quest-progress shape is readable, but no production writer
	# originates it in this expansion release. Every existing writer must carry
	# the opaque nested ids and counts through without truncating a newer
	# client's progress.
	var quest_expanded := {
		"version": 4,
		"comment": "future quest progress writer",
		"attuned": [SaveVault.SHRINE_WARDENS],
		"discoveries": ["starter_cave", "wardens_shrine"],
		"reward_claims": ["wardens_shrine"],
		"quests": {
			"future_quest": {"future_objective": 11},
			"reach_shrine": {"arrive": 2, "return": 1},
		},
	}
	var quest_expanded_reason := SaveVault.validate(quest_expanded)
	if not quest_expanded_reason.is_empty():
		_fail("the v4 quest-progress expansion was refused: %s" % quest_expanded_reason)
		return
	var quest_expanded_after := SaveVault.attune(quest_expanded, "second_shrine")
	if quest_expanded_after.get("quests", {}) != quest_expanded["quests"]:
		_fail("an ordinary v4 attunement write-back changed or dropped quest progress")
		return
	if not SaveVault.save_to(PROBE, quest_expanded_after):
		_fail("saving an already-present v4 vault failed")
		return
	var quest_expanded_loaded = SaveVault.load_from(PROBE)
	if quest_expanded_loaded is not Dictionary \
			or not _quest_progress_equal(
				quest_expanded_loaded.get("quests", {}), quest_expanded["quests"]):
		_fail("the v4 quest progress did not survive its disk round-trip")
		return
	var quest_expanded_discovery_write: Dictionary = vault_api.call(
		"record_discoveries", quest_expanded, ["starter_cave"])
	if int(quest_expanded_discovery_write.get("version", -1)) != 4 \
			or quest_expanded_discovery_write.get("quests", {}) != quest_expanded["quests"]:
		_fail("an ordinary discovery write downgraded or changed an existing v4 vault")
		return
	var quest_expanded_reward_write: Dictionary = vault_api.call(
		"record_reward_claims", quest_expanded, ["wardens_shrine"])
	if int(quest_expanded_reward_write.get("version", -1)) != 4 \
			or quest_expanded_reward_write.get("quests", {}) != quest_expanded["quests"]:
		_fail("an ordinary reward write downgraded or changed an existing v4 vault")
		return
	if not vault_api.has_method("record_quests"):
		_fail("the retained quest reader has no production record_quests() writer")
		return
	var incoming_quests := {
		"future_quest": {"future_objective": 7, "new_objective": 3},
		"reach_shrine": {"arrive": 3},
		"new_quest": {"step": 1},
	}
	var incoming_copy := incoming_quests.duplicate(true)
	var quest_written: Dictionary = vault_api.call(
		"record_quests", quest_expanded, incoming_quests)
	var expected_quests := {
		"future_quest": {"future_objective": 11, "new_objective": 3},
		"reach_shrine": {"arrive": 3, "return": 1},
		"new_quest": {"step": 1},
	}
	if int(quest_written.get("version", -1)) != 4 \
			or not _quest_progress_equal(quest_written.get("quests", {}), expected_quests):
		_fail("the quest writer did not merge every objective monotonically: %s"
			% str(quest_written))
		return
	if incoming_quests != incoming_copy:
		_fail("record_quests() mutated its caller's snapshot")
		return
	if String(quest_written.get("comment", "")) != "future quest progress writer" \
			or quest_written.get("discoveries", []) != quest_expanded["discoveries"] \
			or quest_written.get("reward_claims", []) != quest_expanded["reward_claims"]:
		_fail("the quest writer dropped an older or unknown accepted field")
		return
	var no_quest_progress: Dictionary = vault_api.call(
		"record_quests", {"version": 1, "attuned": []}, {})
	if int(no_quest_progress.get("version", -1)) != 1 or no_quest_progress.has("quests"):
		_fail("recording no quest progress churned a v1 vault to v4")
		return
	if not (vault_api.call(
		"record_quests", quest_expanded, {"hunt": {"step": -1}})
		as Dictionary).is_empty():
		_fail("the quest writer accepted malformed progress")
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
	if int(discovered.get("version", -1)) != 2 or discovered.has("reward_claims"):
		_fail("the discovery writer originated v3 reward-claim state before its reader baked")
		return
	if not SaveVault.is_attuned(discovered, SaveVault.SHRINE_WARDENS):
		_fail("contracting the discovery writer lost the v1 attunement")
		return
	var no_discoveries: Dictionary = vault_api.call("record_discoveries", legacy, [])
	if int(no_discoveries.get("version", -1)) != 1 or no_discoveries.has("discoveries"):
		_fail("recording no discoveries churned a v1 vault to v2")
		return
	var refused_unknown: Dictionary = vault_api.call(
		"record_discoveries", legacy, ["starter_cvae"])
	if not refused_unknown.is_empty():
		_fail("the writer originated an unregistered discovery typo as permanent progression")
		return
	var expanded_with_future := expanded.duplicate(true)
	(expanded_with_future["discoveries"] as Array).append("future_place")
	var expanded_again: Dictionary = vault_api.call(
		"record_discoveries",
		expanded_with_future,
		["future_place", "starter_cave"])
	if expanded_again.get("discoveries", []) != [
		"future_place", "starter_cave", "wardens_shrine"]:
		_fail("a v2 discovery write replaced or rejected a preserved future name: %s" % str(expanded_again))
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

	# Reward claims are the only operation that contracts a discovery vault to
	# v3. The new place must already be durably discovered, existing and future
	# claims remain append-only, and newly supplied typos are refused.
	if not vault_api.has_method("record_reward_claims"):
		_fail("the retained reward-claim reader has no production record_reward_claims() writer")
		return
	var claimed: Dictionary = vault_api.call(
		"record_reward_claims", expanded, ["wardens_shrine"])
	if int(claimed.get("version", -1)) != 3:
		_fail("recording an exploration reward did not contract the vault to v3")
		return
	if claimed.get("reward_claims", []) != ["wardens_shrine"]:
		_fail("the reward writer did not emit the applied place exactly: %s" % str(claimed))
		return
	if claimed.get("discoveries", []) != expanded["discoveries"]:
		_fail("the reward writer changed or dropped the durable discovery set")
		return
	if not SaveVault.is_attuned(claimed, SaveVault.SHRINE_WARDENS):
		_fail("the reward writer lost an earlier attunement")
		return

	var claims_with_future: Dictionary = vault_api.call(
		"record_reward_claims", reward_expanded, ["wardens_shrine"])
	if claims_with_future.get("reward_claims", []) != [
		"future_place", "starter_cave", "wardens_shrine"]:
		_fail("a v3 reward write replaced or rejected preserved future claims: %s"
			% str(claims_with_future))
		return
	if not (vault_api.call(
		"record_reward_claims", expanded, ["starter_cvae"]) as Dictionary).is_empty():
		_fail("the reward writer originated an unregistered place typo as permanent progression")
		return
	var undiscovered := expanded.duplicate(true)
	undiscovered["discoveries"] = ["starter_cave"]
	if not (vault_api.call(
		"record_reward_claims", undiscovered, ["wardens_shrine"]) as Dictionary).is_empty():
		_fail("the reward writer consumed a place that was not durably discovered")
		return
	var no_claims: Dictionary = vault_api.call("record_reward_claims", expanded, [])
	if int(no_claims.get("version", -1)) != 2 or no_claims.has("reward_claims"):
		_fail("recording no reward claims churned a v2 vault to v3")
		return
	if claimed.has("quests"):
		_fail("the production reward writer originated v4 quest state during reader expansion")
		return
	var malformed_claims := {
		"version": 3,
		"attuned": [],
		"discoveries": ["starter_cave"],
		"reward_claims": [42],
	}
	if not (vault_api.call(
		"record_reward_claims", malformed_claims, ["starter_cave"]) as Dictionary).is_empty():
		_fail("the reward writer laundered malformed existing progression into a valid v3 vault")
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

	if not vault_api.has_method("persist_reward_claims"):
		_fail("the reward-claim writer has no production persistence path")
		return
	if not bool(vault_api.call("persist_reward_claims", ["wardens_shrine"])):
		_fail("persist_reward_claims() failed")
		return
	var with_claims = SaveVault.load_saved()
	if with_claims is not Dictionary:
		_fail("the persisted reward-claim vault did not load")
		return
	if int(with_claims.get("version", -1)) != 3:
		_fail("the production reward write did not stamp vault v3")
		return
	if with_claims.get("reward_claims", []) != ["wardens_shrine"]:
		_fail("the production reward claim did not survive its disk round-trip")
		return
	if with_claims.get("discoveries", []) != ["starter_cave", "wardens_shrine"]:
		_fail("the production reward write lost earlier discoveries")
		return
	if not vault_api.has_method("persist_quests"):
		_fail("the quest-progress writer has no production persistence path")
		return
	if not bool(vault_api.call("persist_quests", {
		"future_quest": {"future_objective": 11},
		"restored_hunt": {"hounds": 3},
	})):
		_fail("persist_quests() failed")
		return
	var with_quests = SaveVault.load_saved()
	if with_quests is not Dictionary \
			or int(with_quests.get("version", -1)) != 4 \
			or not _quest_progress_equal(with_quests.get("quests", {}), {
				"future_quest": {"future_objective": 11},
				"restored_hunt": {"hounds": 3},
			}):
		_fail("the production quest write did not survive its disk round-trip")
		return
	if with_quests.get("discoveries", []) != ["starter_cave", "wardens_shrine"] \
			or with_quests.get("reward_claims", []) != ["wardens_shrine"]:
		_fail("the production quest write lost earlier progression sections")
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
	# ...and it left no staging file behind. Matched by PREFIX, not by the exact
	# name: staging paths carry a per-attempt stamp (SaveVault.WRITE_TMP_SUFFIX),
	# so probing one fixed name would answer "clean" without ever looking at the
	# file a refused write actually created.
	if not _staging_leftovers().is_empty():
		_fail("save_to() left its staging file behind after refusing: %s" % (
			", ".join(_staging_leftovers())))
		return
	_cleanup_probe()
	SaveVault.clear_refusals_for_test()

	# 8a. JSON numbers above 2^53 - 1 are not exact. A raw newer vault that
	# carries 9007199254740993 parses as 9007199254740992; accepting that rounded
	# value would let any ordinary write permanently lower earned progress.
	var unsafe_progress := (
		'{"version":4,"quests":{"future_quest":{"future_step":9007199254740993}}}')
	var unsafe_progress_file := FileAccess.open(PROBE, FileAccess.WRITE)
	if unsafe_progress_file == null:
		_fail("could not stage the unsafe-integer vault")
		return
	unsafe_progress_file.store_string(unsafe_progress)
	unsafe_progress_file.close()
	if SaveVault.load_from(PROBE) is Dictionary:
		_fail("the v4 reader accepted quest progress that JSON already rounded")
		return
	var unsafe_reread := FileAccess.open(PROBE, FileAccess.READ)
	if unsafe_reread == null:
		_fail("refusing unsafe quest progress removed its source document")
		return
	var unsafe_source := unsafe_reread.get_as_text()
	unsafe_reread.close()
	if unsafe_source != unsafe_progress:
		_fail("refusing unsafe quest progress did not preserve its source bytes")
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
		"reward claims on v2": { "version": 2, "reward_claims": [] },
		"quests on v3": { "version": 3, "quests": {} },
		"attuned not an array": { "version": 1, "attuned": {} },
		"attuned entry not a string": { "version": 1, "attuned": [7] },
		"discoveries not an array": { "version": 2, "discoveries": {} },
		"discovery entry not a string": { "version": 2, "discoveries": [7] },
		"empty discovery name": { "version": 2, "discoveries": [""] },
		"reward claims not an array": { "version": 3, "reward_claims": {} },
		"reward claim not a string": { "version": 3, "reward_claims": [7] },
		"empty reward claim": { "version": 3, "reward_claims": [""] },
		"quests not an object": { "version": 4, "quests": [] },
		"empty quest id": { "version": 4, "quests": {"": {"step": 1}} },
		"quest objectives not an object": { "version": 4, "quests": {"hunt": []} },
		"empty objective id": { "version": 4, "quests": {"hunt": {"": 1}} },
		"negative quest progress": { "version": 4, "quests": {"hunt": {"step": -1}} },
		"fractional quest progress": { "version": 4, "quests": {"hunt": {"step": 1.5}} },
		"string quest progress": { "version": 4, "quests": {"hunt": {"step": "1"}} },
		"unsafe JSON integer quest progress": {
			"version": 4,
			"quests": {"hunt": {"step": 9_007_199_254_740_992}},
		},
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
	if SaveVault.validate({
		"version": 3,
		"discoveries": ["starter_cave"],
		"reward_claims": ["starter_cave"],
	}) != "":
		_fail("validation refused a valid v3 reward-claim vault")
		return
	if SaveVault.validate({
		"version": 4,
		"discoveries": ["starter_cave"],
		"reward_claims": ["starter_cave"],
		"quests": {
			"future_quest": {"future_objective": 9},
			"reach_shrine": {"arrive": 1},
		},
	}) != "":
		_fail("validation refused a valid v4 quest-progress vault")
		return

	_cleanup_probe()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault seam, attunement, discovery/reward/quest writers, round-trip and refusals hold")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup_probe()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup_probe()


## JSON parses whole numbers as floats, while in-memory fixtures use ints.
## Compare the schema's numeric meaning while still requiring the exact nested
## key set: no quest, objective, or progress amount may be changed or dropped.
func _quest_progress_equal(actual: Variant, expected: Dictionary) -> bool:
	if actual is not Dictionary or (actual as Dictionary).size() != expected.size():
		return false
	for quest_id: String in expected:
		if not (actual as Dictionary).has(quest_id):
			return false
		var actual_objectives: Variant = (actual as Dictionary)[quest_id]
		var expected_objectives: Dictionary = expected[quest_id]
		if actual_objectives is not Dictionary \
				or (actual_objectives as Dictionary).size() != expected_objectives.size():
			return false
		for objective_id: String in expected_objectives:
			if not (actual_objectives as Dictionary).has(objective_id) \
					or int((actual_objectives as Dictionary)[objective_id]) \
						!= int(expected_objectives[objective_id]):
				return false
	return true


func _cleanup_probe() -> void:
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))
	for leftover: String in _staging_leftovers():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))


## Every staging file beside the probe. Staging paths carry a per-attempt stamp,
## so they cannot be reconstructed by name — scan the directory for the prefix.
func _staging_leftovers() -> Array:
	var parent := PROBE.get_base_dir()
	var prefix := PROBE.get_file() + SaveVault.WRITE_TMP_SUFFIX
	var found: Array = []
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			found.append(parent.path_join(entry))
	return found
