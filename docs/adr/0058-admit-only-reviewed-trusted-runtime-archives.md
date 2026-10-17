# Admit only reviewed trusted-runtime archives

Status: accepted for cold builds; archive reuse and publication are not adopted.

APT authentication proves that downloaded bytes belong to signed repository
metadata, while an installed-package lock proves the final dpkg identities.
Neither contract rejects a different authenticated archive closure before its
maintainer scripts execute. The optional cold report records that closure, but a
report cannot authorize its own future execution.

Derive a canonical archive lock from one complete, source-bound hosted cold
report. The generator requires the report's image boundary, installed package
set, APT inputs, transaction, authenticated target joins and recipe identities.
It binds the result to the runtime manifest, snapshot, direct arguments and the
exact reviewed base and installed-package lock bytes. Each entry fixes the
package tuple, basename, requested URI, size, SHA-256 and complete nonempty set
of trusted Packages/InRelease origins. The lock separately fixes the complete
authenticated target census, including targets that supplied no archive, and
requires every archive origin to join that reviewed census. The source report
digest and resulting image ID remain review evidence in the lock.

Every cold build now downloads into its invocation-private cache, validates the
archives and authenticated origins, and compares the complete observation with
the reviewed lock before package scripts can run. The same arguments and cache
then execute with `--no-download`; diagnostic selection only controls whether a
report is published. Missing, extra, duplicated, truncated, linked, corrupted or
drifted evidence fails closed.

An intentional snapshot or pin change can make the old archive lock impossible
to satisfy before a replacement report exists. A manually dispatched,
read-only maintenance workflow therefore permits one explicit evidence-only
proposal mode. It requires complete inventory publication and bypasses only the
old archive comparison. APT authentication, the complete trusted-origin join,
archive bounds and hashes, final package equality and the same-cache offline
install remain mandatory. The disposable image is removed after the report and
generated proposal are extracted. The proposal has no admission authority; a
reviewed replacement lock and a successful ordinary locked build are still
required.

This decision adds no archive store, producer identity, publication path,
credential or warm-executor admission. A future reuse design must independently
define custody and prove that reused bytes satisfy this same boundary. Those
decisions remain with #1397.
