extends Node
## Regression test for the UpdateDecision core (issue #61) — the brain of client
## self-update (docs/design/distribution-and-self-update.md).
##
## This is the one place every forward-only / no-stranding guarantee of the
## product law (no hard resets; an early player keeps playing as it evolves) is
## pinned: a downgrade is never proposed, a pack never applies onto too-old a
## shell, an unresolvable incompatibility is surfaced LOUDLY instead of stranding
## the player, and a malformed manifest is refused without a crash. Pure logic —
## no network, no disk, no scene, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/update_decision_test.tscn

var _failed := false


# A complete, valid manifest whose latest build == `installed_current`, so each
# case perturbs one thing from a known-good baseline.
func _base_manifest() -> Dictionary:
	return {
		"schema": 1,
		"channel": "live",
		"shell": {"current": "0.1.14", "min_supported": "0.1.0", "reads_min": 1, "reads_capability_max": 9},
		"pack": {"version": "0.1.14", "min_shell": "0.1.14", "url": "x", "sha256": "y", "size": 0},
		"protocol": {"min": 1, "max": 1},
		"save_schema": {"min": 1, "writes": 1, "capability": 1},
		"signature": "sig",
	}


# A WELL-FORMED rollback catalogue entry, carrying every field
# RollbackSelection.is_wellformed requires — the forward gate shares that exact
# predicate, so a shorthand fixture would be skipped as unselectable rather than
# testing what it looks like it tests.
func _target(version: String, capability: int, read_ceiling: int) -> Dictionary:
	return {
		"version": version,
		"url": "https://updates.example/pack-%s.pck" % version,
		"sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"size": 0,
		"read_ceiling": read_ceiling,
		"save_capability": capability,
		"speaks_protocol": {"min": 1, "max": 1},
		"shell_compat": {"min": "0.1.0", "max": "0.1.999"},
	}


func _installed_current() -> Dictionary:
	return {"shell_version": "0.1.14", "pack_version": "0.1.14", "save_schema": 1, "save_capability": 1, "protocol": 1}


func _ready() -> void:
	_test_up_to_date()
	_test_pack_update()
	_test_pack_needs_newer_shell()
	_test_shell_below_floor()
	_test_only_shell_newer()
	_test_forward_only_no_downgrade()
	_test_numeric_version_ordering()
	_test_blocked_when_unresolvable()
	_test_incompatible_but_updatable_steers_to_update()
	_test_client_ahead_of_server_is_tolerated()
	_test_save_too_old_always_blocks()
	_test_channel_mismatch_refused()
	_test_unpinned_channel_defaults_to_live()
	_test_shell_only_update_write_regression_refused()
	_test_shell_update_blocked_when_target_cant_read_save()
	_test_future_schema_shell_blocked_when_cant_read_save()
	_test_schema_too_new_updates_shell()
	_test_future_schema_without_newer_shell_refused()
	_test_pack_needs_shell_beyond_advertised_refused()
	_test_pack_write_schema_hazard_routes_to_shell()
	_test_pack_write_schema_regression_refused()
	_test_schema_too_new_ignores_broken_body()
	_test_schema_below_supported_refused()
	_test_pack_update_requires_write_schema()
	_test_pack_update_requires_capability()
	_test_capability_raise_needs_a_readable_rollback_target()
	_test_incoherent_shell_floor_refused()
	_test_fractional_identifiers_refused()
	_test_malformed_manifests_refuse_cleanly()
	if _failed:
		return
	print("TEST PASS — update-decision core upholds forward-only, no-stranding, clean-refusal laws")
	get_tree().quit(0)


func _test_up_to_date() -> void:
	_expect(_installed_current(), _base_manifest(), UpdateDecision.UP_TO_DATE, "on the latest build")


func _test_pack_update() -> void:
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15" # min_shell stays 0.1.14 == installed shell
	_expect(_installed_current(), m, UpdateDecision.PACK_UPDATE, "a newer pack that runs on the current shell")


func _test_pack_needs_newer_shell() -> void:
	var m := _base_manifest()
	m["pack"]["version"] = "0.2.0"
	m["pack"]["min_shell"] = "0.2.0" # needs a shell newer than the installed 0.1.14
	m["shell"]["current"] = "0.2.0"
	_expect(_installed_current(), m, UpdateDecision.SHELL_UPDATE, "a pack needing a newer shell defers to the shell")


func _test_shell_below_floor() -> void:
	var m := _base_manifest()
	m["shell"]["min_supported"] = "0.1.10"
	var inst := _installed_current()
	inst["shell_version"] = "0.1.5" # below the floor
	inst["pack_version"] = "0.1.5"
	_expect(inst, m, UpdateDecision.SHELL_UPDATE, "a shell below the supported floor must update")


