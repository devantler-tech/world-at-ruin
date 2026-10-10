# 0039: Reserve one acknowledged recovery owner without restoring authority

- Status: Accepted for the explicitly enabled native experiment
- Issue: #1323 (delivery slice of #1315)

## Context

An acknowledged drain handoff preserves the complete frozen inventory. Its
StorageRead-only observation does not exclude competing fresh recoverers. A
recovery process must reserve the generation before a later barrier protocol
can begin. Private storage permissions do not authenticate runtime writers.

## Decision

An explicitly enabled owner copies independently retained root binding and
handoff version, plus a bounded recoverer incarnation ID. Its only reservation
attempt first validates both original private documents through ReadHandoff.
One shared 30-second deadline spans that read and one private create-only write
to `world_at_ruin_allocator_recovery_owners`. The key depends only on generation
ID, so different source incarnations, handoff versions and recoverer IDs cannot
create multiple rows for that generation.

Schema 1 retains the recoverer ID, exact acknowledged handoff version and the
entire strict handoff document. Only a complete matching storage acknowledgment
and a final context check produce an opaque reservation. Copies of the owner
share its single attempt. Returned observations are detached diagnostics. The
permanent strict reader never recreates a reservation or writer.

There is no retry, root refresh, expiry, takeover, deletion or resume
operation. A committed write with a lost reply permanently excludes competing
owners without granting a usable reservation. This sacrifices liveness to keep
uncertainty quarantined; production recovery needs a separate approved protocol.

## Crash and acknowledgment cuts

- Missing, changed or incomplete original documents refuse before owner write.
- A failed read consumes the local attempt; it cannot refresh expectations.
- Submission with a lost, partial, malformed or canceled reply exports nothing.
- A crash after storage commit leaves exclusion, whether or not its reply arrived.
- A crash after acknowledgment but before independent export also leaves no
  independently usable reservation. The same ID cannot resume from the row.
- A complete acknowledgment produces an experimental local reservation only.
  Later diagnostic readback cannot repair any preceding unknown outcome.

## Consequences and remaining gates

The native-only `WAR_DURABLE_RECOVERY_OWNER_PROBE_ENABLED` flag defaults off.
Ordinary plugin artifacts exclude the probe, and retirement is tracked by #1316.
The supervisor retains original handoff pins while the source dies. Surviving
supervisor custody is sufficient only for this experiment; authenticated durable
production pin delivery and exclusive mutation authority remain unproven.

Real acceptance races fresh Nakama processes, joins owner crash and lost-reply
cuts, and independently checks the one private row. An original held Kubernetes
allocation must still succeed with zero barriers: reservation is exclusion, not
fencing. Independent barriers, mixed outcomes, complete proof publication,
serving/retained-reader adoption and quarantine release remain #1315/#793 work.
