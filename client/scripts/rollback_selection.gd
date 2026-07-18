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
## Every one of those inputs is a PROOF of eligibility, so each must be present and
## well-typed: unverifiable state yields [constant NO_ELIGIBLE_TARGET] naming what
## could not be verified. There is no safe permissive default — an unknown save
## would make every target look reachable, and an unknown shell would match any
## compatibility window — so this never guesses. (`quarantined` is the one key that
## may be absent: that is the legitimate first-boot state, nothing has failed yet.
## Present-but-malformed is still refused.) Returns
## `{ action: String, version: String, target: Dictionary, reason: String }`, where
## `target` is the VERIFIED catalogue entry itself (empty on a refusal) so the
## bootstrap fetches exactly the artifact whose url/sha256/compatibility was checked,
## never a same-version duplicate carrying different metadata.
##
## Malformed entries are SKIPPED rather than fatal: one bad catalogue entry must not
## deny the player a recovery that other entries can provide. If that leaves nothing
## eligible, the result is still a reasoned [constant NO_ELIGIBLE_TARGET].
static func select(catalog: Variant, state: Variant) -> Dictionary:
	# BOTH parameters are untyped, and that is a rule in this file rather than a
	# case-by-case choice: every input to a fail-closed function arrives from disk or
	# a parsed manifest, so a typed parameter lets GDScript reject the call before the
	# body can return the promised refusal — a runtime error in the recovery path
	# instead of a loud, reasoned one. This trap has now been found four times here
	# (`version`, `quarantined`, `catalog`, `state`); it is the shape, not the field.
	if catalog is not Array:
		return _refuse("the rollback catalogue is missing or is not a list")
	if state is not Dictionary:
		return _refuse("the recovery state is missing or is not a dictionary")
	return _select_verified(catalog as Array, state as Dictionary)


static func _select_verified(catalog: Array, state: Dictionary) -> Dictionary:
	# EVERY eligibility input must be VERIFIED before any target is considered.
	# There is no "conservative default" available here: defaulting unknown state to
	# a permissive value (save schema 0, shell "0.0.0", an open protocol range) does
	# not fail safe — it makes targets look reachable/runnable that may not be, which
	# is precisely the stranding this library exists to prevent. So unverifiable
	# state is a loud refusal, never an assumption.
	var save: Variant = state.get("save")
	if save is not Dictionary:
		return _refuse("save metadata is missing or malformed — cannot prove any target can read the installed save")
	var save_dict: Dictionary = save
	if not (UpdateDecision.is_int_id(save_dict.get("schema")) and UpdateDecision.is_int_id(save_dict.get("capability"))):
		return _refuse("save schema/capability are missing or not whole numbers — cannot prove any target can read the installed save")
	var save_schema: int = int(save_dict["schema"])
	var save_capability: int = int(save_dict["capability"])
	# Schema 0 is NOT a proof. Shipped save schemas start at 1, so a zero is a
	# defaulted or torn read, not a real save — and accepting it makes every target
	# with a normal positive read_ceiling look able to read the player's save, which
	# is exactly the permissive failure this function refuses to make for an ABSENT
	# save. An explicitly-supplied 0 must not buy what a missing value cannot.
	if save_schema < 1:
		return _refuse("the installed save reports schema 0, which is a defaulted or corrupt read rather than a real save — refusing rather than treat every target as able to read it")

	var protocol: Variant = state.get("protocol")
	if protocol is not Dictionary:
		return _refuse("the live protocol range is missing or malformed")
	var protocol_dict: Dictionary = protocol
	if not (UpdateDecision.is_int_id(protocol_dict.get("min")) and UpdateDecision.is_int_id(protocol_dict.get("max"))):
		return _refuse("the live protocol range is missing or malformed")
	var server_min: int = int(protocol_dict["min"])
	var server_max: int = int(protocol_dict["max"])
	# An inverted range (5..1) is incoherent, and a broad target range would appear
	# to "overlap" it under the interval test — the same fail-closed rule as above.
	if server_min > server_max:
		return _refuse("the live protocol range is inverted (%d..%d)" % [server_min, server_max])

	# The installed shell is a runnability PROOF: without a real version there is
	# nothing to check shell_compat against, and a coerced "0.0.0" would silently
	# match any target whose window opens at 0.0.0.
	if not UpdateDecision.is_version(state.get("shell_version")):
		return _refuse("the installed shell version is missing or not a valid version — cannot prove any target runs on it")
	var shell_version: String = str(state["shell_version"])

	# A quarantine ledger that is present but unreadable must NOT be read as
	# "nothing is quarantined" — that would re-select the build that just failed its
	# boot check and reopen the very loop this breaks. Absent is different and
	# legitimate: it is the first-boot state, where nothing has failed yet.
	if state.has("quarantined"):
		if state["quarantined"] is not Array:
			return _refuse("the quarantine ledger is malformed — refusing rather than risk re-selecting a known-broken build")
		# A well-typed Array whose ENTRIES are malformed (e.g. `[42]` after a bad
		# write) is just as dangerous as a malformed container: every lookup misses,
		# so the build that just failed its boot check is selected again. Only an
		# ABSENT key means first boot.
		for raw: Variant in (state["quarantined"] as Array):
			if not UpdateDecision.is_version(raw):
				return _refuse("the quarantine ledger holds an unreadable entry — refusing rather than risk re-selecting a known-broken build")
	var quarantined: Array = state.get("quarantined", [])

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
		if not is_wellformed(target):
			skipped += 1
			continue
		considered += 1
		var version: String = target["version"]
		if is_quarantined(quarantined, version):
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
		# The VERIFIED entry itself, not just its version. A catalogue can hold
		# duplicate or aliased entries for one version carrying different artifact
		# metadata; returning only the version would let the bootstrap re-resolve it
		# and fetch a DIFFERENT duplicate than the one whose url/sha256/compatibility
		# was actually validated here. A copy, so the caller cannot mutate the
		# catalogue through it.
		"target": best.duplicate(true),
		"reason": "newest retained target that can run on shell %s, speak protocol %d..%d and read save schema %d" % [shell_version, server_min, server_max, save_schema],
	}