func _test_only_shell_newer() -> void:
	var m := _base_manifest()
	m["shell"]["current"] = "0.1.15" # pack unchanged
	_expect(_installed_current(), m, UpdateDecision.SHELL_UPDATE, "only the shell is newer")


func _test_forward_only_no_downgrade() -> void:
	# A manifest advertising OLDER artifacts than installed must never propose a
	# downgrade — the core of the no-resets law.
	var m := _base_manifest()
	m["shell"]["current"] = "0.1.10"
	m["pack"]["version"] = "0.1.10"
	m["pack"]["min_shell"] = "0.1.10"
	_expect(_installed_current(), m, UpdateDecision.UP_TO_DATE, "older manifest is never a downgrade")


func _test_numeric_version_ordering() -> void:
	# The classic trap: "0.1.9" < "0.1.10" numerically, not lexically. If compare
	# were lexical, this would wrongly read as up_to_date.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.10"
	var inst := _installed_current()
	inst["pack_version"] = "0.1.9"
	_expect(inst, m, UpdateDecision.PACK_UPDATE, "0.1.9 -> 0.1.10 is an update, not lexical no-op")
	# And the reverse holds: installed 0.1.10 vs manifest 0.1.9 is not a downgrade.
	var m2 := _base_manifest()
	m2["pack"]["version"] = "0.1.9"
	var inst2 := _installed_current()
	inst2["pack_version"] = "0.1.10"
	_expect(inst2, m2, UpdateDecision.UP_TO_DATE, "0.1.10 vs 0.1.9 is not a downgrade")


func _test_blocked_when_unresolvable() -> void:
	# On the newest build, yet still below the live world's needs, with nothing to
	# update to → a loud block, never a silent strand.
	var m := _base_manifest()
	m["protocol"] = {"min": 2, "max": 2} # server needs protocol >= 2
	var inst := _installed_current() # protocol 1, already on the latest pack+shell
	_expect(inst, m, UpdateDecision.BLOCKED_INCOMPATIBLE, "protocol too old and nothing to update to")

	var m2 := _base_manifest()
	m2["save_schema"] = {"min": 2, "writes": 2, "capability": 1} # server needs save schema >= 2
	_expect(_installed_current(), m2, UpdateDecision.BLOCKED_INCOMPATIBLE, "save schema too old and nothing to update to")


func _test_incompatible_but_updatable_steers_to_update() -> void:
	# Incompatible today, but a newer pack is available and runs on the current
	# shell → steer to the pack update (which carries the fix), never block.
	var m := _base_manifest()
	m["protocol"] = {"min": 2, "max": 2}
	m["pack"]["version"] = "0.1.15" # newer pack, min_shell 0.1.14 == installed
	_expect(_installed_current(), m, UpdateDecision.PACK_UPDATE, "incompatible but a pack update resolves it")


func _test_client_ahead_of_server_is_tolerated() -> void:
	# Client protocol ABOVE the accepted range = ahead of a mid-rollout server.
	# A transient: never blocked, never forced to update further ahead.
	var m := _base_manifest()
	m["protocol"] = {"min": 1, "max": 1}
	var inst := _installed_current()
	inst["protocol"] = 2 # ahead of the server's max
	_expect(inst, m, UpdateDecision.UP_TO_DATE, "client ahead of a lagging server is tolerated")


func _test_save_too_old_always_blocks() -> void:
	# A save below the lowest schema the current build can read cannot be read by
	# ANY advertised update, so even with a newer pack available it is a loud block,
	# never routed to an update that cannot read the save.
	var m := _base_manifest()
	m["save_schema"] = {"min": 2, "writes": 2, "capability": 1} # current builds read >= schema 2
	m["pack"]["version"] = "0.1.15" # a newer pack IS available
	var inst := _installed_current() # save_schema 1 — below the read floor
	_expect(inst, m, UpdateDecision.BLOCKED_INCOMPATIBLE, "a save below the read floor blocks even with an update available")


func _test_channel_mismatch_refused() -> void:
	# A validly-signed manifest for a different channel must never enroll the player
	# (default-off opt-in). A mismatch is refused; an unpinned installed channel accepts.
	var m := _base_manifest() # channel "live"
	m["pack"]["version"] = "0.1.15"
	var inst := _installed_current()
	inst["channel"] = "beta" # player is on beta, manifest is live
	_expect(inst, m, UpdateDecision.INVALID_MANIFEST, "a manifest from a different channel is refused")
	# Matching channel proceeds normally.
	var inst2 := _installed_current()
	inst2["channel"] = "live"
	_expect(inst2, m, UpdateDecision.PACK_UPDATE, "a matching channel proceeds")


