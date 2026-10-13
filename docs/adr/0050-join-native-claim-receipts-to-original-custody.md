# Join native claim receipts to original custody

Status: Accepted for a default-off disposable storage-composition experiment.

## Problem

The native custody experiment uses a diagnostic receipt. The native private claim
experiment proves durable claiming but discards its response. Issue #1371 joins
the complete originating response to the original acknowledged enrollment before
the authenticated launch composition in #1346.

## Decision

Keep the original custody owner in one live, tagged native Nakama process. A
separate native serving process owns the actual private claim handler against the
same disposable database. Use the existing second-process launcher with its own
node, ports, configuration, owned stop and sole wait. The custody process does not
enable handoff or a private listener; its startup probe runs before ordinary
runtime initialization, so it cannot serve the claim while awaiting custody.

The new `WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE=control` mode is available only with
`WAR_ZONE_CUSTODY_PROBE_ENABLED=true` in the explicitly built `war_native_trial`
plugin. Its input contains the complete allocation binding, expected observer and
diagnostic owner/child correlations, with no supplied receipt. Existing diagnostic
scenarios retain their input and behavior. Normal command dependencies remain
unchanged.

The order is: serving process startup → actual allocation/handoff → original
enrollment create → accepted originating enrollment ACK → fixture claim call →
complete original response delivery → original enrollment custody create →
accepted originating custody ACK → detached diagnostic pin delivery. The fixture
controller starts the claim only after the enrolled callback, never at the earlier
committed-row callback. There is no gameplay-child spawn or admission in this slice.

The controller uses the actual v2 private claim client and handler with the exact
zone principal and verified fixture-CA TLS. It forwards the complete original
receipt once through a bounded literal-loopback GET response. The probe rejects
redirects, proxies, wrong status/content type, oversized or incomplete bodies,
missing/null/duplicate/unknown fields, changed binding and changed observer. No
response uncertainty may trigger another GET, another claim, a diagnostic fallback
or a storage read to recover the receipt. Matching values alone do not prove that
this fixture transport is independently authenticated or protected.

The existing opaque originating Enrollment consumes the custody attempt before
storage I/O. Lost/canceled enrollment ACKs cause zero claim calls. Lost/canceled
custody ACKs can leave a committed row but export no accepted pins. Killing and
joining the original process destroys its handle; a visible row or fresh reader
cannot reconstruct it, and a competing writer still contends on the immutable
original-lifetime key.

## Evidence and limits

Required native amd64 and arm64 acceptance counts the actual enrollment, private
claim and custody effects separately. Independently inspect PostgreSQL to compare
the original claim version/generation, full receipt, exact originating enrollment
and custody ACK versions, private permissions and unchanged restart exclusion.
Hold the enrollment reply to prove that a committed row cannot start the claim.
Fault controls distinguish missing/changed response, source death and storage ACK
uncertainty. Keep individual transport/process and full-suite deadlines unchanged.

The fixture CA is not SPIRE attestation. Loopback forwarding is test coordination,
not protected production receipt custody. This slice grants no role authority,
child ownership, launch permission, rollback resistance, cleanup or completion.
The protected issuer/role/operation path, exact child sender/handle gate and
combined gameplay admission remain #1346; the independent monotonic witness
remains #1341. Native serving adoption and retirement remain #1192.