## Mark `version` as having failed its boot-attempt health check, returning the new
## quarantine set. FORWARD-ONLY: this only ever adds, so a build proven broken is
## never silently trusted again — that is what breaks the boot loop. The input array
## is not mutated; the caller persists the result.
## Deduplication is NUMERIC (see [method is_quarantined]), so the ledger cannot
## accumulate aliases of one build.
##
## Returns `{ ok: bool, ledger: Array[String], reason: String }`. It REFUSES rather
## than sanitises: if the existing ledger holds an unreadable entry, or `version` is
## not a version, `ok` is false and `ledger` is unchanged. Silently dropping either
## would be the most dangerous thing this file could do — a caller persisting a
## "cleaned" ledger would erase the only record that a build failed its boot check,
## and the next [method select] would happily choose that known-broken build again,
## reopening the very loop this exists to break. [method select] refuses on an
## unreadable ledger for the same reason; the write side must not disagree with the
## read side. Recovering from a corrupt ledger is a policy decision for the
## bootstrap, not a silent repair here.
## `version` is deliberately untyped: the boot-attempt marker is read from disk and
## may come back as `null` or a number after a bad write. A `String` parameter would
## make the caller error before reaching the refusal below — turning the fail-closed
## result the bootstrap needs into a crash, in exactly the situation it is needed.
static func quarantine(quarantined: Variant, version: Variant) -> Dictionary:
	# `quarantined` is untyped for the same reason as `version`: a ledger read back
	# from disk can be null or an object after a bad write, and a typed Array
	# parameter would make GDScript reject the call before this fail-closed body
	# could return — denying the bootstrap its result in the one case it is for.
	if quarantined is not Array:
		# Return the UNREADABLE value, not an empty list. An empty list is a readable
		# ledger, so a bootstrap following this payload into recover_ledger() would be
		# told there is no deadlock to escape — and the deadlock would close again.
		# A refusal must hand back what it was given, or the next function in the
		# chain reasons about a value that was never there.
		return {"ok": false, "ledger": quarantined, "reason": "refusing to rewrite an unreadable quarantine ledger — it is not a list"}
	if not UpdateDecision.is_version(version):
		return {"ok": false, "ledger": quarantined, "reason": "refusing to record a failure for an unreadable version — the boot-attempt marker is malformed"}
	var failed: String = version
	var out: Array[String] = []
	for raw: Variant in (quarantined as Array):
		if not UpdateDecision.is_version(raw):
			return {"ok": false, "ledger": quarantined, "reason": "refusing to rewrite a ledger holding an unreadable entry — persisting it would erase a recorded failure"}
		if not is_quarantined(out, str(raw)):
			out.append(str(raw))
	if not is_quarantined(out, failed):
		out.append(failed)
	out.sort()
	return {"ok": true, "ledger": out, "reason": "recorded %s as failed" % failed}


