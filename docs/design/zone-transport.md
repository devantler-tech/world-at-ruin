# Client-to-zone-server transport

> Status: **accepted** · 2026-07-18 · delivers #167 (Part of the server-foundation epic #4; consumes
> the #165/#166 wire codec). The draft PR is the steering surface — the maintainer redirects there.
>
> This is an architecture decision record. It settles *what carries the wire codec* between the
> Godot client and a zone/dungeon GameServer — the one choice `AGENTS.md` explicitly left to "a
> deliberate ADR-shaped decision". It does not build the socket: the transport child that follows
> cites this document and implements it.

## Why now

The replication chain is pinned end-to-end except for the pipe. The sim produces per-observer
deltas (`server/sim/snapshot.go`), the versioned wire codec freezes their byte layout with
committed hex goldens (`server/wire/`), and `zone -replicate` exercises the whole path — but no
decision anywhere names the transport those bytes travel over. The next server child (the real
socket) cannot be built honestly against an improvised choice: latency behaviour, encryption, the
Agones port model, and the pre-connect handoff all hang on it. This is the same
decide-before-build pattern that worked for distribution and self-update
([distribution-and-self-update.md](distribution-and-self-update.md)).

## The forces

- **The authority is latency-tolerant by design.** The settled design keeps physics out of the
  authoritative path — capsules and navmesh only — *"this is what makes a Go authority cheap,
  deterministic and latency-tolerant"* (`AGENTS.md`). Combat readability comes from telegraphs, not
  twitch dodging. The transport must be good enough for a telegraph MMO, not for an arena shooter.
- **The codec is message-oriented and loss-tolerant already.** Every wire message is
  self-contained: `Decode` refuses trailing bytes, and `KindSnapshot` exists precisely so an
  observer can be resynced from scratch "when an observer joins (or must resync)". A transport that
  preserves message boundaries carries the codec with **zero new framing code**; the resync path
  absorbs whatever the transport cannot promise.
- **The server tier is Go, and the portfolio strongly prefers pure Go.** No cgo in the zone server:
  it is cross-compiled in CI, shipped as a static container to GHCR, and raced (`go test -race`)
  every run. A C dependency in the hot loop is a build, security, and portability cost the suite
  has deliberately avoided everywhere else.
- **The client is Godot 4, core-first.** A transport the engine ships in core is maintained with
  the engine; a GDExtension plugin is a second dependency surface with its own update cadence —
  a real cost under continuous self-update (Tier 1 overlays re-ship scripts, not native libs).
- **Encryption is required.** Source-available product, bespoke EULA, real players on hostile
  networks: game traffic ships encrypted from the first networked build. Retrofitting crypto onto
  an unencrypted live protocol is exactly the kind of breaking change the product law makes
  expensive.
- **Agones owns the port model.** Zone/dungeon GameServers get dynamically allocated host ports on
  node addresses; clients connect **directly** to `node:port` (no L7 ingress in the hot path).
  Agones allocates TCP and UDP ports equally well. Seamless instancing is *"allocate the dungeon
  server as the player approaches, pre-connect, hand off — no loading screens"* — so connection
  establishment must be cheap enough to run seconds ahead, concurrently with play.
- **Browser reach is a non-goal today.** Platforms are deliberately last (Phase 8: desktop,
  consoles, iOS — the web is not even on the list). Reach that comes for free is a bonus, never a
  deciding force.

## The candidates

Godot 4 ships three realistic client transports. Evaluated against the forces:

| Criterion | ENet (UDP) | WebSocket (TCP) | WebRTC (UDP) |
|---|---|---|---|
| Godot client | Core (`ENetConnection`) | Core (`WebSocketPeer`, wss) | Core interface, **native builds need the GDExtension plugin** |
| Go server | **cgo only** (wraps C libenet) | Pure Go, mature | Pure Go (pion), mature but heavy |
| Encryption | **None in ENet itself; Godot's DTLS layer is a custom Godot extension** — a Go peer would have to reimplement a Godot-only dialect | TLS, standard on both ends | DTLS, mandatory, standard |
| Message boundaries | Preserved (packets) | Preserved (RFC 6455 messages) | Preserved (DataChannel messages) |
| Delivery semantics | Per-channel reliable or unreliable-sequenced | Reliable ordered only (TCP; **head-of-line blocking under loss**) | Configurable per DataChannel |
| Agones / ops fit | UDP host port, direct | TCP host port, direct | ICE/STUN + signalling channel + candidate negotiation — a whole subsystem |
| Pre-connect handoff | ~1 RTT connect | TCP+TLS ≈ 2–3 RTT — trivially hidden by an approach-time pre-connect | ICE negotiation is seconds-scale and needs the signalling path up |
| Browser reach | None | Full | Full |

**ENet** is the genre reflex, and it loses on facts, not fashion. Two are disqualifying for *this*
stack: the Go side exists only as a cgo wrapper around C libenet (against the suite's pure-Go,
static-container discipline), and ENet has no encryption — Godot's DTLS-ENet is documented as a
*custom Godot extension*, so a Go server speaking it would be reimplementing a Godot-only dialect
inside a C library. Unencrypted is not an option, so ENet's latency advantage is unreachable
without paying both costs at once.

**WebRTC** solves problems this game does not have. Its two structural advantages — browser reach
and P2P NAT traversal — are respectively a non-goal (platforms-last) and irrelevant
(client-to-server with publicly reachable GameServers). What remains is its cost: a signalling
subsystem, ICE infrastructure, and a native-client GDExtension plugin under a continuous-self-update
regime.

