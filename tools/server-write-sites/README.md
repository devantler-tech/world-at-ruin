# Persistence write-site inventory

The server durability guard joins two independent inventories: collection literals
and references to the server's persistence boundaries. A new writer cannot avoid
registration by importing an existing collection constant or sharing a collection.

`server/persisted-write-sites.txt` contains one line per discovered site:

```text
server/package/file.go|Receiver.Function|StorageWrite|1 server/package/testdata/shipped_family_versions.txt
```

The fields before the space are source path, enclosing function (or `package` for
initializers/type declarations), boundary and occurrence within that function.
Multiple ledger paths on the same line describe an atomic batch or forwarding
boundary. Blank lines and `#` comments are allowed. Duplicate lines/ledgers,
missing ledgers, unregistered sites and registrations without a source site fail.
Refactoring may update site identities; shipped ledger and fixture history remains
immutable independently of the inventory.

The Go AST scanner examines every candidate non-test Go file under `server`,
including untracked additions and all build tags. It inventories `StorageWrite`
method references, including method values and calls inside closures, and imported
`playerstate.RecordWrite` references at the schema-owner side of the atomic player
state boundary. Import aliases are resolved by package path. Runtime `StorageWrite`
type references and interface declarations alone do not dispatch data; they are
excluded. Shadowed import identifiers are treated as local receivers. Dot imports
of these persistence packages and malformed Go source fail closed.

This is an explicit registration check, not whole-program data-flow analysis.
Review must still verify the declared family, every discriminated document shape,
semantic multiplexing within an existing site, aliases and new persistence APIs.
A new forwarding API must extend the recognized boundaries before use. Two schemas
can share a physical collection while keeping separate ledgers, fixtures and reader
contracts. Collection names are not schema identities.

The helper uses only the Go standard library. Its tests run through
`tools/google-binding-durability-guard.test.sh`, alongside the real guard's imported
constant, shared collection, stale registration and missing-ledger controls.
