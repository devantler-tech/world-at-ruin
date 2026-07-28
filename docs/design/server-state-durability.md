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

These rules bind every server-held record. They are **not** all met today, and they fall short in
three different ways. Some are enforced now by the lease store in `server/nakamalease`. Several are
**gaps in running code** — they bind that same lease store, which does not currently keep them. A
few are kept but **unguarded**, enforced in code with no test pinning them. The rest are obligations
on records that do not exist yet, where nothing is broken because nothing is there. **The enforcement map at the end says which is which, rule by rule, and is the authority
whenever this section and the code disagree.**

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

**Routing access through server code is not the same as authorising it.** A server holding
storage credentials on a player's behalf is a deputy, and a deputy that accepts the *subject* of an
operation from its caller can be confused into acting on the wrong player: an RPC taking a
client-supplied user id satisfies every word of the rule above while reading someone else's
character. So the **ownership component** of a player-owned record's key is **derived from the
verified identity** the session resolves to, never from a parameter the client supplies.

The rule binds the *owner*, not the whole key. A player legitimately has several records — characters,
inventory objects, loadouts — so a caller may well select *which* record by a client-supplied
identifier; what it may never do is say *whose*. A selector is therefore allowed, and the server
resolves it **within** the authenticated owner's namespace and verifies the selected record belongs
to that owner. Requiring the entire key to come from identity would either make those APIs
impossible or force unrelated state into one contention-heavy document.

Any operation that legitimately crosses players — moderation, support tooling — is a separately
authorised path, and says so.

**Player-to-player transfer is not on that list, and must not be read onto it.** The settled economy
has bound loot and **no trading or auction house**, precisely because a transfer path is what turns
a duplicate into durable value and makes RMT and botting worth doing. So "separately authorised" is
about operations *on* a player's records by the operator, never about moving value *between*
players. A future inventory implementation that reads this section as permission to build transfers
behind an authorisation check has defeated the guard at the exact point ownership is defined.

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

**Every shipped schema is ledgered, and stays readable forever.** A "range" the reader happens to
accept today is not a promise, because a later change can drop the bottom of that range and every
test still passes — nothing pins it. Meanwhile a record nobody has touched in months is still
sitting at that schema, and dropping support strands it. So each shipped schema is appended to a
permanent ledger and pinned by golden documents that later readers must continue to load, exactly
as `shipped_vault_versions.txt` and its goldens do for client save data. Removing a schema from the
readable set is then a visible, deliberate act rather than a silent consequence of a refactor.

**One golden per schema is not enough when a schema permits several shapes.** A schema is a grammar,
not a single document: a schema-2 lease is stored as staging, finalized, claimed or releasing, and a
golden covering one of those keeps passing while a reader accidentally rejects another shape that is
still sitting in production. The ledger therefore pins **every valid discriminated or optional shape
a schema admits**, not one representative per version number.

**That refusal is only as good as the reader's ability to see a field is present**, and a
zero-valued field is where it fails. A boolean decoded into a plain `bool` reads `false` whether it
was absent or explicitly written as `false`, so a legacy document carrying `"staging": false` is
accepted today even though `staging` postdates that schema. A newer field must therefore be decoded
**presence-aware** — a pointer or an explicit presence flag — not by testing its value for truth.
The same package already does this **partly** for `claimed_at_nanos`, which is a pointer precisely so
that absent and zero are distinguishable; the two booleans beside it are the gap, not the pattern.

**A pointer is not a complete presence check, so do not copy it as one.** `*int64` separates absent
from numeric zero, but an explicit JSON `null` decodes to `nil` as well — absence and a present-null
are indistinguishable. That is harmless where the field is optional and both mean "unset", and it is
not harmless for a **required** field, which can then be omitted or nulled without detection. A
required field whose zero value or null is legal therefore needs a real presence bit or a custom
unmarshaller, not a pointer.

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

**"Baked" means the rollback target can read it, not that the running fleet can.** Reach across
currently-running revisions is the wrong criterion: a rollback does not deploy the revisions that
happen to be running, it deploys a **retained artifact**, and that artifact was built before the
reader was extended. Rolling back to it after the writer activated strands every upgraded record,
and strict decoding guarantees it strands them loudly rather than silently.