**WebSocket** matches the forces almost point for point: core Godot client, pure-Go server,
standard TLS on both ends, preserved message boundaries (the codec maps 1:1, no framing layer),
direct Agones TCP ports, and a handshake cheap enough that the pre-connect handoff hides it
entirely. Its one real cost is TCP head-of-line blocking under packet loss — a latency spike when a
lost segment stalls the delta stream. Two things bound that cost here: the authority is
latency-tolerant by design (telegraphs, no physics), and the shipped-MMO precedent is squarely on
this side — WoW, FFXIV and GW2 (this game's stated economic lineage) all run their realtime traffic
over TCP. Head-of-line blocking is a measurable risk to watch, not a disqualifier.

## Decision

**WebSocket over TLS (`wss://`) is the client-to-zone-server transport.** The Godot client uses
core `WebSocketPeer`; the zone server terminates TLS in-process on its Agones-allocated TCP port
(no L7 ingress in the hot path). One wire-codec message per WebSocket **binary** message, in both
directions.

Consequences:

- **No framing layer is built — deliberately.** WebSocket preserves message boundaries, so
  `wire.Decode`'s refuse-trailing-bytes contract maps exactly onto one-message-per-frame. The
  length-prefix stream framing a raw-TCP choice would have required is explicitly out; a future
  transport must likewise preserve boundaries or add its own framing at the edge.
- **No channels — the kind byte discriminates.** Control and replication multiplex on the single
  ordered stream; `KindSnapshot` vs `KindSnapshotDelta` (and future kinds) is the demultiplexer.
  The codec already refuses unknown kinds, fail-closed.
- **The transport enforces a hard inbound message-size limit.** WebSocket libraries assemble a
  complete message before the codec sees a byte, so `wire.Decode`'s entity-count caps run too late
  to bound memory on their own. The socket child sets a read limit at the WebSocket layer, sized
  to the largest *valid* wire message for the direction — client→server messages (control/input
  kinds) are small, so the server's inbound cap is kilobytes, never the codec's multi-megabyte
  server→client ceiling.
- **The loss-tolerance design maps onto backpressure.** On TCP, deltas are never *lost* — but a
  slow or stalled client backs the stream up. The rules the socket child implements: the
  per-observer send queue is **bounded** — on overflow the server drops the queued deltas and
  replaces them with one fresh `KindSnapshot` resync — and the socket carries **write and idle
  deadlines**: a peer that does not drain within its deadline is **disconnected**, releasing the
  fd, kernel buffers and per-observer state. Never unbounded buffering in the zone process. (The
  distribution ADR's never-kicked-mid-session law forbids update/protocol-*compatibility* kicks;
  it does not oblige the server to host a non-draining socket. A dropped client loses nothing —
  state is server-authoritative, and reconnecting lands on the normal join/`KindSnapshot` path.)
- **TLS identity is by DNS name, never by raw address.** Certificates bind hostnames — a
  dynamically allocated *port* never touches certificate identity, but a raw node IP would. The
  handoff therefore always hands the client a **DNS name plus port**: nodes carry stable names
  under a zone-edge domain, covered by a certificate the platform's existing issuance
  (cert-manager) provisions and mounts into the GameServer. Certificate verification stays **on** —
  an implementation pressured toward `verify=false` is a defect, and this provisioning plan is a
  prerequisite the socket/deploy children build, not an afterthought.
- **Admission requires an allocation-scoped token, not just a session.** A Nakama session ticket
  proves an account, not that *this* account was allocated to *this* GameServer — with directly
  reachable ports, session-only admission would let any signed-in user connect to arbitrary
  instances. The upgrade therefore carries a **short-lived allocation token** minted at the
  Agones-allocation/handoff step and verified by the zone server before the observer is admitted.
  `server/handoff` now owns the transport-neutral verification → allocation → token-minting
  contract, including the managed zone-domain boundary and rollback of a reservation that cannot
  produce a usable handoff; the concrete Agones allocator adapter and Nakama RPC registration
  remain later server-foundation children.
- **One transport discipline across tiers.** Nakama's own realtime API is WebSocket; client
  networking, platform ingress, and TLS handling follow a single pattern instead of two.
- **The wire codec is unchanged.** Nothing in this decision touches `server/wire/` — the goldens
  stand, and `Version` stays 1.

## What would reverse it

1. **Measured head-of-line harm.** Once the client-side delta apply exists and real-network play
   happens, if loss-induced delta stalls measurably break telegraph readability (rubber-banding
   during dodge windows at realistic loss rates), the escape hatch is **DTLS over UDP with
   standard components on both ends** — Godot core `PacketPeerDTLS` against a pure-Go DTLS server
   (pion) — carrying the identical codec (unreliable-sequenced deltas + `KindSnapshot` resync,
   which the codec was designed for). The codec's transport-agnosticism makes this an *additive
   second transport*, not a rewrite. Measure first: the reversal trigger is evidence from play,
   never fashion.
2. **A Godot core defect.** If `WebSocketPeer`/TLS proves broken for sustained per-tick traffic on
   a shipping platform, the same DTLS-over-UDP path applies.
3. **The port model changing.** If GameServers ever stop being directly reachable (forced behind an
   L7-only edge), the transport question reopens wholesale — that would move more than this ADR.

A web platform tier becoming real does **not** reverse this decision — it reinforces it.
