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
	var err := _manifest_error(manifest)
	if err != "":
		return _result(INVALID_MANIFEST, err)

	if int(manifest["schema"]) > SUPPORTED_MANIFEST_SCHEMA:
		# The manifest format is newer than we understand; a newer shell can read
		# it. Don't guess at unknown fields.
		return _result(SHELL_UPDATE, "manifest schema %d is newer than this client understands (%d)" % [
			int(manifest["schema"]), SUPPORTED_MANIFEST_SCHEMA])

	var shell := str(installed.get("shell_version", "0.0.0"))
	var pack := str(installed.get("pack_version", "0.0.0"))
	var save_schema := int(installed.get("save_schema", 0))
	var protocol := int(installed.get("protocol", 0))

	var m_shell: Dictionary = manifest["shell"]
	var m_pack: Dictionary = manifest["pack"]
	var m_protocol: Dictionary = manifest["protocol"]
	var m_save: Dictionary = manifest["save_schema"]

	var shell_below_floor := _cmp(shell, str(m_shell["min_supported"])) < 0
	var pack_newer := _cmp(str(m_pack["version"]), pack) > 0
	var shell_newer := _cmp(str(m_shell["current"]), shell) > 0
	var pack_needs_newer_shell := _cmp(str(m_pack["min_shell"]), shell) > 0

	# "Incompatible with the live world" = the running build is BELOW what the
	# server needs. A protocol ABOVE the accepted range means the client is ahead
	# of a mid-rollout server — a transient the client simply tolerates (it never
	# blocks and is never "fixed" by updating further ahead), so it is not here.
	var protocol_too_old := protocol < int(m_protocol["min"])
	var save_too_old := save_schema < int(m_save["min"])
	var incompatible := protocol_too_old or save_too_old

	# There is something newer to move to.
	var update_available := shell_below_floor or pack_newer or shell_newer

	if incompatible and not update_available:
		# Already on the newest build the manifest offers, yet still below what the
		# live world needs, and nothing resolves it. This must never happen under
		# the product law — surface it loudly, never strand silently.
		return _result(BLOCKED_INCOMPATIBLE, (
			"running build is incompatible with the live world and no update resolves it "
			+ "(protocol %d < min %d, or save schema %d < min %d)") % [
				protocol, int(m_protocol["min"]), save_schema, int(m_save["min"])])

	# A shell update is required when the running shell is below the supported
	# floor, when the newest pack needs a newer shell than is installed, or when
	# the only thing newer is the shell itself. (When incompatible-but-updatable,
	# this same chain routes to whichever update carries the fix.)
	if shell_below_floor:
		return _result(SHELL_UPDATE, "installed shell %s is below the supported floor %s" % [
			shell, str(m_shell["min_supported"])])
	if pack_newer and pack_needs_newer_shell:
		return _result(SHELL_UPDATE, "content pack %s needs shell >= %s but %s is installed" % [
			str(m_pack["version"]), str(m_pack["min_shell"]), shell])
	if pack_newer:
		return _result(PACK_UPDATE, "content pack %s available (installed %s)" % [
			str(m_pack["version"]), pack])
	if shell_newer:
		return _result(SHELL_UPDATE, "shell %s available (installed %s)" % [
			str(m_shell["current"]), shell])

	# Nothing newer, and (per the guard above) not incompatible: current.
	return _result(UP_TO_DATE, "on the latest build for channel %s" % str(manifest.get("channel", "?")))


## Compare two dotted-integer version strings ("0.1.14"). Returns -1 / 0 / 1.
## Comparison is numeric per component (so "0.1.9" < "0.1.10", the classic
## lexical trap), and a shorter version is zero-padded ("1.2" == "1.2.0").
static func _cmp(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n := maxi(pa.size(), pb.size())
	for i in n:
		var xa := (pa[i].to_int() if i < pa.size() else 0)
		var xb := (pb[i].to_int() if i < pb.size() else 0)
		if xa != xb:
			return -1 if xa < xb else 1
	return 0


## Return "" if the manifest carries every field decide() reads with the right
## type, else a short reason. Delivery-only fields (url/sha256/size/signature)
## are the updater's concern and are deliberately not required here.
static func _manifest_error(m: Dictionary) -> String:
	if not (m.has("schema") and _is_num(m["schema"])):
		return "missing or non-numeric 'schema'"
	if not (m.has("shell") and m["shell"] is Dictionary):
		return "missing 'shell' object"
	var sh: Dictionary = m["shell"]
	if not _is_version(sh.get("current")):
		return "shell.current is not a version string"
	if not _is_version(sh.get("min_supported")):
		return "shell.min_supported is not a version string"
	if not (m.has("pack") and m["pack"] is Dictionary):
		return "missing 'pack' object"
	var pk: Dictionary = m["pack"]
	if not _is_version(pk.get("version")):
		return "pack.version is not a version string"
	if not _is_version(pk.get("min_shell")):
		return "pack.min_shell is not a version string"
	if not (m.has("protocol") and m["protocol"] is Dictionary):
		return "missing 'protocol' object"
	var pr: Dictionary = m["protocol"]
	if not (_is_num(pr.get("min")) and _is_num(pr.get("max"))):
		return "protocol.min/max are not numeric"
	if int(pr["min"]) > int(pr["max"]):
		return "protocol.min > protocol.max"
	if not (m.has("save_schema") and m["save_schema"] is Dictionary):
		return "missing 'save_schema' object"
	if not _is_num((m["save_schema"] as Dictionary).get("min")):
		return "save_schema.min is not numeric"
	return ""


## True if v is a JSON number (int, or a float such as JSON parsing may yield).
static func _is_num(v: Variant) -> bool:
	return v is int or v is float


## True if v is a non-empty dotted-integer version string ("0.1.14").
static func _is_version(v: Variant) -> bool:
	if not (v is String) or (v as String).is_empty():
		return false
	for part in (v as String).split("."):
		if part.is_empty() or not part.is_valid_int():
			return false
	return true


static func _result(action: String, reason: String) -> Dictionary:
	return {"action": action, "reason": reason}
