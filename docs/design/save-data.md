# Save data — forward-only migration contract

This is the review contract for changing player data. It covers the character recipe in
`user://character.json`, progression in `user://vault.json`, and the immutable shell's recovery
memory in `user://boot_recovery.json`. The
[distribution and self-update decision](distribution-and-self-update.md) owns how builds reach a
player; this document owns what those builds may read and write.

The outcome is simple: every build keeps reading every state it ever wrote, a retained build stays a
safe rollback target while a new shape is introduced, and refusing data can never become permission
to overwrite it.

## Why both formats are strict

Both documents are closed, versioned and name-keyed:

- `CharacterFactory` accepts the recipe fields allowed by that recipe's version. It refuses a newer
  version, an unknown field, or a name the shipped character kit cannot render. A recipe must describe
  the character exactly; silently ignoring part of it would render a half-truth.
- `SaveVault` accepts the vault fields allowed by that vault's version. It refuses a newer version or
  an unknown field, while preserving every accepted attunement name through a write-back. A vault must
  never quietly lose progression just because this build does not act on every stored name.

That strictness is already installed on players' machines and cannot be relaxed retroactively. A new
field placed into an old recipe does not become safe because the new client treats it as optional: an
old client still rejects it. This is why progression lives in a sibling vault instead of being added
to `character.json`, and why every future change follows a staged rollout.

## Save-bearing vocabulary boundary

Reader compatibility and production writer exposure are deliberately separate:

- The kit, skin and forward-only `shipped_*.txt` registries say what this build can read, render and
  preserve. They may grow in the expand release while `SAVE_CAPABILITY_WRITES` remains unchanged.
- `client/registries/character_writer_vocabulary.json` is the smaller set the production character
  creator may newly originate. It records equipment as exact `piece -> slot` pairs, plus skin names,
  non-plumbing blend-shape names and each field's bone keys. The creator filters its pickers and
  sliders through that resource, while values already present in the opened recipe may still be
  preserved during expansion.

The base-anchored guard compares that writer resource, not the wider reader ledgers. Adding a writer
entry is the contract transition and requires `SAVE_CAPABILITY_WRITES` plus
`shipped_save_capability.txt` to advance. Adding only reader support remains green. This split is what
makes expand → bake → contract enforceable rather than merely described.

Those four groups are save-bearing because an older `CharacterFactory` rejects an unknown blend
shape, bone key, skin or equipment name, and also rejects a known piece under a different slot. The
other registries are excluded for present-state reasons:

- Equipment layer is render metadata derived from the piece; the layer is never written into a
  recipe.
- Vault attunements, discoveries and reward claims accept and preserve unknown stable string names.
  Vault-v4 quest progress similarly preserves unknown quest and objective IDs plus their raw
  non-negative whole-number progress. Their version, resolver and real-effect guards own rollout.
- Ability, class-power and class-cycle ledgers describe combat registries and balance promises, not
  fields in a current player document.
- Creature shapes, tints and recipe versions describe generated world creatures, not persisted player
  state. A creature-tint addition is the guard's permanent presentation-only negative control.
- Recipe, vault and boot-recovery version ledgers, plus the capability ledger itself, describe
  document shape or capability and retain their own immutable base checks.

## Expand, bake, then contract

Every change that makes a new field, value shape or stable name persistable uses three release
stages. Reading arrives before writing.

### 1. Expand the reader

Teach the reader and application path to understand both the shipped shape and the proposed shape.
Production writers must not originate the proposed shape from old state, but they must preserve it
when an expanded document is already present; rollback safety requires both halves.

- New fields are optional while the reader is expanded; absence keeps the old meaning.
- A widened value accepts both representations. The old representation remains valid forever.
- A new stable name is registered and actionable to the reader before any production UI or writer can
  originate it.
- Tests include the future-shaped document and every historical golden, with zero-loss and real-effect
  checks. A parser-only assertion is not enough.
- A schema expansion raises the read ceiling, appends the schema version to its permanent ledger and
  adds the new golden in the same pull request. A same-schema addition raises only the read-capability
  ceiling. Neither change activates the writer.