func _test_shell_update_blocked_when_target_cant_read_save() -> void:
	# A shell update whose target build reads saves only from a schema ABOVE the
	# installed save would strand it — block, never propose the update.
	var m := _base_manifest()
	m["shell"]["current"] = "0.2.0" # a newer shell...
	m["shell"]["reads_min"] = 2 # ...that reads saves only from schema 2
	# installed save is schema 1 — the newer shell cannot read it.
	_expect(_installed_current(), m, UpdateDecision.BLOCKED_INCOMPATIBLE, "a shell update that can't read the installed save is blocked")


func _test_future_schema_shell_blocked_when_cant_read_save() -> void:
	# The same guard holds for a schema we cannot parse: reads_min in the stable
	# envelope lets us block a stranding future-schema shell update.
	var m := {
		"schema": 2,
		"channel": "live",
		"shell": {"current": "0.2.0", "min_supported": "0.1.0", "reads_min": 2, "reads_capability_max": 9},
	}
	_expect(_installed_current(), m, UpdateDecision.BLOCKED_INCOMPATIBLE, "a future-schema shell update that can't read the installed save is blocked")


func _test_unpinned_channel_defaults_to_live() -> void:
	# A fresh install with no pinned channel must fail closed to `live`: it accepts
	# a live manifest but refuses a beta one (default-off opt-in).
	var beta := _base_manifest()
	beta["channel"] = "beta"
	beta["pack"]["version"] = "0.1.15"
	_expect(_installed_current(), beta, UpdateDecision.INVALID_MANIFEST, "unpinned channel refuses a beta manifest (defaults to live)")
	# The same unpinned install accepts a live manifest.
	_expect(_installed_current(), _base_manifest(), UpdateDecision.UP_TO_DATE, "unpinned channel accepts the live manifest")


func _test_shell_only_update_write_regression_refused() -> void:
	# The save-write-regression guard applies to a shell-only update too, not just a
	# pack: a newer shell that writes an older save schema than installed is refused.
	var m := _base_manifest()
	m["shell"]["current"] = "0.2.0" # only the shell is newer
	m["save_schema"] = {"min": 1, "writes": 2, "capability": 1}
	var inst := _installed_current()
	inst["save_schema"] = 4
	inst["save_reads_max"] = 4
	_expect(inst, m, UpdateDecision.INVALID_MANIFEST, "a shell-only update writing below the installed save schema is refused")


func _test_schema_too_new_updates_shell() -> void:
	var m := _base_manifest()
	m["schema"] = 2 # newer than SUPPORTED_MANIFEST_SCHEMA
	m["shell"]["current"] = "0.2.0" # advertises a shell newer than the installed 0.1.14
	_expect(_installed_current(), m, UpdateDecision.SHELL_UPDATE, "a newer schema with a newer shell updates the shell")


func _test_future_schema_without_newer_shell_refused() -> void:
	# A stale/cross-channel future-schema manifest advertising an equal-or-older
	# shell must be refused, never followed to a downgrade or an endless reinstall.
	var m := _base_manifest()
	m["schema"] = 2
	m["shell"]["current"] = "0.1.14" # NOT newer than installed 0.1.14
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "future schema with no newer shell is refused, not a downgrade")


func _test_pack_needs_shell_beyond_advertised_refused() -> void:
	# A manifest whose pack needs a shell newer than the newest shell it offers
	# would loop a client through shell updates forever — refuse it.
	var m := _base_manifest()
	m["pack"]["version"] = "0.2.0"
	m["pack"]["min_shell"] = "0.3.0" # beyond the advertised shell.current 0.1.14
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "pack needing a shell beyond the advertised one is refused (no loop)")


func _test_pack_write_schema_hazard_routes_to_shell() -> void:
	# Hazard + a genuinely newer shell → route to the shell tier.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15"
	m["shell"]["current"] = "0.2.0" # a genuinely newer shell to route to
	m["save_schema"] = {"min": 1, "writes": 4, "capability": 1} # writes v4
	var inst := _installed_current()
	inst["save_reads_max"] = 3 # installed build reads only up to v3
	_expect(inst, m, UpdateDecision.SHELL_UPDATE, "a pack writing beyond the read ceiling rides the newer shell")
	# Hazard but NO newer shell advertised → refuse, never follow to a downgrade.
	var m3 := _base_manifest()
	m3["pack"]["version"] = "0.1.15" # shell.current stays 0.1.14 == installed
	m3["save_schema"] = {"min": 1, "writes": 4, "capability": 1}
	var inst3 := _installed_current()
	inst3["save_reads_max"] = 3
	_expect(inst3, m3, UpdateDecision.INVALID_MANIFEST, "a write-hazard with no newer shell is refused, not a downgrade")
	# Safe case: writes within the read ceiling → a plain pack update.
	var m2 := _base_manifest()
	m2["pack"]["version"] = "0.1.15"
	m2["save_schema"] = {"min": 1, "writes": 3, "capability": 1}
	var inst2 := _installed_current()
	inst2["save_reads_max"] = 3
	_expect(inst2, m2, UpdateDecision.PACK_UPDATE, "a pack writing within the read ceiling is a plain pack update")