So the bake condition is that **the retained rollback target itself carries the expanded reader**,
registered and tested as the standing rollback candidate, before the writer is activated.

### A stored document is decoded strictly

Decoding rejects unknown fields and trailing content. An unexpected field is a refusal, not
something to skip past.

This is the server-side form of the closed-format law the character recipe already follows: a
format that silently ignores what it does not understand cannot be reasoned about later, because
no reader can tell an old document from a corrupted one.

**"Strict" must include duplicate members, which the obvious decoder does not reject.** Go's
`json.Decoder` with `DisallowUnknownFields` rejects an *unknown* field and still accepts a document
repeating a **known** one — `{"schema":1,"schema":2}` decodes without error and silently keeps `2`
(verified). So a corrupted or half-migrated document can carry two balances and the parser picks
one, which is precisely the "cannot tell an old document from a corrupted one" failure this rule
exists to prevent. Rejecting a repeated member needs an explicit token-level check; it does not come
free with the standard decoder.

**A refusal latches the record read-only; it never leaves it writable.** Refusing to *read* a
document is only half an answer, and the dangerous half is what happens next: a caller that gets
"cannot read this" and treats it as "nothing is stored here" will happily write a fresh default
record over a player's earned state. That is the no-resets law broken by a reader, not a writer.

So a refusal must block create, update and delete at that key, and the stored bytes must be
preserved untouched, until a reader that understands the document runs or a deliberate recovery
handles it.

**A process-local latch does not achieve that here, and copying the client's one would be a
mistake.** `CharacterStore` latches a refusal in memory and that is sufficient *because it is the
only writer on one machine*. Server requests move between replicas and replicas restart, so the
next mutation for that key can land on an instance that never saw the refusal, holds no latch, and
proceeds. The safeguard would then be defeated by ordinary routing rather than by anything going
wrong.

The quarantine therefore has to be **shared and durable** — a marker at the key itself that any
replica observes — or, equivalently, every mutation must be gated on a **successful strict read of
the current document plus a version match**, so that a document no reader can decode is one no
writer can replace. The second form is usually cheaper, because compare-and-swap already carries
the version; what it adds is that a *failed decode* must block the write rather than be treated as
"no current document".

**Presence-awareness is required for the fields a schema *needs*, not only the ones it forbids.**
Rejecting a newer field on an older schema is one direction; the other is a document that omits a
field its own schema requires. Decoded into a plain value, a missing balance, count or flag arrives
as an implicit zero, so a truncated or half-written document is accepted as a valid one that just
happens to say the player has nothing. Every accepted schema therefore declares its **exact
required-field set**, and any required field whose zero value is legal is decoded presence-aware.

### A replay is recognised by identity, and content identity does not generalise

A retry across a dropped connection is normal, so every operation must be safe to deliver twice.
The leases reach that by comparing the record's **own content**: a replayed create for the same
attempt returns the existing record instead of writing again.

That technique works only where a record is identified by what it contains. It does not extend to a
mutation like "grant three gold", because two legitimate identical grants are indistinguishable
from one grant delivered twice — there is no field to compare. Such a mutation must carry an
identity supplied by its **caller**, which is the obligation #475 states.

**A caller-supplied key is only safe if it is bound to the mutation it names.** A bare key answers
"have I seen this token before", and answering that alone is how a reused token silently returns the
first result for a second, different mutation — or suppresses a legitimate grant. So a key is
durably stored **with the authenticated subject and the normalized mutation it was issued for**, and
the same key presented for a different subject, operation, or payload is **rejected as a conflict**
rather than served from the earlier result. Retry gets the original outcome; collision gets an
error. Silently treating a collision as a retry is the failure this rule exists to prevent, and it
loses player value in the direction no wipe can undo.