## Start a FRESH ledger recording only `version`, deliberately discarding a previous
## ledger that could not be read.
##
## This is the escape hatch from an otherwise closed loop: [method select] refuses on
## a corrupt ledger (reading it as "nothing quarantined" would re-select the build
## that just failed), and [method quarantine] refuses to rewrite one (silently
## dropping entries would erase recorded failures). Both refusals are right on their
## own, but together they leave a bootstrap with a torn ledger unable to record the
## current failure OR select a target — consistent, and permanently stuck.
##
## So the recovery is EXPLICIT rather than automatic. The caller must choose it
## knowingly, and the trade is stated plainly: the history of older failures is lost,
## so a build that failed long ago may be selected again. What is preserved is the
## thing that matters most — the failure happening RIGHT NOW is recorded, so the
## immediate boot loop is broken. Never call this as a fallback from a refusal; it is
## for a bootstrap that has decided a torn ledger is unrecoverable.
static func recover_ledger(quarantined: Variant, version: Variant) -> Dictionary:
	if not UpdateDecision.is_version(version):
		return {"ok": false, "ledger": [], "reason": "cannot start a recovery ledger from an unreadable version — the boot-attempt marker is malformed too"}
	# The escape hatch must PROVE the escape is needed. Without seeing the ledger it
	# discards, this would happily throw away a perfectly readable history of failures
	# and make those known-broken builds selectable again — turning a recovery tool
	# into a way to lose the very evidence the ledger exists to keep. A readable
	# ledger is not a deadlock: append to it with [method quarantine] instead.
	if _is_readable_ledger(quarantined):
		return {
			"ok": false,
			"ledger": quarantined,
			"reason": "refusing to reset a READABLE ledger — there is no deadlock to escape here, and discarding it would make known-failed builds selectable again; use quarantine() to append",
		}
	var fresh: Array[String] = [str(version)]
	return {
		"ok": true,
		"ledger": fresh,
		"reason": "started a fresh quarantine ledger recording %s — PREVIOUS FAILURE HISTORY WAS DISCARDED as unreadable" % str(version),
	}


## Whether `version` has been quarantined. Safe (false) for an unknown version.
##
## Matching is NUMERIC, not string equality: `compare_versions` treats `0.1.10`,
## `0.1.010` and `0.1.10.0` as the same build, so an exact-string check would let a
## catalogue that spells a quarantined version differently re-select the build that
## just failed its boot check, under an alias. Any spelling of a quarantined version
## stays quarantined.
## Both parameters are untyped for the reason established across this file, and this
## one needs a further decision: it returns a bool, so it cannot refuse. Answering
## `false` for an unreadable ledger would be the permissive LIE — "this build is not
## quarantined" asserted from evidence that could not be read, which is precisely how
## a known-broken build gets re-selected. So unverifiable input answers TRUE: not
## "this is quarantined" but "this cannot be shown to be safe", which fails closed the
## way the rest of the file does. Callers wanting to distinguish the two cases should
## validate the ledger themselves, as [method select] does.
static func is_quarantined(quarantined: Variant, version: Variant) -> bool:
	if not UpdateDecision.is_version(version):
		return true
	if not _is_readable_ledger(quarantined):
		return true
	for raw: Variant in (quarantined as Array):
		if UpdateDecision.compare_versions(str(raw), str(version)) == 0:
			return true
	return false


## Whether `v` is a ledger that can be trusted to answer questions: a list in which
## EVERY entry is a real version. A well-typed list holding one unreadable entry is
## not readable — skipping the bad entry and answering from the rest treats corrupt
## evidence as absence, which is the container-versus-entries mistake that also
## produced a bug in [method select].
static func _is_readable_ledger(v: Variant) -> bool:
	if v is not Array:
		return false
	for raw: Variant in (v as Array):
		if not UpdateDecision.is_version(raw):
			return false
	return true


