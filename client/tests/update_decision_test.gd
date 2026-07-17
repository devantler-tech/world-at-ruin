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
		"save_schema": {"min": 1},
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
	m2["save_schema"] = {"min": 2} # server needs save schema >= 2
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
	_expect(_installed_current(), m, UpdateDecision.SHELL_UPDATE, "a newer manifest schema needs a newer shell")


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
