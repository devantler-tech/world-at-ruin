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
		"shell": {"current": "0.1.14", "min_supported": "0.1.0"},
		"pack": {"version": "0.1.14", "min_shell": "0.1.14", "url": "x", "sha256": "y", "size": 0},
		"protocol": {"min": 1, "max": 1},
		"save_schema": {"min": 1, "writes": 1},
		"signature": "sig",
	}


func _installed_current() -> Dictionary:
	return {"shell_version": "0.1.14", "pack_version": "0.1.14", "save_schema": 1, "protocol": 1}


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
	_test_schema_too_new_updates_shell()
	_test_future_schema_without_newer_shell_refused()
	_test_pack_needs_shell_beyond_advertised_refused()
	_test_pack_write_schema_hazard_routes_to_shell()
	_test_schema_too_new_ignores_broken_body()
	_test_schema_below_supported_refused()
	_test_pack_update_requires_write_schema()
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
	m2["save_schema"] = {"min": 2, "writes": 2} # server needs save schema >= 2
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
	# A newer pack that WRITES a save schema the rollback target cannot READ must
	# ride the shell tier, so a later rollback never strands the save.
	var m := _base_manifest()
	m["pack"]["version"] = "0.1.15" # newer pack, runs on the current shell
	m["save_schema"] = {"min": 1, "writes": 4} # writes v4
	var inst := _installed_current()
	inst["save_reads_max"] = 3 # installed build reads only up to v3
	_expect(inst, m, UpdateDecision.SHELL_UPDATE, "a pack writing beyond the rollback target's read ceiling rides the shell")
	# Safe case: writes within the read ceiling → a plain pack update.
	var m2 := _base_manifest()
	m2["pack"]["version"] = "0.1.15"
	m2["save_schema"] = {"min": 1, "writes": 3}
	var inst2 := _installed_current()
	inst2["save_reads_max"] = 3
	_expect(inst2, m2, UpdateDecision.PACK_UPDATE, "a pack writing within the read ceiling is a plain pack update")


func _test_schema_too_new_ignores_broken_body() -> void:
	# The envelope (schema + shell) must be read BEFORE the schema-specific body.
	# A schema-2 manifest that restructured/removed body fields must still route an
	# old client to a shell update via the envelope — never invalid_manifest, which
	# would strand it. (Codex P0.)
	var m := {
		"schema": 2,
		"channel": "live",
		"shell": {"current": "0.2.0", "min_supported": "0.1.0"},
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


func _test_incoherent_shell_floor_refused() -> void:
	# An incoherent manifest whose advertised shell is below its own floor must be
	# refused, not followed to a downgrade. (Codex P0.)
	var m := _base_manifest()
	m["shell"] = {"current": "1.0.0", "min_supported": "3.0.0"} # current below its own floor
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
