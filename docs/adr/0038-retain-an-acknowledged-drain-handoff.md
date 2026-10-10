# 0038: Retain an acknowledged drain handoff without restoring authority

- Status: Accepted for the explicitly enabled native experiment
- Issue: #1321 (first delivery slice of #1315)

## Context

A durable admission root freezes the complete registered inventory at drain.
Its private writer snapshot currently dies with the source process. A fresh
process needs independently retained expectations before inspecting storage.
Neither a visible draining row nor an observed publication can establish that
the original owner received its acknowledgment.

## Decision

The original private admission writer may publish exactly once from its own
acknowledged draining snapshot. A separate private Nakama collection,
`world_at_ruin_allocator_recovery_handoffs`, has one create-only key per
generation, independent of incarnation. Schema 1 retains the acknowledged
admission-root version and the entire strict admission document, including
original actor, attempt, namespace, fleet, name, UID and resourceVersion.

`Generation.CloseForRecovery` closes preparation and commit admission before
waiting for pending registration. It serializes with that registration, rejects
any unknown outcome, drains the latest acknowledged root, then publishes.
A registered-but-unexposed capability remains in the frozen inventory.
Fence and handoff are mutually exclusive terminal operations. There is no
retry, root refresh, new incarnation election or reopen operation.

Publication returns detached diagnostic pins only after a complete private
storage acknowledgment and a final context check. The native supervisor retains
those pins through its private control channel and supplies them to a separately
launched reader. This experimental supervisor is the trusted handoff owner;
production authentication and delivery of these pins remain unproven.

The StorageRead-only reader requires those independently pinned root binding
and handoff version before reading. It checks private owner/permissions, exact
versions, strict schema and complete inventory equality across both documents.
It cannot construct a writer snapshot, grant or receipt.

## Crash and acknowledgment cuts

- A drain whose reply is lost or canceled produces no handoff.
- An acknowledged drain followed by a crash before publication leaves only a
  draining root; that is insufficient recovery input.
- A publication whose reply is lost, malformed or canceled produces no exported
  reference. A visible publication never repairs that uncertainty.
- Publication acknowledgment without successful independent pin retention
  leaves no trusted recovery input.
- Successful pinning permits diagnostic inventory readback only.

## Consequences and remaining gates

The native-only `WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED` flag defaults off,
before dependency access, and has retirement tracked in #1316. Ordinary plugin
builds exclude the probe. Existing writer and production import guards remain.

A handoff does not fence any outstanding GameServer write. Native acceptance
must hold an original PUT through publication and fresh readback, observe zero
barrier PUTs, then require the original write to return HTTP 200/Allocated.
Independent barrier recovery, durable competing-recoverer ownership, mixed
barrier outcomes, crash-safe complete proof publication and quarantine release
remain #1315/#793 work. No production allocator or retained serving reader is
activated by this decision.
