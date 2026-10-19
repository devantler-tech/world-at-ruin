# Witness zone custody in a forward-only record

Status: accepted for the witness record and its source client (#1442). The
DynamoDB adapter and the native trial (#1443) remain open.

## Context

ADR 0044 retains original zone custody through private, create-only Nakama
documents. A restore of Nakama, its database or the cluster brings those
documents back to an earlier state, and nothing inside that recovery domain can
tell the restored history from the original one. #1341 selected an independent
witness for that question: one record per original zone lifetime, kept outside
the platform's recovery domain and advanced only by conditional writes.

## Decision

The witness record is keyed by the unchanged ADR 0044 lifetime key. Its stage
moves only `enrolled` → `custody` → `tombstone`, and it carries exactly the pins
of the stages reached: the enrollment pin from `enrolled` onward, the custody pin
from `custody` onward and the tombstone pin at `tombstone`. A record follows
another only when it is the single next stage of the same lifetime with every
earlier pin unchanged. There is no delete, overwrite, expiry or downgrade.

The schema-1 reader is permanent and strict. It refuses missing, duplicate,
null, unknown and trailing fields, a pin for an unreached stage and a stage that
disagrees with its fields. The shipped documents are permanent fixtures under
the server durability guard.

The client works over an abstract strongly consistent table. It is default-off
and requires a table identity pinned at deployment; it reads the table's actual
identity before every read and write and refuses a mismatch, because a restored
or recreated table has a different identity even under the same name. An
enrollment is created only when no record exists; every later stage is written
only when the stored record equals the exact previous record. A refused
condition is final. A lost or late reply is resolved by exactly one strongly
consistent re-read, detached from the caller's cancellation and bounded: only
the exact intended record is the acknowledgement, and anything else leaves
authority unknown. Nothing is retried.

Comparison returns one of seven verdicts: verified, witness ahead (the expected
record comes from a rolled-back history), witness behind (the expected stage was
never witnessed), absent, conflicting, table replaced or unavailable. Only
verified is positive, and even that grants no launch, claim or completion
authority by itself. Absence never means a fresh lifetime.

## Evidence

The package tests drive a local compare-and-set fake through the forward chain,
every refusal control with the stored record unchanged, a committed write whose
reply is lost or canceled, an uncommitted write whose reply is lost, a competing
writer's record, a replaced or unreadable table and each comparison verdict. An
import control keeps the package free of any network, cloud SDK or storage
client.

## Not covered

A local fake cannot prove the service's durability, its conditional-write
atomicity, its strong consistency or that a restore creates a new table
identity. The DynamoDB adapter and the native trial on a real disposable table
(#1443) carry that proof. Nothing composes the client, so no launch, custody or
completion path depends on it yet (#1336, #1340, #1318).
