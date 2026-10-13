# 0052 — Accept inspectable claims material under one runtime owner

Status: Accepted

## Context

The private claims listener consumes projected files. A workload identity adapter
holds its signing key in the fetching process and needs an explicit initialization
entry without writing that key to a shared file. An opaque TLS configuration or
root pool cannot establish the required allocator/claims key separation.

## Decision

Keep projected-file initialization and its current certificate policy. Add an
explicit initializer for a static bounded certificate-chain DER snapshot, a
signing handle, authority DER, and independently pinned server DNS/URI expectations.
Both existing handoff and claims enablement switches dominate this entry. Disabled
paths ignore material; enabled material mode never falls back to projected claims
files. No current plugin entry selects the new source.

The runtime clones and reparses DER, verifies current validity and ordered chain
signatures, certificate purposes, signer-to-leaf equality, an anchored server
chain, an exact DNS SAN and exactly one expected URI in the configured trust
domain. Wildcard-only DNS matches are refused. It constructs the verified-client
TLS policy internally and inspects all authorities and chain keys for allocator
overlap. The served leaf cannot share an issuer key.

Use the same listener preparation, registration rollback, detached runtime
lifetime, admission gate, connection/request limits and actual shutdown drain.
Credentials introduce no second worker or shutdown owner. Caller DER mutation
and replacing the supplied signer field cannot change the retained configuration.
The signer object itself cannot be cloned: the caller must keep its signing
handle valid for the initialized lifetime; underlying key mutation can cause
handshake refusal and confers no alternate verified principal.

## Boundaries

This supplies static material adaptation and fixture-backed verified transport
and lifecycle evidence. It does not establish successful WorkloadAPI issuance
inside Nakama, process attestation/key ownership, native PostgreSQL custody,
role-private controller cleanup, protected receipt forwarding, gameplay admission,
rotation/revocation or rollback-resistant recovery. #1383 delivers this seam;
#1374/#1346 retain the combined outcomes and #1192 retains retirement. No serving
image, shared credential, production activation or privilege change is authorized.
