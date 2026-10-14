# 0054 — Prove real issued claims in native storage

Status: Accepted

## Context

The issued plugin accepts one locally fetched static credential. Existing native
acceptance uses a synthetic issuer; the separate SPIRE trial uses synthetic
storage. Neither proves a real issued private claim against native PostgreSQL.

## Decision

An unpublished `issued-spire` native acceptance profile composes the issued
runtime with pinned SPIRE binaries and a separate Linux-only test tag. It runs
only with explicit opt-in. Existing native and issued suites retain their
unprivileged identities and unchanged scenario sets.

A controller with only SETUID, SETGID and KILL owns private issuer state and
fixed child handles. An unprivileged coordinator owns the existing native
fixture and Nakama child at UID 10001. The plugin fetches and retains its own
credential. After a real authenticated handoff, the controller registers the
exact allocation zone principal for a distinct UID. The zone process fetches
its own credential and presents it through ordinary verified TLS. Private
pipes carry binding/token metadata and complete receipts, never workload keys.

Independent PostgreSQL reads compare the complete receipt and unchanged replay.
Wrong identity, issuer, server expectation and key controls must preserve the
native lease. Workload readiness is distinct from issuer socket readiness.
Cooperative coordinator cleanup and its acknowledgement precede exact process
join. A failed or uncertain join fails acceptance and retains private evidence;
disposable container retirement is containment, not evidence of child joining.

## Consequences

This establishes the issuance/private-claim/native-storage intersection only.
It does not compose original enrollment and custody handles or their complete
loss/death/restart matrix. Those remain #1374. Controller forwarding is test
coordination, not a protected production receipt path. Same-role identities
grant no original-handle adoption, gameplay admission, launch exclusion or
independent rollback witness authority. #1346 and #1341 remain open. Existing
retirement owner #1192 covers the experimental profile and issued entry.
