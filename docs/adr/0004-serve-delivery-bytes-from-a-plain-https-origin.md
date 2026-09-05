# ADR 0004: Serve delivery bytes from a plain HTTPS origin, never from the registry

- Status: Accepted
- Date: 2026-09-05
- Decision issue: [#611](https://github.com/devantler-tech/world-at-ruin/issues/611)

## Context

The update manifest is published to GHCR as a cosign-signed OCI artifact — the
digest-pinned contract origin the updater pins (maintainer direction
2026-07-18, recorded in `AGENTS.md`). The same manifest is where a delivery
would be described: `pack.full`, `pack.deltas` and `shell.download` each carry
a `url`, a `sha256` and a `size`.

`RollbackSelection.is_wellformed()` gates every rollback target through
`_is_fetchable_url`: a whitespace-free `https://` address with a host, and
nothing else. The same shape is what a `pack.full.url` or `shell.download.url`
would have to satisfy. It is a shape check by design — reachability is the
updater's problem — and the shape it demands is a plain download, because an
artifact is fetched before its signature can be checked and the transport is
part of the trust story. Being a shape check, it cannot by itself enforce this
decision: a syntactically valid `https://ghcr.io/v2/…/blobs/…` address passes
it even though a bare `GET` of that address does not resolve.

A GHCR blob is not a plain download. Reading one takes an OCI token exchange
first: `cd.yaml`'s own anonymous reachability check fetches a bearer token from
`https://ghcr.io/token?scope=repository:<repo>:pull` and only then reads the
manifest with `Authorization: Bearer`. So no URL the registry could offer
satisfies the rule the client enforces for a delivery, and the two cannot both
stand as written.

Nothing is broken today: the manifest omits delivery entirely, and omission is
the fail-closed value — the update decision refuses a capability-raising pack
rather than offering one no player could roll back from. The question is what
the delivery URL will be once there is a mountable pack to deliver.

Three answers were on the table:

1. **Teach the client the OCI token exchange for delivery too.** The client
   downloads blobs from the registry, and `_is_fetchable_url` widens to an OCI
   reference shape.
2. **Publish delivery bytes to a plainly fetchable origin** and keep GHCR as the
   digest-pinned contract origin.
3. **Front GHCR with a plain-HTTPS redirector.**

## Decision

**Delivery bytes are served from a plain HTTPS origin named by the channel, and
the registry is never a delivery origin.** The channel's delivery origin is a
GitHub release asset while GitHub Releases is the interim bootstrap origin the
distribution design already names, and the platform's object store behind its
CDN edge once the platform CD path exists. The client knows one channel, so that
migration needs no client change.

**The contract stays where it is and is read the way the design already
intends.** GHCR remains the digest-pinned, cosign-signed contract origin for the
manifest and the build it describes. The updater (decomposition child 4 of the
distribution design) reads that contract from the registry **by digest** through
the anonymous OCI read — token exchange, then manifest fetch — that
`verify-ghcr-public` performs today. That read is the one registry interaction
the client has; it is bounded to the contract, it is unauthenticated, and it
never widens into a delivery path. A delivery entry inside that contract names
the plain origin and pins the bytes by `sha256` and `size`.

`_is_fetchable_url` stays exactly as strict as it is: `https://`, a host, a
plain download. It is deliberately **not** widened. It is also not the
enforcement of this decision: it guards only rollback targets today, and it is
a shape check. Enforcement is that the updater applies the same predicate to
every delivery field before fetching, and that the publishing pipeline proves,
with no credentials, that every published delivery URL downloads and hashes to
the digest the manifest pins.

Two origins holding the same bytes is the failure mode #280 refused for the
*manifest*, and it is acceptable for *delivery* only because the client verifies
every delivered byte against the manifest's hash before mounting and the publish
pipeline proves the asset and the pinned digest are the same bytes before a
release leaves draft. The client check is a backstop rather than the only line.

## Consequences

- Option 1 is rejected for delivery: it would route every pack and shell byte
  through registry authentication, move that logic into the one component that
  cannot be patched without a shell update, and put a URL in the manifest that
  the client's own rule refuses. The anonymous contract read by digest is kept,
  because a contract the client cannot fetch describes nothing.
- Option 3 is rejected: a redirector adds infrastructure and a new trust
  surface on the delivery path to solve a problem option 2 solves with none.
- When the pack build and publish pipeline (decomposition child 3 of the
  distribution design) produces a mountable pack, CD publishes it as a release
  asset alongside the OCI artifact, writes its release-asset URL, `sha256` and
  `size` into the manifest's `pack.full` entry, and fails the release if the
  asset's hash does not equal the pinned digest (#788).
- The anonymous GHCR reachability check keeps guarding the contract origin; a
  sibling check that downloads each published delivery URL with no credentials
  and verifies its hash guards the delivery origin from the first delivery on
  (#789), and both become blocking when the updater consumes them (#141).
- The updater applies `_is_fetchable_url` to every delivery field, not only to
  rollback targets, before it fetches anything.
- A shell download follows the same rule and additionally needs the offline
  root's authorisation (#490) whatever origin serves it.
