# ADR 0031 — Close the complete issued GameServer capability set

Status: accepted for an inactive, process-local experiment (#1289). Production
generation fencing and durable quarantine release remain #793 and #569 gates.

An exact-resource receipt proves only its own frozen write cannot commit late.
The experimental `gameservercommit.Generation` privately owns its commit client
and every capability it exports. Its configuration requires explicit enablement
and a canonical open generation observation in the current writer schema, with
an exact source version and complete membership digest. It copies the member
set. Actor names supplied during preparation must belong to that set; this is
attribution, not authenticated allocator identity or exclusive Kubernetes access.

Preparation reads outside the owner lock, then registers the frozen capability
under open admission before returning its opaque wrapper. A read that finishes
after drain cannot export or submit the private raw capability. Each private
client admits at most 256 distinct resource UIDs in its process lifetime.

Commit serializes its local one-submission admission against closure under the
generation lock, then releases that lock before the HTTP request. Drain atomically
closes preparation and commit admission and freezes every issued capability
before any barrier traffic. An admitted request may still be outstanding; the
exact-version storage barrier, rather than cancellation or process observations,
prevents its late commit.

The complete fence has one 30-second budget and needs an acknowledged exact
barrier and readback for every issued capability. Each observation retains its
actor, attempt, target UID, frozen source version, barrier version and outcome.
An allocation that committed before its barrier remains allocated. It is never
reclassified as uncommitted. An empty issued set covers zero capabilities; it
cannot prove real allocator membership or absence of external writers.

Any missing object, replacement UID, changed history, conflict, lost reply or
canceled budget leaves the owner irreversibly closed without a complete receipt.
Partial barriers are neither retried nor used to authorize release. Receipts
are opaque and bound to the originating owner and process incarnation. Copies
of handles share that state; acceptance returns detached diagnostic data.
Serialization, reconstructed receipts and another owner cannot recover authority.

The required disposable kube-apiserver/etcd trial holds multiple allocation
PUTs before real storage and demonstrates both unfenced late allocations and
storage conflicts after a complete fence, including canceled callers. Mixed
allocated/uncommitted outcomes and partial proof failures use the same storage.
The trial keeps the Kubernetes, Agones CRD and binary pins of ADR 0028; it runs
no Agones controller, allocator service or production client.

This complete set is process-local and covers only capabilities issued by this
owner. Durable activation still requires a complete grant journal and authority
incarnation recovery, authenticated exclusive allocator membership, retained
reader rollout and artifact readback, serialized durable admission/drain, and
the real handoff proof. No persisted writer, production import, discovery
permission, deployment or quarantine release is introduced.

References: [ADR 0028](0028-fence-an-inactive-exact-version-gameserver-mutation.md),
[Kubernetes conditional resource updates](https://kubernetes.io/docs/reference/using-api/api-concepts/#resource-versions).
