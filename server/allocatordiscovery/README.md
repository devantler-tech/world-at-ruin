# Allocator discovery

`allocatordiscovery` supplies read-only Kubernetes observations for the allocator
generation milestone (#793). It is not registered with a running supervisor and
does not dispatch, persist generations, mutate Kubernetes objects or clear quarantine.

`New` takes typed Core V1 and Discovery V1 clients and explicit namespace, Pod label
selector, Service name/UID, named TCP port and page budget. It retains only Pod
`List`/`Get` and EndpointSlice `List` capabilities, bound to that namespace. The
eventual Kubernetes role needs only namespaced `get/list` on Pods and `list` on
EndpointSlices; this component never reads Secrets, GameServers or ReplicaSets.
Configure a bounded transport and pass an operation context. There is no watch,
background loop or internal restart after an expired continuation token.

## Complete observations

`Discover` completes both collections before returning anything. Each list uses
100-object pages and a required budget of 1–100 pages. Collection resource versions
must remain nonempty and identical within each list. Repeated or oversized cursors,
oversized pages, expiration, errors, cancellation and exhausted budgets discard the
entire observation. A failed API call returns a stable error without backend details;
cancellation and deadlines remain distinguishable.

The two collection resource versions are returned separately: Kubernetes pagination
provides consistency **within one collection**, not an atomic snapshot across Pods
and EndpointSlices. Discovery rejects stale or conflicting joins, and callers must
treat a successful result as an observation that can already be outdated.
[Kubernetes pagination contract](https://kubernetes.io/docs/reference/using-api/api-concepts/#retrieving-large-results-sets-in-chunks).

Every EndpointSlice must belong to the configured Service UID through its controller
owner reference. Every endpoint must reference an observed Pod's exact namespace,
name and UID, carry one configured named TCP port, and use an IP found on that Pod
with the matching IPv4/IPv6 address family. Missing targets, foreign resources,
reused identities and conflicting socket ownership fail the entire result.
The Pod target reference may omit its optional API version or explicitly use `v1`;
other versions and missing or different kinds are rejected in both cases.

Identical endpoints across slices are deduplicated; dual-stack addresses aggregate
under one Pod UID. Conflicting conditions for the same socket are rejected rather
than selecting whichever slice arrived first. Members and their addresses are sorted
deterministically, and returned slices are detached from API objects.
[EndpointSlice aggregation contract](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/#duplicate-endpoints).

Limits also include 1,000 endpoint entries and 100 ports per slice, 100 addresses per
endpoint, two addresses per Pod, and 10,000 processed endpoint addresses across the
observation (including duplicates). Identity tokens are bounded to 128 bytes,
resource versions to 1,024 bytes, continuation tokens to 16 KiB, and selectors to
4 KiB. These are intentional application bounds, not claims about all possible
Kubernetes deployments. Oversized data produces no usable observation.

## Readiness and identity are not authority

Selected Pods remain members even without endpoints or while unready, terminating
or in a terminal phase. Observed Pod readiness, phase and deletion, and endpoint
ready/serving/terminating/deletion conditions stay explicit. `EligibleEndpoints`
requires a running, ready, non-deleting Pod and an explicitly ready endpoint that
is neither deleting, explicitly not serving, nor explicitly terminating. Unknown
endpoint readiness is excluded. Unknown serving/terminating retain API defaults.
The Pod check prevents `publishNotReadyAddresses` from making an unready Pod eligible.
Eligibility is a connection candidate, not permission to allocate.

`ObservePod` reads an exact name and returns `Present`, `Absent` or `Replaced` by
comparing the returned UID with the expected UID. Replaced includes the observed new
identity; absent contains no Pod. API failures return neither result. These facts do
not prove the old process is dead: forced deletion can remove the API object while
its process keeps running, and a disconnected node can cause Pods to be marked
Failed. [Kubernetes Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#forced-pod-termination).

The pending fence implementation must prove every actor capable of committing the
old allocation has lost that ability. It also needs admission serialized against
generation draining and authentication of the actual RPC process; an IP can be
reused and a shared Service certificate does not bind a Pod UID. No termination
proof or persisted proof schema is introduced here. See the corrected boundary in
[ADR 0002](../../docs/adr/0002-seal-zone-admission-secrets-before-readiness.md).

## Validation

The tests use the generated typed clients both through Kubernetes fake reactors and
an HTTP API fixture. They cover pagination and late failures, exact selectors and
URLs, identity reuse, duplicate and dual-stack endpoints, readiness, cancellation,
private-error suppression and detached observations. They do not contact a cluster
or claim that a process can no longer commit an allocation.
