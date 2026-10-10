# ADR 0028 — Fence an inactive exact-version GameServer mutation

Status: accepted for an inactive, single-capability experiment (#1271). Durable
generation fencing and production quarantine release remain #793 and #569 gates.

An allocation can lose its reply and still reach Kubernetes storage. The internal
`gameservercommit` capability freezes one Ready GameServer's namespace, name, UID,
opaque resourceVersion and full Ready-to-Allocated update, including the full
attempt digest. Its single conditional PUT never refreshes that version, selects
another resource, follows a redirect or retries a Retry-After response. The local
HTTP client preserves the operator's transport settings while refusing redirect
resubmission and removes the PUT body's replay factory from a private request
copy. This prevents the standard HTTP/1 and HTTP/2 transports from replaying the
mutation, including an unprocessed stream. Shared defaults and the underlying
transport remain unchanged. Operator-supplied transports are trusted configuration;
an arbitrary custom retry implementation is outside this standard-transport guarantee.
Copied handles share the same
one-submission and irreversible drain state. Construction requires explicit
enablement and operator-owned API configuration; each client admits at most 256
distinct resource UIDs for its process lifetime.

Fence closes local admission before reading that exact object over an independent
request. A new random metadata nonce is written with the observed UID/version.
Kubernetes's optimistic concurrency rule makes the already frozen version stale.
An opaque process-local receipt requires a validated acknowledgement and exact
UID, version, nonce and outcome readback. A replacement UID is never modified.
Conflict, missing objects, cancellation, lost replies or malformed responses issue
no receipt and do not reopen the capability.

Noncommit is historical as well as prospective: it requires the pre-barrier
version to equal the original frozen version. A changed version with missing
attempt metadata is unknown, because an earlier commit's state or correlation
could have been changed by another writer. An exact matching allocation observed
before the barrier is reported separately. The receipt covers only this frozen
write, and is accepted only by its originating handle and process incarnation.
It cannot authorize generation closure, native allocator retries, reconciliation
cleanup or release from the existing coordinator's quarantine.

The required CI trial starts real Kubernetes v1.37.0 kube-apiserver and etcd using
SHA-512-pinned controller-tools assets. Helm v4.3.0 renders the declared Agones
v1.61.0 GameServer CRD without modifying its schema. No node or Agones controller
runs. An HTTP proxy holds an allocation before storage while barrier requests use
independent TLS API connections. Positive controls prove late unfenced commits,
including caller cancellation and deadline expiry. Barrier-first cases must
receive storage's HTTP 409 and retain the exact barrier version. Commit-first,
recreated-UID, changed-history and concurrent controls exercise the same storage.

The environment explicitly refuses existing-cluster selection and binds every
binary path. Ambient kubeconfig, cluster-selection and binary overrides cannot
redirect the trial. The runner supervises its own test child and rechecks the
exact private binary path before retiring control-plane processes after a panic,
timeout or signal. Certificates and etcd state stay inside that invocation's
scratch directory; cleanup verifies process retirement before removing it.

This is storage-boundary evidence for the pinned versions, not an Agones deployment
or a complete allocator protocol. The trial module holds its heavy control-plane
test dependencies separately from the server. Production Go composition refuses
imports of the capability, including escaped or aliased imports.

Activation requires a durable, complete grant journal and incarnation recovery,
authenticated exclusive allocator membership, retained reader rollout, and the
real handoff proof. No runtime flag, persisted writer, discovery permission or
production deployment is introduced here.

References: [Kubernetes API concurrency](https://kubernetes.io/docs/reference/using-api/api-concepts/#resource-versions),
[Agones GameServer allocation](https://agones.dev/site/docs/reference/gameserverallocation/),
[controller-tools assets](https://github.com/kubernetes-sigs/controller-tools/blob/main/envtest-releases.yaml).
