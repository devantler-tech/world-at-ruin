class_name UpdateManifest
## What THIS build can truthfully say about itself to a future copy of itself.
##
## [UpdateDecision] is the brain of self-update, but it decides from a manifest
## someone else has to write. This is that someone. It exists so the manifest is
## DERIVED from the constants the build actually runs on, never restated by hand
## in a CI script — a hand-written manifest drifts silently, and every
## no-stranding guarantee of the product law (no hard resets; an early player
## keeps playing as the game evolves) is decided from exactly these numbers.
##
## The rule this module is built around: it asserts only facts the repo can back.
## Where a fact does not exist yet, the manifest omits it rather than inventing a
## plausible value — a published manifest that lies about what the client reads
## is worse than no manifest at all, because the updater believes it.
##
## Deliberately NOT emitted, because nothing here can honestly produce them:
##   * `signature` / `key` / `revocation` — the Ed25519 + RFC-8785-JCS root of
##     trust is unstarted (issue #69's signing child). The published OCI artifact
##     IS cosign-signed by digest, which is a real integrity property, but it is a
##     different one and this module does not pretend otherwise.
##   * `shell.download` — and this omission is LOAD-BEARING, not an oversight. The
##     ADR requires a shell replacement to be authorized by the offline root (or
##     platform codesign), carried in `shell_authorization`. That root does not
##     exist yet, so any download offered here would be an UNAUTHORIZED shell
##     replacement — the single most dangerous thing this manifest could carry.
##     Omitting it fails closed: a client that follows the envelope to a
##     `shell_update` simply finds nowhere to go and keeps playing, which is the
##     safe outcome. It is filled in by the same signing child that supplies the
##     authorization, never before.
##   * `pack.deltas` — no delta pipeline exists, so the list is empty. A client
##     "always falls back to the full pack" (ADR), so empty is correct, not a gap.
##   * `rollback_targets` — nothing is retained yet. Empty is the FAIL-CLOSED
##     value: [UpdateDecision] treats an uncovered capability raise as blocked, so
##     an empty catalogue refuses a capability-raising pack instead of shipping one
##     the player could not roll back from.
##
## See docs/design/distribution-and-self-update.md and the shape reference
## docs/design/client-update-manifest.example.json.

## The manifest schema this build emits. Taken from the consumer rather than
## written twice: a manifest we emit at a schema our own client cannot read would
## be a self-inflicted `shell_update` loop.
const SCHEMA := UpdateDecision.SUPPORTED_MANIFEST_SCHEMA

## The only release channel that exists. [UpdateDecision] matches this string
## EXACTLY against the installed channel, so it is contract, not decoration.
const CHANNEL := "live"

## The oldest save schema this build can still read.
##
## Backed by evidence, not by assertion: `save_fixture_guard_test.gd` proves this
## build reads every committed `tests/data/golden_recipe_v*.json`, and the oldest
## committed fixture is v1. `update_manifest_test.gd` pins the two together, so
## dropping a fixture without raising this floor fails the suite.
const SAVE_SCHEMA_MIN := 1

## What this build writes WITHIN its save schema — the content-capability counter.
##
## Distinct from the schema version: a same-schema content addition (a new savable
## registry name) raises the capability without changing the shape, and a rollback
## target that cannot read the new content would strand it. Nothing had ever
## incremented this before it was introduced here, so it starts at the floor.
##
## APPEND-ONLY, and it may only ever RISE. Raise it by exactly one in the same PR
## that adds a savable field, and never reuse or lower a value: a lower capability
## reaching a player's vault reads as "this build understands less than it wrote",
## which is precisely the stranding [UpdateDecision] refuses.
const SAVE_CAPABILITY := 1

## The oldest shell this manifest still supports updating FROM.
##
## `0.1.0` is the first version the project ever shipped, so nothing is excluded:
## the honest floor today is "everything". This becomes a real decision the first
## time a shell change is genuinely unsupportable, and raising it is a deliberate,
## player-visible act — it strands anyone below it.
const SHELL_MIN_SUPPORTED := "0.1.0"