Do not blindly raise a constant that also controls writing. `CharacterFactory.RECIPE_VERSION`
currently feeds both `UpdateManifest.shell.reads_max` and `UpdateManifest.save_schema.writes`, while
`SaveVault.VAULT_VERSION` feeds the version of a new empty vault. Split the read ceiling from the
write version before schema read support advances. An expansion that starts writing is not an
expansion.

### 2. Bake the expansion

Ship the read-capable build through the applicable update tier and keep the old writer active. A
save-schema bump rides the shell; a same-schema capability follows the distribution decision's normal
routing. The expansion is baked only when that build is the standing last-known-good rollback target
for every release channel that will write the new state. Until then, the new field, shape or name
remains unpersisted.

This wait is what makes rollback safe: if the next build fails, the retained build already understands
everything the failed build may have written.

“Applicable update tier” is literal. While the client ships as one monolithic app, the retained
whole-app release is the rollback target: its published app must boot and apply the expanded state
before the later app starts writing it. `v0.52.0` is that retained, independently booted whole-app
target for capability 3. The manifest's `rollback_targets` array is a different tier: it is consumed
only by the future mountable-pack recovery path, so it stays empty until a real `.pck` is retained.
Putting a monolithic `.app` ZIP there would not strengthen rollback; it would make recovery select
bytes the pack path cannot mount. Once pack delivery exists, its capability expansions require a
selectable catalogue entry before their writers activate.

### 3. Contract by starting the new writer

Enable the new write path only after the expansion is baked.

- Stamp the new version only on a document that actually uses the new shape. Loading or editing an
  older document must not churn it to the newest version without need.
- Advance the published write capability only when the production writer really emits that state, and
  append that capability to `shipped_save_capability.txt` in the same pull request.
- Keep every older read and application path. For save data, “contract” means starting the new writer;
  it never means dropping old-version support.

## Permitted changes

- Add an optional field at a new version, with a reader that still accepts its absence.
- Widen a value at a new version while retaining the old representation. Recipe version 4's
  single-piece-or-layered equipment value is the existing example.
- Add a stable, name-keyed registry entry. The name becomes permanent once persisted.
- Add a sibling document when an installed closed format cannot grow safely. The vault is the existing
  example.
- Preserve an older document at its own version until it uses a capability that requires a newer one.

## Forbidden changes

- Remove, rename, repurpose or repoint a shipped field, version, registry name or live-name mapping.
- Change a persisted value's meaning or type without a new version and a staged reader expansion.
- Teach and activate a new writer in one release, leaving the rollback target unable to read it.
- Rewrite an old document merely to make its version current.
- Silently ignore an unknown field or future version, or half-apply a document this build does not
  understand.
- Delete or rewrite a historical golden, lower a version constant, or remove a shipped-ledger entry.
- Put progression inside `character.json`; every already-shipped client treats that recipe as closed.
- Treat a refused document as first-run state and replace it. Refusal means preserve the bytes and stop
  writing, not start over. The single exception is a document **no client could own** — see
  *Setting aside a document no client could own* below — where the bytes are moved intact to a
  neighbouring file first, so nothing is replaced and nothing is lost.

An additive transform may copy a historical document without loss, but there is no destructive
“migration to latest”. Old documents remain valid at their original version. Removing anything needs
the separate, announced-deprecation path required by the product law; a schema bump is not that path.

## What a version bump must contain

### Character recipe

The schema-version bump is the expansion pull request. For recipe version `N`, that change must:

1. Teach `CharacterFactory` to validate and apply versions `1..N`, including both the old and new
   shapes.
2. Introduce or raise a dedicated maximum recipe-schema read ceiling, separate from the production
   write version. Publish it as immutable metadata for that build in the manifest's stable shell
   envelope, then populate each retained rollback target's `read_ceiling` from that target build's own
   published value. Never stamp the current build's ceiling across the catalogue: an older target that
   reads only `N-1` must continue to say so. Guard the manifest mapping and a mixed catalogue containing
   both the old and expanded builds in runtime tests. `shell.reads_min` is the oldest supported schema,
   not this maximum. The reader may understand `N`, while `CharacterCreator` and
   `UpdateManifest.save_schema.writes` remain on the baked version. Registry entries needed to read
   `N` must not automatically become editor options: gate every new piece, skin and other persisted
   name out of writable UI and production write paths until the contract stage.