func _test_pack_write_schema_regression_refused() -> void:
	# A newer pack that WRITES an older save schema than the installed build must be
	# refused — applying it would regress the save format and drop intervening state.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15"
	m["save_schema"] = {"min": 1, "writes": 2, "capability": 1}
	var inst := _installed_current()
	inst["save_schema"] = 4
	inst["save_reads_max"] = 4
	_expect(inst, m, UpdateDecision.INVALID_MANIFEST, "a pack writing below the installed save schema is refused (no regression)")


func _test_schema_too_new_ignores_broken_body() -> void:
	# The envelope (schema + shell) must be read BEFORE the schema-specific body.
	# A schema-2 manifest that restructured/removed body fields must still route an
	# old client to a shell update via the envelope — never invalid_manifest, which
	# would strand it. (Codex P0.)
	var m := {
		"schema": 2,
		"channel": "live",
		"shell": {"current": "0.2.0", "min_supported": "0.1.0", "reads_min": 1, "reads_capability_max": 9},
		"future_field": {"restructured": true}, # no schema-1 pack/protocol/save at all
	}
	_expect(_installed_current(), m, UpdateDecision.SHELL_UPDATE, "newer schema with a valid envelope still routes to a shell update")


func _test_schema_below_supported_refused() -> void:
	# A schema below the one this client understands (0, negative) is stale/malformed
	# and must be refused, never parsed with the wrong schema-1 field semantics.
	_expect(_installed_current(), _with(_base_manifest(), "schema", 0), UpdateDecision.INVALID_MANIFEST, "schema 0 is refused")
	_expect(_installed_current(), _with(_base_manifest(), "schema", -1), UpdateDecision.INVALID_MANIFEST, "negative schema is refused")


func _test_pack_update_requires_write_schema() -> void:
	# `save_schema.writes` drives rollback-safety routing, so a manifest that omits
	# it must fail closed (invalid), never silently allow a possibly-stranding pack.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15" # a pack update would otherwise apply
	m["save_schema"] = {"min": 1} # writes omitted
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "a manifest omitting save_schema.writes fails closed")


func _test_pack_update_requires_capability() -> void:
	# `save_schema.capability` drives the same-schema stranding gate below, so a
	# manifest omitting it must fail closed exactly like one omitting `writes`.
	# Without it there is no way to prove a rollback target could read what the
	# candidate writes, and an assumed-safe default is how a player gets stranded.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15" # a pack update would otherwise apply
	m["save_schema"] = {"min": 1, "writes": 1} # capability omitted
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "a manifest omitting save_schema.capability fails closed")
	# A malformed capability is refused on the same grounds as a missing one.
	m["save_schema"] = {"min": 1, "writes": 1, "capability": -1}
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "a negative save_schema.capability is refused")
	m["save_schema"] = {"min": 1, "writes": 1, "capability": 2.5}
	_expect(_installed_current(), m, UpdateDecision.INVALID_MANIFEST, "a fractional save_schema.capability is refused")


