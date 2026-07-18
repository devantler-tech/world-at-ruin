class_name UpdateDecision
extends RefCounted
## The pure decision core of client self-update — the "brain" that decides, from
## what this build currently IS and a signed update manifest, what the client
## should do next. It performs NO I/O: no network, no disk, no clock, no scene
## tree. Downloading, signature/hash verification, staging, mounting and
## rollback are the in-client updater's job (a later child); this library only
## makes the decision, so every forward-only / no-stranding guarantee the
## product law demands is unit-testable with plain dictionaries — exactly like
## the pure predicates in `Telegraph` and `Interactable`.
##
## Product law it enforces (AGENTS.md — no hard resets, forward-only):
##   * NEVER proposes a downgrade. A manifest older than the installed build is a
##     no-op (`up_to_date`).
##   * A content pack is applied ONLY if the shell it needs is already installed;
##     otherwise the shell must update first (a pack can't run on too-old a shell).
##   * If the running build is incompatible with the live world (its protocol is
##     below the server's accepted range, or its save schema is too old) and NO
##     available update resolves it, it says so LOUDLY (`blocked_incompatible`) —
##     it never silently strands the player or drops below their save. Under
##     backward-compatible protocols + forward-only saves this state should be
##     unreachable; surfacing it is a product-law alarm, not a normal outcome.
##   * A malformed manifest is refused cleanly (`invalid_manifest`); the client
##     keeps playing its current build. A bad manifest never crashes or strands.
##
## See docs/design/distribution-and-self-update.md and the manifest contract
## docs/design/client-update-manifest.example.json.

## The manifest schema version this client understands. A manifest that declares
## a higher schema means this client is too old to read the update format safely,
## so it is told to update its shell rather than guess at unknown fields.
const SUPPORTED_MANIFEST_SCHEMA := 1

# --- Actions: the only values decide().action can take ---
const UP_TO_DATE := "up_to_date"
const PACK_UPDATE := "pack_update"
const SHELL_UPDATE := "shell_update"
const BLOCKED_INCOMPATIBLE := "blocked_incompatible"
const INVALID_MANIFEST := "invalid_manifest"