## Build the update manifest for this build.
##
## `artifact` carries the only facts CI owns and the client cannot know — where
## the published build lives and what it hashes to:
##   { url: String (https), sha256: String (64 hex), size: int }
##
## Returns `{ manifest: Dictionary, error: String }`. `error` is "" on success;
## otherwise `manifest` is empty and `error` says what was wrong. It FAILS CLOSED
## on a bad artifact rather than emitting a manifest with a placeholder download —
## a manifest is only useful if the thing it points at is real, and a CI step that
## silently published a half-filled one would be exactly the guard-that-guards-
## nothing this project keeps having to delete.
static func build(artifact: Dictionary) -> Dictionary:
	var err := artifact_error(artifact)
	if err != "":
		return {"manifest": {}, "error": err}

	# The pack version IS the release the dev-log announces (ADR: "the pack
	# version tracks the release the dev-log announces"). CD stamps DevLog.VERSION
	# from the tag, so reading it here means the manifest cannot disagree with the
	# build it describes.
	var version: String = DevLog.VERSION

	# THE MONOLITHIC-SHELL ASSUMPTION.
	#
	# The ADR keeps the shell version independent of the pack, because a native
	# shell and a content pack are meant to ship separately. That split does not
	# exist yet: `export_presets.cfg` has one preset and no `patches=`, so the
	# shell and the pack ARE one artifact and honestly carry one version.
	#
	# This is true today and will become false the moment the pack pipeline lands
	# (ADR child 3). A comment would not stop that, so `update_manifest_test.gd`
	# asserts the export config is still monolithic — the day a pack split appears,
	# that test fails and forces the shell to be given its own source of record
	# here, rather than quietly continuing to publish the pack version as a shell.
	var shell_version: String = version

	return {
		"error": "",
		"manifest": {
			"schema": SCHEMA,
			"channel": CHANNEL,
			"shell": {
				"current": shell_version,
				"min_supported": SHELL_MIN_SUPPORTED,
				# The save floor and capability ceiling live in the STABLE envelope
				# because a client on a FUTURE schema decides from this block alone —
				# it is where a strand check matters most and evidence is thinnest.
				"reads_min": SAVE_SCHEMA_MIN,
				"reads_capability_max": SAVE_CAPABILITY,
			},
			"pack": {
				"version": version,
				# Monolithic: the pack needs precisely the shell it ships inside.
				# When the split lands this becomes the real compatibility floor.
				"min_shell": shell_version,
				# Full entry shape (the same one `RollbackSelection.is_wellformed`
				# requires), so today's pack is already a well-formed candidate for
				# tomorrow's rollback catalogue instead of needing a second format.
				"full": {
					"version": version,
					"url": str(artifact["url"]),
					"sha256": str(artifact["sha256"]),
					"size": int(artifact["size"]),
					# A CEILING, not a floor: the HIGHEST save schema this build can
					# read (`RollbackSelection` asks `read_ceiling >= save_schema`).
					# This build reads every committed golden fixture up to the one it
					# writes, so the ceiling is the write schema. Publishing the floor
					# here would make this pack look, once it aged into the rollback
					# catalogue, like it could not read the saves it wrote itself —
					# spuriously blocking later updates.
					"read_ceiling": CharacterFactory.RECIPE_VERSION,
					"save_capability": SAVE_CAPABILITY,
					"speaks_protocol": {"min": WireCodec.VERSION, "max": WireCodec.VERSION},
					"shell_compat": {"min": shell_version, "max": shell_version},
				},
				# No delta pipeline — a client falls back to the full pack.
				"deltas": [],
			},
			# A point value, not a range: both `wire_codec.gd` and the server's
			# `wire.go` hard-reject any version but their own, so advertising a
			# range would claim a tolerance neither side has.
			"protocol": {"min": WireCodec.VERSION, "max": WireCodec.VERSION},
			"save_schema": {
				"min": SAVE_SCHEMA_MIN,
				# What a freshly-written save carries, straight from the writer.
				"writes": CharacterFactory.RECIPE_VERSION,
				"capability": SAVE_CAPABILITY,
			},
			# Nothing retained yet. Empty is fail-closed, not unfinished — see the
			# class comment.
			"rollback_targets": [],
		},
	}


## Serialise a built manifest. Sorted keys and no indentation because these bytes
## are what a signature will one day cover (ADR: "the signing bytes are pinned"),
## and a byte-stable ordering is the cheapest half of that promise to keep now
## rather than to retrofit under a signing scheme.
static func to_json(manifest: Dictionary) -> String:
	return JSON.stringify(manifest, "", true, true)


## "" if `artifact` carries a usable download, else why it does not.
##
## Held to the SAME predicates `RollbackSelection.is_wellformed` applies to a
## catalogue entry, deliberately: the entry this produces must be one the
## rollback selector would actually accept, or we would publish a pack that
## becomes unselectable the moment it ages into the catalogue.
static func artifact_error(artifact: Dictionary) -> String:
	for key: String in ["url", "sha256", "size"]:
		if not artifact.has(key):
			return "artifact is missing '%s'" % key
	if not UpdateDecision.is_int_id(artifact["size"]):
		return "artifact.size is not a whole non-negative number"
	# Reuse the selector's own predicates rather than re-deriving "is this a URL"
	# and "is this a hash" — a second opinion on the same question is a second
	# place to be wrong.
	var probe := {
		"version": DevLog.VERSION,
		"url": artifact["url"],
		"sha256": artifact["sha256"],
		"size": artifact["size"],
		# Mirrors the real entry (a maximum, not a floor) so the probe validates the
		# same shape that will actually be published.
		"read_ceiling": CharacterFactory.RECIPE_VERSION,
		"save_capability": SAVE_CAPABILITY,
		"speaks_protocol": {"min": WireCodec.VERSION, "max": WireCodec.VERSION},
		"shell_compat": {"min": DevLog.VERSION, "max": DevLog.VERSION},
	}
	if not RollbackSelection.is_wellformed(probe):
		return "artifact.url must be an https URL and artifact.sha256 a 64-character hex digest"
	return ""
