# ADR 0004: Serve delivery bytes from a plain HTTPS origin, never from the registry

- Status: Accepted
- Date: 2026-09-05
- Decision issue: [#611](https://github.com/devantler-tech/world-at-ruin/issues/611)

## Context

The update manifest is published to GHCR as a cosign-signed OCI artifact — the
digest-pinned contract origin the client will one day resolve against. The same
manifest is where a delivery would be described: `pack.full`, `pack.deltas` and
`shell.download` each carry a `url`, a `sha256` and a `size`.

The client gates every such URL through `RollbackSelection._is_fetchable_url`:
a whitespace-free `https://` address with a host, and nothing else. It is a
shape check by design — reachability is the updater's problem — but the shape
it demands is a plain download, because an artifact is fetched before its
signature can be checked and the transport is part of the trust story.

A GHCR blob is not a plain download. Reading one takes an OCI token exchange
first: `cd.yaml`'s own anonymous reachability check fetches a bearer token from
`https://ghcr.io/token?scope=repository:<repo>:pull` and only then reads the
manifest with `Authorization: Bearer`. A bare `GET` of a blob URL does not
resolve. So no URL the registry could offer satisfies the rule the client
enforces, and the two cannot both stand as written.

Nothing is broken today: the manifest omits delivery entirely, and omission is
the fail-closed value — the update decision refuses a capability-raising pack
rather than offering one no player could roll back from. The question is what
the delivery URL will be once there is a mountable pack to deliver.

Three answers were on the table:

1. **Teach the client the OCI token exchange.** The client becomes a registry
   client and `_is_fetchable_url` widens to an OCI reference shape.
2. **Publish delivery bytes to a plainly fetchable origin** and keep GHCR as the
   digest-pinned contract origin.
3. **Front GHCR with a plain-HTTPS redirector.**

## Decision

Delivery bytes are served from a **plain HTTPS origin named by the channel**,
and the registry is **never a delivery origin**. The channel's origin is a
GitHub release asset while GitHub Releases is the interim bootstrap origin the
distribution design already names, and the platform's object store behind its
CDN edge once the platform CD path exists. The client only ever knows the
channel URL, so that migration needs no client change.

`_is_fetchable_url` stays exactly as strict as it is: `https://`, a host, a
plain download. It is deliberately **not** widened. The client never learns
registry authentication, and the transport it trusts stays a shape a reviewer
can read in one line.

GHCR keeps its role unchanged: the **digest-pinned, cosign-signed contract
origin** for the manifest and the build it describes. A delivery entry in that
manifest names the plain origin and pins the bytes by `sha256` and `size`.

Two origins holding the same bytes is the failure mode #280 refused for the
*manifest*, and it is acceptable for *delivery* only because the client verifies
every delivered byte against the manifest's hash before mounting. A mismatch
between the release asset and the digest the manifest pins is therefore
detected and refused on the client, and the publish pipeline additionally
proves the two are the same bytes before a release leaves draft, so the client
check is a backstop rather than the only line.

## Consequences

- Option 1 is rejected: it couples the client to GitHub's token endpoint, moves
  authentication logic into the one component that cannot be patched without a
  shell update, and contradicts the design's rule that the client knows only a
  channel URL.
- Option 3 is rejected: a redirector adds infrastructure and a new trust
  surface on the delivery path to solve a problem option 2 solves with none.
- When the pack build and publish pipeline (decomposition child 3 of the
  distribution design) produces a mountable pack, CD publishes it as a release
  asset alongside the OCI artifact, writes its release-asset URL, `sha256` and
  `size` into the manifest's `pack.full` entry, and fails the release if the
  asset's hash does not equal the pinned digest.
- The anonymous GHCR reachability check keeps guarding the contract origin; a
  sibling check that downloads the release asset with no credentials and
  verifies its hash guards the delivery origin from the first delivery on, and
  both become blocking when the updater consumes them (#141).
- A shell download follows the same rule and additionally needs the offline
  root's authorisation (#490) whatever origin serves it.
