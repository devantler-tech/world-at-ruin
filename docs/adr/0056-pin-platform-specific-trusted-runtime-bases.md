# Pin platform-specific trusted runtime bases

Status: accepted for the repository build recipe; runtime reuse is not adopted.

The cold inventory records an image after construction, while the two existing
FROM digests identify multi-platform indexes. An independently reviewable recipe
must also identify the exact Linux/amd64 manifests and their configurations.

Keep the existing index roots in a small source declaration. A maintenance-only
resolver fetches public registry metadata, verifies complete bounded raw bytes
against every digest and descriptor size, and requires one Linux/amd64 selection.
Generate a lock retaining those exact metadata bytes. Offline checking repeats
the cryptographic chain and joins both actual Dockerfile references to the lock.
The build consumes the selected manifest digests with an explicit platform;
checking and Docker execution share the original build deadline.

Registry metadata is data, never a command or endpoint selector. Only the two
reviewed Docker Hub library repositories are fetched. Layer bytes remain Docker's
content-addressed responsibility during the real build. The lock does not prove
package resolution, producer authorization, reusable artifact provenance or a
warm saving. The existing snapshot/signature/HTTPS policy, engine verification,
non-root containment and complete regression verdicts remain unchanged.

Validate refusal paths locally and the actual selected bases in hosted cold CI.
The generated metadata lock is updated through the resolver, never by hand.
