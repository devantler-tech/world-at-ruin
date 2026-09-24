# Fence ended zone sessions before cleanup

Status: accepted for the inert storage boundary (#875, part of #567).

## Context

A claimed allocation must survive an uncertain socket upgrade or disconnect.
Its handoff deadline only governs initial admission, so expiry cannot authorize
deleting a claimed session. Once a trusted caller independently proves that the
session has ended, cleanup needs an exact ownership fence before releasing the
reservation for another allocation.

## Decision

Add `nakamalease.Store.EndSession` as an explicitly invoked storage operation.
Its caller supplies the opaque lease object key, exact claimed storage version,
attempt digest, allocation name, pinned GameServer UID and persisted claim time.
Together these identify one allocation lifetime. Reconnecting a socket does not
start a new generation. The descriptor is not authentication or proof of death;
the caller must establish that authority separately and capture the descriptor
at admission, never refresh it in response to an old completion message.

The store validates the descriptor against the durable claimed record, then
conditionally clears the claim stamp and sets `releasing` in one write. There
is no intermediate state that permits admission. This is the existing schema-3
release representation, readable by every retained schema-3 reader. No save
format, advertised capability, historical fixture or reader version changes.

Read back the barrier before external cleanup, even when the write response
claims success. A lost or malformed acknowledgement permits only that bounded
read; it never causes another write against a newly adopted version. Run the
context-aware, idempotent cleanup callback only after the exact barrier is
durable. `agonesresources.Adapter.Release` deletes the named GameServer with
its original UID precondition. A recreated GameServer is left alone.

Delete the lease only after resource cleanup succeeds, using the exact barrier
version. A failed delete gets one readback: absence is complete, changed
ownership is a conflict, and unchanged or unavailable evidence retains failure.
The operation has a maximum thirty-second context budget. It returns sanitized
errors, and cancellation never triggers additional destructive work.

The barrier remains durable after a crash or failed cleanup. An old claim
descriptor cannot resume it because its generation has deliberately been
consumed. The existing `ReclaimExpired` reconciler resumes releasing records
immediately, even before their old no-show deadline, using the pinned resource
reference and version. A replay after the record is absent succeeds without
calling cleanup; a replacement at the same key fails the old ownership fence.

## Consequences and delivery boundaries

This increment exposes no endpoint and registers no runtime hook. It does not
enable the claim handler, zone command or any experimental flag. #567 and #569
still own the authenticated session-end signal, normal-completion lifecycle,
receipt capture and production composition. A network disconnect, timeout,
Pod disappearance or replica count is insufficient evidence of session end.
Deployment must also prove an old process cannot resume its session authority.
Allocator-generation quarantine and the unresolved proof in #793 are unchanged.

## Verification

Tests cover stale versions, generations, attempts and UIDs; unclaimed records;
claim-versus-cleanup fencing; lost write and delete responses; canceled calls;
overlapping completion; replacement leases; and restart recovery. Integration
tests exercise the real mutual-TLS claim service and Agones resource adapter
with transport fakes, asserting the durable barrier and exact UID precondition
at deletion. They do not establish production process-death or deployment proof.
