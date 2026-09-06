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
CDN edge once the platform CD path exists. Because the delivery URL travels inside the
fetched contract, that migration needs no client change. The contract origin itself is
not yet free to move: the updater reaches it through a registry reference the shell carries,
so retiring GHCR needs either a project-controlled channel-discovery reference or a shell
update — tracked under the distribution epic, not settled here.

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
every delivery field before fetching, and that the publishing pipeline verifies
every published delivery URL against the `sha256` and `size` the manifest pins —
in the two stages the Consequences below set out.

A delivery URL is **durable and public**: no userinfo, no signed or expiring
query parameters, nothing that stops answering once a token lapses. The shape
check accepts optional userinfo and any query string, and a presigned
object-store or CDN URL also passes a credential-free fetch on publication day —
then expires, leaving retained manifests and rollback targets pointing at bytes
nobody can fetch. The publishing pipeline therefore refuses a delivery URL that
carries userinfo or a signed-URL parameter (#788); reachability checks alone
cannot catch it.

Two origins holding the same bytes is the failure mode #280 refused for the
*manifest*, and it is acceptable for *delivery* only because the client verifies
every delivered byte against the manifest's hash before mounting, and the
publish pipeline proves — with its own credentials, before the release leaves
draft — that the asset it uploaded matches the `sha256` and `size` the manifest pins.
Credential-free reachability is a different property and cannot be proven
before publication: a draft release's assets answer an unauthenticated request
with 404. It is therefore verified after publication, the way
`verify-ghcr-public` already verifies the contract origin, and a failure turns
the release red rather than staying hidden. The client check is a backstop
rather than the only line.

## Consequences

- Option 1 is rejected for delivery: it would route every pack and shell byte
  through registry authentication, move that logic into the one component that
  cannot be patched without a shell update, and put a URL in the manifest that
  the client's own rule refuses. The anonymous contract read by digest is kept,
  because a contract the client cannot fetch describes nothing.
- Option 3 is rejected: a redirector adds infrastructure and a new trust
  surface on the delivery path to solve a problem option 2 solves with none.
- When the pack build and publish pipeline (decomposition child 3 of the
  distribution design) produces a mountable pack, it stays a layer of the cosign-signed
  OCI artifact — one digest keeps attesting build, pack and contract — and CD mirrors it to the
  delivery origin as a release asset, writes that asset's URL, `sha256` and
  `size` into the manifest's `pack.full` entry, and — before the release leaves draft, with
  CD's own credentials — fails the release if the uploaded asset's `sha256` or byte count does not equal
  the pinned `sha256` and `size` (#788).
- The anonymous GHCR reachability check keeps guarding the contract origin; a
  sibling check that runs after publication, downloads each published delivery URL with no credentials,
  and verifies its `sha256` and `size` guards the delivery origin from the first delivery on
  (#789), and both become blocking when the updater consumes them (#141).
- Publication order changes once delivery fields exist: today `publish-ghcr`
  advances the `latest` tag before `publish-release` makes the asset public, so a
  manifest carrying a delivery URL would be live while that URL still answers
  404. CD must stage the digest without advancing the live channel, publish and
  verify the release asset, confirm the contract itself is anonymously readable at that
  digest — the `verify-ghcr-public` check, which a private package fails — and only then
  promote that digest to `latest`. Both verifications enter the durable eligibility record,
  because promoting on the delivery check alone can expose a contract every client gets a
  401 fetching. A failed publication or verification of either kind leaves the
  previous contract live. Promotion
  is **monotonic and eligibility-aware**: per-tag CD runs overlap, so `latest`
  converges on the greatest release that has passed every gate — never on a newer
  immutable tag that has not yet been verified, and never backwards onto an older
  one whose verification finished late. That needs verification recorded durably
  per version and a promotion that is **serialized or a genuine compare-and-swap**:
  one writer at a time — a workflow concurrency group or an equivalent lease — that
  re-reads the verified set inside its critical section and writes `latest` once.
  A read followed by an unconditional `oras tag`, as the current `latest` helper
  does, is not a compare-and-swap: a newer run can promote between the read and the
  write and a bounded retry can end on the stale write. The record's shape and the
  fence are #788's to design.
- The updater applies `_is_fetchable_url` to every delivery field, not only to
  rollback targets, before it fetches anything.
- A shell download follows the same rule and additionally needs the offline
  root's authorisation (#490) whatever origin serves it.