## Decide what the client should do. `installed` describes the running build:
##   { shell_version: String, pack_version: String, save_schema: int, protocol: int }
## Missing keys default to the lowest value, so a partial state is never a crash.
## `manifest` is the parsed update manifest (the caller has already verified its
## signature). Returns { action: String, reason: String } where action is one of
## the constants above. It never crashes on a malformed manifest.
static func decide(installed: Dictionary, manifest: Dictionary) -> Dictionary:
	# Envelope first: `schema` and the `shell` block keep a stable, backward-
	# compatible shape across every schema bump, so a client of ANY schema can
	# always at least learn it needs a newer shell — it is never stranded by a
	# manifest whose newer body it cannot fully parse.
	if not (manifest.has("schema") and is_int_id(manifest["schema"])):
		return _result(INVALID_MANIFEST, "missing or non-integer 'schema'")
	var env_err := _envelope_error(manifest)
	if env_err != "":
		return _result(INVALID_MANIFEST, env_err)

	# Channel guard: a validly-signed manifest for a DIFFERENT channel (e.g. a
	# beta/experimental build) must never enroll a player on another channel.
	# Signature proves authenticity, not channel membership, so a cache/endpoint
	# mix-up could otherwise opt a player into an unfinished experience — the
	# default-off opt-in product law. An UNPINNED installed channel FAILS CLOSED to
	# `live` (the stable channel): a fresh install accepts only `live`, never beta.
	# Opting into another channel is an explicit installed-state choice.
	var want_channel := str(installed.get("channel", "live"))
	if want_channel != str(manifest["channel"]):
		return _result(INVALID_MANIFEST, "manifest channel '%s' does not match the installed channel '%s'" % [
			str(manifest["channel"]), want_channel])

	if int(manifest["schema"]) > SUPPORTED_MANIFEST_SCHEMA:
		# The manifest format is newer than we understand. Route to a shell update
		# through the always-readable envelope — but ONLY if that shell is actually
		# newer than the installed one. A stale or cross-channel future-schema
		# manifest that advertises an equal/older shell must never trigger a
		# downgrade or an endless reinstall; refuse it and keep the running build.
		# Do NOT validate the (possibly restructured) schema-specific body.
		var env_shell: Dictionary = manifest["shell"]
		if compare_versions(str(env_shell["current"]), str(installed.get("shell_version", "0.0.0"))) > 0:
			# The stable envelope carries the shell's save read floor, so even a
			# schema we cannot parse is checked: block if the newer shell cannot read
			# the installed save (updating to it would strand the save).
			return _shell_or_block(int(installed.get("save_schema", 0)), env_shell, "manifest schema %d is newer than this client understands (%d); update to shell %s" % [
				int(manifest["schema"]), SUPPORTED_MANIFEST_SCHEMA, str(env_shell["current"])])
		return _result(INVALID_MANIFEST, "manifest schema %d exceeds understood (%d) but advertises no newer shell (%s <= installed %s) — stale/incoherent" % [
			int(manifest["schema"]), SUPPORTED_MANIFEST_SCHEMA, str(env_shell["current"]), str(installed.get("shell_version", "0.0.0"))])

	if int(manifest["schema"]) < SUPPORTED_MANIFEST_SCHEMA:
		# A schema older than the one this client understands is stale or malformed.
		# Refuse it rather than mis-parse it with the wrong (schema-1) field
		# semantics — a signed-but-stale manifest must never drive a real update.
		return _result(INVALID_MANIFEST, "manifest schema %d is below the schema this client understands (%d)" % [
			int(manifest["schema"]), SUPPORTED_MANIFEST_SCHEMA])

	# The schema-specific body is validated only against the exact schema this
	# client understands.
	var body_err := _body_error(manifest)
	if body_err != "":
		return _result(INVALID_MANIFEST, body_err)

	var shell := str(installed.get("shell_version", "0.0.0"))
	var pack := str(installed.get("pack_version", "0.0.0"))
	var save_schema := int(installed.get("save_schema", 0))
	var protocol := int(installed.get("protocol", 0))

	var m_shell: Dictionary = manifest["shell"]
	var m_pack: Dictionary = manifest["pack"]
	var m_protocol: Dictionary = manifest["protocol"]
	var m_save: Dictionary = manifest["save_schema"]

	var shell_below_floor := compare_versions(shell, str(m_shell["min_supported"])) < 0
	var pack_newer := compare_versions(str(m_pack["version"]), pack) > 0
	var shell_newer := compare_versions(str(m_shell["current"]), shell) > 0
	var pack_needs_newer_shell := compare_versions(str(m_pack["min_shell"]), shell) > 0

	# A save OLDER than the lowest schema the current builds can read
	# (`save_schema.min`) is unreadable by EVERY advertised update — proposing any
	# update would send the player to a build that cannot read their save. So this
	# is ALWAYS a loud block, never routed to an update. Under expand-before-write
	# (the read floor only rises after old saves migrate forward) it is unreachable;
	# reaching it is a product-law alarm.
	if save_schema < int(m_save["min"]):
		return _result(BLOCKED_INCOMPATIBLE, "installed save schema %d is below the lowest schema the current build can read (%d) — no update can read this save" % [
			save_schema, int(m_save["min"])])

	# A protocol BELOW the accepted range is fixable by updating (a newer build
	# speaks the newer protocol); a protocol ABOVE it means the client is ahead of a
	# mid-rollout server — a transient the client tolerates, so it is not here.
	var protocol_too_old := protocol < int(m_protocol["min"])

	# There is something newer to move to.
	var update_available := shell_below_floor or pack_newer or shell_newer

	if protocol_too_old and not update_available:
		# On the newest build the manifest offers, yet its protocol is still below
		# what the live world accepts, and nothing resolves it. Must never happen
		# under the two-phase protocol rollout — surface it loudly, never strand.
		return _result(BLOCKED_INCOMPATIBLE, "protocol %d is below the accepted minimum %d and no update resolves it" % [
			protocol, int(m_protocol["min"])])

	# Forward-only (ANY tier): a candidate that WRITES a save schema OLDER than the
	# installed build would regress the save format and drop the intervening state —
	# whether it arrives as a pack OR a shell update. Refuse it before routing to any
	# update tier.
	if int(m_save["writes"]) < save_schema:
		return _result(INVALID_MANIFEST, "candidate writes save schema %d below the installed build's %d — would regress the save (forward-only)" % [
			int(m_save["writes"]), save_schema])

	# The same forward-only rule for the CAPABILITY counter, which the schema check
	# above cannot see: a same-schema candidate advertising a capability BELOW the
	# installed one would move the player onto a build that cannot read shapes they
	# have already saved. Monotonic in both directions, on every tier.
	var installed_capability := int(installed.get("save_capability", 0))
	if int(m_save["capability"]) < installed_capability:
		return _result(INVALID_MANIFEST, "candidate advertises save capability %d below the installed build's %d — would regress the save (forward-only)" % [
			int(m_save["capability"]), installed_capability])

	# A shell update is required when the running shell is below the supported
	# floor, when the newest pack needs a newer shell than is installed, or when
	# the only thing newer is the shell itself. (When incompatible-but-updatable,
	# this same chain routes to whichever update carries the fix.)
	if shell_below_floor:
		return _shell_or_block(save_schema, m_shell, "installed shell %s is below the supported floor %s" % [
			shell, str(m_shell["min_supported"])])
	if pack_newer and pack_needs_newer_shell:
		return _shell_or_block(save_schema, m_shell, "content pack %s needs shell >= %s but %s is installed" % [
			str(m_pack["version"]), str(m_pack["min_shell"]), shell])
	if pack_newer:
		# Rollback safety: a pack update is offered only when the rollback target
		# (the installed build) could still READ what the candidate WRITES. If the
		# candidate's write-schema (`save_schema.writes`) exceeds how high the
		# installed build can read (`save_reads_max`, defaulting to its own schema),
		# a later rollback would strand a save the old build cannot read — so it
		# rides the SHELL tier. But route there only if the manifest actually offers
		# a NEWER shell; a stale/cross-channel manifest advertising an older shell is
		# refused, never followed to a downgrade.
		var reads_max := int(installed.get("save_reads_max", installed.get("save_schema", 0)))
		if int(m_save["writes"]) > reads_max:
			if shell_newer:
				return _shell_or_block(save_schema, m_shell, "content pack %s writes save schema %d beyond the rollback target's read ceiling %d — routing to the newer shell %s" % [
					str(m_pack["version"]), int(m_save["writes"]), reads_max, str(m_shell["current"])])
			return _result(INVALID_MANIFEST, "content pack %s writes save schema %d beyond the read ceiling %d but the manifest offers no newer shell — refusing (no safe route)" % [
				str(m_pack["version"]), int(m_save["writes"]), reads_max])

		# The SAME rollback-safety rule, one counter over. A same-schema content
		# expansion raises `save_schema.capability` while leaving `writes` untouched,
		# so the gate above cannot see it — yet the pack would then save shapes the
		# rollback target cannot read, and [RollbackSelection] would correctly find no
		# eligible target after a failed boot. That is the strand this closes.
		#
		# The gate is UNCONDITIONAL: `capability` is a required manifest field, and an
		# installed build that does not report one is treated as capability 0. Both
		# defaults fail closed — an unproven pack routes to the shell tier rather than
		# being offered. An earlier version engaged only when both sides declared a
		# capability, which meant omitting the field silently bypassed it; a gate with
		# an opt-out is not a gate.
		var capability_max := int(installed.get("save_capability_max", installed.get("save_capability", 0)))
		if int(m_save["capability"]) > capability_max:
			if shell_newer:
				return _shell_or_block(save_schema, m_shell, "content pack %s raises save capability to %d beyond the rollback target's %d — routing to the newer shell %s" % [
					str(m_pack["version"]), int(m_save["capability"]), capability_max, str(m_shell["current"])])
			return _result(INVALID_MANIFEST, "content pack %s raises save capability to %d beyond the rollback target's %d but the manifest offers no newer shell — refusing (no safe route)" % [
				str(m_pack["version"]), int(m_save["capability"]), capability_max])
		return _result(PACK_UPDATE, "content pack %s available (installed %s)" % [
			str(m_pack["version"]), pack])
	if shell_newer:
		return _shell_or_block(save_schema, m_shell, "shell %s available (installed %s)" % [
			str(m_shell["current"]), shell])

	# Nothing newer, and (per the guard above) not incompatible: current.
	return _result(UP_TO_DATE, "on the latest build for channel %s" % str(manifest.get("channel", "?")))


