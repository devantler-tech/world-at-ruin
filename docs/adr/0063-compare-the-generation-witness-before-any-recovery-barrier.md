# Compare the generation witness before any recovery barrier

Status: accepted for source composition with a local fake (#1602, part of #1444).
The native trial on a real table (#1445) remains open, and nothing in a shipped
artifact composes the witness.

## Context

ADR 0060 records the witness client and #1398 decided that allocator generations
use it as the independent custody of recovery pins. #1444 made each stage
persist-before-ACK, so the witness holds `registered`, `drained`, `handoff`,
`owner`, `recovered` and `published` before each acknowledgement is exported.
Nothing read that record before a recovery touched a game server, so a restored
Nakama was only caught when a later conditional write happened to be refused.

## Decision

A composed recovery compares twice, and both comparisons accept only `verified`.
Every other verdict, including one the recoverer has never heard of, keeps the
quarantine.

- **`Reserve`** compares the retained `handoff` record before it writes the owner
  row. A rolled-back history therefore leaves no permanent exclusion row in the
  restored Nakama, and the attempt ends.
- **`Fence`** spends the reservation and then calls `VerifyWitness` before its
  first game-server request. That re-reads the handoff, journal and owner row from
  Nakama, derives the `owner` record from them and the retained pins, and compares
  it. A refusal performs zero barrier I/O and, the inventory being spent, never
  repeats.

`ReadRecoveryPublication` can also compare a retained `published` record, after
re-deriving every pin the proof and owner row acknowledged except the registration
pin, whose binding is no longer known there. A match is read-only verification. It
returns the same diagnostics as before: no reservation, no barrier retry and no
release of quarantine.

The admission package declares the reader interface and the one positive verdict,
so admission and the commit authority still never import the witness client. The
generation writer keeps its write-only interface.

Without a witness composed, none of this runs: no comparison, no extra Nakama read
and unchanged behaviour.

## Evidence

The tests use the real witness client over a local compare-and-set table, with a
counted Agones API.

| #1398 failure matrix row | Source test | Result |
| --- | --- | --- |
| Restore drops a registration | `TestRecoveryKeepsQuarantineWhenARestoreDropsARegistration` | conflicting; no row, no witness write, no target request |
| Restore drops the handoff | `TestRecoveryKeepsQuarantineWhenARestoreDropsTheHandoff` | witness ahead of the drain; no row, no target request |
| Restore drops the owner row | `TestWitnessRefusesTheSecondRecovererAfterARestoreDropsTheOwnerRow` | witness ahead; no row, no target request |
| Restore drops the proof | `TestRecoveryKeepsQuarantineWhenARestoreDropsTheProof` | verification refused; a fresh recoverer is refused with no target request |
| History or witness changes after `Reserve`, every non-verified verdict | `TestFenceComparesBeforeAnyBarrier` | zero barriers, record unmoved, no retry |
| Stale or foreign retained pins | `TestCompletedChainAllowsReadOnlyVerificationOnly` | refused |
| Partial publication | `TestPartialPublicationIsNotCompleteEvidence` | witness behind; not complete evidence |
| Custodian dies before or after its `owner` write | `TestCustodianDeathAtOwnerKeepsTheQuarantine` | recoverer holds nothing; next recoverer refused |
| Lost custodian reply | the existing witness refusal tests at each stage | settled only by the exact re-read |

## Not covered

A local fake shows the refusal boundaries and nothing about the service. Only #1445
can show:

- that a real table's conditional writes and consistent reads behave as the fake
  does, and that a restored table gets a new identity;
- the death of a real custodian process, as opposed to a lost reply at a chosen
  point, and the exact re-read against a real service;
- that the distinct allocator custodian principal is enforced, so the changed
  principal row of the matrix has no source test here;
- a real Nakama restore, as opposed to deleted rows and a self-consistent smaller
  history.

The row where Nakama and the witness are both rolled back stays outside the proof,
as #1341 and #1398 record. Recoverers need distinct owner IDs, because a lost reply's
re-read cannot separate two identical owner records. The comparison and the
conditional write are separate calls, so a witness change between them is caught by
the write, not by the comparison. This ADR grants no production authority.
