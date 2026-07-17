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
   - `shell_update` → hand off to the launcher (installed shell too old for the current pack).
   - `blocked_incompatible` → **should be impossible by construction** under the product law
     (backward-compatible protocols + forward-only saves). If it ever occurs it is a **loud product-law
     violation surfaced to the player**, never a silent strand or a corrupted save.
4. **Forward-only + last-known-good:** a staged pack is promoted only after signature+hash pass; the
   previous good pack is retained, so a failed apply **rolls back to the last playable build**. The
   flow never downgrades below the save's schema and never deletes the save.

This decision core is **pure, deterministic, and unit-testable** with no network or art — exactly like
`Telegraph`/`Interactable`. It is the **first implementation increment**, because every correctness
and no-stranding guarantee lives here and can be proven in the Godot test harness before a single byte
is downloaded.

## The manifest — the contract between CI and the client

A small **signed JSON** document per channel, published by CI beside the artifacts. See
[`client-update-manifest.example.json`](./client-update-manifest.example.json). Shape:

- `schema` — manifest schema version (forward-only; the client understands `>= its own`).
- `channel` — `live` by default; the field exists so `canary` can be added later without a redesign.
- `shell` — `current`, `min_supported` (shells older are refused — the forward-only floor), and
  per-target signed `download` entries (`url`, `sha256`, `size`).
- `pack` — `version`, `min_shell` (the shell this pack needs), `url`, `sha256`, `size`, and
  `base_version` (`null` = full/cumulative pack; a version = delta from that base).
- `protocol` — `{min, max}`: the client protocol range the **live server tier accepts right now**.
  The client updates before it falls outside this window, so it is never kicked mid-evolution.
- `save_schema` — `{min}`: the lowest save schema the current client must support (forward-only; ties
  to #3).
- `signature` — a detached signature over the canonicalised manifest body.

Version strings reuse the existing scheme (`config/version` in `project.godot` == `DevLog.VERSION`);
the pack version tracks the release the dev-log already announces.

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
- **Signing:** packs and manifests are signed in CI with an **offline release key**; the **public key
  is baked into the shell**. The client verifies signature + `sha256` before mounting. This upholds
  proprietary integrity and is the anti-tamper foundation, reusing the CI trust model that already
  runs `license-guard` and the CLA gate. Key custody is host-least-privilege (a scoped CI secret).

## How this upholds the product law

- **No reset / no reinstall:** updates never wipe; the save is versioned/forward-only (#3); the flow
  never downgrades below the save schema, never deletes the save, and rolls back to last-good on
  failure.
- **Play while it evolves:** Tier 0 gives realtime, server-driven evolution with zero client change;
  Tier 1 auto-delivers client changes with at most a restart; Tier 2 is rare and launcher-automated.
  The player is never told to go re-download the game.
- **Forward-only, backward-compatible:** the `protocol {min,max}` window plus the shell/pack version
  floors force the client forward **before** it can become incompatible — nudged, never stranded.
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
2. **Pack build & publish pipeline** — CI exports a signed `.pck` overlay + manifest to the origin;
   base+overlay split; a committed pack-overlay load-order test (the live-verified piece).
3. **In-client updater** — fetch → verify signature/sha → stage → mount / restart-to-apply →
   last-good rollback.
4. **Protocol-version handshake** — client negotiates its protocol with the meta tier and
   refuses-and-prompts-update before it can become incompatible (the server half is a server-tier
   child).
5. **Desktop launcher / shell auto-update (Tier 2) — deferred** (maintainer direction 2026-07-17):
   swap the native binary; pick the desktop mechanism (self-hosted updater / Butler / Steam) per
   target, later.
6. **Signing key custody + verification** — offline release key, public key baked into the shell,
   scoped CI secret, documented rotation.
7. **(Phase 8) Console/iOS store-delivery fallback** — store-delivered Tier 1+2; Tier 0 stays live.

## Decisions

- ✅ **Desktop shell-update / storefront (Tier 2) mechanism — DEFERRED** (maintainer direction
  2026-07-17). Ship the pack-overlay self-update first; decide self-hosted launcher vs itch.io Butler
  vs Steam later. The manifest already carries the `shell` fields the future launcher will read.

Still made defensibly above from the settled stack, open to redirect on this PR:

1. **Origin:** platform-hosted OCI/object store (interim: GitHub Releases). Or a specific CDN/host from
   the start?
2. **Channel model:** a single rolling `live` channel (schema allows a future `canary`). Or a
   stable/beta split now?
