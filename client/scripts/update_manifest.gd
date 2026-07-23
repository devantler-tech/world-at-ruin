class_name UpdateManifest
## What THIS build can truthfully say about itself to a future copy of itself.
##
## [UpdateDecision] is the brain of client self-update, but it decides from a
## manifest someone else has to write. This is that someone. It exists so the
## manifest is DERIVED from the constants the build actually runs on, never
## restated by hand in a CI script — a hand-written manifest drifts silently, and
## every no-stranding guarantee of the product law (no hard resets; an early
## player keeps playing as the game evolves) is decided from exactly these
## numbers.
##
## The rule this module is built around: it asserts only facts the repo can back.
## Where a fact does not exist yet, the manifest OMITS it rather than inventing a
## plausible value — a published manifest that lies about what the client reads
## is worse than no manifest at all, because the updater believes it.
##
## This build therefore publishes a **contract, not a delivery**: what it reads,
## writes and speaks. Every field that would tell a client where to FETCH
## something is withheld, and each omission is load-bearing:
##
##   * `pack.full` / `pack.deltas` — there is no pack. The ADR defines `pack.full`
##     as a mountable cumulative `.pck`, but CD builds and publishes a macOS
##     `.app` ZIP (one export preset, no `patches=`). Recording that ZIP here
##     would make it pass [RollbackSelection.is_wellformed], so a recovery after a
##     failed pack update could select it and hand an APPLICATION ARCHIVE to the
##     pack-mount path, which cannot restore anything. Omitted until the pack
##     pipeline (ADR child 3) produces a real artifact.
##   * `shell.download` — a shell replacement must be authorized by the offline
##     root (or platform codesign), carried in `shell_authorization`. That root
##     does not exist yet, so any download offered here would be an UNAUTHORIZED
##     shell replacement — the most dangerous thing this manifest could carry.
##     (This is also why the monolithic ZIP cannot simply be re-labelled a shell
##     artifact instead of a pack: that is the same unauthorized download.)
##   * `signature` / `key` / `revocation` — the Ed25519 + RFC-8785-JCS root of
##     trust is unstarted (ADR child 6). The published OCI artifact IS
##     cosign-signed by digest, which is a real integrity property, but it is a
##     different one and this module does not pretend otherwise.
##   * `rollback_targets` — nothing is retained yet. Empty is the FAIL-CLOSED
##     value: [UpdateDecision] treats an uncovered capability raise as blocked, so
##     an empty catalogue refuses a capability-raising pack rather than shipping
##     one no player could roll back from.
##
## Omitting delivery is not a gap to be filled in quietly — a client reading this
## manifest can learn it is out of date and say so, and can go no further. That is
## the correct state while there is genuinely nothing to deliver.
##
## See docs/design/distribution-and-self-update.md and the shape reference
## docs/design/client-update-manifest.example.json.

## The manifest schema this build emits. Taken from the consumer rather than
## written twice: emitting a schema our own client cannot read would be a
## self-inflicted `shell_update` loop.
const SCHEMA := UpdateDecision.SUPPORTED_MANIFEST_SCHEMA

## The only release channel that exists. [UpdateDecision] matches this string
## EXACTLY against the installed channel, so it is contract, not decoration.
const CHANNEL := "live"

## The oldest save schema this build can still read.
##
## Backed by evidence, not assertion: `save_fixture_guard_test.gd` proves this
## build reads every committed `tests/data/golden_recipe_v*.json`, and the oldest
## is v1. `update_manifest_test.gd` pins the two together, so dropping a fixture
## without raising this floor fails the suite.
const SAVE_SCHEMA_MIN := 1

## What a freshly-written save carries WITHIN its schema — the content-capability
## counter this build WRITES.
##
## Distinct from the schema version: a same-schema content addition (a new savable
## registry name) raises the capability without changing the save's shape.
##
## APPEND-ONLY, and it may only ever RISE — enforced against
## `tests/data/shipped_save_capability.txt`. Raise it by one in the same PR that
## adds a savable field. A build claiming to write LESS than it once did is
## exactly the stranding the no-resets law forbids.
##
## Capability 3 is vault-v2 discovery state. Its read ceiling shipped in v0.52.0
## and is now a retained rollback target, so this separate release may originate
## the shape without stranding a player who rolls back.
const SAVE_CAPABILITY_WRITES := 3

## The highest content capability this build can READ.
##
## Deliberately SEPARATE from [constant SAVE_CAPABILITY_WRITES], because the ADR's
## expand-before-write rollout needs a build that reads capability N+1 while still
## writing N. Collapsing the two into one constant makes that state
## unrepresentable: left low, the expansion build can never become an eligible
## rollback target; raised, `save_schema.capability` would falsely claim the build
## already writes the new shape, and the following release gets refused or
## needlessly routed away from a pack update despite a valid fallback existing.
##
## Must always be >= the write capability (a build must read what it writes).
## Capability 3 is vault-v2 discovery state. The v0.52.0 expansion release
## baked this ceiling before the writer above was activated.
const SAVE_CAPABILITY_READS := 3

