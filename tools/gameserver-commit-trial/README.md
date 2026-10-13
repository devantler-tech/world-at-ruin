# Exact GameServer commit trial

This optional storage trial supports **Darwin arm64 and Linux amd64**. Run from the
**repository root** with Go **1.27.2** (the server and trial module pin), `curl`, `tar`, and
`shasum`. Linux amd64 additionally needs `sha256sum` for the Helm archive check.
Race-enabled trial tests require cgo (`go -C tools/gameserver-commit-trial env CGO_ENABLED` must
print `1`) and GCC or Clang on Linux; see the [Go race-detector requirements](https://go.dev/doc/articles/race_detector#Requirements).
Darwin arm64 also needs Helm **v4.3.0** installed; Linux amd64 downloads and
verifies that Helm version. The runner downloads and verifies envtest **v1.37.0**, so allow
network access and local scratch space before starting.

Download the server modules first: rendering the Agones **v1.61.0** CRD reads the module cache.

```sh
go -C server mod download
bash tools/test-gameserver-commit.sh
```

Success means the tests report `PASS`, the command exits zero, and the runner reports
`Trial cleanup: verified retirement and removed private state`. Unsupported hosts, missing tools,
checksum failures, test failures, or unverified cleanup exit nonzero. Do not count a partial run as
a passing storage proof. `WAR_ENVTEST_ARCHIVE` can select an already downloaded archive; its
platform-specific SHA-512 is still verified before execution.

The runner creates private scratch storage, renders the declared Agones CRD and
starts only local kube-apiserver/etcd. It never loads a kubeconfig or contacts a
platform cluster. Normal completion stops both processes and removes scratch
files. The runner also retires its exact owned control-plane binaries after a
panic, timeout or interruption before deleting their private state. Missing
assets and failed storage proof fail the test; there is no skip
or fake-client substitute.

See [ADR 0028](../../docs/adr/0028-fence-an-inactive-exact-version-gameserver-mutation.md)
for receipt scope and the production activation gates. The test deliberately
demonstrates that already submitted requests can commit after caller cancellation.
The single-resource receipt applies to one immutable capability. The generation
trial freezes its complete issued set before networking and requires every exact
storage barrier before accepting a complete process-local receipt. It exercises
multiple outstanding writes, mixed allocation outcomes, replacements, missing
resources, changed histories and a lost barrier acknowledgement.

[ADR 0031](../../docs/adr/0031-close-the-complete-issued-gameserver-capability-set.md)
defines that owner's scope. No receipt proves exclusive production writers,
survives an incarnation restart or releases durable quarantine.

The journal-reader arms round-trip exact native grant metadata through the
shared Nakama storage fake and a freshly constructed read-only reader. Unfenced
held writes still allocate after that readback; actual barriers make both old
writes conflict. A fresh owner rejects the previous owner's receipt. Wrong
incarnation, stale journal version and incomplete expected-set controls return
no inventory. This proves source-reader behavior, not a serving Nakama rollout,
actual retained rollback-artifact compatibility or durable journal writes. See
[ADR 0032](../../docs/adr/0032-read-issued-grant-journals-without-restoring-authority.md).
