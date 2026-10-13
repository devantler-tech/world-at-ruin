# 0051 — Prove the issued native runtime union

Status: Accepted

## Context

The native storage trial selects Nakama 3.40/runtime API 1.47. The ordinary
server and identity trial select 3.41/1.48 and gRPC 1.84. A Go plugin requires
compatible shared package builds; separately passing storage and credential
trials do not establish a compatible combined runtime.

## Decision

Use a nested experimental module at `server/nakama-issued-runtime`, with its
own Go-generated locks and the local server replacement. The fixed `issued`
builder profile selects Nakama 3.41.0, runtime API 1.48.0, SPIFFE SDK 2.8.2
and gRPC 1.84.0. Binary and plugin share one native compiler environment,
module union and flags. Evidence records both nested locks and inherited
server locks, actual selected dependencies and built artifact hashes.

Both plugin entries share the server initialization entrypoint. Normal builds
retain the build-tag exclusion of admission/custody probe dependencies. The
separate issued entry contains the SDK; ordinary and legacy native graphs do
not gain it. Existing native acceptance runs unchanged against the new union
on both supported Linux architectures, alongside a race-built mismatched
plugin that must refuse loading.

The issued entry has a default-off diagnostic SDK probe. Absent or false
enablement ignores every probe setting. Enabled probes make a bounded real
WorkloadAPI request before any shared runtime initialization and always
refuse serving startup. Missing issuer, malformed configuration, unknown
transport failure and an unexpectedly successful fetch have distinct sanitized
refusals. Fetched credentials never leave the plugin or confer authority.

## Boundaries

This proves runtime compatibility and SDK unavailable-issuer behavior. It
does not prove successful issuance, process-owned claims TLS, a combined
issued-zone/native-storage claim, protected receipt forwarding or gameplay
admission. Those outcomes remain #1374/#1346. Production rollout and
experimental retirement remain #1192. No shared credential or serving image
changes. The independent monotonic witness remains a separate prerequisite.

## Dependency update — 2026-10-13

The issued profile selects SPIFFE SDK 2.9.0 with matching module locks and
artifact expectations. The runtime-union and authority boundaries above remain
unchanged. A selected-module conformance test requires dependency updates to
advance the explicit profile together with the immutable graph.
The issued module declares Nakama as a Go tool dependency, retaining the
separately built binary target through module maintenance. Artifact-target
resolution must succeed under read-only locks for both binary and plugin.