3. Append `N` to `client/tests/data/shipped_recipe_versions.txt`.
4. Add `client/tests/data/golden_recipe_vN.json`. Preserve all older goldens; the new fixture exercises
   every new persisted field group and proves it still changes the built character.
5. Extend the focused runtime tests and keep `save_fixture_guard_test` green. Starting from an old
   recipe, prove the expansion build cannot originate or select the new field, name or value through
   any production UI or writer. Separately load the version-`N` fixture, make an ordinary supported
   edit and prove the expansion writer round-trips every already-present new value without loss. If
   the change adds a persisted piece, skin, slot, layer or other stable name, update its append-only
   ledger and real-effect guard too.
6. Raise `UpdateManifest.SAVE_CAPABILITY_READS` for a new persistable capability while leaving
   `SAVE_CAPABILITY_WRITES` unchanged.

After the expansion bakes, the contract pull request enables the writer, makes `CharacterCreator`
stamp `N` only when the new shape is present, reports the real write version in the manifest, raises
`SAVE_CAPABILITY_WRITES`, and appends the capability to
`client/tests/data/shipped_save_capability.txt`.

The first active use of that sequence is capability 2: recipe-version-4 layered equipment became
readable in v0.32.0, but builds through v0.49.0 still published a capability-1 read ceiling. v0.50.0
is the retained expansion release: it publishes reads 2 while writes remain 1 and keeps every
production writer unreachable. The separate contract release may now activate the opt-in writer,
raise writes to 2 and append 2 to the capability ledger. The raw preview remains behind
`WAR_LAYERED_OUTFIT_PICKERS=1` until #336 delivers an authored wardrobe surface; the flag controls
exposure, not the already-completed two-release compatibility sequence.

### Progression vault

For vault version `N`, the expansion pull request must:

1. Teach `SaveVault` to validate versions `1..N` and preserve every accepted field and attunement name
   on write-back.
2. Split the read ceiling from the production write version before raising it. Keep `empty()` and
   old-state writes on the baked version until the contract stage; an already-present version-`N`
   vault must remain version `N` and preserve its accepted fields through ordinary writes.
3. Append `N` to `client/tests/data/shipped_vault_versions.txt`.
4. Add `client/tests/data/golden_vault_vN.json`. Preserve every older golden.
5. Extend `save_vault_guard_test` with the new shape and its negative controls. Prove old vaults cannot
   originate the capability during expansion, and prove an already-present version-`N` vault
   round-trips losslessly after an ordinary write. A new live attunement also enters
   `shipped_attunements.txt`, `SaveVault.KNOWN_ATTUNEMENTS`, the resolver, and the boot restoration
   test in the same change. A new writable discovery id similarly enters
   `shipped_discoveries.txt` as an immutable `id=landmark` mapping,
   `SaveVault.KNOWN_DISCOVERIES`, and the real boot's bidirectional
   point-of-interest registration guard. Unknown discovery names already present in a newer vault
   remain preserved, but this build may originate only a registered, ledgered ID. A persisted reward
   also enters `shipped_reward_mappings.tsv` as an immutable
   `place_id → kind → reward_id → display_name` row; the real boot binds every production reward
   registration to that payload in both directions.
6. Assign the new persistable capability and raise `UpdateManifest.SAVE_CAPABILITY_READS` to it while
   leaving `SAVE_CAPABILITY_WRITES` unchanged. The retained expansion build must advertise the read
   ceiling that makes it an eligible rollback target before the contract release can write that
   capability.

After bake, the contract pull request lets new or changed vaults use version `N`, raises the global
write capability, and appends that capability to `shipped_save_capability.txt`.

The first progression-vault sequence is capability 3: v0.52.0 shipped the version-2 discovery reader
while production writes remained at capability 2. With that release retained as a rollback target,
the later contract build registers `starter_cave` and `wardens_shrine`, observes the real wanderer's
position, and persists the append-only found set at vault version 2. Empty and attunement-only vaults
remain version 1; the first actual discovery is what contracts them to version 2. Quests and map
presentation remain separate children of the exploration roadmap rather than being implied by this
persistence contract.

