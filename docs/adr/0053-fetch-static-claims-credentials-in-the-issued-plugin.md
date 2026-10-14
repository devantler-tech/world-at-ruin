# 0053 — Fetch static claims credentials in the issued plugin

Status: Accepted

## Context

The separate issued runtime supports the SDK, but its diagnostic probe always
refuses serving authority. ADR 0052 provides the fixed inspectable-material
listener without selecting it from a plugin entry. Join these two surfaces
before attempting real issuer and originating custody composition.

## Decision

Only the distinct issued entry recognizes `WAR_ISSUED_CLAIMS_ENABLED=true`.
Require both existing handoff/claims switches and independent expected DNS/URI
configuration. Refuse simultaneous diagnostic-probe selection. Disabled mode
keeps projected behavior and ignores all new material settings.

Fetch one parsed SVID and its pinned trust-domain bundle using an explicit local
Unix WorkloadAPI endpoint. Limit the request to three seconds and its received
message to 256 KiB. Refuse canceled startup and sanitize failures. Close the SDK
transport before initializing the shared plugin probes and claims listener.
Retain the parsed signer in the static material snapshot; never write it to a
credential file. The shared runtime still reparses and validates certificates,
identity, chain, signing key and allocator separation and owns rollback/draining.
There is no refresh goroutine, second lifetime or projected-credential fallback.

## Evidence and limits

Source tests exercise real SDK Unix RPCs. Both issued native architectures must
load the actual plugin and perform a verified private claim against native
Nakama/PostgreSQL, then independently compare the receipt and replay with storage.
The native WorkloadAPI service is explicitly synthetic and transfers fixture
keys; it proves SDK/plugin/storage integration, never SPIRE attestation or
process-exclusive issuance. Existing native and ordinary module graphs, image
privileges, scenarios and production entry points stay unchanged.

#1387 delivers this prerequisite. Real distinct-role SPIRE credentials,
originating enrollment/custody, protected forwarding, gameplay admission and
rollback resistance remain #1374/#1346. #1192 owns experimental switch retirement.
