# Exact GameServer commit trial

Run `tools/test-gameserver-commit.sh` from any directory. Darwin arm64 requires
Helm v4.3.0; Linux amd64 downloads and verifies that version. Go follows the
server and trial module pins. `WAR_ENVTEST_ARCHIVE` can select an already downloaded
archive; its platform-specific SHA-512 is still verified before execution.

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