Capability 4 adds vault v3 `reward_claims`. The retained v0.61.0 app reads and preserves that shape,
and production writes it while keeping that safe whole-app rollback target. The boot-owned
exploration reward tracker restores every accepted stable place name, re-applies registered outcomes,
and keeps unknown future claims inert but remembered. A newly discovered place is marked claimed only
after its horizontal outcome succeeds; the claim writer then requires that place's discovery to
already be durable. Transient discovery and claim failures keep independent retry backoff without
granting twice in-session. If a writable cloud replacement drops a claim's already-written
discovery, the refused claim requeues that prerequisite before retrying so the vault converges
without re-applying the live reward. A refused newer or unreadable vault remains session-only and
byte-intact.
Because a claim stores only its stable place id, `shipped_reward_mappings.tsv` permanently binds that
id to the exact outcome every later boot derives from it; CI base-compares complete rows and the real
boot verifies the live registry against the ledger.
Ordinary attunement and discovery writes preserve an already-present v3 document and its claims;
discovery-only documents remain v2.

Capability 5 is the reader expansion for vault v4 quest progress. Its optional `quests` object maps
stable quest IDs to stable objective IDs and non-negative whole-number progress. `SaveVault` validates
and preserves the whole nested shape; `Main` restores it into a boot-owned `QuestLog` before any quest
definition registers. Known objectives get a clamped live view, while snapshots retain raw values and
opaque future IDs so a rollback build cannot truncate newer progress. Restored completion is latched
silently and can never be announced or granted again. The production writer remains vault v3 at
capability 4: empty state and ordinary attunement, discovery and reward writes cannot originate
`quests`, but they preserve an already-present v4 document. Activating vault-v4 writes is the separate
contract child #560, gated on retaining the capability-5 reader release as a whole-app rollback target.

### Boot recovery

Boot recovery follows the same sequence, with its own read ceiling and write version. It reads and
preserves both unversioned v0 and explicit v1, records both schemas in
`shipped_boot_recovery_versions.txt`, and pins them with `golden_boot_recovery_v<N>.json`. The
published v0.51.1 app is the standing retained rollback target that reads and applies v1. First boot
uses explicit v1, while a loaded v0 stays v0 in memory and migrates only on its next real write.

Recovery refusal is path-latched for the process lifetime, and persistence reparses the destination
immediately before atomic replacement. Reconstructing state, deleting a refused file, or landing a
future/corrupt replacement therefore cannot turn the path writable. Recovery persistence also takes
the same cross-process write lock the vault takes, so a second lock-aware writer cannot read, merge
and rename between another's check and its replace. That matters here more than anywhere: the
updater and the game are both live writers of this file, and what a lost update discards is the
evidence deciding whether a client rolls back.

The ledgers are the immutable floor: the in-game guards compare the current constants and fixtures,
while CI compares each ledger with the pull request's base revision. Editing code, fixtures and a
ledger together therefore cannot make a shipped version disappear quietly.

## Refusal and failure rules

The character recipe and vault deliberately fail differently:

- A recipe that `CharacterFactory` refuses is existing player state, not a first run. The file stays
  untouched, no writable replacement path opens, and the player is told rather than shown a blank
  character. `CharacterStore.load_from()` decides this at the save boundary: it parses, then asks
  `CharacterFactory.refusal_reason()` whether this build can accept what it parsed, and latches a
  refusal on the path when it cannot. The latch outlives the file, so a recipe that disappears after
  being refused — cloud sync, a second client, the player deleting it — does not reopen the writable
  path. `CharacterStore.save_to()` refuses every write to a refused path, and `main.gd` locks all
  character-creator entry, so the door and the lock are independent. Only an absent, never-refused
  path is a first run.
- A missing vault degrades to an empty, session-capable vault and never blocks character boot.
- An existing vault that is unreadable, malformed or newer degrades to session-only progression and
  becomes read-only for the rest of the process. `SaveVault` latches that refusal even if the file
  later disappears, so an older client cannot overwrite newer progression after cloud sync changes
  the path. The one document that does not stay latched forever is one no client could own, which is
  set aside at boot instead — see the next section.

### Setting aside a document no client could own

