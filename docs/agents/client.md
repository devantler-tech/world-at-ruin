# Client — structure, running, tests and player-visible work

> Part of the [AGENTS.md](../../AGENTS.md) contract. Read it before any client, asset,
> save-format or player-visible change.

## Project structure

- **Editor-only scenes are NOT dead code.** Three scenes are deliberately unreferenced by the running
  game and exist as **editor surfaces**: `client/scenes/recipes.tscn` (the character taste gate,
  documented in `recipe_gallery.gd`), `client/scenes/cave.tscn` (the cave-generation preview
  harness, documented in `cave_system_gen.gd` — a `@tool` rig for judging cave interior/exterior work
  by eye, #124), and `client/scenes/telegraph.tscn` (the telegraph readability preview harness,
  documented in `telegraph_preview.gd` — looping circle/cone casts under the shipping overworld
  lighting for judging the ground read by eye, #175). A repo-wide "no references, therefore dead"
  sweep will flag all three; check the owning
  script's docstring before proposing a deletion, and retire such a scene only when the work it
  supports is finished — saying so in the same change. Anything unreferenced **without** such a
  marker is genuine scaffolding and should go (as `scenes/character.tscn` did in #116).
- **Structure:** `client/` is the Godot 4 project (scenes built in GDScript from engine
  primitives). The one sanctioned exception to "no binary assets" is `client/assets/` — artifacts
  BAKED BY COMMITTED CODE (`tools/artgen/`, the Python/bpy exception) from CC0 data, plus the
  sanctioned committed CC0 base meshes that generators reshape in code (maintainer direction on
  #20); every asset directory carries a `PROVENANCE.md` with its source/licence chain and an exact
  SHA-256 manifest of every tracked non-Markdown file it covers (enforced by
  `tools/provenance-guard.sh` in the `license-guard` job — a directory holding any non-Markdown
  file must be covered by a `PROVENANCE.md` at itself or an ancestor, and every addition or byte
  replacement must be deliberately accounted for there). The same guard requires every tracked
  Godot-supported image under `client/assets/` to carry an indexed texture `.import` sidecar with
  `mipmaps/generate=true`: this is a 3D asset catalogue, and a texture reached only through runtime
  `load()` never triggers the editor's 3D-use detection. `skin_texture_mipmaps_test` remains the
  runtime proof that the shipped skin images actually carry a mip chain and that their material
  samples it; the static guard prevents the next registry from escaping that proof class. Bakes must
  be deterministic (the artgen workflow re-bakes and byte-compares). Characters are
  composed at runtime by `CharacterFactory` from **recipes** (`client/recipes/*.json`, versioned
  and name-keyed — names are forward-only per the no-resets law; `tests/save_fixture_guard_test`
  enforces it: every historical golden fixture must load with zero loss, every recipe version up
  to `RECIPE_VERSION` must have one, and `tests/data/shipped_recipe_versions.txt` is the
  append-only ledger anchoring that range — bumping `RECIPE_VERSION` means appending the ledger
  line AND committing the version's golden fixture in the same PR). **Progression state lives in a
  SEPARATE versioned file** — `SaveVault` (`user://vault.json`, #249): the recipe format is closed
  (`CharacterFactory.validate` rejects any unknown top-level field, and every shipped client already
  enforces that), so the character save cannot grow new kinds of data without older clients refusing
  it. `CharacterStore.load_from()` parses the JSON object and then asks
  `CharacterFactory.refusal_reason()` whether this build can accept it, latching a refusal on the
  path when it cannot — the same shape as the vault's, and latched for the life of the process so a
  recipe that disappears after being refused does not reopen a writable path. While a path is
  refused, `save_to()` and `clear()` both refuse it and `main.gd` locks every character-creator
  entry, so an unreadable recipe is never mistaken for a first run. Both writes additionally run under
  the SAME cross-process `FileLock` the vault takes — spanning the acceptance read, the validation and
  the rename as one unit, and proving ownership again before the rename (`tests/character_lock_test`);
  the two stores fail the same way for the same reason rather than each growing a bespoke mechanism.
  The recipe additionally carries the same **compare-and-swap on its own bytes** the vault (#386) and
  the boot-recovery ledger (#453) do (#469, `tests/character_cas_test`) — `document_identity()` plus an
  `expected_identity` argument to `save_to()`/`save_recipe()`, with `IDENTITY_UNCHECKED` the explicit
  opt-out so blind seeds and the existing refusal, lock and staging suites are unaffected. The lock and
  the CAS answer different halves and neither subsumes the other: the lock keeps cooperating writers
  from ENTERING the read-modify-write together, and cannot see that the base a caller READ has moved on
  — two clients opening the creator from the same saved recipe serialise exactly as intended and the
  second still discards the first's character. **The identity is captured BEFORE `load_saved()`**, in
  `main.gd::_open_creator`: captured after, a foreign write landing between the load and the capture
  becomes the expectation while the creator still opens on the old recipe, and the check passes. A
  stale-identity refusal is **retryable and never latches** — it joins lock contention on that side of
  the distinction #423 established, rather than becoming a second permanent refusal — and
  `CharacterStore.last_refusal()` names which of the three outcomes occurred, because one
  undifferentiated `false` cannot tell a caller whether to retry or lock the creator shut.
  `CharacterStore._last_write_expectation` exists so a test can prove the production apply threads a
  REAL identity directly, rather than only through a consequence: a caller writing blind is
  indistinguishable from a correct one until something races it, and that ablation was measured
  passing every assertion in `character_cas_test`. It is asserted in `character_revert_boot_test`'s
  control arm, against the scene that actually calls `save_recipe()`. That test's arm D catches the
  same ablation behaviourally — it stages a real race, so a blind apply overwrites the foreign
  character and fails there too — and the two are deliberately kept: the control arm names the cause
  in one line, arm D proves the player-visible consequence. Unlike the vault and the ledger, whose
  end-to-end coverage that ablation passed outright, this file has both.
  The character store's staging sweep keeps an age floor the vault has no need of, because a retained
  rollback build or a foreign writer stages through that prefix without ever taking the lock. A sibling file is the only shape a shipped client
  handles safely: it never reads it, so it never rejects or deletes it. The vault obeys the same laws
  (name-keyed, additive-only, newer versions refused) with the same enforcement shape —
  `tests/save_vault_guard_test`, golden `tests/data/golden_vault_v<N>.json`, and the append-only
  `tests/data/shipped_vault_versions.txt` — plus two rules of its own: a missing or unreadable vault
  DEGRADES to session-only and may never block a boot, and a vault that exists but cannot be read is
  READ-ONLY for that session (refuse-to-read implies refuse-to-write, or a downgrade would overwrite
  progression a newer client wrote). Every write additionally runs under a cross-process lock spanning
  the whole read-modify-write, so two lock-aware clients cannot each read the same document, merge
  their own change and have the slower rename discard the faster one's progression
  (`tests/vault_lock_test`). The lock is a DIRECTORY beside the vault —
  `DirAccess.make_dir_absolute` is `mkdir`, the only atomic exclusive-create Godot exposes, and a lock
  built from `FileAccess.open` would be check-then-act again, so do not "simplify" it into a file. It
  carries an ownership claim and is therefore deliberately NOT empty: renaming onto an empty directory
  succeeds, and the claim also lets a holder prove the lock is still its own before it replaces the
  vault. **Acquisition is only ever that single `mkdir` on an absent path. Reclaiming an abandoned lock
  is a SEPARATE pass that never acquires** — it renames the stale directory aside (rename wins for
  exactly one process, which serializes reclamation), verifies on that private copy the timestamp it
  judged abandoned, removes it, and still refuses; the next attempt acquires the freed slot. Folding
  reclaim and acquire back into one pass lets two processes each recreate the lock over the other and
  both proceed as owners, so never restore remove-then-create. **Ownership itself is settled in ONE
  step at both ends, and neither end may become a test followed by an action**
  (#430, `tests/lock_ownership_test`). The lock is **PUBLISHED WHOLE**: built complete — stamp included
  — in a private `.staging-<pid>-<ticks>` directory and `rename`d into place, so the shared path never
  holds a half-built lock. Do not "simplify" this back to creating the lock and stamping it afterwards:
  an acquirer descheduled in that gap past the stale timeout has its empty lock reclaimed and the slot
  retaken, and it then stamps BY PATH over the new holder's token, recording itself as owner of a lock
  it never created. Publishing keeps one refusal guard in front of the rename, because `rename` fails
  onto a non-empty directory but REPLACES an empty one (measured) — an existing lock directory is
  refused rather than displaced, so a bare lock still excludes a writer exactly as it always has. That
  guard only ever turns a success into a refusal, which is why it is not check-then-act.
  The **release renames the STAMP, never the lock**, to `owner.release-<pid>-<ticks>` inside the lock,
  and verifies the token there before deleting. Taking the whole lock aside would empty the slot for
  the length of the check, and a briefly-absent lock is one a third process can acquire — so a stale
  former holder would vacate the CURRENT holder's slot, admit a third writer, then delete the displaced
  lock. Keeping the lock present and non-empty throughout means nothing can acquire or create a stamp
  meanwhile, so the restore cannot collide. Do not delete the lock at its shared path after asking
  `owns()`. The on-disk shape is deliberately UNCHANGED by all this — atomicity comes from the rename,
  not from the stamp's shape — so a retained older client and a current one still exclude each other
  exactly as before. `FileLock._last_publish_staging` and `_last_release_private` exist solely so tests
  can prove acquisition and release really go through those paths: single-threaded, both the fixed and
  the broken shapes leave identical end states and differ only under a real substitution, and each
  broken form was measured passing every other case in that suite. **Scope the claim honestly:** a lock
  binds only writers that take it, so pre-lock retained/rollback builds and foreign writers (cloud
  sync, a hand edit) walk straight through it. Those are covered by a **compare-and-swap on the
  document's own bytes** (#386, `tests/vault_cas_test`): the read-modify-write records the vault's
  SHA-256 when it reads it and refuses the rename once the file no longer carries it, which keys on
  what the file IS rather than on who cooperated. The identity is captured BEFORE the load — captured
  after, a foreign write landing in between would become the expectation while the merge still held the
  old document and the check would pass; captured before, that interleaving refuses. `save_to()`
  remains a blind whole-document replace via an explicit sentinel so fixture seeding is unaffected;
  `replace_if_unchanged()` is the guarded path every persist takes. It shrinks the window to the rename
  syscall rather than closing it — closing that needs an OS-level lock held across the rename, which
  Godot does not expose — so the gain is a DETECTED refusal in place of a silent lost update.
  `SaveVault._last_write_expectation` exists solely so a test can prove the production path threads a
  real identity: a helper writing blind is indistinguishable from a correct one until something races
  it, and that ablation was measured passing every end-to-end assertion. **Each write stages through a
  PRIVATE `vault.json.tmp-<pid>-<ticks>`, never a shared `vault.json.tmp`** — the CAS verifies the
  target, so a pre-lock build truncating our staged document leaves `path` untouched, passes every
  check, and gets its partial bytes committed by our rename. Do not "simplify" staging back to a fixed
  name; `_sweep_abandoned_writes()` (under the lock, prefix-scoped) reclaims what a fixed name used to
  get for free by being overwritten, and tests must match staging files by PREFIX or they assert
  vacuously. Contention degrades to session-only rather than blocking
  a boot, and the stale timeout is generous on purpose — shortening it to make writes prompt would let
  a live writer be robbed mid-write. Tests redirect it with `WAR_VAULT_PATH`, mirroring
  `WAR_SAVE_PATH`, and seam the timeout with `WAR_LOCK_STALE_SECONDS` (test-only; malformed or
  negative values keep the shipped window). Production writers emit vault v4 only when a real quest
  objective advance adds or raises `quests`; reward-only documents remain v3, discovery-only
  documents remain v2, and empty or attunement-only documents remain v1. `Main` restores accepted
  claims into its boot-owned
  `ExplorationRewards` tracker, re-applies their registered horizontal outcomes, and records a newly
  discovered place only after its outcome succeeds. Because a claim persists only the place id, the
  append-only `tests/data/shipped_reward_mappings.tsv` ledger permanently binds each shipped claim to
  its exact reward payload; the real boot guard checks the production registry bidirectionally and CI
  base-compares complete rows. The retained v0.61.0 capability-4 reader is the rollback target that
  permits the reward writer. The vault reader accepts optional v4 `quests` as
  `quest_id → objective_id → progress in the exact JSON integer range 0..2^53-1`, and the manifest
  requires save capability 6. The retained v0.70.0 capability-6 reader is the
  whole-app rollback target that permits this writer. `Main` restores that data
  into its boot-owned `QuestLog` before definitions register; the tracker preserves opaque future
  IDs and raw progress, clamps only its live known view, and latches restored completion without
  announcing it again. Every later monotonic objective advance queues the complete snapshot for the
  same locked, compare-and-swap vault path; transient failures retry with bounded exponential backoff,
  while an unreadable or newer vault remains session-only and byte-intact. The writer merges progress
  by maximum value, so retry, rollback-only IDs and a higher concurrent value can never be driven
  backwards. The vault-v5 reader additionally accepts a complete `mastery` snapshot whose stable
  weapon IDs map to exact banked and unbanked points and whose standing bloodstain is restored as
  part of the same ledger. `Main` applies that snapshot to its boot-owned `Mastery` before content
  registration; unknown future weapon IDs stay live. The manifest advertises read and write
  capability 7, backed by the retained precision-safe v0.93.1 whole-app reader. Only real mastery
  transitions originate vault v5: `MasteryPersistence` saves complete snapshots synchronously,
  coalesces transient refusals with backoff capped at 30 seconds, and flushes once on clean exit.
  The whole transaction holds `FileLock`, compares this session's acknowledged mastery, and passes
  the vault identity captured before load to guarded replacement. A competing mastery snapshot
  permanently fences the session's writer, including exit flush; unrelated progression is preserved.
  `mastery_vault_writer_test` directly asserts the original byte identity, and
  `mastery_lock_process_test` exercises real foreign-process contention and recovery.
  Combat award sources and interactive death/reclaim remain separately scoped; production gameplay
  does not yet call those ledger operations. **The lock lives in
  `FileLock`, not in the vault, and `BootRecovery` persistence takes it too**
  (`tests/boot_recovery_lock_test`) — that file's two writers, the updater and the game, both exist
  today, and a lost update there discards the evidence deciding whether a client rolls back. One
  primitive guards both files; a second mechanism for the second file would be a second set of bugs.
  **All three persisted writers — vault, character store and boot recovery — stage through a PRIVATE
  `<file>.tmp-<pid>-<ticks>`, never a shared `<file>.tmp`.** A derivable staging name is a hole no
  target-side check can see, because the target is untouched until the rename. **Whether that
  writer's abandoned-stage sweep may delete unconditionally is decided by SHIPPING ORDER, and copying
  the wrong shape deletes a live write rather than a dead one.** An unconditional sweep is safe only
  while every build that can create a file carrying the prefix also takes the lock. Vault and boot
  recovery gained their lock BEFORE private staging, so that holds and their sweeps are lock-gated
  alone. The character store is the mirror image — private staging (#434) shipped before its lock
  (#423) — so retained builds from that window stage through its prefix taking no lock, which is why
  it keeps an age floor permanently, lock or no lock. Before reusing either sweep, ask which order the
  writer you are copying INTO shipped them in.
  The immutable shell's recovery memory is a third persisted contract:
  `BootRecovery` (`user://boot_recovery.json`) reads through schema v1 and writes explicit v1 on
  first boot or the next real write of legacy v0 state. The retained v0.51.1 app reads v1 and is the
  rollback target that permits this writer; v0 remains readable forever. The contract is anchored by
  `tests/boot_recovery_guard_test`, `tests/data/golden_boot_recovery_v<N>.json`, and
  `tests/data/shipped_boot_recovery_versions.txt`. A corrupt or future recovery document is
  path-latched read-only and refuses new update attempts; persistence revalidates the destination
  immediately before replacement. That revalidation catches a destination this build cannot READ;
  a foreign document that reads perfectly well is caught by the ledger's **compare-and-swap on its
  own bytes** (#453, `tests/boot_recovery_cas_test`), the same guard and the same shape the vault
  gained in #386 — `document_identity()` plus an `expected_identity` argument to `save_state()`,
  with `IDENTITY_UNCHECKED` left as the explicit opt-out so blind seeds and the existing lock and
  staging suites are unaffected. **The identity is captured BEFORE `load_state()`**, in
  `main.gd::_reconcile_boot_recovery_locked`: captured after, a foreign write landing between the
  load and the capture becomes the expectation while the transaction still holds the old document,
  and the check passes. Neither that ordering nor `document_identity()`'s unhashable-file branch is
  pinned by a test — both were ablated and both stayed green, because separating them needs a
  second process and a genuinely unhashable file respectively — so both are guarded by review, and
  the test file names them rather than implying coverage. `BootRecovery._last_write_expectation`
  exists solely so `boot_ledger_boot_test` can prove the BOOTED scene threads a real identity: a
  caller writing blind is indistinguishable from a correct one until something races it, and that
  ablation is measured passing every other assertion in both suites.
  The degraded state exposes a readable empty quarantine view so
  broken recovery metadata cannot itself veto an otherwise-compatible retained rollback.
  This is deliberate: rollback targets still independently prove save, protocol and shell
  compatibility, while refusing every target would guarantee the stranding recovery exists to
  prevent. Tests redirect it with `WAR_BOOT_RECOVERY_PATH`. Non-humanoid **creatures**
  follow the same shape — `CreatureFactory` composes a baked creature kit (the ash hound is the
  pilot archetype) from versioned, name-keyed, forward-only recipes, one canonical skeleton per
  archetype. `tests/creature_factory_test` binds every version through
  `tests/data/shipped_creature_recipe_versions.txt` to its matching
  `tests/data/golden_creature_recipe_v<N>.json`; CI runs that scene in a dedicated non-skippable
  product-law step and holds the ledger append-only against the base revision. `server/` is the Go
  authoritative tier — its **zone tick core** has landed
  (`server/sim/`, the deterministic fixed-timestep simulation; `server/cmd/zone/`, the runnable
  skeleton), plus its **area-of-interest** query and enter/leave tracker (`server/sim/aoi.go` —
  the seam the replication layer consumes, with its own cross-platform golden) and the
  **replication snapshot** built on it (`server/sim/snapshot.go` — per-observer state plus the
  minimal spawn/update/despawn delta, its own golden pinning the state stream) and the
  **versioned wire codec** that frames that payload (`server/wire/` — transport-agnostic binary
  encoding, fail-closed decode, committed hex goldens pinning the byte layout for the future
  client-side decoder), and the **zone socket** implementing the transport ADR
  (`server/zonesock/` — WebSocket over TLS per `docs/design/zone-transport.md`, one codec message
  per binary frame: token-gated fail-closed admission, bounded send queue with snapshot resync on
  overflow, write/idle deadlines, hard inbound size cap; opt-in via `zone -listen`, off by
  default; terminal hub shutdown cancels admission, drains upgraded sockets and clears observer
  interest on the simulation owner before lifecycle shutdown, with bounded waits and visible
  errors; no durable lease release or process-death proof, per ADR 0007),
  its **default-off authoritative movement** (`zone -movement-intents` plus explicit
  wire-v3 negotiation; retained v1/v2 replication unchanged; bounded newest-input
  mailbox applied only before the simulation step, server-owned ground speed,
  silence expiry and a separate coalesced own-position/applied-sequence acknowledgement;
  no player prediction composition or production activation, per ADR 0024),
  its **default-off client movement networking** (`WAR_ZONE_MOVEMENT=1` selects
  v3 at connect time; `ZoneConnection.queue_movement` submits newest finite planar
  samples at most 30 Hz, with bounded writes, cumulative ACKs and fresh reconnect
  state; ordinary v2 and player controls remain unchanged, per ADR 0025;
  required client CI runs `WAR_GODOT_ZONE_PROOF=1 go -C server test -count=1
  -timeout 90s ./cmd/zone -run '^TestNativeGodotMovement$'` against the built
  verified-TLS zone, with missing prerequisites failed rather than skipped),
  the **latent integer prediction core** (`GroundStep` and `PredictedMovement`,
  ADR 0026 — explicit immutable isolated-flat configuration, exact integer
  ground arithmetic and bounded speculative tick replay independent of sent
  sequence ownership; shared actual Go position goldens plus the native TLS
  prediction scenario; no collision parity or production configuration discovery),
  the **default-off predicted player body** (`WAR_PREDICTED_MOVEMENT=1`, which
  also requires `WAR_ZONE_MOVEMENT=1`; `PredictedBody` steps the prediction at
  30 Hz from the player's controls, interpolates it to the display rate, shows a
  correction as an offset that decays over 100 ms and snaps once a correction or
  the drawn error is wider than the 0.4 m capsule radius, holds still rather than
  refusing when the zone is silent for the whole 120-tick replay window, keeps the
  jump a render-only hop per #814, and hands the
  body back to local physics on any refusal or lost connection; the demo zone's
  settings are its fixture configuration; `predicted_body_test`, #812),
  the **Agones lifecycle** (`server/agones/` — Ready/Health/Shutdown through the
  official SDK, opt-in and default-off; its sealed-admission mode accepts a projected RSA public
  key, generates one in-memory 32-byte secret while the GameServer is `Starting`, publishes the
  identity-bound ciphertext/fingerprint/readiness metadata, observes those exact values through
  `WatchGameServer`, and only then permits the serving command to call `Ready`; an allocatable
  restart calls `Shutdown` without rotating metadata), the latent **zone claim gate**
  (`server/zoneclaim/` plus `zonesock.NewClaimedHub` — claims through a private boundary before
  upgrading a socket, using only the exact sealed GameServer's observed allocation locator;
  cancellation, token expiry, metadata changes, watch termination and lifecycle shutdown refuse
  admission, and an invalidated observation cannot be reused after restoration), the inert
  **private claim boundary** (`server/claimrpc/`, ADR 0005 — verified mutual TLS identifies the
  exact namespace/GameServer UID; opaque lease lookup, pinned resource/envelope resolution and
  canonical token verification precede a conditional claim in the existing schema; no-show cleanup
  races on that same version, replay reads durable state, and ambiguous admission retains the claim;
  strict bounded requests, generic refusals and a verified client with no redirects;
  additive `/v2/claim` returns the original durable version/generation while `/v1/claim`
  retains its empty acknowledgement. Explicit `zoneclaim.NewReceiptGate` admission retains
  one immutable receipt across reconnects and failed upgrades; the command keeps the v1 gate.
  `NewCustodiedReceiptGate` additionally requires explicit `CustodyConfig.Enabled` and an
  injected custodian. It withholds admission/receipt export until original custody ACK,
  latches uncertainty before initial claim dispatch and never retries an ambiguous
  initial claim or custody result. Acknowledged reconnects authenticate without refreshing
  the original receipt. Run the custody race and real mutual-TLS controls in `zoneclaim`
  and `claimrpc`; fixture storage proves no native durability. Keep this gate for its lifetime,
  never copy/reconstruct it. ADR 0043/#1336 retain independent launch enrollment,
  authenticated durable custody, rollback-resistant witness and termination gates;
  no normal command or completion caller composes this source boundary.
  The inert `server/internal/zonecustody/` owner requires explicit `Config.Enabled`
  and two private system-owned create-only schema-1 documents. One original
  allocation key excludes owner/child correlations; copies share terminal
  enrollment/custody attempts, and only originating exact ACKs export a live
  custodian or detached pins. Strict permanent readers compare complete private
  data against independently retained pins and never reconstruct a handle.
  Run its race/reader/import controls and `claimrpc` custody integration, plus
  the server durability guard for both families. ADR 0044 keeps authentication,
  bootstrap/child launch sequencing, protected ACK custody, rollback witness and
  completion outside this source delivery; fixture storage is not native proof.
  The native-only `WAR_ZONE_CUSTODY_PROBE_ENABLED` experiment uses diagnostic
  lifetime/receipt fixtures against actual Nakama/PostgreSQL. Require its six
  mandatory amd64/arm64 scenarios for private create-only writes, competing
  processes, lost/canceled replies, exact source death and complete fresh-reader
  refusals and the original private-claim receipt/storage ACK join. The separate
  `WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE=control` mode accepts a receipt-free
  binding/observer input and consumes one complete actual private claim response
  after the original enrollment ACK. Require its committed-before-ACK hold,
  reply-loss/cancellation, changed-binding, source-death and restart controls.
  Its fixture CA and loopback coordination prove neither issuer identity,
  protected production custody nor exclusive child launch. Normal artifacts have
  no probe/writer dependency. ADR 0045/#1342 and ADR 0050/#1371
  preserve #1340/#1341/#1336/#1318/#567 authority gates; #1192 owns retirement.
  `server/internal/custodywitness/` holds the #1341 witness record contract and
  its client over an abstract table: one schema-1 record per ADR 0044 lifetime
  key whose stage moves enrolled → custody → tombstone, carrying exactly the pins
  of reached stages. Its strict reader and `Follows` refuse any skipped, repeated
  or backward step or rewritten pin. The default-off client checks the pinned
  table identity before and after every read and write, writes conditionally on the exact
  previous record, resolves a lost reply by one exact re-read and never retries;
  `Compare` returns one of seven verdicts and only `verified` is positive. It
  grants no authority, and nothing composes it; the DynamoDB adapter and native
  trial are #1442/#1443. Keep its import control and the server durability
  guard for the `custody_witness` family. The package also holds the #1444
  allocator-generation record (`generation_witness` family, its own key
  namespace): stage registered → drained → handoff → owner → recovered →
  published, where registration repeats only by advancing the issued-grant count
  by exactly one with a new pin and set digest, and every later step keeps the
  count, set digest and earlier pins. `WriteGeneration` and `CompareGeneration`
  reuse the same pinned, conditional, single-re-read path under the
  `generation/` key prefix (zone keys stay bare); ahead and behind are reported
  only within one registration, and a differing grant count is `conflicting`.
  Nothing composes them (#1498).
  The separately constructed completion handler requires exact workload identity plus a
  server-injected irreversible termination verifier before original-version fencing and
  UID cleanup (ADR 0020). It opens no listener and has no runtime or shutdown-hook caller;
  attested
  workload certificate issuance, platform listener deployment and session-end recovery remain
  separate work; the command composes the gate only through default-off `-private-claims`,
  requiring sealed Agones admission and separate verified mTLS credentials, loading bounded
  material before readiness and retiring transport after admission drains, per ADR 0008),
  the inert **session-end storage boundary** (`nakamalease.Store.EndSession`, ADR 0006 —
  original claimed version, claim stamp, opaque key, attempt digest, allocation and pinned UID
  must all agree before atomically entering the existing release barrier; exact-UID resource
  cleanup precedes conditional reservation deletion; failures retain restart recovery state;
  no new storage schema or death detector; the private completion interface does not activate
  a production listener or provide termination proof. Trusted end-of-session proof
  and production lifecycle composition remain #567/#569 work),
  the first **Nakama identity boundary**
  (`server/nakamaauth/` — locally validates audience-bound Google ID tokens, derives a
  server-keyed opaque email/password pair whose logged identifier is not replayable alone,
  provisions through Nakama's generated `AuthenticateEmail` API, verifies the returned session,
  and atomically preserves that authenticated user ID in a private system-owned create-only
  binding so mutable Nakama email link/unlink operations cannot detach the Google identity;
  repeat sign-in resolves the durable binding without reusing the email field, then checks the
  exact Nakama account still exists and is enabled; the strict schema and complete
  identity-address contract are base-anchored before this default-off writer is composed), the
  **player handoff core**
  (`server/handoff/` — gives only that verified identity plus a caller-stable reservation key and
  server-generated attempt ID to an allocation boundary, conditionally reconciles ambiguous
  outcomes by that owned attempt, constrains the returned endpoint to the configured managed DNS
  domain, requires an expiring no-show lease, observer binding and per-allocation admission secret,
  and mints the nanosecond-expiry token only that allocated zone verifier accepts), the private
  **Nakama handoff lease store** (`server/nakamalease/` — server-owned, strict-schema objects keyed
  by a SHA-256-derived user/reservation key; unique create and exact-version
  staging/dispatch/finalization/replacement/claim/release preserve one current attempt under retries,
  with base-anchored permanent schema-shape goldens, a durable uniquely identified dispatched point
  of no return and a durable releasing barrier; its private-collection expiry sweep arbitrates zone claim against external
  cleanup while retaining ambiguous dispatches for exact reconciliation, without persisting raw user
  or reservation IDs or admission secrets; the
  durability contract those objects follow — and that every later server-held record inherits — is
  [`docs/design/server-state-durability.md`](../../docs/design/server-state-durability.md)), the private
  **player-state mutation boundary** (`server/playerstate/` — atomically commits one private
  conditional record write with one private create-only audit object under the same player or system
  owner boundary, binds the caller's stable mutation key to its operation and normalized payload,
  and returns the original outcome on replay or an ambiguous committed response; its strict audit
  schema is permanently ledgered, and it remains inert until a record owner calls it), the private
  **Nakama character-record owner** (`server/nakamacharacter/` — stores one strict-schema character
  document at an account-derived key under Nakama's system owner, authenticates the requested account
  against the runtime caller, rejects client-owned preseeds plus public, malformed or stale
  observations, keeps every shipped schema readable through a ledgered golden, and delegates every
  conditional write and system-owned replay audit to the atomic `playerstate` boundary; it remains
  inert until a server caller composes it), the private **Nakama inventory-container owner**
  (`server/nakamainventory/` — stores one strict-schema container of opaque item stacks at an
  account-derived key under the system owner, bounds stacks and counts so no write can mint an
  unbounded amount of anything, refuses a stale observation or a malformed durable container, keeps
  every shipped schema readable through a ledgered golden, and commits every replacement with its
  replay audit through the same atomic `playerstate` boundary; the item model is not its concern), the server-owned
  **friends boundary** (`server/nakamafriends/` — edits and reads one player's Nakama friend graph
  acting only for the verified session identity, names only another well-formed player, refuses an
  invite towards a target that player has blocked rather than letting Nakama drop it silently, maps
  Nakama's four friend states onto a closed vocabulary and refuses any other shape, and sanitises every
  graph failure so a caller learns its own cancellation and nothing about the store; it holds no state
  and is inert until an RPC composes it), the
  durable **handoff allocation coordinator**
  (`server/handoffalloc/` — implements `handoff.Allocator` over the real lease store and an injected
  GameServer-resource boundary; exact-version persists a uniquely identified dispatched barrier
  before the one allowed external allocation call, reconciles lost barrier acknowledgements so only
  the persisted caller dispatches, makes replays and concurrent losers reconcile only that exact
  attempt, lets transport retries observe ambiguous dispatches or reuse finalized unclaimed
  allocations without redispatch, retains every published resource and ambiguous post-dispatch
  outcome against overlapping response-failure cleanup, quarantines unresolved dispatches against
  expiry and unverified outer cleanup, releases at once a dispatch the allocator answered
  definitively unallocated (an empty pool — fenced, released by attempt label, then forgotten, so a
  fresh attempt may follow), detaches known-resource fence-and-cleanup from caller
  cancellation, finalizes the allocation before returning connection material, protects
  claimed/stale ownership and supervises exact no-show cleanup without stopping after transient
  sweep failures; its concrete Agones adapter is `server/agonesresources/`, and it remains inert
  until the default-off `server/nakamaruntime/` plugin is explicitly enabled to supervise its
  expiry loop and register the authenticated `war_handoff` RPC (empty payload; one server-owned
  reservation per player, so a client cannot open parallel allocations); its configuration, observer-1
  binding, mutual TLS and shutdown requirements are documented in that package; its independent
  default-off `WAR_HANDOFF_CLAIMS_ENABLED` listener composes the same lease store and resource
  resolver over verified workload mutual TLS, with bounded connections/requests, startup rollback
  and module-owned cancellation/drain, per ADR 0009), and
  the **orphan reconciler** (`server/orphanreaper/` — completes bounded resource
  and private lease scans, protects every stored attempt regardless of expiry,
  requires consecutive orphan observations plus grace, and deletes only the
  revalidated UID and resource version; the Nakama module supervises startup/periodic sweeps
  only with the independent default-off `WAR_HANDOFF_ORPHANS_ENABLED` runtime.env flag,
  shares its existing private lease store and resource scope, and drains both workers before
  transport retirement; count-only observations and bounded settings are documented in that
  package and ADR 0021), and the **combat first
  slice** (`server/sim/combat.go` — the telegraph cast
  lifecycle: painted at cast start, resolved once after a tick-counted cast time against
  positions at resolution, health/damage application, and one mob AI that deterministically
  aggros the nearest entity; a mob with positive `ChaseSpeedMM` closes through the existing
  kinematic movement path to a bounded capsule-surface cast range before stopping and painting the
  dodgeable circle, while zero chase speed deliberately preserves a stationary caster; the
  integer-speed floor remains mobile on diagonals; threat from damage, dead-target
  filtering, real navmesh pathfinding and cast replication remain later children — with its own
  cross-platform golden). The zone-side sealed-envelope boot from
  `docs/adr/0002-seal-zone-admission-secrets-before-readiness.md` is available through
  `zone -agones -agones-admission-public-key <path>`; production activation of orphan supervision
  and its flag retirement (#1177), session-end recovery,
  platform deployment of the default-off Nakama RPC plugin and broader persistence remain later children of the server-foundation
  epic (#4);
  `deploy/` contains the opt-in private zone trial's tenant manifests. The host
  owns namespace-wide default-deny ingress and egress; standard Kubernetes
  NetworkPolicy resources must stay out of the tenant artifact. Run
  `go -C server test -count=1 ../tools/deploy-manifests/main.go ../tools/deploy-manifests/main_test.go`
  (Go and `kubectl` required) to check the actual rendered bundle and nested-resource refusals.
- **Raised exposed-stone overlay (#547, ADR 0001) — default-off, solid where drawn.** Under
  `WAR_GROUND_PLATES=1` `WorldGen` adds one `GroundPlates` `MeshInstance3D` after the rest of the
  world is built: `ExposedSlabGeometry` walks the deterministic `ExposedSlabField`, lifts every slab
  whose site and enough of whose corners the field decides are exposed (`MIN_EXPOSED_CORNER_SHARE`)
  by a per-slab integer-hashed thickness, closes the lip with side strips buried below the ground,
  and packs all of it into ONE `ArrayMesh` surface sharing the terrain's `ShaderMaterial` — the
  shader derives plate identity, substance and exposure from world position, so a lifted top renders
  as the slab beneath it and no slab owns a node, material or draw call. The overlay casts no shadow:
  measured, the shadow passes were most of its cost (p95 wall-clock delta 1.34 ms → 0.52 ms at
  1280×720 on Apple M2 Pro), and a 6–14 cm side face already darkens by the sun's angle. Tops conform to the ground
  EXACTLY: each polygon is split along the terrain grid lines and quad diagonals it crosses so every
  piece lies in one terrain triangle, and the side strips split at the same crossings.
  `exposed_slab_geometry_test` holds that law on a hand-built creased ground and on the real world,
  proves two fresh builds agree, and proves the flag-off world's terrain mesh, collision and heights
  are unchanged with the flag on. Foliage centres inside built slab polygons are excluded (#895);
  retained ash placements keep their stored traits, and opting out restores the complete original
  scatter. The flag-on node tree is the flag-off tree plus the
  overlay node and its collision body; the cosmetic rubble batch belongs beneath the overlay,
  leaving the world's top-level inventory unchanged. **The tops are solid exactly where drawn (#548):** one
  `GroundPlatesBody` carries a trimesh built from the overlay mesh itself, lips included, so render and
  collision cannot disagree; `WorldGen.walkable_height_at()` answers the raised top inside a built
  slab (its ground plus that slab's thickness) and exactly `surface_height_at()` everywhere else, and it
  is what the player's anti-embed net and people and hound placement stand on — anything about the
  terrain itself keeps asking `surface_height_at()`. A capsule meets a lip taller than ~12 cm as a wall,
  so `main.gd` gives the wanderer a step (`Player.enable_step`) sized by
  `WorldGen.ground_plates_step_height()`, which fires only on a ledge (a landing at least 1 cm above
  the ground the body stands on, so a stride up a plain slope is never taken for a step), and while
  stepping is on `Player.is_grounded()` keeps the gait
  out of the airborne pose as the capsule rolls off a lip edge — both 0/off with the flag off, so
  ordinary movement and animation are untouched. `ground_plates_physics_test` holds all of it on the real
  seed: collision equals the query at every top and just past every edge (and is the terrain where no
  other top is), a player climbs and descends the thickest lip, crosses a seam and a three-slab
  junction, two fresh builds agree bit for bit, and hiding the overlay removes both. The treatment
  stays opt-in until it clears the art gate. The step also tries bounded inward directions when a
  glancing uphill stride lands on a rounded lip (#896); each path spends the held input's accelerated
  stride and retains the floor-angle, rise, forward-gain, ledge and headroom guards. The unchanged
  `client/tools/plate_crossing_sweep.gd` measures 0 stalls in 262 approaches, versus the prior 12.
  Independent regressions hold actual raised-side support and forbid unearned travel from rest or
  after changing direction, climbing tall walls, and stepping beneath insufficient headroom. Inspect
  the [close frames and controller sequence](../../docs/evidence/issue-895-896-slab-crossings/README.md).
  **Chips and grit follow actual edges (#549, ADR 0029):** the built top records carry stable
  identities and ash-cover samples immediately outside their original fracture edges.
  ExposedSlabRubble ranks eligible ash-facing edges and gathers larger chips beside the lip,
  smaller grit further out. Shared raised-stone edges, shrine and ruin clearings, the cave
  footprint and the doorway walk-out apron remain clear for the entire scaled cluster footprint.
  Circle/polygon distances and protected-circle radius sums reuse at most nine nearby cells
  of the existing raised-top index. Every accepted apron retains larger chips and finer grit.
  No original foliage placement is appended or rewritten. At most 192 aprons and 1,152 cluster
  instances render in one unshadowed GroundPlateRubble MultiMesh using the existing generated
  opaque rubble art (four stone chunks per instance); it has no
  collision or saved state. Live opt-out hides it and repeated opt-in reuses the batch.
  exposed_slab_rubble_test holds source, graded reach, clear neighbours, count bounds,
  reordered-source and process-RNG independence. ground_plate_rubble_test proves fresh/live
  convergence and the unchanged base terrain, plate collision and foliage records.
  client/tools/plate_rubble_capture.tscn captures walking and grazing before/after/control
  arms of one real boot; use 1280×720, all three redirected save seams and
  WAR_PLATE_RUBBLE_SHOT_DIR. The art and GPU activation gates remain open.
  Inspect the [same-build close frames and fresh-boot controls](../../docs/evidence/issue-549-slab-rubble/README.md).
  **Regions decide exposure in a separate opt-in (#550, ADR 0030):** exact
  WAR_REGION_STONE=1 together with WAR_GROUND_PLATES=1 uses authored density and
  scouring tendencies from GroundRegions. The existing maximum-per-region blend
  supplies continuous thresholds to the slab site, corners and outward ash
  samples, plus the shared GPU include used by terrain and cave contact.
  Stable identities, substance hashes and lip thickness do not depend on region
  ownership. Changing the profile rebuilds the one overlay and collision; cave
  rebuilds retain both live opt-ins. Regional-only and malformed opt-ins leave
  the ordinary terrain path intact. region_stone_profile_test and
  region_stone_world_test hold boundary blends, actual normalized coverage,
  fresh/live equality, material readback and unchanged base terrain/foliage.
  client/tools/region_stone_capture.tscn captures committed Bonepale/Cinderreach
  vantages, repeat/restore floors and a numerically checked plates-off arm.
  Use 1280×720, three redirected save seams and WAR_REGION_STONE_SHOT_DIR.
  region_stone_shader_probe.tscn checks six CPU/GPU profile samples within one
  RGB8 quantum; it does not certify full exposure parity or GPU frame time.
  Inspect the [regional frames, controls and remaining art gap](../../docs/evidence/issue-550-regional-stone/README.md).
  The experiment remains default-off; #1287 owns its decision and flag retirement
  by 2026-11-07. Repeated tiled shapes, edge wear and contact shadows still need work.
  The overlay keeps out
  of `cave_protects`. `WorldGen.set_ground_plates_enabled()` flips the terrain uniform, the cave's terrain-contact
  uniform and the overlay together in a running world so a measurement tool can compare both
  states of one build; the ordinary game reads the flag once at generation. The cost instrument is
  [`client/tools/plate_geometry_budget.gd`](../../client/tools/plate_geometry_budget.gd) (windowed only,
  1280×720, VSync off, shipping volumetrics): it reads the viewport's measured GPU frame time for
  600 steady frames per state and reports candidate/slab/exposed/built counts, vertices, triangles,
  surfaces and draw calls. Its shader-only arm explicitly hides both tops and cosmetic rubble;
  the full-on arm includes both, and plate_geometry_state_test holds those state meanings.
  **On Metal that GPU timer reads 0.0 in every frame, as ADR 0001 already
  recorded for the command-line profiler, and the tool reports UNAVAILABLE rather than a pass** —
  it prints wall-clock frame time beside it as a GPU-bound *proxy* for what a player feels, never as
  the budget measurement. Its frames are the close-range evidence under
  `docs/evidence/issue-547-ground-plate-geometry/`.

## Persisted player data

- **Changing any persisted player-data format:** follow the
  [forward-only save-data migration contract](../../docs/design/save-data.md). It defines the staged
  expand → bake → contract rollout, the version-bump checklist, and the refusal rules for the
  character recipe, progression vault and recovery ledger. Stable live names are permanent too:
  attunements need append-only ledgers, while writable discovery IDs need append-only
  `id=landmark` mappings plus real boot/application guards; a green fixture guard alone does not
  make a one-release read-and-write bump rollback-safe. Character reader registries may expand
  without activating their writers; production origination is the explicit
  `client/registries/character_writer_vocabulary.json` subset, whose equipment-slot, skin,
  blend-shape and bone-key additions require the contract-stage save-capability advance.
  The recipe reader accepts v5 `joint_push.thigh` and `joint_push.calf`: they scale knee and
  ankle offsets, not hip separation. Versions 1–4 refuse these keys, and absent keys preserve
  historical geometry and visual roots. Recipe origination stays v4 and capability writes stay 7;
  ordinary edits preserve accepted v5 state exactly, while new/changed/removed leg values,
  downstamping and deletion are refused. Actual update checks retain the accepted save requirements
  separately from reader ceilings. The trusted stature scenes cover real boots, grounded Player
  capsules, clothing clearance and lock release; see
  [ADR 0034](../../docs/adr/0034-read-stature-without-originating-it.md).

## Run and validate

- **Run:** `godot client` (macOS: `/Applications/Godot.app/Contents/MacOS/Godot client`).
  - **Experimental content-pack builds:** `bash tools/build-contentpack.sh --experimental
    client <new-output-directory>` stages a trusted local project privately, imports it natively and
    produces a cumulative PCK plus exact-byte build evidence. Recovery owners and their remaps stay
    outside the pack. Run `bash tools/test-contentpack.sh` for the exported-base precedence, receipt
    and no-mount controls. This tooling grants no installation or production publication authority;
    see `docs/adr/0014-build-experimental-cumulative-content-packs.md`.
- **Validate before every PR:**
  `godot --headless --editor --quit --path client && godot --headless --quit-after 120 --path client` —
  the editor pass imports AND writes the global class-name cache (`--import` alone never writes
  it, and scene-arg runs hang without it); the smoke boot must print the `BOOT_OK` marker AND no
  `SCRIPT ERROR`/`ERROR`. **`--path` is required on the smoke boot too** — the bare positional
  form (`godot ... client`) silently boots no project at all (verified on 4.7.1: ~1 s, no
  project mount) and every absence-of-error check then passes vacuously.
  Then run the regression tests: `godot --headless --path client res://tests/<name>.tscn` for each
  scene under `client/tests/`. CI (`ci.yaml`) runs exactly this, plus the `license-guard` job (no
  GPL/AGPL texts in the tree), the `GDScript lint` job, and the `Server CI (Go)` job ([Server → Validate the server](server.md#validate-the-server)).
  GDScript lint uses `gdtoolkit==4.5.0` with the repository's explicit `.gdlintrc`; after installing
  that pinned tool, run `./tools/gdscript-lint.test.sh` to prove the policy rejects a real invalid
  fixture and `./tools/gdscript-lint.sh client` to lint the product tree. Both are blocking in CI.

## Tests

- **Adding a test needs NO `ci.yaml` edit:** name the scene `<name>_test.tscn` and put it directly
  under `client/tests/` — CI's "Regression tests" step auto-discovers `client/tests/*_test.tscn`
  (issue #50; the old hardcoded list forced every parallel test-adding PR to collide on one line).
  Each scene must print a `TEST PASS` marker on success and run within the 180 s per-test timeout.
  Six exclusions: `save_fixture_guard_test`, `creature_factory_test`, `save_vault_guard_test`,
  `boot_recovery_guard_test`, `vault_restore_boot_test` and `ability_registry_test` each run in
  their own dedicated named step (the product-law surfaces for character, progression, recovery and
  combat state — the restore test is the BEHAVIOURAL check that an attuned point still restores on
  boot, which the persistence guards cannot see; all kept loud/separate and NOT skippable), and a test can be
  temporarily skipped by adding its basename (no
  `.tscn`) on its own line in the optional `client/tests/ci-skip.txt` (blank/`#`-comment lines
  ignored) — a rarely-edited escape hatch, so the run line itself stops changing per-test.
  **That candidate-owned discovery loop is not the product-law boundary.** The organization ruleset
  `Require workflow - World at Ruin trusted regressions`, managed declaratively by
  `devantler-tech/.github`, separately requires
  `devantler-tech/.github/.github/workflows/world-at-ruin-required-regressions.yaml` at
  `refs/heads/main`. The external workflow checks out the proposed product bytes as the candidate and
  the GitHub-supplied pull-request or merge-group base SHA as trusted World at Ruin bytes. It copies
  only the candidate's product tree into a throwaway evaluation root, replaces `client/tests/` with
  the trusted base's snapshot (apart from the narrowly validated capability declaration described
  under [CI, CD and releases](ci-and-evidence.md#ci-cd-and-releases)), and invokes the trusted base's `tools/run-client-test.sh` over every
  trusted `*_test.tscn`. A pull request can add, edit, delete or skip a checkout-local scene without
  changing which trusted scenes execute or how their verdict is judged; the external workflow is the
  aggregate required gate for both `pull_request` and `merge_group`.
  provider-upjet-github v0.20.0 cannot express GitHub's immutable required-workflow SHA selector, so
  the live rule binds the reviewed Actions `main` branch. Change the external workflow only through
  an exact-head-reviewed Actions PR; preserve compatibility with the World base controller and
  harness, pass `tools/required-regression-control.test.sh`, and run live positive and missing-input
  controls. Change the rule itself only through the declarative `.github` release path, then read the
  live ruleset back. The product-owned `.github/workflows/trusted-regressions.yaml` is a latent
  required-workflow source for unprivileged `pull_request` and `merge_group` events. It runs
  only when GitHub selects its canonical `refs/heads/main` workflow reference; ordinary
  candidate-owned invocations skip the job. The resolver binds the GitHub integration SHA to the
  event's merge commit, verifies the main-base and all three checkout identities, and invokes the
  verified workflow-source controller and its sibling verdict runner with read-only permissions and
  no persisted credentials. The event base supplies test scenes, settings, fixtures and ledgers,
  never host helper selection. Harness and candidate data
  are fetched anonymously into fresh repositories without credential variables or inherited Git
  configuration; their exact event identities are independently verified. Candidate Godot runs
  in a digest-bound, non-root container with no network, capabilities or host credentials; its
  project and harness are read-only. The protected suite uses reviewed-base project settings and
  the standard SceneTree loop; alternate binary configuration is refused before import. This
  tests candidate code under base-owned engine settings. Candidate configuration changes remain
  covered by ordinary CI; configuration-dependent features may be absent or fail in the frozen suite.
  Autoloads and editor plugins are unsupported until the controller contract is reviewed.
  Only disposable import state is writable during the editor scan.
  Host import and scene logs are captured in a fresh controller-owned directory outside the
  candidate tree, so candidate log symlinks cannot redirect host writes.
  The real-container refusal test pins that execution boundary. Its ordinary skipped job is
  preparation, never enforcement proof. Game-specific enforcement belongs at repository scope;
  do not add another World-only organization rule to select this latent source.
  The external catalogue required workflow remains active throughout activation; no ruleset cutover
  is implied by these source bytes.
- **Boot tests go through `IsolatedBoot` — booting and isolating are ONE act:** a test that
  instantiates `main.tscn` runs the real launch path, which reads — and on the first-run path
  writes — every file the player's state lives in: `user://character.json` and the progression
  vault. It must NOT clear-and-restore them (a run killed mid-test strands the only copy —
  no-resets law). Instead the game resolves each location through a seam honouring an env override
  (unset in production — the seams are inert): `CharacterStore.save_path()` / `WAR_SAVE_PATH`, and
  `SaveVault.vault_path()` / `WAR_VAULT_PATH`. `SaveIsolation` (`tests/save_isolation.gd`) is the
  ONE place that lists those seams and redirects them all to throwaway `user://*_boot_probe.json`
  probes, so a seam added there reaches every harness without a single test changing.
  It also disables ambient experimental update checks before scene loading and restores their
  environment after the test. A networking control opts in only after isolation has succeeded.
  Authenticated update history is the fourth seam (`UpdateHistory.history_path()` /
  `WAR_UPDATE_HISTORY_PATH`), covered by the same real-file byte assertion. Its separate bounded
  schema and locked acceptance rules are defined in [ADR 0017](../../docs/adr/0017-retain-authenticated-update-floors-at-locked-acceptance.md).
  Boot with **`IsolatedBoot`** (`tests/isolated_boot.gd`): `boot()` redirects every seam and returns
  the instantiated scene, or `null` when the redirect did not take — so a caller cannot hold a
  booted scene and an unisolated save at the same time. Drive `SaveIsolation` directly only when the
  harness must act BETWEEN the redirect and the boot (`vault_restore_boot_test` seeds vault fixtures
  there). Either way, assert `real_save_untouched()` on every exit path.
  `tests/boot_isolation_guard_test` fails the build when a test boots the scene unisolated;
  `tests/save_path_seam_test` pins the seam contract itself. That guard matches **code, never
  prose** — a doc comment saying a test never boots `main.tscn` is not a violation (#309 was filed
  off a grep that made exactly that mistake and accused five correct files). A developer running the
  suite on a machine with a played save can also `export WAR_SAVE_PATH=/tmp/probe.json
  WAR_VAULT_PATH=/tmp/probe_vault.json WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json
  WAR_UPDATE_HISTORY_PATH=/tmp/probe_update_history.json` to keep all four fully out of reach.

## Determinism, previews and player-visible work

- **Determinism:** world generation is seeded (`WorldGen.WORLD_SEED`) — the same world every boot.
  Never introduce wall-clock or unseeded randomness into generation; differences between builds
  must be attributable to code.
- **Ragged wrap geometry previews:** `WAR_RAGGED_CLOTH_DRAPE=1` retains the closed
  wrap, its fully pinned waist and prior outward gathers. The independent default-off
  `WAR_RAGGED_WRAP_REFINEMENT=1` additionally narrows the waist band and thins the shell;
  it is inert without the drape prerequisite. Its accept-or-retire task is #1275, due 2026-11-01.
  `RaggedDrape` also owns a private body mesh that restores only the newly exposed
  equipment-inset skin; player morphs, imported resources and saved recipes stay intact.
  The `ragged_cloth` capture includes `_unrefined` and `_unrefined_mask` arms that
  remove this refinement alone, including its skin restoration, while retaining earlier
  drape. The existing `_geometry_flat` arm removes all drape and cannot evidence
  this refinement by itself. Both geometry and material previews remain independent
  and default-off; the 2026-11-01 decisions never activate them.
- **Player-visible work is judged on the frame, not the suite:** before calling a player-visible
  change ready, render or play it, look at it, and judge it against the
  **[Quality bar](../../AGENTS.md#quality-bar--it-has-to-resemble-a-aaa-game)** (AAA resemblance). The PR must
  carry **evidence a reviewer can inspect** — an attached screenshot, captured frame or short clip
  of the actual change — together with the **named reference** (from
  [`docs/art-direction/`](../../docs/art-direction/README.md)) and the **remaining gap**. A
  claim with no attached frame is self-attestation, not evidence, and does not satisfy this.
  New below-bar player-facing elements do not ship default-on, including each new element inside a
  mixed change. A settled in-place improvement to an already-shipped below-bar surface may remain
  default-on only under the exception in the [quality bar](quality-bar.md); an unsettled or experimental
  improvement remains default-off under product law 2.
- **Dev log is a contract:** every player-visible change adds a dev-log entry in the same PR — the
  maintainer watches progress by playing, and the dev log is that surface. **Add a new file
  `client/devlog/<words-for-the-change>.json`** — lowercase words joined by hyphens, such as
  `raised-stone-holds.json` — holding one object with `"version": "next"`, `date`, `title` and
  `notes` (an array of strings); copy the shape from any existing entry. **Never write a release
  number into a new entry.** Its release cannot be known on a branch: several releases are cut an
  hour, so a predicted number is routinely overtaken before the PR merges, and the log would then
  tell the maintainer a change arrived in a build that does not contain it. The release build
  answers exactly instead — `tools/devlog-stamp.sh` rewrites every `"next"` entry to the first
  release containing the commit that added its file (#518). A development build has not been
  through a release, so it lists these entries at the top of the log under **Numbered at
  release**, shipped or not. Entries that ship together all receive that release's number and are
  listed newest first; the same entry must never appear twice, which `devlog_entries_test` checks
  before stamping and the stamp checks again after it. `tools/devlog-entry-version-guard.sh`
  refuses a numbered new entry in CI and prints the `git mv` that fixes it; `devlog_storage_test`
  checks the file name. One file per entry is deliberate: entries used to share a single array, so
  **every** concurrent player-visible PR collided on the same lines and had to rebase behind each
  sibling merge. Never reintroduce a shared list. Two PRs now collide only when they pick the same
  file name — choose another; never merge two entries into one file.
  ⚠️ **Once an entry has merged, leave its file where it is.** The stamp dates an entry by the
  commit that added its file and follows an exact rename only, so moving an entry while editing
  it, or converting a numbered entry to `"next"`, re-dates it to a later release than the one that
  carried it. The guard refuses a placeholder added in a change that also removes an existing
  entry unless it is the same bytes under a new name. Editing an entry's prose in place stays
  legal.
  **Correcting an old numbered entry** is the one case where a new file names a released version:
  list it in `tools/devlog-entry-corrections.tsv` with the anchor commit whose change it describes,
  and the guard proves the number is the first release containing that commit.
  `tools/devlog-entry-version-sweep.sh --gate` checks every numbered entry that way on each change
  and reports each placeholder with the release its stamp will give.
  **Do NOT hand-edit `DevLog.VERSION` or `config/version` in `project.godot`** — release builds are
  stamped from the release tag ([CI, CD and releases](ci-and-evidence.md#ci-cd-and-releases)), so a hand-bump only drifts from the real version.
  **`shipped_in` marks an entry whose version was never cut.** The seventeen oldest entries were
  written before the repo's first tag (`v0.1.15`), so their numbers name builds that have never
  existed and cannot be renamed onto the release that carried them — fifteen of them first shipped
  in the same one, and versions are unique by filename and by `devlog_entries_test`. Such an entry
  keeps its number as its identity and adds an optional `"shipped_in"` field naming the release its
  change first reached players in; the log then renders it **without** the leading `v` and says
  where it landed, instead of presenting a build nobody could have played.
  **You will almost certainly never add one.** It records an already-released change, so
  `tools/devlog-entry-version-guard.sh` refuses it on a new entry — a fresh entry describes a build
  that has not shipped and carries `"next"`. The guard checks every declaration
  in the tree, not just added ones, against the tags in the checkout: the entry's own version must
  be untagged, the declared release must exist, and it must be the **first** release cut above the
  entry's version (a later one contains the change too, so only the first dates it).
  `tools/devlog-entry-version-sweep.sh` reports a verified declaration as `PRE-RELEASE` rather than
  `NEVER-CUT`.