## Whether the target can READ the installed save without loss: its published read
## ceiling covers the save's schema and its save-capability covers the save's. Both
## are required — a same-schema content expansion raises only `capability`, so
## checking the schema alone would still strand the player.
static func _is_reachable(target: Dictionary, save_schema: int, save_capability: int) -> bool:
	var read_ceiling: int = int(target["read_ceiling"])
	var capability: int = int(target["save_capability"])
	return read_ceiling >= save_schema and capability >= save_capability


## Whether the target can actually RUN and CONNECT: the protocol range it speaks
## overlaps the range the live tier accepts, and the installed shell is inside its
## compatibility window.
static func _is_runnable(target: Dictionary, server_min: int, server_max: int, shell_version: String) -> bool:
	var speaks: Dictionary = target["speaks_protocol"]
	var speaks_min: int = int(speaks["min"])
	var speaks_max: int = int(speaks["max"])
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
##
## PUBLIC because the FORWARD path needs the identical question. [UpdateDecision]
## must not count a target as rollback cover that this selector would later skip,
## and every field checked here is STATIC manifest data — knowable when the update
## decision is made, unlike the time-varying runnability in [method _is_runnable].
## Sharing the predicate rather than mirroring it is what stops the two paths
## drifting apart, the same reason this file validates fields with
## [UpdateDecision]'s own [method UpdateDecision.is_int_id] / [method
## UpdateDecision.is_version] rules instead of its own copies.
## Every field is validated with the SAME rules the forward path uses
## ([method UpdateDecision.is_int_id], [method UpdateDecision.is_version]), so a real
## signed manifest can never be readable by the updater and unreadable by recovery.
## Two consequences worth stating:
##   * Whole numbers may arrive as JSON floats (`1.0`); those are accepted, while a
##     fractional value is not — an eligibility number that would be truncated into a
##     different decision is not a proof.
##   * A version must be a genuine dotted-integer version. `compare_versions` coerces
##     unparseable components to 0, so accepting `"99.bad"` would let a nonsense entry
##     win the ordering and be handed to the bootstrap as a recovery target.
static func is_wellformed(target: Dictionary) -> bool:
	if not UpdateDecision.is_version(target.get("version")):
		return false
	if not (UpdateDecision.is_int_id(target.get("read_ceiling")) and UpdateDecision.is_int_id(target.get("save_capability"))):
		return false
	var speaks: Variant = target.get("speaks_protocol")
	if speaks is not Dictionary:
		return false
	var speaks_dict: Dictionary = speaks
	if not (UpdateDecision.is_int_id(speaks_dict.get("min")) and UpdateDecision.is_int_id(speaks_dict.get("max"))):
		return false
	if int(speaks_dict["min"]) > int(speaks_dict["max"]):
		return false
	var compat: Variant = target.get("shell_compat")
	if compat is not Dictionary:
		return false
	var compat_dict: Dictionary = compat
	# Both bounds must be real versions: a bound like "garbage" would compare as
	# 0.0.0 and silently widen the window it is supposed to prove.
	if not (UpdateDecision.is_version(compat_dict.get("min")) and UpdateDecision.is_version(compat_dict.get("max"))):
		return false
	if UpdateDecision.compare_versions(str(compat_dict["min"]), str(compat_dict["max"])) > 0:
		return false
	# Eligibility is not enough: the bootstrap has to MOUNT this build. An entry
	# without a fetchable, verifiable artifact is undeployable, and because it can
	# still carry the highest version it would win the ordering and deny a recovery a
	# lower, complete entry could have provided.
	# Non-emptiness is not fetchability: whitespace, or any string without a real
	# scheme, is unusable to the bootstrap, and such an entry can still carry the
	# highest version and displace a complete lower one.
	if not _is_fetchable_url(target.get("url")):
		return false
	if not _is_sha256(target.get("sha256")):
		return false
	if not UpdateDecision.is_int_id(target.get("size")):
		return false
	return true