The refusal latch above is permanent per path, which is correct while the bytes are still somebody's
progression and wrong once they are nobody's. A document that no client can read is progression no
client can recover, so latching it refuses every future write for the life of the install: the player
is told each waking that the Reach may not remember, and the only remedy is deleting a file inside
`user://` that the game never mentions. That is its own no-resets harm, quieter than data loss.

So at boot, and only at boot, such a vault is **moved intact** to a neighbouring
`vault.json.unreadable-<unique>` file and a fresh vault is started. This does not weaken the rule
above, because nothing is replaced and nothing is deleted — the bytes survive for manual recovery,
and the latch is cleared only once the path genuinely holds nothing.

**The line is drawn at the version, not at validity.** A document is *unownable* when it is not a JSON
object at all, or carries no positive integer `version`. `version` is the one field whose meaning is
fixed across every schema, so a document without one was written by no client that ever shipped and can
be read by none that ever will. A document that *declares* a version is left exactly where it is, even
when it fails validation and even when its version is far ahead of this build: a version is a claim of
ownership, and being wrong about it destroys progression, while being cautious only leaves a
hand-edited shape read-only.

Three properties keep the act safe, and all three are load-bearing:

- **It waits.** The document must have sat unchanged for a window (five minutes) before it is moved,
  so a partial file that cloud sync or a backup restore is about to complete — possibly a newer
  client's progression caught mid-write — is not mistaken for abandoned corruption.
- **It re-judges immediately before the move,** both that the document is still unownable and that its
  modification time is unchanged. The second is an identity check: without it a freshly arriving
  unparseable file would inherit the old one's staleness verdict and be moved instantly.
- **It never overwrites.** The destination carries a per-attempt unique stamp rather than an index,
  because `rename()` replaces its destination silently and any name a second party could also derive
  is a way to destroy exactly the bytes this is preserving.

Quarantine happens on the boot path only. Reads stay free of side effects, and the readability
re-check inside `_save_to_locked()` runs mid-write holding the lock, where moving the file would be
catastrophic rather than helpful.
- An unreadable or newer boot-recovery document degrades to a rollback-safe empty quarantine view,
  while the path remains read-only for the process lifetime. Rollback eligibility still proves save,
  protocol and shell compatibility independently; new update attempts and recovery writes stop.
- The character write commits from a **private staging file**, `character.json.tmp-<pid>-<ticks>`,
  never a derivable `character.json.tmp`. A shared staging name is a hole no target-side check can
  see: a second client — a retained rollback build, a sync agent, a second install — opens that same
  predictable path and can truncate the staged recipe after it is serialised and before the rename,
  and because `character.json` itself is untouched until then, both the write guard and the
  pre-replacement re-check pass and the rename commits the other writer's partial bytes. A name a
  foreign writer cannot derive removes the sharing instead of trying to detect it.
- Because a per-attempt name is not reclaimed by being overwritten the way one fixed name was, a
  crashed writer's staging file is swept on the next write — but only once it has sat unchanged past
  `WRITE_TMP_MIN_AGE_SECONDS` (300 s, overridable for tests via
  `WAR_CHARACTER_WRITE_TMP_MIN_AGE_SECONDS`). The character sweep keeps that age floor even though it
  now runs under the write lock, because the lock proves less than it appears to: it binds only
  writers that take it, so a retained rollback build or a foreign writer can still be mid-write on a
  young stage, and deleting it would cause exactly the corruption the private name removes. The
  vault's sweep needs no such floor. The window errs long —
  sweeping too eagerly destroys another client's write, sweeping too late leaves one file for one
  more launch.
- Character, vault and boot-recovery persistence each take a cross-process write lock around their
  whole read-modify-write, so no second lock-aware writer can read, merge and rename between another's
  check and its replace. For the character that span is the acceptance read, the validation and the
  rename together: locking only the rename would still let two clients each accept the same recipe
  before either acquires, and the slower one would discard the other's character. One primitive serves
  all three (`FileLock`); a second mechanism per file would be a second set of bugs. The lock is a
  directory beside the file it guards
  (`character.json.lock`, `vault.json.lock`, `boot_recovery.json.lock`): `DirAccess.make_dir_absolute` is `mkdir`, the one
  atomic exclusive-create Godot exposes, so exactly one writer wins and the rest refuse. A refused
  write degrades to session-only and never blocks a boot — and reads take no lock at all, so a held
  lock can never prevent a rollback decision.