func _test_capability_raise_needs_a_readable_rollback_target() -> void:
	# THE STRANDING CASE (#120). A same-schema content expansion keeps `writes`
	# inside the rollback target's read ceiling while raising `capability`. The
	# writes/reads_max check therefore passes it, and if the pack then fails its
	# boot health check, RollbackSelection finds no target whose `save_capability`
	# covers the save the pack already wrote — the forward path admitted a state
	# the recovery path cannot undo.
	var raising := func() -> Dictionary:
		var m := _base_manifest()
		m["pack"]["version"] = "0.1.15" # a pack update is on offer
		m["shell"]["current"] = "0.1.15" # ...and a newer shell exists to route to
		# Same schema (writes 1 == installed, well inside the read ceiling), but the
		# capability rises 1 -> 5. Only the capability axis moves.
		m["save_schema"] = {"min": 1, "writes": 1, "capability": 5}
		return m

	# No catalogue at all: unprovable, so it must not ride the pack tier.
	_expect(_installed_current(), raising.call(), UpdateDecision.SHELL_UPDATE, "a capability-raising pack with no rollback catalogue routes to the shell tier")

	# A catalogue that cannot read the raised capability is no better than none.
	var short_target: Dictionary = raising.call()
	short_target["rollback_targets"] = [_target("0.1.14", 4, 9)]
	_expect(_installed_current(), short_target, UpdateDecision.SHELL_UPDATE, "a rollback target one capability short still routes to the shell tier")

	# A malformed entry must not be counted as cover (fail closed).
	var malformed: Dictionary = raising.call()
	malformed["rollback_targets"] = [{"version": "0.1.14", "save_capability": "lots"}, {"read_ceiling": 9}]
	_expect(_installed_current(), malformed, UpdateDecision.SHELL_UPDATE, "a malformed rollback entry never counts as capability cover")

	# CODEX P0: ample capability but a read ceiling BELOW the save's schema is NOT
	# cover. RollbackSelection._is_reachable requires read_ceiling >= save_schema
	# AND save_capability >= the save's, so judging capability alone would count an
	# entry that recovery itself would reject. An entry missing read_ceiling
	# entirely is equally unprovable.
	var low_ceiling: Dictionary = raising.call()
	low_ceiling["rollback_targets"] = [_target("0.1.14", 9, 0)]
	_expect(_installed_current(), low_ceiling, UpdateDecision.SHELL_UPDATE, "capability cover with a read ceiling below the save schema is not cover")
	var no_ceiling: Dictionary = raising.call()
	no_ceiling["rollback_targets"] = [{"version": "0.1.14", "save_capability": 9}]
	_expect(_installed_current(), no_ceiling, UpdateDecision.SHELL_UPDATE, "a target without a verifiable read_ceiling is not cover")

	# CODEX P0: the candidate cannot be its own rollback cover — after a failed boot
	# that version is quarantined, so recovery will skip it. A numeric ALIAS of the
	# candidate ("0.1.15.0") must be excluded on the same grounds.
	var self_cover: Dictionary = raising.call()
	self_cover["rollback_targets"] = [_target("0.1.15", 9, 9)]
	_expect(_installed_current(), self_cover, UpdateDecision.SHELL_UPDATE, "the candidate pack is not its own rollback cover")
	var alias_cover: Dictionary = raising.call()
	alias_cover["rollback_targets"] = [_target("0.1.15.0", 9, 9)]
	_expect(_installed_current(), alias_cover, UpdateDecision.SHELL_UPDATE, "a numeric alias of the candidate is not rollback cover either")
	var newer_cover: Dictionary = raising.call()
	newer_cover["rollback_targets"] = [_target("0.1.16", 9, 9)]
	_expect(_installed_current(), newer_cover, UpdateDecision.SHELL_UPDATE, "a target NEWER than the candidate is not a rollback either")

	# An unidentifiable target cannot be proven distinct from the candidate.
	var no_version: Dictionary = raising.call()
	no_version["rollback_targets"] = [{"save_capability": 9, "read_ceiling": 9}]
	_expect(_installed_current(), no_version, UpdateDecision.SHELL_UPDATE, "a target without a verifiable version is not cover")

	# CODEX P1: cover must be judged against the schema the CANDIDATE WILL WRITE, not
	# the installed one. A pack raising writes 1 -> 3 (still inside the installed
	# read ceiling) plus capability leaves the save at schema 3; a target whose
	# read_ceiling is 2 covers the OLD schema but would be rejected by recovery.
	var raises_writes: Dictionary = raising.call()
	raises_writes["save_schema"] = {"min": 1, "writes": 3, "capability": 5}
	var inst_wide := _installed_current()
	inst_wide["save_reads_max"] = 9 # writes 3 stays inside the installed ceiling
	raises_writes["rollback_targets"] = [_target("0.1.14", 9, 2)]
	_expect(inst_wide, raises_writes, UpdateDecision.SHELL_UPDATE, "cover is judged against the candidate's write schema, not the installed one")
	# ...and a ceiling that DOES cover the new write schema is cover.
	var raises_ok: Dictionary = raising.call()
	raises_ok["save_schema"] = {"min": 1, "writes": 3, "capability": 5}
	raises_ok["rollback_targets"] = [_target("0.1.14", 9, 3)]
	_expect(inst_wide, raises_ok, UpdateDecision.PACK_UPDATE, "a ceiling covering the candidate's write schema is cover")

	# CODEX P1: a target already in the local quarantine ledger is not cover —
	# recovery skips quarantined versions before testing reachability, so its only
	# fallback would be a build already proven broken.
	var quarantined: Dictionary = raising.call()
	quarantined["rollback_targets"] = [_target("0.1.14", 9, 9)]
	var inst_q := _installed_current()
	inst_q["quarantined"] = ["0.1.14"]
	_expect(inst_q, quarantined, UpdateDecision.SHELL_UPDATE, "a quarantined target is not rollback cover")
	# The ledger match is NUMERIC, so an alias of the quarantined build is excluded.
	var inst_alias := _installed_current()
	inst_alias["quarantined"] = ["0.1.14.0"]
	_expect(inst_alias, quarantined, UpdateDecision.SHELL_UPDATE, "a numeric alias of a quarantined version is excluded too")
	# A present-but-unreadable ledger must not read as "nothing is quarantined".
	var inst_bad := _installed_current()
	inst_bad["quarantined"] = [42]
	_expect(inst_bad, quarantined, UpdateDecision.SHELL_UPDATE, "an unreadable quarantine ledger blocks rather than counting cover")

	# CODEX P2: an unverifiable installed capability is a loud block, never a
	# defaulted 0 — a pre-field save carries a REAL capability, and reading it as 0
	# would let a lower-capability candidate through the forward-only check.
	var inst_nocap := _installed_current()
	inst_nocap.erase("save_capability")
	_expect(inst_nocap, _base_manifest(), UpdateDecision.BLOCKED_INCOMPATIBLE, "a missing installed save_capability blocks loudly rather than defaulting to 0")
	var inst_badcap := _installed_current()
	inst_badcap["save_capability"] = "lots"
	_expect(inst_badcap, _base_manifest(), UpdateDecision.BLOCKED_INCOMPATIBLE, "a malformed installed save_capability blocks loudly")
	# CODEX P0 (round 4): and it blocks on EVERY route, including the future-schema
	# path, which routes to a shell update from the stable envelope alone — an
	# envelope that carries no capability proof at all.
	var future := _base_manifest()
	future["schema"] = UpdateDecision.SUPPORTED_MANIFEST_SCHEMA + 1
	future["shell"]["current"] = "0.2.0" # a newer shell IS offered
	_expect(_installed_current(), future, UpdateDecision.SHELL_UPDATE, "sanity: a future-schema manifest with a newer shell still routes to a shell update")
	_expect(inst_nocap, future, UpdateDecision.BLOCKED_INCOMPATIBLE, "an unverifiable capability blocks the future-schema shell route too")

	# CODEX P0 (rounds 5-6): the envelope needs a CAPABILITY bound, and it is a
	# CEILING, not a floor. Capability counts shapes PRESENT in the save, so the
	# hazard is a save holding a shape the build does not understand — mirroring
	# RollbackSelection._is_reachable, which accepts a target only when its
	# save_capability is at least the save's. (reads_min is genuinely a floor; the
	# two axes are not interchangeable, which is the error round 6 caught.) The
	# future-schema route decides from the envelope ALONE, so a bound living only in
	# the parseable body would be absent exactly where the client understands least.
	var inst_cap5 := _installed_current()
	inst_cap5["save_capability"] = 5
	var high_floor := _base_manifest()
	high_floor["shell"]["current"] = "0.1.15"
	high_floor["save_schema"] = {"min": 1, "writes": 1, "capability": 5} # no regression: clears the forward-only check
	high_floor["shell"]["reads_capability_max"] = 4 # shell understands shapes only up to capability 4
	_expect(inst_cap5, high_floor, UpdateDecision.BLOCKED_INCOMPATIBLE, "a shell understanding fewer shapes than the save holds blocks rather than stranding it")
	# ...on the future-schema (envelope-only) route as well, which is the whole point.
	var future_high := _base_manifest()
	future_high["schema"] = UpdateDecision.SUPPORTED_MANIFEST_SCHEMA + 1
	future_high["shell"]["current"] = "0.2.0"
	future_high["shell"]["reads_capability_max"] = 4
	_expect(inst_cap5, future_high, UpdateDecision.BLOCKED_INCOMPATIBLE, "the capability ceiling is enforced on the envelope-only future-schema route")
	# A floor the save clears is fine — proving the guard discriminates.
	var ok_floor := _base_manifest()
	ok_floor["shell"]["current"] = "0.1.15"
	ok_floor["save_schema"] = {"min": 1, "writes": 1, "capability": 5}
	ok_floor["shell"]["reads_capability_max"] = 5 # understands exactly what the save holds — inclusive boundary
	_expect(inst_cap5, ok_floor, UpdateDecision.SHELL_UPDATE, "a shell understanding every shape the save holds is a normal shell update")
	# The envelope field is REQUIRED: absent would read as 0 and clear every save.
	var no_floor := _base_manifest()
	no_floor["shell"].erase("reads_capability_max")
	_expect(_installed_current(), no_floor, UpdateDecision.INVALID_MANIFEST, "a manifest without shell.reads_capability_max fails closed")

	# CODEX P1 (round 3): a target reachable on both axes is still not cover if the
	# SELECTOR would skip it. RollbackSelection.is_wellformed also requires artifact
	# metadata and the shape of speaks_protocol / shell_compat — all static manifest
	# data, so it is decidable here. Each case strips exactly one required field from
	# an otherwise-covering target, so a failure can only mean that field.
	for missing: String in ["url", "sha256", "size", "speaks_protocol", "shell_compat"]:
		var unselectable: Dictionary = raising.call()
		var t := _target("0.1.14", 9, 9)
		t.erase(missing)
		unselectable["rollback_targets"] = [t]
		_expect(_installed_current(), unselectable, UpdateDecision.SHELL_UPDATE,
			"a target missing '%s' is not selectable, so it is not cover" % missing)
	# A malformed (not merely absent) sub-shape is equally unselectable.
	var bad_shape: Dictionary = raising.call()
	var t_bad := _target("0.1.14", 9, 9)
	t_bad["speaks_protocol"] = {"min": 5, "max": 1} # inverted range
	bad_shape["rollback_targets"] = [t_bad]
	_expect(_installed_current(), bad_shape, UpdateDecision.SHELL_UPDATE, "a target with an inverted protocol range is not cover")

	# CODEX P0 (round 4): a target that cannot RUN right now is known-bad now, just
	# like a quarantined one, so it is not cover — even though future runnability
	# cannot be guaranteed. Both halves of is_runnable are covered.
	var no_overlap: Dictionary = raising.call()
	var t_proto := _target("0.1.14", 9, 9)
	t_proto["speaks_protocol"] = {"min": 7, "max": 9} # manifest protocol is 1..1
	no_overlap["rollback_targets"] = [t_proto]
	_expect(_installed_current(), no_overlap, UpdateDecision.SHELL_UPDATE, "a target whose protocol range misses the accepted one is not cover")
	var bad_shell: Dictionary = raising.call()
	var t_shell := _target("0.1.14", 9, 9)
	t_shell["shell_compat"] = {"min": "0.9.0", "max": "0.9.9"} # installed shell is 0.1.14
	bad_shell["rollback_targets"] = [t_shell]
	_expect(_installed_current(), bad_shell, UpdateDecision.SHELL_UPDATE, "a target excluding the installed shell is not cover")

	# CODEX P0 (round 4): a PRESENT-but-corrupt `quarantined: null` is malformed, not
	# first boot. RollbackSelection keys on `has`, so the forward path must too.
	var null_ledger: Dictionary = raising.call()
	null_ledger["rollback_targets"] = [_target("0.1.14", 9, 9)]
	var inst_null := _installed_current()
	inst_null["quarantined"] = null
	_expect(inst_null, null_ledger, UpdateDecision.SHELL_UPDATE, "a present-but-null quarantine ledger is malformed, not first boot")

	# An unverifiable installed shell cannot prove runnability, so it is not cover.
	var no_shell_ver: Dictionary = raising.call()
	no_shell_ver["rollback_targets"] = [_target("0.1.14", 9, 9)]
	var inst_noshell := _installed_current()
	inst_noshell["shell_version"] = "garbage"
	_expect(inst_noshell, no_shell_ver, UpdateDecision.SHELL_UPDATE, "an unverifiable installed shell means no target can be proven runnable")

	# POSITIVE CONTROL: one strictly-older target reachable on BOTH axes makes the
	# pack safe again. This is what proves the gate discriminates rather than simply
	# blocking every capability raise — without it, every case above would pass
	# equally against a gate that refused unconditionally.
	var covered: Dictionary = raising.call()
	covered["rollback_targets"] = [_target("0.1.13", 4, 9), _target("0.1.14", 5, 9)]
	_expect(_installed_current(), covered, UpdateDecision.PACK_UPDATE, "a strictly-older target reachable on both axes admits the pack")

	# A pack that does NOT raise the capability is untouched by this gate — the
	# installed build is its own rollback target on this axis.
	var level: Dictionary = raising.call()
	level["save_schema"] = {"min": 1, "writes": 1, "capability": 1}
	_expect(_installed_current(), level, UpdateDecision.PACK_UPDATE, "a pack holding the capability level still applies without a catalogue")

	# With no newer shell to route to, refuse rather than follow a stale manifest
	# into a downgrade — mirroring the read-ceiling branch.
	var no_shell: Dictionary = raising.call()
	no_shell["shell"]["current"] = "0.1.14" # == installed, nothing newer
	_expect(_installed_current(), no_shell, UpdateDecision.INVALID_MANIFEST, "a capability-raising pack with no newer shell is refused, never downgraded")

	# CODEX P0: forward-only applies to the capability axis in BOTH directions. A
	# candidate writing a capability BELOW the installed build's cannot read the
	# shapes the save already holds, so it is refused before routing to any tier —
	# the exact rule the `writes < save_schema` check already enforces on the
	# schema axis. Without this it fell straight through to pack_update.
	var regress: Dictionary = raising.call()
	regress["save_schema"] = {"min": 1, "writes": 1, "capability": 4}
	var inst_high := _installed_current()
	inst_high["save_capability"] = 5 # the save already holds capability-5 shapes
	_expect(inst_high, regress, UpdateDecision.INVALID_MANIFEST, "a candidate writing a capability below the installed build's is refused (forward-only)")
	# ...and it is refused on the SHELL path too, not just the pack path.
	var regress_shell: Dictionary = raising.call()
	regress_shell["pack"]["version"] = "0.1.14" # no pack update; only the shell is newer
	regress_shell["save_schema"] = {"min": 1, "writes": 1, "capability": 4}
	_expect(inst_high, regress_shell, UpdateDecision.INVALID_MANIFEST, "a capability regression is refused on the shell path too")


