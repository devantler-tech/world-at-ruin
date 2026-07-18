class_name RollbackSelection
extends RefCounted
## The recovery half of client self-update: given the signed catalogue of retained
## rollback targets, decide which build to fall back to when the installed one is
## broken. [UpdateDecision] decides what to move FORWARD to; this decides what to
## fall BACK to, and the two share [method UpdateDecision.compare_versions] so they
## can never disagree about which build is newer.
##
## It performs NO I/O: no network, no disk, no clock, no scene tree. Mounting and
## unmounting a `.pck`, the boot-attempt marker, the health check and persisting
## the quarantine set are the immutable bootstrap's job (a later child); this
## library only makes the decision, so every no-stranding guarantee is unit-testable
## with plain dictionaries — exactly like [UpdateDecision], [Telegraph] and
## [Interactable].
##
## Why this must exist before the first overlay ships (ADR
## `docs/design/distribution-and-self-update.md`): "a pack that crashes at startup
## cannot recover itself; without this in place a single bad overlay would strand
## every client that received it."
##
## The three product-law failures it makes unrepresentable:
##
## 1. [b]The boot loop.[/b] A pack that failed its boot-attempt health check is
##    QUARANTINED and never selected again ([method quarantine] is forward-only), so
##    a broken overlay cannot be re-mounted every launch.
## 2. [b]Rolling back below the save.[/b] A target is REACHABLE only if it can read
##    the installed save — its `read_ceiling` is at least the save's schema and its
##    `save_capability` is at least the save's. Handing a build a save it cannot read
##    is precisely the stranding the no-resets law forbids.
## 3. [b]Rolling back to an unreachable build.[/b] A target is RUNNABLE only if the
##    protocol range it speaks overlaps what the live tier accepts AND the installed
##    shell is inside its `shell_compat` range. Recovering to a build that cannot
##    connect or cannot run recovers nothing.
##
## Eligibility is decided entirely from PUBLISHED, SIGNED per-target fields
## (`read_ceiling`, `save_capability`, `speaks_protocol`, `shell_compat`) rather than
## inferred from a version number — the ADR's explicit choice. When nothing
## qualifies the answer is a loud, reasoned [constant NO_ELIGIBLE_TARGET]: this
## library never guesses, never "just takes the newest", and never silently strands.

## A rollback target was chosen; `version` names it.
const ROLLBACK := "rollback"
## No retained target is both runnable and reachable. A product-law alarm, not a
## normal outcome — the caller must surface it rather than boot into a broken pack.
const NO_ELIGIBLE_TARGET := "no_eligible_target"


## Choose the newest retained target that is not quarantined, is reachable (can read
## the installed save) and is runnable (speaks a protocol the live tier accepts and
## fits the installed shell).
##
## `catalog` is the manifest's `rollback_targets` array. `state` describes the client
## and the live world:
## [codeblock]
## {
##     save: { schema: int, capability: int },   # the installed save
##     protocol: { min: int, max: int },         # what the live tier accepts NOW
##     shell_version: String,                    # the installed shell
##     quarantined: Array,                       # versions that failed a boot check
## }
## [/codeblock]
## Missing keys take the most conservative default, so a partial state never crashes
## and never widens eligibility. Returns
## `{ action: String, version: String, reason: String }`.
##
## Malformed entries are SKIPPED rather than fatal: one bad catalogue entry must not
## deny the player a recovery that other entries can provide. If that leaves nothing
## eligible, the result is still a reasoned [constant NO_ELIGIBLE_TARGET].
static func select(catalog: Array, state: Dictionary) -> Dictionary:
	var save: Dictionary = state.get("save", {}) if state.get("save") is Dictionary else {}
	var save_schema: int = _as_int(save.get("schema"), 0)
	var save_capability: int = _as_int(save.get("capability"), 0)
	var protocol: Dictionary = state.get("protocol", {}) if state.get("protocol") is Dictionary else {}
	var shell_version: String = str(state.get("shell_version", "0.0.0"))
	var quarantined: Array = state.get("quarantined", []) if state.get("quarantined") is Array else []

	# An absent/!malformed accepted-protocol range cannot be treated as "anything
	# goes" — that would let an unrunnable build through. Refuse loudly instead.
	if not (protocol.get("min") is int and protocol.get("max") is int):
		return _refuse("the live protocol range is missing or malformed")
	var server_min: int = protocol["min"]
	var server_max: int = protocol["max"]

	var best: Dictionary = {}
	var best_version := ""
	var skipped := 0
	var considered := 0
	# Why the newest ELIGIBLE rather than the newest: rolling back further than
	# necessary discards working content, so among the builds that can actually run
	# and read the save, the most recent one is the least destructive recovery.
	for raw: Variant in catalog:
		if raw is not Dictionary:
			skipped += 1
			continue
		var target: Dictionary = raw
		if not _is_wellformed(target):
			skipped += 1
			continue
		considered += 1
		var version: String = target["version"]
		if quarantined.has(version):
			continue
		if not _is_reachable(target, save_schema, save_capability):
			continue
		if not _is_runnable(target, server_min, server_max, shell_version):
			continue
		if best_version.is_empty() or UpdateDecision.compare_versions(version, best_version) > 0:
			best = target
			best_version = version

	if best_version.is_empty():
		if considered == 0:
			return _refuse("the rollback catalogue has no well-formed target (%d skipped)" % skipped)
		return _refuse("no retained target is both runnable and reachable for save schema %d (capability %d), protocol %d..%d, shell %s" % [save_schema, save_capability, server_min, server_max, shell_version])
	return {
		"action": ROLLBACK,
		"version": best_version,
		"reason": "newest retained target that can run on shell %s, speak protocol %d..%d and read save schema %d" % [shell_version, server_min, server_max, save_schema],
	}