- Acquisition is only ever that single `mkdir` against an absent path. Reclaiming an abandoned lock is
  a **separate pass that never acquires**: it renames the stale directory to a uniquely-named copy
  (rename succeeds for exactly one process, which is what serializes reclamation), verifies on that
  privately-owned copy that the timestamp is the one it judged abandoned, removes it, and still
  refuses this write. The next attempt then acquires the free slot normally. Reclaiming and acquiring
  in one pass is unsound — two processes would each recreate the lock over the other and both proceed
  as owners — so do not "simplify" it back into remove-then-create.
- The lock directory is **not** empty: it holds an ownership stamp. Renaming onto an empty directory
  succeeds, so an unstamped lock could be silently renamed over; the stamp also lets a holder prove
  the lock is still its own immediately before it replaces the file, and abandon the write if it is
  not. Both writers make that check on their own replace path.
- **Scope the lock precisely.** A lock only excludes writers that take it. Builds from before this
  protocol — the retained and rollback clients the updater keeps runnable — write the same file without
  it, as do foreign writers such as cloud sync, a backup agent or a hand edit. The lock removes lost
  updates between lock-aware builds and nothing more; do not describe it as closing the
  differently-versioned case outright.
- Every write additionally **compare-and-swaps on the document's own bytes**. The read-modify-write
  records the SHA-256 of the vault it read and verifies the file still carries it immediately before the
  rename, refusing when it does not. This keys on what the file *is* rather than on who cooperated, so
  it covers exactly the writers the lock cannot bind — and it subsumes the point-in-time ownership gap,
  because a reclaimed-and-rewritten vault fails the comparison. `save_to()` stays a deliberate blind
  whole-document replace via an explicit sentinel; `replace_if_unchanged()` is the guarded entry point.
- The identity is captured **before** the read, not after. Captured after, a foreign write landing
  between the read and the hash would be recorded as the expectation while the merge still held the old
  document, and the comparison would pass. Captured before, that interleaving makes the expectation
  stale and the write refuses. Both orders leave a window; only this one fails safe.
- Each write **stages through a private per-attempt path** (`vault.json.tmp-<pid>-<ticks>`), never a
  shared `vault.json.tmp`. The compare-and-swap verifies the *target*, so it cannot see a foreign
  writer truncating the staged document between serialisation and the rename — the target is untouched,
  every check passes, and the rename would commit the other writer's partial bytes while reporting
  success. A per-attempt name removes the sharing rather than detecting it. Abandoned staging files are
  swept under the write lock, which a fixed name previously got for free by being overwritten.
- **The residual is a shrunk window, not a closed one.** Verify-then-rename is two operations, so the
  gap narrows to the rename syscall. Closing it needs a lock the OS holds across the rename (`flock`,
  `O_EXCL`), which Godot's `FileAccess`/`DirAccess` do not expose. The gain is turning a *silent* lost
  update into a *detected refusal*, which degrades to session-only and never blocks a boot.

Boot tests redirect every player-state seam through `SaveIsolation`; persistence and fixture tests use
explicit throwaway paths. A migration test that touches a played save is itself a product-law
violation.

## Enforcement map

| Promise | Runtime owner | Permanent guard |
|---|---|---|
| Historical character recipes still load and build | `CharacterFactory`, `CharacterStore` | `save_fixture_guard_test`, recipe ledger and goldens |
| A refused recipe is never replaced by a first run | `CharacterStore`, `main.gd` | `character_refusal_test`, `character_refusal_boot_test` |
| Historical vaults still load and re-save | `SaveVault` | `save_vault_guard_test`, vault ledger and goldens |
| Historical recovery documents still load and re-save | `BootRecovery` | `boot_recovery_guard_test`, recovery ledger and goldens |
| Shipped attunement names still work | `SaveVault`, `RespawnPoints` | `shipped_attunements.txt`, vault and boot-restoration guards |
| Writes never outrun rollback readers | Writers and `UpdateManifest` | `update_manifest_test`, `shipped_save_capability.txt`, CI and the distribution decision |
| Player files stay outside tests | Save-path environment seams | `SaveIsolation`, boot-isolation and path-seam guards |