## Compare two dotted-integer version strings ("0.1.14"). Returns -1 / 0 / 1.
## Comparison is numeric per component (so "0.1.9" < "0.1.10", the classic
## lexical trap), and a shorter version is zero-padded ("1.2" == "1.2.0").
static func compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n := maxi(pa.size(), pb.size())
	for i in n:
		var xa := (pa[i].to_int() if i < pa.size() else 0)
		var xb := (pb[i].to_int() if i < pb.size() else 0)
		if xa != xb:
			return -1 if xa < xb else 1
	return 0


## The always-readable envelope: `schema` (checked by the caller) plus a coherent
## `shell` block. Its shape is guaranteed stable across schema bumps, so a client
## of any schema can read it to learn it needs a newer shell — never stranded.
## Returns "" if valid, else a short reason.
static func _envelope_error(m: Dictionary) -> String:
	if not (m.get("channel") is String) or (m["channel"] as String).is_empty():
		return "channel is missing or not a non-empty string"
	if not (m.has("shell") and m["shell"] is Dictionary):
		return "missing 'shell' object"
	var sh: Dictionary = m["shell"]
	if not is_version(sh.get("current")):
		return "shell.current is not a version string"
	if not is_version(sh.get("min_supported")):
		return "shell.min_supported is not a version string"
	# reads_min lives in the STABLE envelope (the save schema the advertised shell
	# reads down to) so a shell update can be checked for save-strand safety even on
	# a manifest whose schema-specific body this client cannot parse.
	if not is_int_id(sh.get("reads_min")):
		return "shell.reads_min is missing or not an integer"
	# A coherent manifest never advertises a current shell below its own floor;
	# such a manifest could otherwise steer a shell update to a DOWNGRADE.
	if compare_versions(str(sh["current"]), str(sh["min_supported"])) < 0:
		return "shell.current %s is below its own min_supported %s (incoherent manifest)" % [
			str(sh["current"]), str(sh["min_supported"])]
	return ""


