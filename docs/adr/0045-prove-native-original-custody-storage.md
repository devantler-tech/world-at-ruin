# Prove native original-custody storage before launch composition

Status: Accepted for a default-off disposable experiment; production authority unproven.

## Problem

ADR 0044 retains the original enrollment and complete receipt through one
acknowledged private create per document. Its source tests use fixture storage.
They cannot establish Nakama's native create-only exclusion, actual PostgreSQL
permissions, originating acknowledgement versions or crash ordering. Issue #1342
closes that runtime assumption before authenticated launch work under #1340.

## Decision

Compose one individually enabled startup experiment only in the explicitly built
`war_native_trial` Nakama plugin. Both source and native disabled controls must
observe zero writes and zero control requests. The normal plugin and zone commands
retain no import of the custody writer or experiment.

Supply a complete diagnostic allocation and receipt fixture. This receipt is not
an originating native private claim acknowledgement and neither its owner nor
child correlation is an attested identity. Only the enrollment and custody
storage acknowledgements in this experiment originate from actual Nakama writes.
Do not compose admission, launch, completion, tombstones or cleanup.

Use the existing original-lifetime key and schema-1 owners/readers unchanged. A
copied owner shares its consumed attempt; independent processes contend on the
same create-only database key regardless of owner or replacement incarnation.
Each surviving originating enrollment may attempt custody once. Failed, partial,
canceled or lost replies never export detached diagnostic pins or permit retry.

The disposable supervisor coordinates bounded loopback stages. Storage fault
seams wrap the actual runtime calls: they cannot manufacture successful writes
or acknowledgements. Before-submit, committed-before-ACK, accepted-enrollment,
accepted-custody-before-export and delivered-pin stages are separately observable.
Kill and join the exact owned process at each crash cut. Inspect the database
independently of the source to count committed effects; never derive reader inputs
from those inspected rows.

Only complete acknowledged pins delivered by the source are retained in the
disposable supervisor. A fresh reader compares both private documents and exact
versions against these inputs without writing. Missing/changed rows, permission,
version, receipt or original binding produce a specific complete-reader refusal.
Even a successful read returns diagnostics only. Same-owner and changed-owner
writer restart must lose the existing enrollment create, not adopt its contents.
Observe create-only versions at both write boundaries. Database readback must
match the exact writer's owner/child pair, including after lost replies and death.
Change each lifetime field independently in both documents; keep changed custody
receipts internally consistent so refusal proves comparison against original pins.
Disabled controls use a reachable counting endpoint with a positive request check.

## Ordering and uncertainty

| Cut | Possible committed effects | Diagnostic pins delivered |
| --- | --- | --- |
| Before enrollment submit | None | None |
| Enrollment commit before ACK, including lost/canceled reply | Enrollment | None |
| Accepted enrollment before custody | Enrollment | None |
| Before custody submit | Enrollment | None |
| Custody commit before ACK, including lost/canceled reply | Both documents | None |
| Accepted custody before export | Both documents | None |
| Independently accepted pin delivery, then source death | Both documents | Complete originating storage pins |

Visible records after death cannot restore the originating handle. A crash before
the first enrollment submission leaves no storage exclusion; a fresh writer can
perform its first create. That is a persistence boundary, not permission to
relaunch a production lifetime. Production launch needs independent protected
exclusion before the original child starts. A committed enrollment continues to
exclude replacement even when its source never received or exported an ACK.

## Evidence and remaining gates

Required native acceptance on amd64 and arm64 exercises the packaged plugin
against fresh PostgreSQL, simultaneous processes, actual reply loss/cancellation,
exact process kill/join, independently retained pins and changed-document readers.
Unit tests establish input/refusal behavior and bounded local control transport;
they are not native persistence proof. The mandatory scenario inventory fails on
missing tests and preserves every existing deadline.

SPIRE issuance, separately attested launcher/custodian/child roles, original
private-claim-to-custody composition, exclusive child ownership, independently
protected ACK custody and a monotonic witness remain #1340/#1341/#1336 gates.
Production session completion stays #1318/#567. Readback, create-only rows,
fixture process death and matching digests do not establish rollback resistance
or irreversible termination. No service, shared credential or published native
serving artifact is activated here. Retire this entrypoint through #1192.
