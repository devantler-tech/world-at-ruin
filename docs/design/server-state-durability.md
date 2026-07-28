# Server-held state — durability contract

[`save-data.md`](save-data.md) states the contract for state held on the **player's own disk**. This states the
contract for state held on the **server**: what a record must guarantee, what survives a failure,
and what a player is owed when something is lost.

The two are separate documents because they fail differently. A client save is lost with one
machine and is protected by rules the player's own build enforces. A server record is shared,
concurrent, and outlives any single process, so its guarantees are about *ordering* and
*attribution* rather than about what one client will agree to load.

## Scope

Server-held state is any record the server writes and treats as authoritative. Today that is the
handoff leases in `server/nakamalease`. Phase 4 (#11) adds player-owned records — characters,
inventory, progression — and every one of them answers the questions below.

A record is in scope the moment the server writes it. A value the server merely reads from a client,
or recomputes each tick, is not server-held state and carries none of these obligations.

## Record classes

Durability is not one promise. It is three, and conflating them is what makes a system either
unaffordable or dishonest.

| Class | Lifetime | What loss costs a player | Present example |
|---|---|---|---|
| **Session-scoped** | one allocation or connection | a reconnect | handoff leases (`nakamalease`) |
| **Player-owned** | forever | **unrecoverable** — no wipe exists | characters (#473), inventory (#474) |
| **World-owned** | forever, shared | affects every player at once | none yet |

The classes rank strictly: a player-owned record may never be given a session-scoped guarantee
because it happens to be cheaper. Under the no-resets law there is no wipe to recover with, so a
lost player-owned record is lost permanently and a duplicated one is duplicated permanently.

## The rules

These rules bind every server-held record. They are **not** all met today. Some are enforced now by
the lease store in `server/nakamalease`; others — cross-record atomicity, rollout ordering,
cancellation reconciliation, player-owned recovery — are obligations on records that do not exist
yet, and one is a known gap against running code. **The enforcement map at the end says which is
which, rule by rule, and is the authority whenever this section and the code disagree.**

Each rule states the invariant first. Where an implementation currently enforces one, that is named
as evidence of how — never as the rule itself, because the storage engine is replaceable and the
invariant is not.

### Server-authoritative state is unreadable and unwritable by clients

A client may never read or write a server-held record directly. Its only access is through server
code that decides what it is allowed to see and change.

The reason is that a store's client API does not stop existing because we chose not to document a
record in it. Obscurity is not a permission boundary: if the transport can address the record at
all, the guarantee has to come from an access rule the store enforces, not from nobody having
looked.

*How the lease store meets it today:* the record is written with no client owner and both permission
bits closed, so Nakama attributes it to the system account and no client API can reach it, and the
read path re-verifies collection, key, owner, version and both permission bits before trusting the
object it was handed.

### Every write is a compare-and-swap

A writer presents the exact version it observed. A write whose version no longer matches is
rejected by storage and surfaces as a conflict, never as a silent overwrite. Creation presents the
create-if-absent version, so two racing creators cannot both believe they created the record.

There is no blind write. This is the same guarantee the client vault reaches by a different route
(#386), and for the same reason: a lock orders writers, but only a compare-and-swap can tell a
writer that the document it read has moved on since.

A conflict is a normal outcome, not an error to retry blindly. The caller re-reads, re-decides
against the current document, and writes again — or gives up. Retrying with the same stale version
can only fail again.

### A logical mutation spanning records is atomic, or states its recovery invariant

Compare-and-swap is **per record**. It prevents a lost update; it does not make two writes one act.
A mutation that credits an inventory and records its audit entry is two compare-and-swaps, and a
process that dies between them leaves the credit applied and unrecorded — or recorded and
unapplied.

So a logical mutation that spans records either commits in **one storage transaction**, or it
states the invariant that makes a partial application recoverable: which write goes first, how a
reader recognises the half-applied state, and what completes it. "Both writes usually succeed" is
not an invariant.

This is why #475 is a durability obligation rather than bookkeeping — the audit entry is what makes
the partial state recoverable at all.

### Every document declares its schema, and readers accept a range

Each document carries an explicit schema number. The writer writes the current one; the reader
accepts the current one and the legacy range below it, and refuses a document that claims an old
schema while carrying a newer field.

Accepting a version number is not the same as accepting the document: a forged or half-migrated
document that claims to be old but carries new fields is refused rather than partially understood.

**That refusal is only as good as the reader's ability to see a field is present**, and a
zero-valued field is where it fails. A boolean decoded into a plain `bool` reads `false` whether it
was absent or explicitly written as `false`, so a legacy document carrying `"staging": false` is
accepted today even though `staging` postdates that schema. A newer field must therefore be decoded
**presence-aware** — a pointer or an explicit presence flag — not by testing its value for truth.
The same package already does this correctly for `claimed_at_nanos`, which is a pointer precisely so
that absent and zero are distinguishable; the two booleans beside it are the gap, not the pattern.

### Read support ships and bakes before the writer that needs it

A reader that accepts schema N is not permission to write schema N. The two are separate releases:
extend every reader first, let that reach every running revision, and only then activate the writer.

The reason is that the reverse strands data. If a writer activates first and the deployment is
rolled back — or simply while old and new revisions overlap, which is the normal state during any
rollout — the older reader meets a document it strictly refuses, and every record already upgraded
becomes unreadable. Strict decoding makes this worse rather than better, which is the trade it is
worth.

This is the same expand-then-contract discipline `save-data.md` already requires of client save
data, and it applies here for the same reason: the writer is the irreversible step.

### A stored document is decoded strictly

Decoding rejects unknown fields and trailing content. An unexpected field is a refusal, not
something to skip past.

This is the server-side form of the closed-format law the character recipe already follows: a
format that silently ignores what it does not understand cannot be reasoned about later, because
no reader can tell an old document from a corrupted one.

### A replay is recognised by identity, and content identity does not generalise

A retry across a dropped connection is normal, so every operation must be safe to deliver twice.
The leases reach that by comparing the record's **own content**: a replayed create for the same
attempt returns the existing record instead of writing again.

That technique works only where a record is identified by what it contains. It does not extend to a
mutation like "grant three gold", because two legitimate identical grants are indistinguishable
from one grant delivered twice — there is no field to compare. Such a mutation must carry an
identity supplied by its **caller**, which is the obligation #475 states.

Reading the lease implementation as general-purpose idempotency is the trap here. It is a correct
solution to the narrower problem, and copying it onto player state would silently collapse two
legitimate mutations into one.

### A storage failure never crosses the boundary intact

Upstream storage errors collapse to this package's own error before they reach a caller, except for
cancellation, which is preserved because a caller must be able to distinguish "we gave up" from
"storage refused". The upstream message is deliberately dropped.

The reason is the same one that keeps `nakamaauth` from reflecting a rejected bearer token into a
log: an error string from a system holding player data is an exfiltration surface, and the stable
classification is the only part a caller should branch on anyway.

**A cancellation is an ambiguous outcome, not a failed one.** Preserving it tells the caller that
*this call* stopped waiting — never that storage did not apply the write. A deadline that expires
after the write commits but before the response arrives is indistinguishable, at the caller, from
one that expires before it commits.

So a caller must never read a cancellation as proof that nothing happened. Where the mutation
carries player value, the caller reconciles it by its stable identity — re-read the record, or
resolve the idempotency key (#475) — before reporting an outcome or issuing a different mutation.
Treating cancellation as failure is how a player is told a reward did not arrive after it already
did.

## What survives a failure

| Failure | Session-scoped | Player-owned | World-owned |
|---|---|---|---|
| **Zone process loss** | survives — the record lives in Nakama, not in the zone process | survives | survives |
| **Nakama process restart** | survives — records are in Postgres behind Nakama | survives | survives |
| **Postgres failover** | bounded by the platform's replication guarantee | bounded by the platform's replication guarantee | bounded by the platform's replication guarantee |

No world-owned record exists yet. The column is stated rather than left blank because this contract
says every later server-held record inherits it, and a class that affects every player at once must
not be the one that arrives without a guarantee. A world-owned record additionally may **not** rely
on the rollback path below: re-applying from an audit trail is a per-player remedy, and a
world-owned value cannot be reconstructed player by player. The first such record needs its own
recovery invariant stated before it ships.

Two consequences of the first row are worth stating outright, because they are the ones that get
assumed wrongly:

- A record is durable only **once the write is acknowledged**. Work that a zone process has done
  but not yet written is not server-held state, and it dies with the process. A mutation that
  matters must be written before it is shown to the player as done.
- Surviving a crash is not the same as being *correct* after one. A process that dies between
  applying a mutation and acknowledging it leaves a client that will retry, which is why the
  idempotency contract (#475) is a durability obligation and not an optimisation.

**Not yet established:** the Postgres failover bound. The platform runs CNPG, so a bound exists, but
this project has not measured or stated it, and a number nobody has verified would be worse than an
admitted gap. Establishing it is the first thing any player-owned record needs, because failover is
the only case in the table where a player can lose a mutation that was genuinely acknowledged.

## What a rollback costs a player

A rollback is the one case where the no-resets law and operational reality meet, so the answer must
be a bound rather than a case-by-case judgement.

The bound this project commits to: **a player never loses something they were told they had.** If a
rollback would take back an acknowledged player-owned mutation, the mutation is re-applied from the
audit trail (#475).

Where re-applying the original mutation is impossible, the obligation is to **restore the value by
another route** — a compensating grant carrying the same worth — not merely to tell the player it
is gone. Telling them is required as well, and it is not the remedy.

Surfacing a loss is not an alternative to remedying it. Under the no-resets law there is no wipe to
even out an unlucky player against a lucky one, so an acknowledged mutation left unrestored is a
permanent, uncompensated loss to one person. Notification is owed on top of the remedy, never
instead of it.

Session-scoped state carries no such promise, and deliberately so: a rolled-back lease costs a
reconnect, which is a cost a player can see and recover from without help.

## What is deliberately not durable

Naming this is as load-bearing as naming what is, because everything on this list is state nobody
needs to write a guard for.

- **Simulation state** — positions, velocities, active casts, telegraph timers. These live in the
  zone process's memory (`server/sim`), and the replication snapshot built from them is a read-only
  per-observer payload that is never persisted. A client reconnecting to a **live** zone is resynced
  from that zone's current tick; if the **zone process itself is lost**, this state is **gone**, not
  rebuilt. Players resume from whatever the surviving player-owned records say, and an in-flight
  cast or telegraph simply does not survive. Making it survivable would need a durable checkpoint
  plus input replay, which this project has deliberately not built.
- **Session tokens** — reissued by authentication; a lost one costs a re-authenticate.
- **Presence and connection state** — who is online right now is derived, never stored.
- **Anything recomputable from a durable record** — a derived view is not state. Storing it creates
  a second source of truth that can disagree with the first.

## Enforcement map

| Promise | Runtime owner | Permanent guard |
|---|---|---|
| Server-authoritative state is unreadable and unwritable by clients | `nakamalease.Store` | `TestCreatePersistsPrivateVersionedLeaseByHashedKey`, `TestCreateIgnoresAClientOwnedObjectAtTheDerivedKey`, `TestLoadRejectsMalformedOrPublicStoredObjects` |
| No write is blind — every write is a compare-and-swap | `nakamalease.Store` | `TestReplaceUsesObservedVersionAndStaleRecordCannotOverwrite`, `TestConcurrentReplaceLeavesExactlyOneCurrentAttempt` |
| Documents declare a schema and readers accept a range | `nakamalease` document decode | `TestLoadKeepsSchemaOneLeaseReadableAsNotReleasing` |
| Unknown fields and trailing content are refused | `nakamalease` document decode | `TestLoadRejectsMalformedOrPublicStoredObjects` |
| A newer field on a legacy schema is refused **by presence, not by truth** | `nakamalease` document decode | **gap (#491)** — `staging`/`releasing` are plain booleans, so an explicit `false` is accepted; needs presence-aware decoding and a zero-value case |
| Read support ships and bakes before its writer activates | every record owner | not yet built — no server-side equivalent of the client staging guard |
| A logical mutation spanning records is atomic or recoverable | player-owned record owners | not yet built — #474, #475 |
| A cancellation is reconciled, never read as failure | every caller | not yet built — #475 supplies the stable identity |
| Upstream storage errors do not cross the boundary | `nakamalease` error sanitization | `TestStorageFailuresAreSanitized`, `TestStorageContextCancellationIsPreserved` |
| A replay identified by its own content applies once | `nakamalease.Store` | `TestCreateReplaysTheSameAttemptWithoutAnotherWrite`, `TestClaimReplayKeepsTheOriginalClaimWithoutWriting` |
| An acknowledged player-owned mutation is never lost | player-owned record owners | not yet built — #473, #474, #475 |
| A replay **not** identified by its own content applies once | player-owned record owners | not yet built — #475 |
| A world-owned record states its own recovery invariant | first world-owned record owner | not yet built — no such record exists |

Rows marked *not yet built* are obligations on work that does not exist. They are listed so a record
added later is measured against them rather than shipping without a guard and being noticed
afterwards.

The row marked **gap** is different, and worse: it is a promise this document makes that the running
code does not currently keep. It is recorded here rather than quietly softened, because the honest
options were to weaken the rule or to fix the decoder, and weakening a rule to match an
implementation is how a contract stops meaning anything.
