# 0055 — Compose issued original receipt custody

Status: Accepted

## Context

ADR 0054 proves real process-held issuance against native private-claim storage.
The original enrollment/receipt/custody matrix still uses fixture credentials.
Neither separate proof establishes the original acknowledged sequence with real
issued credentials or refuses a legitimately issued replacement process.

## Decision

Extend only the explicitly opted-in unpublished `issued-spire` acceptance
profile. Reuse its fixed controller privileges and exact child ownership. Each
of the nine existing custody cuts gets a fresh issuer, database and unprivileged
coordinator. Register the exact zone after the actual handoff and finish its
credential readiness before starting the original enrollment source.

Reuse the original custody assertions through an explicit claim callback and
peer environment. Only the original HTTP receipt GET may request the sole zone
claim. One coordinator protocol owner exchanges case/sequence/operation-bound
messages over private pipes. HTTP handlers use bounded internal channels; the
five-second bridge contains the existing three-second claim call. Forward the
complete actual receipt before applying the declared fault. Independent SQL
readback verifies the result and never manufactures the original response.

The source, successful reader and both refusal peers each fetch their own issued
credential in their actual plugin process. A constant, value-free log marker
records successful snapshot selection before native probes; it does not assert
the later listener validation or grant authority. Missing projected claims files
rule out fallback. Peers that finish startup use a distinct claims address and
are joined before port reuse. Same-correlation and replacement peers must show
their own snapshot marker followed by the specific enrollment refusal.

Keep the nine cuts, independent GET/claim/committed-row/accepted-pin counts and
the original HTTP, probe and stage deadlines. The existing SPIRE test separately
retains every TLS refusal and replay control. The wrapper requires both tests
and every named custody-cut verdict on both native architectures. Cooperative
cleanup acknowledgement follows native child joins and database retirement;
container disposal remains containment rather than child-join proof.

## Consequences

This establishes disposable native original-custody composition. Controller
forwarding remains diagnostic, and correlation labels do not attest original
process ownership. Protected forwarding, exact-child gameplay admission,
continuous launch exclusion and the independent rollback witness remain
#1346/#1341. No production activation, new GitHub App or shared credential
change follows. The existing #1192 retirement owner covers this experiment.
