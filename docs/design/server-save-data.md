# Server save data — retain every shipped contract

Server persistence obeys the no-reset law: an older record remains readable, a refused record is
never replaced as though it were absent, and an ordinary write cannot silently lose earned state.
The [client save-data contract](save-data.md) owns local client files. This contract covers the
server's private Nakama records and the evidence that makes their mutations replay-safe.

## Two independent checks

`tools/google-binding-durability-guard.sh` is the shared server-history entry point. It discovers
schema ledgers from both the reviewed base revision and the candidate tree. An entire deleted
package therefore remains part of the check. The identity-address fixture is protected separately
because it defines a permanent lookup contract rather than a versioned record family.

- Every shipped ledger must remain present, with every shipped version retained.
- A ledger contains one canonical positive decimal version per line, consecutively from `1`.
  Empty, malformed, reordered or duplicate entries are refused.
- Every declared version has a fixture: exactly one JSON object, or a nonempty array of objects,
  each declaring that version in its numeric `schema` field.
- Historical fixture bytes are immutable. Add a new version and its fixture when expanding a
  schema; do not rewrite the evidence for an already-shipped document.
- Ledger, fixture and collection-mapping paths must be ordinary files, with no symbolic-link component.

The naming convention is `server/<package>/testdata/shipped_<family>_versions.txt` with sibling
`golden_<family>_v<N>.json` files. Nested package directories are supported. Package names use
letters, digits, underscores and hyphens; family names use lowercase letters, digits and underscores.
Record families use this convention and join the check without editing an allowlist.

Each ledger also has a sibling `shipped_<family>_collection.txt` containing exactly one
`world_at_ruin_<name>` collection name on one line. The mapping connects the family to its
production collection without guessing from the family name. Two ledgers in the same package
cannot map to the same collection, and a mapping present in the reviewed base is immutable.
The guard checks every double-quoted or raw collection literal in production Go files against
the package's mappings, including multiple collections in one file. This is a lexical check:
comments can also contain matching literals, and dynamically constructed names require store
review.

Each family registers its historical reader in `shipped_<family>_reader.txt`, one line containing
the exact top-level Go test name, production Go filename, and reader function name. For example:

```text
TestLoadKeepsEveryShippedCharacterSchemaReadable store.go Load
```

The guard compiles an instrumented package test binary and runs only that test against a private
copy of the package's `testdata`. The test must execute and pass without skipped subtests, and
coverage must identify exactly one matching production reader with executed statements. An absent
test, an empty test, a skipped test, a missing reader, and a test-only reader cannot satisfy this
contract. Every declared fixture is then made unreadable individually in that private copy; the
named test must fail each time. A test using constants instead of its fixtures, or ignoring a new
fixture, therefore cannot pass. Checkout files and historical fixture bytes remain untouched.

The second check is behavioral: the stores' Go tests load their historical fixtures through the
production reader. Character tests retain the character identity and recipe; audit tests retain
the idempotency identity, target record, operation, payload
and committed outcome; identity-binding tests pin the historical binding fields. Lease fixtures
prove historical acceptance, with ownership and transitions covered by separate tests. A JSON-shape
check cannot prove these semantics, and a checkout-local test cannot alone prove that its historical
fixture was preserved. Coverage and fixture probes enforce participation, not arbitrary semantic
correctness: the registered tests still need independently specified expected fields and meaningful
loss/refusal assertions. Reader or test renames update the registration together with that evidence.

## Expanding a server schema

1. Add read support for the new version while retaining all historical reader paths. Keep the
   production writer on the supported version until every serving reader can accept the expansion.
2. Append the new version to its ledger and add a complete fixture. Extend the store's behavioral
   test with independently specified expected fields and an observable loss/refusal regression.
3. Validate the unchanged historical fixtures, the new reader and the old writer together. Record
   the supported reader/writer combination and its rollback constraint in the delivery issue.
4. Activate the writer in a separate reversible step after that compatibility evidence exists.
   Keep the old readers. Do not rewrite old records solely to raise their schema number.

Player-state records and their idempotency evidence commit through the existing player-state
mutation boundary. Identity bindings and handoff leases retain their own storage-write contracts.
Storage ownership, observed-version checks, replay behavior and failure sanitization remain part of
the store's tests. A schema number never authorizes loss, a destructive migration or a silent reset.
An announced, player-visible deprecation requires its own implemented and reviewed delivery path;
this fixture gate does not provide one.

## Validate locally

From the repository root, with `BASE_SHA` set to the immutable reviewed base commit:

```sh
BASE_SHA=<reviewed-base-commit> ./tools/google-binding-durability-guard.sh
./tools/google-binding-durability-guard.test.sh
bash tools/server-reader-contract.test.sh
go -C server test -race ./...
```

The shell suite runs the real guard against temporary Git repositories. It proves that deleted
families, coordinated ledger/fixture removal, altered historical records, malformed input and
incomplete additions fail, while unchanged history and complete expansions pass. Server CI invokes
the same guard for pull requests and merge groups; its required aggregate also includes the store
tests. The reader-registration suite runs real miniature Go packages and includes lossy readers,
unread fixtures, empty/skipped/missing tests, and a valid two-version extension. The guard requires
the server's declared Go toolchain; CI runs both regression suites after installing it.
The guard compares data against the supplied base; it does not make candidate-owned CI
instructions immutable or replace review of the workflow itself.