## Whether `v` is a usable artifact URL: a whitespace-free `https://` address with
## something after the scheme. HTTPS only, because an update artifact is fetched
## before its signature can be checked, so the transport is part of the trust story.
## This is a SHAPE check — reachability is the updater's problem, not the selector's.
static func _is_fetchable_url(v: Variant) -> bool:
	if v is not String:
		return false
	var url: String = v
	# Reject rather than trim: a signed field with stray whitespace is malformed
	# metadata, and silently repairing signed data is not this library's business.
	if url != url.strip_edges():
		return false
	const SCHEME := "https://"
	if not url.begins_with(SCHEME) or url.length() <= SCHEME.length():
		return false
	# Everything must be printable ASCII: control characters and spaces cannot appear
	# in a URL, and a non-ASCII host would need IDNA encoding the publisher should
	# have done.
	for i in url.length():
		var c := url.unicode_at(i)
		if c <= 32 or c >= 127:
			return false
	var rest: String = url.substr(SCHEME.length())
	# The authority ends at the first path, query or fragment delimiter.
	var authority: String = rest
	for delimiter: String in ["/", "?", "#"]:
		var at: int = authority.find(delimiter)
		if at >= 0:
			authority = authority.substr(0, at)
	# Optional userinfo.
	var at_sign: int = authority.rfind("@")
	if at_sign >= 0:
		authority = authority.substr(at_sign + 1)
	# Optional port, which must actually be a port.
	var colon: int = authority.rfind(":")
	if colon >= 0:
		# Digits of a sane length is the SHAPE; a port also has a RANGE. `99999` is
		# five digits and not a port. Bounding the form and not the value is the same
		# shape-versus-contents gap this grammar was written to close, so close it here.
		var port: String = authority.substr(colon + 1)
		if not UpdateDecision.is_unsigned_digits(port) or port.length() > 5:
			return false
		var port_number: int = port.to_int()
		if port_number < 1 or port_number > 65535:
			return false
		authority = authority.substr(0, colon)
	return _is_host(authority)


## Whether `host` is a plausible registered name or IPv4 literal: a non-empty,
## dot-separated set of labels, each of which is alphanumerics and hyphens only and
## neither starts nor ends with a hyphen.
##
## This is a POSITIVE grammar — what a host may be — rather than a list of the
## malformed shapes seen so far. That distinction is the point: this check was found
## one notch too permissive in four consecutive review rounds (empty, then
## `https:///`, then `https://:443` and `https://@/`, then `host:bad`), because each
## fix rejected the reported counterexample and left the next layer unconsidered.
## Enumerating what is ALLOWED terminates; enumerating what is forbidden does not.
static func _is_host(host: String) -> bool:
	if host.is_empty() or host.length() > 253:
		return false
	for label: String in host.split("."):
		if label.is_empty() or label.length() > 63:
			return false
		if label.begins_with("-") or label.ends_with("-"):
			return false
		for i in label.length():
			var c := label.unicode_at(i)
			var is_digit := c >= 48 and c <= 57
			var is_lower := c >= 97 and c <= 122
			var is_upper := c >= 65 and c <= 90
			if not (is_digit or is_lower or is_upper or c == 45): # 45 == '-'
				return false
	return true


## Whether `v` is a syntactically valid SHA-256 digest: exactly 64 hex characters.
## The digest is the artifact's integrity proof, so a truncated or non-hex value is
## no proof at all. (Its correctness is verified against the downloaded bytes by the
## updater; this only rejects a value that could never be a digest.)
static func _is_sha256(v: Variant) -> bool:
	if v is not String:
		return false
	var digest: String = v
	if digest.length() != 64:
		return false
	# NOT is_valid_hex_number(): it accepts a leading sign, so "-" plus 63 hex
	# characters is 64 long and "valid", i.e. an impossible digest treated as a
	# deployable artifact. Every character must be a hex digit.
	for i in digest.length():
		var c := digest.unicode_at(i)
		var is_digit := c >= 48 and c <= 57 # '0'..'9'
		var is_lower := c >= 97 and c <= 102 # 'a'..'f'
		var is_upper := c >= 65 and c <= 70 # 'A'..'F'
		if not (is_digit or is_lower or is_upper):
			return false
	return true


## A loud refusal carrying WHY nothing was selected — never a silent strand.
static func _refuse(reason: String) -> Dictionary:
	return {"action": NO_ELIGIBLE_TARGET, "version": "", "target": {}, "reason": reason}