## SHELL_UPDATE to `m_shell.current`, unless that shell's save read floor
## (`reads_min`) is above the installed save — in which case updating to it would
## strand the save, so it is a loud block instead. Every shell-update path routes
## through here so the check can never be forgotten.
static func _shell_or_block(installed_save: int, m_shell: Dictionary, why: String) -> Dictionary:
	if installed_save < int(m_shell["reads_min"]):
		return _result(BLOCKED_INCOMPATIBLE, "shell update (%s) targets a build reading saves only from schema %d, but the installed save is %d — updating would strand it" % [
			why, int(m_shell["reads_min"]), installed_save])
	return _result(SHELL_UPDATE, why)


## Validate the schema-specific body (pack / protocol / save_schema) — only ever
## called for the schema THIS client understands. Delivery-only fields
## (url/sha256/size/signature/key) are the updater's concern, not required here.
static func _body_error(m: Dictionary) -> String:
	if not (m.has("pack") and m["pack"] is Dictionary):
		return "missing 'pack' object"
	var pk: Dictionary = m["pack"]
	if not is_version(pk.get("version")):
		return "pack.version is not a version string"
	if not is_version(pk.get("min_shell")):
		return "pack.min_shell is not a version string"
	# A coherent manifest never advertises a pack that needs a shell newer than the
	# newest shell it offers — otherwise a client would be sent to a shell update
	# that still cannot run the pack, and loop forever.
	if compare_versions(str(pk["min_shell"]), str((m["shell"] as Dictionary)["current"])) > 0:
		return "pack.min_shell %s exceeds the advertised shell.current %s (incoherent manifest)" % [
			str(pk["min_shell"]), str((m["shell"] as Dictionary)["current"])]
	if not (m.has("protocol") and m["protocol"] is Dictionary):
		return "missing 'protocol' object"
	var pr: Dictionary = m["protocol"]
	if not (is_int_id(pr.get("min")) and is_int_id(pr.get("max"))):
		return "protocol.min/max are not integers"
	if int(pr["min"]) > int(pr["max"]):
		return "protocol.min > protocol.max"
	if not (m.has("save_schema") and m["save_schema"] is Dictionary):
		return "missing 'save_schema' object"
	var sv: Dictionary = m["save_schema"]
	if not is_int_id(sv.get("min")):
		return "save_schema.min is not an integer"
	# `writes` (the candidate's write-schema) is REQUIRED: it drives the
	# rollback-safety routing, so a manifest that omits it must be refused (fail
	# closed) rather than silently allow a pack update that could strand a save.
	if not is_int_id(sv.get("writes")):
		return "save_schema.writes is missing or not an integer"
	if int(sv["writes"]) < int(sv["min"]):
		return "save_schema.writes %d is below save_schema.min %d (incoherent)" % [
			int(sv["writes"]), int(sv["min"])]
	# `capability` is REQUIRED, for the same reason `writes` is: it drives the
	# same-schema rollback gate in decide(). A gate that can be bypassed by omitting
	# the field is not a gate, so an absent capability is a refusal rather than an
	# unproven pass.
	if not is_int_id(sv.get("capability")):
		return "save_schema.capability is missing or not a whole number"
	return ""


