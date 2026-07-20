# Client distribution & self-update

> Status: **proposed** (draft for maintainer steer) · 2026-07-17 · a product-law foundation, solved
> early on maintainer direction.
>
> This is an architecture decision record. It settles *how a player gets the game and how the game
> keeps itself current* while the world evolves continuously. It does not add new **platforms**
> (consoles/iOS stay [deliberately last](../../AGENTS.md), Phase 8 / #15) — it establishes the
> **update mechanism** for the desktop tier we ship first. Mechanism-early is not platforms-early.

> **Maintainer direction (2026-07-17):** *ship the self-applied content-pack update (Tier 1) now;
> **defer** the storefront / native-shell (Tier 2) channel decision.* So the near-term build is the
> **pack-overlay self-update** and its decision core (children 1–3); the launcher/storefront choice
> (child 5) is parked until later — the pack overlay is what makes "update the client from the client"
> real, and it stands on its own.

## Why this is a day-one problem, not a Phase-8 one

The product law says **no hard resets, ever** — an early player keeps playing as the game evolves,
forward-only and non-destructively. World at Ruin is built almost entirely by agents and changes
**many times a day**, so "the game evolves" is not a metaphor: it is the normal operating condition.

That makes distribution a **product-law problem, not a packaging chore**. If updates are not
forward-only, signed, and non-stranding *from the first build a real person installs*, you cannot add
those properties later without a reset — and the reset is exactly what the product law forbids. This
is the same reasoning that put the forward-only save guard (#3) before the first player. The update
path is the second such guard: **an update must never strand a character, force a reinstall, or drop a
player onto a build that cannot load their save or reach the live world.**

The maintainer's ask — *"update the client from the client, easy updates, play while the game is
evolving in realtime"* — is therefore not a convenience feature. It is the delivery half of the
no-resets law.

## The forces

- **Continuous, automated delivery.** Dozens of changes a day, all authored and built headlessly in
  CI ("as code"). Update artifacts must be **produced, signed, and published by CI**, never by hand.
- **No reinstall friction.** The common change (a scene, a script, an asset, client tuning) must reach
  the player without re-downloading the whole game or visiting a store.
- **Forward-only & non-stranding.** Versioned saves already exist (#3); the update flow must never
  downgrade below a save's schema, never delete a save, and must **roll back to the last playable
  build** if an apply fails.
- **Source-available & proprietary.** Copying/redistribution is prohibited and there is a bespoke
  EULA. Only **official, unmodified** content may run: update artifacts are **signed and
  integrity-checked** before they are trusted. (This is also the anti-tamper/anti-fork foundation;
  gameplay authority stays server-side regardless — the client is never trusted for game state.)
- **Cloud-native, on the existing platform.** The server tier (Agones zones + Nakama meta, Postgres/
  CNPG) runs on the platform via Flux. The update **origin of record should be self-hosted on that
  platform** (control-plane material stays ours — the self-host default); a CDN edge for the *bytes*
  is fine (adjacent, cacheable, blast-radius-bounded).
- **Godot 4.** Godot mounts additional `.pck`/`.zip` packs over `res://` at runtime
  (`ProjectSettings.load_resource_pack`), including GDScript. This is the engine-native way to deliver
  content/logic updates **without re-shipping the executable** — it is the mechanism this whole design
  leans on.
- **Compatibility while evolving.** For an MMO, "play while it evolves" means the client and the live
  server tier must stay protocol-compatible. The client must be nudged forward **before** it can
  become incompatible — never kicked mid-session.

## Decision — a three-tier update model

Updates are separated by *what actually changed*, cheapest tier first. Most changes never reach the
player as a download at all.

### Tier 0 — Live, server-authoritative (no client change)

The world is server-authoritative, so most "evolution" reaches the player with **zero client update**:
zone state, spawns, balance/tuning, world events, and server-driven content are delivered by the
running server tier and streamed to the client through replication (area-of-interest, #53, is one
piece of this). The player literally watches the world change in realtime. **This is the primary
meaning of "play while it evolves,"** and it is already the settled architecture. Distribution's job
here is only to keep the client *compatible* so it can keep receiving the stream.

### Tier 1 — Content/logic pack overlay (client data + script, no reinstall)

The common case for an agent-shipped client change. The install is a **thin shell + a base pack**;
each release publishes a **signed, versioned `.pck` overlay** that the client downloads and mounts
over `res://`. New scenes, scripts, shaders, assets, and client-side tuning arrive this way — **no
store round-trip, no manual reinstall**. This is "update the client from the client." Apply is at most
a *restart-to-apply*; hot-mount is a later refinement where it is safe.

### Tier 2 — Shell/native update (executable + engine) — deferred

Rare — only when the engine version, native bindings, or export template change, which a pack cannot
replace. Handled by a thin **desktop launcher/bootstrapper** (or the desktop packaging channel) that
swaps the native binary. On desktop this is fully automatable; the launcher acts when the current pack
requires a newer shell than the one installed. **The launcher/storefront mechanism is deferred by
maintainer direction (2026-07-17)** — it is a commercial/storefront call (self-hosted vs itch.io vs
Steam) that does not block the pack overlay, so the manifest already carries the `shell` fields the
future launcher will read, but the launcher itself is child 5, built later.

## The update-decision core — where the no-stranding guarantee lives

A client-side **update manager** that, at boot and periodically:

1. **Fetches a signed manifest** from the channel origin (see the contract below).
2. **Verifies** the manifest signature, then each artifact's `sha256`, before trusting anything.
3. **Decides one action** from a *pure* comparison of the installed state
   `{shell_version, pack_version, save_schema, negotiated_protocol}` against the manifest:
   - `up_to_date` → play.
   - `pack_update` → download + verify + stage + mount (automatic, low-friction).
   - `shell_update` → hand off to the launcher (installed shell too old for the current pack, **or** the
     candidate pack would raise the save schema — see below).
   - `blocked_incompatible` → **should be impossible by construction** under the product law
     (backward-compatible protocols + forward-only saves). If it ever occurs it is a **loud product-law
     violation surfaced to the player**, never a silent strand or a corrupted save.
4. **Forward-only + last-known-good, and the two rules that make rollback actually safe:**
   - **Rollback is owned by the immutable shell, never by the overlay.** A pack that crashes *at
     startup* cannot roll itself back — the recovery code would be inside the broken pack. So the
     **shell/bootstrap** (outside the replaceable tree) writes a *boot-attempt marker* before mounting a
     staged pack and only promotes it once the boot reaches a success checkpoint; if a launch does not
     reach it, the next launch **selects the previous good pack**. The shell, not the overlay, is the
     root of recovery — which is why a trustworthy shell must exist before the first player (child 6).
   - **A pack never advances the save schema; a save-schema bump rides the shell.** If a pack raised the
     persisted save/recipe version and the player then saved, a later rollback would mount older code
     against newer data — and the older pack, which rejects versions above its own `RECIPE_VERSION`,
     would refuse or discard it: a strand. So the decision core routes any pack that would raise the save
     schema to `shell_update`, and **rollback is offered only when the previous build can read every
     state the candidate build can write** (else the step is shell-tier or an expand-contract migration
     where the old pack already reads the new data). The flow never downgrades below the save's schema
     and never deletes the save.

This decision core is **pure, deterministic, and unit-testable** with no network or art — exactly like
`Telegraph`/`Interactable`. It is the **first implementation increment**, because every correctness
and no-stranding guarantee lives here and can be proven in the Godot test harness before a single byte
is downloaded.

### Rollback eligibility — the one law that makes last-known-good actually safe

Retaining the previous bytes is not enough; a rollback target is only *safe* if the player can keep
playing on it. A previous build is an **eligible rollback target only if it can (a) READ every save the
candidate can WRITE** — including a **same-schema** addition such as a new equipment/skin registry name,
not merely a schema-number bump — **and (b) SPEAK a protocol the live server still accepts.** A
schema-number check alone misses both (a same-schema new name, and a retired protocol).

The single law that guarantees both is **expand-before-write / expand-before-contract**: every change
that makes something new *persistable* or advertises a new *protocol* first ships its **read/accept**
support in a release, and only once that read-capable release is the **standing rollback target** does
the new thing become writable (or the old protocol get retired). A save-schema bump, a new savable
registry name, and a protocol raise are three instances of the same shape — *expand (add read/accept,
no writes) → bake → contract (start writing / retire the old)*. The `save_schema.writes` field, the
two-phase protocol rollout, and the existing append-only recipe ledger + golden-fixture CI guards are
all facets of this one law, and the immutable bootstrap (child 2) only ever selects a rollback target
that satisfies (a) and (b). Routing a save-schema bump "to the shell tier" is therefore necessary but
**not sufficient on its own** — the shell change must itself be expand-before-write, or its own rollback
strands the same way.

## The manifest — the contract between CI and the client

A small **signed JSON** document per channel, published by CI beside the artifacts. See
[`client-update-manifest.example.json`](./client-update-manifest.example.json). Shape:

- `schema` — manifest schema version. A **stable, backward-compatible envelope** — `schema`, `channel`,
  and the `shell.current`/`shell.min_supported`/`shell.download` fields — keeps its shape across *every*
  schema bump, so a client of any schema can always at least read "you need this shell." Bumps are
  additive within that envelope; a client processes only the schema it understands and, on a higher
  schema, follows the envelope to a `shell_update` rather than guessing at (or rejecting on) new fields.
- `channel` — `live` by default; the field exists so `canary` can be added later without a redesign.
- `shell` — `current`, `min_supported` (shells older are refused — the forward-only floor),
  `reads_min` (the lowest save **schema** the advertised shell can read) and `reads_capability_max`
  (the **highest** save capability it understands), and per-target signed `download` entries (`url`, `sha256`, `size`). The **shell
  version is independent of the pack version**: the executable and the content advance on their own
  clocks. Both read floors live in the **stable envelope** rather than the schema-specific body for the
  same reason: a future-schema manifest is followed to a `shell_update` from the envelope ALONE, so a
  save-strand check placed in the body would be missing on precisely the route where the client
  understands least. `reads_capability_max` exists because the schema floor does not cover the
  capability axis — a shell can read a save's schema while lacking the same-schema shapes it holds.
  Note the directions differ and are not interchangeable: `reads_min` is a **floor** (a newer shell
  drops support for ancient schemas), whereas capability is a **ceiling** — capability counts shapes
  PRESENT in the save, so the hazard is a save holding a shape the build does not understand. This
  matches `rollback_targets[].save_capability`, which is likewise compared as "the build's capability
  must be at least the save's".
- `pack` — `version`, `min_shell` (the shell this pack needs), and **two artifacts**: a `full` cumulative
  pack (`url`/`sha256`/`size`) that any in-range shell can apply **from any prior state**, plus an
  optional ordered `deltas` list (each with its `base_version`). A client applies the smallest delta
  chain it has and **always falls back to the `full` pack** when it lacks a base — so a player offline
  for several releases is never stranded on a broken update chain. Every artifact also carries its own
  `read_ceiling`, `save_capability`, `speaks_protocol` and `shell_compat` (see the eligibility rules).
- `rollback_targets` — the signed catalogue of **retained standing rollback targets**, each with the
  same per-artifact fields. The bootstrap picks a recovery build from here, so eligibility is decided on
  *published, signed* capability data rather than inferred from the candidate's numbers.
- `protocol` — `{min, max}`: the client protocol range the **live server tier accepts right now** (not
  what any given build speaks — that is each artifact's `speaks_protocol`), raised only via the
  two-phase rollout below, and only once every manifest advertising the old range has expired.
- `save_schema` — `{min}` (the lowest save schema the current client must **read** — forward-only; ties
  to #3), `writes` (the schema the candidate build **writes**), and `capability` (the monotonic
  **save-capability** counter). These are deliberately distinct: a backward-compatible pack can keep
  `min` low while raising `writes`, and a *same-schema* expansion raises only `capability`. The decision
  core routes any pack whose `writes` exceeds the rollback target's read ceiling — or whose `capability`
  exceeds the target's — to the **shell** tier, so a rollback can never face a save it cannot read.
- `key` — the id/certificate of the current signing key, signed by the offline **root** key baked into
  the shell (see Signing) — this is what lets a signing key rotate without a reinstall.
- `revocation` — the root-signed, monotonically versioned revoked-key list **plus `head_url`**, the
  independently fetched root-signed **revocation head** whose version acts as a floor (see Signing), so
  a stale embedded block cannot be masked by a freshly signed manifest.
- `signature` — a detached signature over the manifest. The signing bytes are **pinned** (see Signing):
  a canonical JSON profile with the `signature` field excluded, a named algorithm, and a fixed encoding,
  so CI and the Godot client sign and verify exactly the same bytes.

Versions: the **pack** version tracks the release the dev-log announces (`DevLog.VERSION`); the **shell**
version is stored and bumped independently with the native build (**not** `config/version`, which ships
inside the pack) — so a pack-only release never masquerades as a phantom shell change or vice-versa.

### What the build can state about itself today (`UpdateManifest`)

`client/scripts/update_manifest.gd` derives the manifest from the constants the build actually runs on,
so it can never disagree with the build it describes. `update_manifest_test.gd` proves the generated
manifest is accepted by the **real** `UpdateDecision.decide()`, and deletes each required field in turn
to prove that acceptance is not vacuous.

It publishes a **contract, not a delivery**: what this build reads, writes and speaks. Every field that
would tell a client where to *fetch* something is withheld, and each omission is **load-bearing**:

- **`pack.full` / `pack.deltas`** — there is no pack. This doc defines `pack.full` as a mountable
  cumulative `.pck`, but CD builds and publishes a macOS `.app` ZIP (one export preset, no `patches=`).
  Recording that ZIP would make it pass `RollbackSelection.is_wellformed`, so a recovery after a failed
  pack update could select it and hand an **application archive to the pack-mount path**, which cannot
  restore anything. Withheld until child 3 produces a real pack artifact.
- **`shell.download`** — a shell replacement must be root-authorized (see Signing). Publishing a
  download without its `shell_authorization` would offer an unauthenticated place to fetch an
  executable from, so it is withheld until child 6 supplies that authorization. This is also why the
  monolithic ZIP cannot simply be re-labelled a *shell* artifact instead of a pack: that is the same
  unauthorized download. A client following the envelope to a `shell_update` finds nowhere to go and
  keeps playing — the safe failure.
- **`signature` / `key` / `revocation`** — the root of trust is child 6, unstarted. The published OCI
  artifact is cosign-signed by digest, which is a real but *different* integrity property.
- **`rollback_targets`** — empty, because nothing is retained. Empty is the fail-closed value: it makes
  the decision core refuse a capability-raising pack rather than ship one no player could roll back from.

Publishing no delivery is the correct state while there is genuinely nothing to deliver — a client can
learn it is out of date and say so, and can go no further.

**The two save capabilities are separate constants on purpose.** `SAVE_CAPABILITY_WRITES` feeds
`save_schema.capability`; `SAVE_CAPABILITY_READS` feeds `shell.reads_capability_max`. Collapsing them
makes the expand-before-write rollout unrepresentable: a build that reads capability N+1 while still
writing N could not be described, so it would either never become an eligible rollback target or would
falsely claim to write the new shape. Writes are backed by an append-only ledger
(`tests/data/shipped_save_capability.txt`) and reads must always cover writes.

**Three assumptions are guarded by failing tests rather than comments**, because each is true today and
will expire:

1. `shell.current` is derived from the pack version — honest only while the build is a **single
   artifact**. The test fails the moment `export_presets.cfg` declares a pack split (child 3), forcing
   the shell to get its own source of record in that same change.
2. The top-level `protocol` range is **what the live server accepts**, not what the client speaks.
   Sourcing it from `WireCodec.VERSION` is valid *only* because client and server are both pinned to one
   version, so a test asserts the server's `wire.Version` still equals the client's. When the two-phase
   expansion begins (server accepts `[1,2]`, newest client speaks only `2`) that test fails — and the
   range must become a CD-supplied input read from deployment state, or a retained `v1` target would be
   rejected even though the server would still talk to it.
3. `DevLog.VERSION` must be a dotted-integer version. `cd.yaml` accepts prerelease tags
   (`v0.2.0-rc.1`), which `UpdateDecision.is_version` does not, so `build()` refuses to emit a manifest
   no client could accept rather than publishing one dead on arrival.

## Delivery substrate (decided; open to steer)

- **Origin of record:** self-hosted on the platform — an **OCI registry / object store**, published by
  CI through the same Flux-based CD the rest of the platform uses. Control-plane material stays ours.
- **Edge:** a **CDN** in front of the pack/shell bytes (adjacent tooling, cacheable, bounded blast
  radius — an acceptable SaaS use under the self-host-the-control-plane boundary).
- **Interim bootstrap:** until the platform CD path exists, **GitHub Releases** is the origin (CI can
  already publish there; the macOS export artifact #6 is the seed). The client only ever knows a
  *channel URL*, so the origin can migrate from Releases → platform without a client change.
- **Channel model:** one rolling **`live`** channel by default — one world, continuously delivered,
  consistent with no-seasons/no-resets. The schema permits named channels for a future `canary`.
- **Signing & a rotatable root of trust.** Packs and manifests are signed in CI; the client verifies the
  signature + `sha256` before mounting. The signing bytes are **pinned** — a canonical JSON profile
  (sorted keys, UTF-8, the `signature` field excluded), an **Ed25519** signature, base64 encoding — so CI
  and the client never disagree on what was signed. Critically the first shell bakes in a **rotatable
  root of trust, not a single signing key**: a long-lived **root key** (offline; only its public half is
  in the shell) signs short-lived **signing keys**, and the manifest's `key` field carries the current
  signing key's certificate. A compromised or lost *signing* key is then rotated by signing a new one
  with the root — **no reinstall**, even while shell updates are deferred. Only root-key compromise needs
  an out-of-band shell update, so the root is guarded hardest (host least-privilege, child 6). This
  reuses the CI trust model that already runs `license-guard` and the CLA gate.
  - **Rotation must also revoke — not just re-sign.** Re-signing with the root does not by itself stop an
    attacker who kept a compromised *signing* key. So each signing-key certificate carries a **validity
    window** and a **monotonic key epoch**, the client **persists the highest epoch it has seen and
    refuses any manifest signed below it** (anti-rollback), and revoked-key ids are carried forward in a
    root-signed revocation list. A stolen old key therefore cannot sign a "newer" manifest a client will
    accept — the rotation is effective, not cosmetic.

## Trust & recovery hardening (contract obligations the children implement)

A signed-update system has a few more sharp edges the contract closes, so no *single* key compromise,
stale cache, or engine change can strand or subvert a client:

- **Anti-replay / freshness.** Every manifest carries a **monotonic, root-anchored `sequence`** and an
  expiry (`not_after`); the client persists the highest sequence it has accepted and **refuses any older
  or expired manifest**.
  - **The persisted sequence alone is NOT enough, so contraction waits out the TTL.** A returning or
    freshly-installed client has no high-water mark, so an unexpired cached manifest at sequence `N`
    looks perfectly valid to it even after the server contracted per `N+1` — every signature and expiry
    check passes while the client sits on a pack that can no longer reach the world. Therefore
    **the server may only contract (raise `protocol.min`) after every manifest advertising the old
    range has EXPIRED**: the contraction is scheduled at least `manifest_ttl + margin` after the expand
    step. `not_after` is what bounds how long a cached manifest can be believed, so it is the clock the
    contraction schedule is derived from — never an assumption that clients have seen a newer sequence.
- **Root-authenticated revocation, with an INDEPENDENT freshness head.** The revocation list and the
  signing-key certificate are **signed by the offline root and monotonically versioned**, and validated
  *before* the manifest's own signature — so an attacker holding a compromised signing key cannot omit
  its own id to keep issuing accepted same-epoch manifests.
  - **Embedded-only revocation is still forgeable against an offline client.** A stolen key can sign a
    fresh, higher-sequence manifest that embeds an **older but still validly root-signed** revocation
    block which does not list the stolen key; a client that was offline during the revocation has never
    seen the newer version, so a monotonic counter alone does not save it. The contract therefore
    requires an **independently fetched, root-signed revocation head** (its own endpoint, its own
    freshness/`not_after`) carrying the **current revocation version floor**. The client fetches the
    head separately and **refuses any manifest whose embedded revocation version is below that floor**,
    so a stale embedded block cannot be masked by a fresh manifest. A head that cannot be fetched is
    fail-closed for *new* installs/updates (the client keeps playing its current build).
- **Shell replacement is root-authorized.** A `shell.download` is authorized by the **offline root (or
  platform code-signing)** and verified by the existing bootstrap — never by the short-lived signing
  key. Otherwise a compromised signing key could install a hostile shell that replaces the baked root
  itself, which no later rotation could recover; this is what keeps "signing-key compromise ≠ root
  compromise" actually true.
- **A rollback target must be runnable AND reachable, not merely retained.** A retained build is an
  eligible rollback target only if it (a) **runs on the installed shell** — so a shell/pack pair that
  changed engine/bindings incompatibly **rolls back atomically together**, or the pack declares a
  shell-compat range (an upper bound, not just `min_shell`); (b) can **read** the candidate's writes;
  and (c) **speaks a protocol the live server still accepts**. Schema integers alone prove neither (b)
  nor (c), so each artifact carries two more signed fields:
  - **`save_capability` — a monotonic counter that advances for EVERY newly persistable shape**, not
    only for a schema bump. A same-schema expansion (a new equipment/skin registry name) leaves `writes`
    and `read_ceiling` identical while still making the older pack reject the new save, so the decision
    is made on capability: a target is read-eligible only when its `save_capability` is **>= the
    candidate's**. (The existing golden-fixture guard checks the *current* build against *historical*
    data — the opposite direction — so it cannot cover this.) Equivalently, a release may bump the
    schema instead; the capability counter simply makes the cheap same-schema case expressible.
  - **a per-artifact `protocol` range — what that build SPEAKS**, distinct from the manifest's top-level
    `protocol`, which is only what the **server accepts right now**. During an expansion the server may
    advertise `[1,2]` while an old pack speaks only `1`; after contraction to `[2,2]` that pack is
    unreachable, and top-level metadata alone would wrongly make it look eligible. The bootstrap selects
    a target whose *speaks* range intersects the server's *accepts* range.

  A signed, server-compatible **recovery artifact** is always published for dormant clients, or the
  candidate is applied only after a verified intermediate promotion.
- **Canonicalization pinned to a standard.** The signed bytes use **JCS (RFC 8785)** with shared test
  vectors both CI and the client consume, so two conforming implementations never derive different bytes
  and reject every otherwise-valid update.

These are contract-level obligations; the pack pipeline (child 3), the updater (child 4), the protocol
handshake (child 5), and key custody (child 6) implement them, and the manifest schema carries the
`sequence`, per-target read-ceiling/compat, and root-signed revocation fields they need.

## How this upholds the product law

- **No reset / no reinstall:** updates never wipe; the save is versioned/forward-only (#3); the flow
  never downgrades below the save schema, never deletes the save, and rolls back to last-good on
  failure.
- **Play while it evolves:** Tier 0 gives realtime, server-driven evolution with zero client change;
  Tier 1 auto-delivers client changes with at most a restart; Tier 2 is rare and launcher-automated.
  The player is never told to go re-download the game.
- **Forward-only, backward-compatible, two-phase.** A protocol change rolls out **expand-then-contract**:
  the server first *adds* support for the new protocol while still accepting the old range (expand), the
  manifest advertises the update, clients adopt it, and only *then* does the server raise `protocol.min`
  (contract) — with existing sessions kept on their negotiated protocol until they reconnect, and the
  contraction held until **every manifest advertising the old range has expired**, so a returning client
  holding an unexpired cached manifest is never stranded. So a client is always nudged forward **before**
  compatibility is removed, and no connected session is kicked mid-evolution. The `protocol {min,max}`
  window, each artifact's own `speaks_protocol`, and the shell/pack version floors enforce this.
- **Must exist before the first player:** like the save guard, the update mechanism and its
  no-stranding invariant are a day-one requirement; retrofitting them later would need a reset.

## Consequences

- **Positive:** continuous low-friction delivery; no reinstall for content; product law upheld
  end-to-end; fully CI-driven (as code); stack-consistent origin; anti-tamper baked in from the first
  build.
- **Costs / risks to manage in the children below:**
  - Pack-overlay discipline: base + overlay must export correctly and the `res://` override load-order
    must be **verified with a committed test** (the one behaviour that needs a live Godot check, not
    reasoning).
  - Signing-key custody (offline key, CI secret) — host least-privilege; a leak is a revoke-and-rotate
    incident.
  - Shell×pack version matrix must be tested — that is the decision core's whole job.
  - Console/iOS **cannot** self-update code (store certification forbids it): there, updates are
    store-delivered. This is a **Phase-8** concern and is called out honestly, not solved here; the
    manifest/decision model degrades to "store handles Tier 1+2, Tier 0 still live."

## Alternatives considered (rejected)

- **Full-binary auto-update only (no pack split).** Every content change re-downloads the whole
  client — far too heavy for continuous agent delivery. Rejected; pack overlay is Godot-native and
  light.
- **App-store-only delivery on desktop.** Store review latency kills "evolving in realtime." Reserved
  for console/iOS where it is mandatory (Phase 8), never the desktop primary path.
- **Client-authoritative hot-patching of arbitrary networked code.** A security and cheat nightmare.
  Rejected: only **signed** packs from the official origin are ever mounted, and gameplay authority
  stays server-side regardless.
- **A bespoke updater protocol.** Reinvents the wheel. Prefer industry-standard building blocks
  (OCI/HTTP + detached signatures; a Sparkle/Butler/Steam-class launcher on desktop) — the portability
  principle.

## Decomposition (roadmap children of the epic)

1. **Update-decision core + manifest schema** — the pure, testable brain and the signed-manifest
   contract (this doc's `.example.json`). No network, no art. *First.*
2. **Immutable boot/rollback bootstrap** — a **non-replaceable** shell component (this is **not** the
   deferred storefront launcher below) that owns the boot-attempt marker, the health check, and the
   last-good pack selection. It **must ship before the first overlay can be delivered**, because a pack
   that crashes at startup cannot recover itself; without this in place a single bad overlay would
   strand every client that received it.
3. **Pack build & publish pipeline** — CI exports a signed `full` + `deltas` `.pck` set + manifest to
   the origin; base+overlay split; a committed pack-overlay load-order test (the live-verified piece).
4. **In-client updater** — fetch → verify signature/sha → stage → hand promotion/rollback to the
   bootstrap (child 2). Never promotes a pack that raises the save write-schema beyond the rollback
   target's read ceiling (that routes to the shell tier).
5. **Protocol-version handshake (two-phase)** — client negotiates its protocol with the meta tier and
   refuses-and-prompts-update before it can become incompatible; the server rolls out
   expand-then-contract so no session is kicked (the server half is a server-tier child).
6. **Signing key custody + rotation** — offline **root** key, rotatable short-lived signing keys, a
   client-remembered **key epoch** (anti-rollback) plus certificate validity/revocation, scoped CI
   secret. Guards the immutable bootstrap's root of trust.
7. **Desktop storefront / native-app auto-update (Tier 2) — deferred** (maintainer direction
   2026-07-17): the *distribution/storefront* channel — self-hosted updater / itch.io Butler / Steam —
   picked later. Distinct from child 2, which is the minimal always-present recovery bootstrap.
8. **(Phase 8) Console/iOS store-delivery fallback** — store-delivered Tier 1+2; Tier 0 stays live.

## Decisions

- ✅ **Desktop shell-update / storefront (Tier 2) mechanism — DEFERRED** (maintainer direction
  2026-07-17). Ship the pack-overlay self-update first; decide self-hosted launcher vs itch.io Butler
  vs Steam later. The manifest already carries the `shell` fields the future launcher will read.

Still made defensibly above from the settled stack, open to redirect on this PR:

1. **Origin:** platform-hosted OCI/object store (interim: GitHub Releases). Or a specific CDN/host from
   the start?
2. **Channel model:** a single rolling `live` channel (schema allows a future `canary`). Or a
   stable/beta split now?