func _test_incoherent_shell_floor_refused() -> void:
	# An incoherent manifest whose advertised shell is below its own floor must be
	# refused, not followed to a downgrade. (Codex P0.)
	var m := _base_manifest()
	m["shell"] = {"current": "1.0.0", "min_supported": "3.0.0", "reads_min": 1, "reads_capability_max": 9} # current below its own floor
	var inst := _installed_current()
	inst["shell_version"] = "2.0.0"
	_expect(inst, m, UpdateDecision.INVALID_MANIFEST, "shell.current below its own floor is refused, never a downgrade")


func _test_fractional_identifiers_refused() -> void:
	# Discrete identifiers must reject fractional values so int() never silently
	# truncates a wrong decision; an integral float (1.0) is still accepted. (Codex P1.)
	_expect(_installed_current(), _with(_base_manifest(), "schema", 1.5), UpdateDecision.INVALID_MANIFEST, "fractional schema 1.5 is refused")
	_expect(_installed_current(), _with(_base_manifest(), "protocol", {"min": 1.9, "max": 3}), UpdateDecision.INVALID_MANIFEST, "fractional protocol.min 1.9 is refused")
	_expect(_installed_current(), _with(_base_manifest(), "save_schema", {"min": 2.5}), UpdateDecision.INVALID_MANIFEST, "fractional save_schema.min 2.5 is refused")
	# An integral JSON float must still be accepted (JSON parsing may yield 1.0).
	_expect(_installed_current(), _with(_base_manifest(), "schema", 1.0), UpdateDecision.UP_TO_DATE, "integral float schema 1.0 is accepted")


