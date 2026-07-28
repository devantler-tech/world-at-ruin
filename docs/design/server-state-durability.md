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

These are the rules `server/nakamalease/store.go` already enforces. They are stated here once so
that later records inherit them rather than each deriving its own.

### Every record is private and server-owned

A record is written with no client owner and with both permissions closed, so Nakama attributes it
to the system account and no client API can read or write it. The read path re-verifies all of it —
collection, key, owner, non-empty version, and both permission bits — and fails closed rather than
trusting the object it was handed.

The reason is that Nakama's storage is also a *client-facing* API. A record that is merely
undocumented is still reachable; a record written with closed permissions is not.

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

### Every document declares its schema, and readers accept a range

Each document carries an explicit schema number. The writer writes the current one; the reader
accepts the current one and the legacy range below it, and refuses a document that claims an old
schema while carrying fields that did not exist at that schema.

That last clause is the part worth copying. Accepting a version number is not the same as accepting
the document: a forged or half-migrated document that claims to be old but carries new fields is
refused rather than partially understood.

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

## What survives a failure

| Failure | Session-scoped | Player-owned |
|---|---|---|
| **Zone process loss** | survives — the record lives in Nakama, not in the zone process | survives |
| **Nakama process restart** | survives — records are in Postgres behind Nakama | survives |
| **Postgres failover** | bounded by the platform's replication guarantee | bounded by the platform's replication guarantee |

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
audit trail (#475) rather than dropped. Where re-applying is impossible, the loss is surfaced to the
player rather than silently absorbed.

Session-scoped state carries no such promise, and deliberately so: a rolled-back lease costs a
reconnect, which is a cost a player can see and recover from without help.

## What is deliberately not durable

Naming this is as load-bearing as naming what is, because everything on this list is state nobody
needs to write a guard for.

- **Simulation state between snapshots** — positions, velocities, telegraph timers. Rebuilt from the
  authoritative tick on reconnect.
- **Session tokens** — reissued by authentication; a lost one costs a re-authenticate.
- **Presence and connection state** — who is online right now is derived, never stored.
- **Anything recomputable from a durable record** — a derived view is not state. Storing it creates
  a second source of truth that can disagree with the first.

## Enforcement map

| Promise | Runtime owner | Permanent guard |
|---|---|---|
| Records are private and server-owned | `nakamalease.Store` | `TestCreatePersistsPrivateVersionedLeaseByHashedKey`, `TestCreateIgnoresAClientOwnedObjectAtTheDerivedKey`, `TestLoadRejectsMalformedOrPublicStoredObjects` |
| No write is blind — every write is a compare-and-swap | `nakamalease.Store` | `TestReplaceUsesObservedVersionAndStaleRecordCannotOverwrite`, `TestConcurrentReplaceLeavesExactlyOneCurrentAttempt` |
| Documents declare a schema and readers accept a range | `nakamalease` document decode | `TestLoadKeepsSchemaOneLeaseReadableAsNotReleasing` |
| Unknown fields and trailing content are refused | `nakamalease` document decode | `TestLoadRejectsMalformedOrPublicStoredObjects` |
| Upstream storage errors do not cross the boundary | `nakamalease` error sanitization | `TestStorageFailuresAreSanitized`, `TestStorageContextCancellationIsPreserved` |
| A replay identified by its own content applies once | `nakamalease.Store` | `TestCreateReplaysTheSameAttemptWithoutAnotherWrite`, `TestClaimReplayKeepsTheOriginalClaimWithoutWriting` |
| An acknowledged player-owned mutation is never lost | player-owned record owners | not yet built — #473, #474, #475 |
| A replay **not** identified by its own content applies once | player-owned record owners | not yet built — #475 |

The last two rows are obligations on work that does not exist yet. They are listed so that a record
added later is measured against them rather than shipping without a guard and being noticed
afterwards.