**Binding catches a *mismatched* reuse; it cannot catch an identical one.** Two legitimate grants of
the same reward to the same player have the same subject, operation and payload, so every binding
matches and the second is classified as a retry and silently dropped — the same loss, reached from
the other side. A key therefore has to be unique per **logical mutation**, not per mutation
*shape*: derive it from a stable source-event identity (the thing that caused the grant), or issue
it from a namespace where reuse is structurally impossible. A key a caller can pick freely and
reuse in good faith is not an idempotency key.

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

**Every error returned after a write is dispatched is an indeterminate outcome, not a failed one.**
Once the request is on the wire, no error the caller receives distinguishes "storage never applied
it" from "storage applied it and the answer did not come back". That is true of a cancellation or
deadline, and equally true of a transport or backend error — `Unavailable`, a reset connection, a
proxy 502 — which this contract otherwise collapses to one opaque storage error.

The classification exists to keep an upstream message from crossing the boundary; it is **not** a
statement about whether the write landed, and must never be read as one. Reserving
ambiguity-handling for cancellation alone is the dangerous half-rule: it invites a caller to treat
the far more common transport error as proof that nothing committed, then issue a different
mutation and duplicate the value.

So: any error after dispatch, whatever its class, is reconciled by stable identity — re-read the
record, or resolve the idempotency key (#475) — before reporting an outcome or issuing another
mutation. Only a *pre-dispatch* rejection (a validation refusal, a refused connection) is safe to
treat as "nothing happened". Reading an ambiguous error as failure is how a player is told a reward
did not arrive after it already did.

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

**That remedy is only real if the evidence outlives the failure.** The audit trail is what a
re-application reads from, and an audit entry written into the same database as the mutation is
rolled back *by the same rollback*. A point-in-time restore that loses the grant loses the record of
the grant with it, and the promise above quietly becomes unkeepable at exactly the moment it is
needed.

So the recovery evidence must **survive the failure domain it is meant to recover from**: an
independently durable journal — archived write-ahead log, or a sink outside the database's own
restore boundary. Until such a journal exists, this bound is **stated but not yet keepable**, and
the enforcement map records it that way rather than implying otherwise.

**Its retention must exceed the restore window, not match it.** Matching is the pathological case:
restoring to the oldest permitted point is exactly the moment the entries just after that point
become eligible for deletion, so the evidence expires precisely when reconciliation needs it. The
minimum retention is the maximum restore lookback **plus** the time to detect the incident, perform
the restore, and finish reconciling from the journal — with margin, since all three are measured
after the fact and none is a constant.

**A journal that is merely *eventually* durable moves the window, it does not close it.** If the
mutation is acknowledged to the player while its evidence is still in flight to that journal, a
restore landing in the interval loses the mutation and its only record together — the original
failure, in a shorter window. The acknowledgement is therefore the thing that has to be gated: a
player-owned mutation is reported as done only once **evidence sufficient to re-apply it is itself
durable**, whether by writing the journal synchronously before acknowledging, or by an explicitly
defined atomic commit across the record and its evidence. "Both are written, usually within a
second" is the same not-an-invariant this contract already rejects for cross-record mutations.

**Durable-before-acknowledge is necessary and still not sufficient: the journal needs an ordered
protocol.** The journal and the record are two writes, so ordering alone fails in both directions.
Journal-first leaves evidence for a primary write that never committed, and reconciliation after a
restore then re-applies a grant that never happened — **permanently inflating the economy**, which
under the no-resets law is as irreversible as losing value and rather harder to notice. Record-first
can crash before any evidence exists, which is the loss this rule set out to prevent.

So the journal must let reconciliation tell a **committed** mutation from a mere **attempt**: an
intent written first and a commit marker written after the record lands, or an equivalent ordered,
recoverable protocol. Reconciliation re-applies only what is marked committed, and an intent with no
commit marker is never grounds to grant value on its own.

**Resolving such an intent by reading the record is not generally possible, so the protocol must
make it decidable.** A crash between the primary write and its commit marker leaves an intent whose
outcome the current record usually cannot answer: if the mutation was `+3` and a later grant has
since moved the same balance, no value the record can hold distinguishes "the `+3` landed" from "it
did not". Attribution by arithmetic fails as soon as a second mutation touches the field.

So a record owner must adopt one of two mechanisms, and say which:

- **store the mutation's identity and outcome atomically with the primary write** — then the record
  itself answers whether that identity has been applied, whatever happened afterwards; or
- **block subsequent mutations to the record while an intent is unresolved** — then no later write
  can obscure the answer, at the cost of a stall.

The first is usually right, and it is the same idempotency-key record #475 already requires — which
is why that obligation is load-bearing for recovery, not only for retries.

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
| No blind **create** — create is conditional | `nakamalease.Store` | `TestConcurrentIdenticalCreateReconcilesTheDurableWinner` |
| No blind **replace** — replace presents the observed version | `nakamalease.Store` | `TestReplaceUsesObservedVersionAndStaleRecordCannotOverwrite`, `TestConcurrentReplaceLeavesExactlyOneCurrentAttempt` |
| No blind **claim** — claim presents the observed version | `nakamalease.Store` | `TestClaimRejectsAStaleAttemptWithoutWriting`, `TestClaimReportsConflictWhenTheObservedLeaseWasReleased` |
| No blind **finalize** — finalize presents the observed version | `nakamalease.Store` | **unguarded** — `Finalize` writes with `current.Version`, but the only direct call site (`handoffalloc/coordinator_test.go`) finalizes a freshly loaded record and never supplies a stale version |
| No blind **release** — release deletes conditionally | `nakamalease.Store` | `TestReleaseRejectsAStaleAttemptWithoutDeleting`, `TestReleaseReconcilesNakamaConditionalDeleteRejections` |
| The writer declares the current schema | `nakamalease` document encode | `TestCreatePersistsPrivateVersionedLeaseByHashedKey` (asserts `schema: 2` on the stored value) |
| The reader accepts the legacy end of the range | `nakamalease` document decode | `TestLoadKeepsSchemaOneLeaseReadableAsNotReleasing` |
| The reader rejects a schema outside the range | `nakamalease` document decode | `TestLoadRejectsMalformedOrPublicStoredObjects` (`unsupported schema`) |
| Unknown fields are refused | `nakamalease` document decode | `TestLoadRejectsMalformedOrPublicStoredObjects` (`unknown JSON field`) |
| A repeated known member is refused | `nakamalease` document decode | **gap (running code)** — `DisallowUnknownFields` does not reject duplicates; `{"schema":1,"schema":2}` decodes clean and keeps `2` |
| A required nullable field cannot be omitted or nulled undetected | every record owner, **incl. `nakamalease` today** | **gap (running code)** — `claimed_at_nanos` is a `*int64`, so absent and explicit `null` are indistinguishable |
| Trailing content is refused | `nakamalease` document decode | **unguarded (#491)** — `leaseFrom` *does* enforce this via its second decode and `io.EOF` check; no test appends a trailing token, so a regression would leave every named guard green |
| A required field omitted from its own schema is refused | every record owner, **incl. `nakamalease` today** | **gap (running code)** — no schema declares a required-field set, so an omitted required field decodes as an implicit zero |
| Every shipped schema **shape** stays readable, permanently | every record owner, **incl. `nakamalease` today** | **gap (running code)** — schemas 1 and 2 have shipped with no ledger or goldens, and schema 2 alone admits staging, finalized, claimed and releasing shapes |
| A refusal quarantines the record **across replicas** | `nakamalease.Store` | **unguarded** — met by the operation-level form: every write presents `current.Version` from a strict `Load`, so an undecodable document yields no version and blocks every write. No composite refusal→write test pins it |
| A refusal quarantines the record across replicas | future player-owned record owners | not yet built — `CharacterStore`'s process-local latch does not port; use the strict-read + version-match form |
| A newer field on a legacy schema is refused **by presence, not by truth** | `nakamalease` document decode | **gap (#491)** — `staging`/`releasing` are plain booleans, so an explicit `false` is accepted; needs presence-aware decoding and a zero-value case |
| Read support ships and bakes before its writer activates | every record owner, **incl. `nakamalease` today** | **gap (running code)** — no server-side equivalent of the client staging guard, and nothing registers the rollback target as carrying the expanded reader |
| A logical mutation spanning records is atomic or recoverable | player-owned record owners | not yet built — #474, #475 |
| Any error after a write is dispatched is reconciled, never read as failure | every caller, **incl. `nakamalease` today** | **gap (running code)** — `writeKey` returns `sanitizeStorageError` immediately for any non-version error and `Create` propagates it without reconciling the durable record; #475 supplies the stable identity for future records |
| Read and write storage errors do not cross the boundary | `nakamalease` error sanitization | `TestStorageFailuresAreSanitized`, `TestStorageContextCancellationIsPreserved` |
| **List** errors do not cross the boundary | `nakamalease` expiry sweep | **unguarded (#491)** — `ReclaimExpired` *does* call `sanitizeStorageError`; the fake's `listErr` field is never assigned by any test, so that path is unexercised |
| A replay of an already-final operation returns without writing | `nakamalease.Store` | `TestCreateReplaysTheSameAttemptWithoutAnotherWrite`, `TestClaimReplayKeepsTheOriginalClaimWithoutWriting`, `TestBeginReleaseReplayKeepsTheExistingBarrier` |
| A replay whose response was lost is reconciled to the durable outcome | `nakamalease.Store` | `TestClaimReconcilesAClaimCommittedFromTheSameObservedRecord`, `TestReplaceReconcilesAReplacementCommittedFromTheSameObservedRecord`, `TestReleaseReconcilesNakamaConditionalDeleteRejections`, `TestConcurrentIdenticalCreateReconcilesTheDurableWinner` |
| Player-owned keys derive from the verified identity, never a client-supplied subject | player-owned record owners | not yet built — #472, #473, #474 |
| An idempotency key is bound to its subject and payload; mismatched reuse is rejected | player-owned record owners | not yet built — #475 |
| An idempotency key is unique per logical mutation, so two identical legitimate mutations cannot share one | player-owned record owners | not yet built — #475 |
| Recovery evidence survives the failure domain it recovers from | platform + player-owned record owners | not yet built — no journal outside the database restore boundary |
| A mutation is acknowledged only once evidence sufficient to re-apply it is durable | player-owned record owners | not yet built — **and conditional on the row above** |
| Reconciliation can tell a committed mutation from an attempt | player-owned record owners | not yet built — needs an intent + commit-marker protocol; ordering alone inflates the economy or loses the evidence |
| An unresolved intent is decidable without arithmetic on the record | player-owned record owners | not yet built — store mutation identity + outcome atomically with the write (#475), or block later mutations while an intent is open |
| An acknowledged player-owned mutation is never lost | player-owned record owners | not yet built — #473, #474, #475, **and conditional on the row above** |
| A replay **not** identified by its own content applies once | player-owned record owners | not yet built — #475 |
| A world-owned record states its own recovery invariant | first world-owned record owner | not yet built — no such record exists |

The four labels mean different things, and the difference is the point of the table:

- **A cited guard** — the promise holds today and a named test body covers it.
- **`gap (running code)`** — the promise binds a record that **already exists** and that record does
  not keep it. These are defects now, not future work.
- **`unguarded`** — the running code *does* keep the promise, but no test pins it, so a regression
  would be silent. Not a defect today; a defect waiting for an unlucky refactor.
- **`not yet built`** — the promise binds records that do not exist yet. Nothing is broken; the row
  exists so a record added later is measured against it rather than shipping unguarded and being
  noticed afterwards.

The `gap`/`unguarded` split matters because collapsing them misreports working code as broken, and
the map is supposed to be the authority on which is which.

Every gap is recorded rather than quietly softened. The honest options were always to weaken the
rule or to fix the code, and weakening a rule to match an implementation is how a contract stops
meaning anything.

**Read this map as claims about test *bodies*, not test names.** Several gaps above were found that
way: a named guard existed and looked sufficient, and the case that would actually catch the
regression was not among its cases. A guard cited here should be opened and checked before it is
trusted — including by whoever next edits this table.