## True only for a discrete integer identifier: a NON-NEGATIVE int, or an integral,
## finite, non-negative JSON float (1.0). Fractional (1.5), non-finite and bool
## values are rejected, so one can never be silently truncated or coerced by a later
## int() into a wrong decision.
##
## Negative is rejected because every field validated with this is a COUNTER or
## ORDINAL (a schema, a protocol bound, a save capability), for which a negative is
## malformed rather than merely unusual. Accepting one is an eligibility hole on
## BOTH paths: a save schema of -1 makes every rollback target look able to read it,
## and a negative protocol bound widens the accepted range.
## Public because a signed manifest parsed from JSON may present whole numbers as
## floats: [RollbackSelection] validates the rollback catalogue with the SAME rule,
## so a real manifest shape can never be readable by the forward path and
## unreadable by the recovery path.
static func is_int_id(v: Variant) -> bool:
	if v is bool:
		return false
	if v is int:
		return v >= 0
	if v is float:
		return is_finite(v) and v == floor(v) and v >= 0.0
	return false


## True if v is a non-empty dotted-integer version string ("0.1.14"). Public for
## the same reason as [method is_int_id]: [RollbackSelection] must reject an
## unverifiable version rather than let [method compare_versions] coerce it to 0.
static func is_version(v: Variant) -> bool:
	if not (v is String) or (v as String).is_empty():
		return false
	for part in (v as String).split("."):
		# NOT is_valid_int(): that accepts a SIGNED component, so "-1.0.0" would
		# pass as a version and compare as a floor of -1 that every shell clears.
		# A version component is an unsigned ordinal.
		if not is_unsigned_digits(part):
			return false
	return true


## True if `s` is a non-empty run of ASCII digits only. Unlike `String.is_valid_int`
## it rejects a leading `+`/`-`, which matters wherever a signed value would be a
## malformed ordinal rather than a small negative number.
static func is_unsigned_digits(s: String) -> bool:
	if s.is_empty():
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 48 or c > 57: # '0'..'9'
			return false
	return true


static func _result(action: String, reason: String) -> Dictionary:
	return {"action": action, "reason": reason}