func _test_malformed_manifests_refuse_cleanly() -> void:
	# Each of these must return invalid_manifest — no crash, no strand.
	var bad: Array[Dictionary] = [
		{},
		{"schema": "one"}, # non-numeric schema
		{"schema": 1, "shell": {"current": "0.1.14"}}, # missing pack/protocol/save
		_with(_base_manifest(), "shell", {"current": "abc", "min_supported": "0.1.0"}), # bad version
		_with(_base_manifest(), "protocol", {"min": 5, "max": 1}), # min > max
		_with(_base_manifest(), "pack", {"version": "0.1.14"}), # pack missing min_shell
		_with(_base_manifest(), "save_schema", {"min": "soon"}), # non-numeric save min
		_with(_base_manifest(), "shell", "not-an-object"), # wrong type entirely
	]
	for m in bad:
		var got: String = UpdateDecision.decide(_installed_current(), m)["action"]
		if got != UpdateDecision.INVALID_MANIFEST:
			_fail("malformed manifest %s -> %s, expected invalid_manifest" % [m, got])
			return


# --- helpers ---

func _with(base: Dictionary, key: String, value: Variant) -> Dictionary:
	var m := base.duplicate(true)
	m[key] = value
	return m


func _expect(installed: Dictionary, manifest: Dictionary, want_action: String, label: String) -> void:
	if _failed:
		return
	var got: Dictionary = UpdateDecision.decide(installed, manifest)
	if got.get("action") != want_action:
		_fail("%s — expected %s, got %s (reason: %s)" % [label, want_action, got.get("action"), got.get("reason")])
		return
	if str(got.get("reason", "")).is_empty():
		_fail("%s — action %s came with an empty reason" % [label, want_action])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