## Mark `version` as having failed its boot-attempt health check, returning the new
## quarantine set. FORWARD-ONLY: this only ever adds, so a build proven broken is
## never silently trusted again — that is what breaks the boot loop. The input array
## is not mutated; the caller persists the result.
static func quarantine(quarantined: Array, version: String) -> Array[String]:
	var out: Array[String] = []
	for raw: Variant in quarantined:
		if raw is String and not out.has(raw):
			out.append(raw)
	if not version.is_empty() and not out.has(version):
		out.append(version)
	out.sort()
	return out


## Whether `version` has been quarantined. Safe (false) for an unknown version.
static func is_quarantined(quarantined: Array, version: String) -> bool:
	return quarantined.has(version)


## Whether the target can READ the installed save without loss: its published read
## ceiling covers the save's schema and its save-capability covers the save's. Both
## are required — a same-schema content expansion raises only `capability`, so
## checking the schema alone would still strand the player.
static func _is_reachable(target: Dictionary, save_schema: int, save_capability: int) -> bool:
	var read_ceiling: int = target["read_ceiling"]
	var capability: int = target["save_capability"]
	return read_ceiling >= save_schema and capability >= save_capability


## Whether the target can actually RUN and CONNECT: the protocol range it speaks
## overlaps the range the live tier accepts, and the installed shell is inside its
## compatibility window.
static func _is_runnable(target: Dictionary, server_min: int, server_max: int, shell_version: String) -> bool:
	var speaks: Dictionary = target["speaks_protocol"]
	var speaks_min: int = speaks["min"]
	var speaks_max: int = speaks["max"]
	# Two ranges overlap iff each starts no later than the other ends.
	if speaks_min > server_max or speaks_max < server_min:
		return false
	var compat: Dictionary = target["shell_compat"]
	if UpdateDecision.compare_versions(shell_version, str(compat["min"])) < 0:
		return false
	if UpdateDecision.compare_versions(shell_version, str(compat["max"])) > 0:
		return false
	return true


## Whether a catalogue entry carries every field eligibility is decided from, each
## well-typed. Entries failing this are skipped, never trusted: an entry missing its
## capability data cannot be shown to be safe, and this library never assumes.
static func _is_wellformed(target: Dictionary) -> bool:
	var version: Variant = target.get("version")
	if version is not String or (version as String).is_empty():
		return false
	if not (target.get("read_ceiling") is int and target.get("save_capability") is int):
		return false
	var speaks: Variant = target.get("speaks_protocol")
	if speaks is not Dictionary or not (_dict_of(speaks, "min") is int and _dict_of(speaks, "max") is int):
		return false
	if (speaks as Dictionary)["min"] > (speaks as Dictionary)["max"]:
		return false
	var compat: Variant = target.get("shell_compat")
	if compat is not Dictionary:
		return false
	var compat_min: Variant = _dict_of(compat, "min")
	var compat_max: Variant = _dict_of(compat, "max")
	if compat_min is not String or compat_max is not String:
		return false
	return true


## A key's value from `source`, or null when absent — keeps the guards above readable.
static func _dict_of(source: Variant, key: String) -> Variant:
	return (source as Dictionary).get(key)


## `value` as an int when it genuinely is one, else `fallback`. `bool` is excluded so
## `true` can never stand in for 1.
static func _as_int(value: Variant, fallback: int) -> int:
	if value is bool or value is not int:
		return fallback
	return value


## A loud refusal carrying WHY nothing was selected — never a silent strand.
static func _refuse(reason: String) -> Dictionary:
	return {"action": NO_ELIGIBLE_TARGET, "version": "", "reason": reason}
