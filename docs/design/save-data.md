# Save data — forward-only migration contract

This is the review contract for changing player data. It covers the character recipe in
`user://character.json` and progression in `user://vault.json`. The
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

## Expand, bake, then contract

Every change that makes a new field, value shape or stable name persistable uses three release
stages. Reading arrives before writing.

### 1. Expand the reader

Teach the reader and application path to understand both the shipped shape and the proposed shape,
but keep every production writer on the shipped shape and version.

- New fields are optional while the reader is expanded; absence keeps the old meaning.
- A widened value accepts both representations. The old representation remains valid forever.
- A new stable name is registered and actionable before any save can contain it.
- Tests include the future-shaped document and every historical golden, with zero-loss and real-effect
  checks. A parser-only assertion is not enough.
- A schema expansion raises the read ceiling, appends the schema version to its permanent ledger and
  adds the new golden in the same pull request. A same-schema addition raises only the read-capability
  ceiling. Neither change activates the writer.

Do not blindly raise a constant that also controls writing. Today `CharacterFactory.RECIPE_VERSION`
feeds `UpdateManifest.save_schema.writes`, and `SaveVault.VAULT_VERSION` feeds the version of a new
empty vault. If read support cannot advance without advertising or emitting the new version, split
the read ceiling from the write version first. An expansion that starts writing is not an expansion.

### 2. Bake the expansion

Ship the read-capable build through the applicable update tier and keep the old writer active. A
save-schema bump rides the shell; a same-schema capability follows the distribution decision's normal
routing. The expansion is baked only when that build is the standing last-known-good rollback target
for every release channel that will write the new state. Until then, the new field, shape or name
remains unpersisted.

This wait is what makes rollback safe: if the next build fails, the retained build already understands
everything the failed build may have written.

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
  writing, not start over.

An additive transform may copy a historical document without loss, but there is no destructive
“migration to latest”. Old documents remain valid at their original version. Removing anything needs
the separate, announced-deprecation path required by the product law; a schema bump is not that path.

## What a version bump must contain

### Character recipe

The schema-version bump is the expansion pull request. For recipe version `N`, that change must:

1. Teach `CharacterFactory` to validate and apply versions `1..N`, including both the old and new
   shapes.
2. Introduce or raise a dedicated maximum recipe-schema read ceiling, separate from the production
   write version. Publish it in the manifest's stable shell envelope, feed the same value into each
   retained build's rollback-target `read_ceiling`, and guard both mappings in runtime tests.
   `shell.reads_min` is the oldest supported schema, not this maximum. The reader may understand `N`,
   while `CharacterCreator` and `UpdateManifest.save_schema.writes` remain on the baked version.
   Registry entries needed to read `N` must not automatically become editor options: gate every new
   piece, skin and other persisted name out of writable UI and production write paths until the
   contract stage.
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

### Progression vault

For vault version `N`, the expansion pull request must:

1. Teach `SaveVault` to validate versions `1..N` and preserve every accepted field and attunement name
   on write-back.
2. Split the read ceiling from the production write version before raising it. Keep `empty()` and
   every production write path on the baked version until the contract stage.
3. Append `N` to `client/tests/data/shipped_vault_versions.txt`.
4. Add `client/tests/data/golden_vault_vN.json`. Preserve every older golden.
5. Extend `save_vault_guard_test` with the new shape and its negative controls. A new live attunement
   also enters `shipped_attunements.txt`, `SaveVault.KNOWN_ATTUNEMENTS`, the resolver, and the boot
   restoration test in the same change.
6. Assign the new persistable capability and raise `UpdateManifest.SAVE_CAPABILITY_READS` to it while
   leaving `SAVE_CAPABILITY_WRITES` unchanged. The retained expansion build must advertise the read
   ceiling that makes it an eligible rollback target before the contract release can write that
   capability.

After bake, the contract pull request lets new or changed vaults use version `N`, raises the global
write capability, and appends that capability to `shipped_save_capability.txt`.

The ledgers are the immutable floor: the in-game guards compare the current constants and fixtures,
while CI compares each ledger with the pull request's base revision. Editing code, fixtures and a
ledger together therefore cannot make a shipped version disappear quietly.

## Refusal and failure rules

The character recipe and vault deliberately fail differently:

- A recipe that `CharacterFactory` refuses is existing player state, not a first run. Keep the file
  untouched, do not open a writable replacement path, and surface recovery instead of presenting a
  blank character. `CharacterStore` currently parses only; rejection happens later during
  `CharacterFactory.build()`, and there is no vault-style refusal latch to mistake for protection.
- A missing vault degrades to an empty, session-capable vault and never blocks character boot.
- An existing vault that is unreadable, malformed or newer degrades to session-only progression and
  becomes read-only for the rest of the process. `SaveVault` latches that refusal even if the file
  later disappears, so an older client cannot overwrite newer progression after cloud sync changes
  the path.
- Vault persistence rechecks readability immediately before its atomic replace. The remaining
  concurrent-writer compare-and-swap gap is tracked by
  [#262](https://github.com/devantler-tech/world-at-ruin/issues/262); do not describe the current
  recheck as a complete lock.

Boot tests redirect every player-state seam through `SaveIsolation`; persistence and fixture tests use
explicit throwaway paths. A migration test that touches a played save is itself a product-law
violation.

## Enforcement map

| Promise | Runtime owner | Permanent guard |
|---|---|---|
| Historical character recipes still load and build | `CharacterFactory`, `CharacterStore` | `save_fixture_guard_test`, recipe ledger and goldens |
| Historical vaults still load and re-save | `SaveVault` | `save_vault_guard_test`, vault ledger and goldens |
| Shipped attunement names still work | `SaveVault`, `RespawnPoints` | `shipped_attunements.txt`, vault and boot-restoration guards |
| Writes never outrun rollback readers | Writers and `UpdateManifest` | `update_manifest_test`, `shipped_save_capability.txt`, CI and the distribution decision |
| Player files stay outside tests | Save-path environment seams | `SaveIsolation`, boot-isolation and path-seam guards |