## The oldest shell this manifest still supports updating FROM.
##
## `0.1.0` is the first version the project ever shipped, so nothing is excluded:
## the honest floor today is "everything". Raising it is a deliberate,
## player-visible act — it strands anyone below it.
const SHELL_MIN_SUPPORTED := "0.1.0"


## Build the update manifest for this build.
##
## Takes no arguments: every value is derived from this build's own constants, and
## the fields that would need outside input (where to fetch, and the signature
## over it) are exactly the ones withheld — see the class comment.
##
## Returns `{ manifest: Dictionary, error: String }`. `error` is "" on success;
## otherwise `manifest` is empty and `error` says what was wrong. It FAILS CLOSED
## rather than emitting something [UpdateDecision] would refuse in the field,
## where the failure is expensive and invisible.
static func build() -> Dictionary:
	# `cd.yaml` accepts a prerelease tag (`^v[0-9]+\.[0-9]+\.[0-9]+(-.+)?$`) and
	# stamps `DevLog.VERSION` from it, so a `v0.2.0-rc.1` release would put
	# "0.2.0-rc.1" here. `UpdateDecision.is_version` takes dotted digits ONLY, so
	# such a manifest would be refused as `invalid_manifest` by every client.
	# Refuse to emit it at all, loudly, rather than publish something dead on
	# arrival — and name which side has to change.
	var version: String = DevLog.VERSION
	if not UpdateDecision.is_version(version):
		return {"manifest": {}, "error": "version '%s' is not a dotted-integer version, so no client could accept a manifest carrying it — either the manifest version grammar must learn prerelease tags, or CD must stop building them" % version}

	# THE MONOLITHIC-SHELL ASSUMPTION.
	#
	# The ADR keeps the shell version independent of the pack, because a native
	# shell and a content pack are meant to ship separately. That split does not
	# exist yet: `export_presets.cfg` has one preset and no `patches=`, so the
	# shell and the pack ARE one artifact and honestly carry one version.
	#
	# True today, false the moment the pack pipeline lands (ADR child 3). A
	# comment would not stop that, so `update_manifest_test.gd` asserts the export
	# config is still monolithic — the day a pack split appears, that test fails
	# and forces the shell to be given its own source of record here.
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
				# where a strand check matters most and evidence is thinnest.
				"reads_min": SAVE_SCHEMA_MIN,
				"reads_capability_max": SAVE_CAPABILITY_READS,
			},
			"pack": {
				"version": version,
				# Monolithic: the pack needs precisely the shell it ships inside.
				"min_shell": shell_version,
				# No `full`, no `deltas` — see the class comment. There is no pack
				# artifact to point at, and pointing at the .app ZIP would offer the
				# pack-mount path something it cannot mount.
			},
			# THE RANGE THE LIVE SERVER ACCEPTS — not what this client speaks.
			#
			# [RollbackSelection] reads this as the server's accepted range when it
			# decides whether a retained target is still reachable, so during the
			# ADR's two-phase expansion (server accepts [1,2] while the newest client
			# speaks only 2) publishing the client's own version here would reject a
			# retained v1 target the server would still have talked to — defeating
			# last-known-good recovery.
			#
			# Sourcing it from the client codec is correct ONLY because both sides are
			# pinned to a single version today: `wire_codec.gd` and the server's
			# `wire.go` each hard-reject anything but their own, and
			# `update_manifest_test.gd` guards that the two constants remain equal.
			# When the expansion begins this MUST become a CD-supplied input read from
			# deployment state; the guard test is what will force that conversation.
			"protocol": {"min": WireCodec.VERSION, "max": WireCodec.VERSION},
			"save_schema": {
				"min": SAVE_SCHEMA_MIN,
				# What a freshly-written save carries, straight from the writer.
				"writes": CharacterFactory.RECIPE_VERSION,
				"capability": SAVE_CAPABILITY_WRITES,
			},
			# Nothing retained yet. Empty is fail-closed, not unfinished.
			"rollback_targets": [],
		},
	}


## Serialise a built manifest to the exact bytes a signature will cover.
##
## [JCS] canonicalizes per RFC 8785, the standard the ADR pins the signing bytes to
## so that two conforming implementations never derive different bytes. This used
## to be `JSON.stringify(..., sort_keys)` — byte-stable, but NOT RFC 8785: Godot
## orders member names by code point where JCS requires UTF-16 code unit, and the
## two disagree for every supplementary-plane name.
##
## Pinning the bytes before a signing scheme exists is deliberate. Today nothing
## signs anything, so changing them costs nothing; once a key is in play the same
## correction invalidates every signature already issued.
##
## Returns `{"error": String, "text": String}` — the shape [method build] uses.
## When `error` is non-empty the manifest contains a value the canonicalizer has no
## conformance vectors for, and `text` is empty: it must not be signed or published,
## because bytes we cannot reproduce are bytes a verifier will reject.
static func to_json(manifest: Dictionary) -> Dictionary:
	return JCS.canonicalize(manifest)
