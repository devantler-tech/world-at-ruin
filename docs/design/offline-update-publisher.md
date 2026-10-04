# Prepare signed update documents

The experimental offline publisher prepares documents the client already knows how to
verify. It does not activate automatic updates or publish a release.

Build it with `go -C server build -o /tmp/updatepublisher ./cmd/updatepublisher`.
Every invocation requires `-experimental`. Supply public JSON through `-input` and a
new output path through `-output`; existing output is always preserved.

Use `-operation canonicalize` to reproduce the client's signing bytes.
Use `-operation issue -kind certificate|revocation|head` with `-private-key`
pointing to an owner-only offline-root PEM and an explicit `-observed-at` UTC timestamp.
The input is the corresponding existing schema, without a signature.
Certificate issuance accepts windows through 31 days; new heads expire within 24 hours.
Choose shorter budgets when the reviewed production policy requires them.

Use `-operation assemble` with the unsigned build manifest, signed `-certificate`,
`-revocation`, independently obtained `-head`, trusted `-root-public-key` and certified
leaf `-private-key`. The command verifies the chain before signing.
Use `-operation verify` with the signed manifest, independent head and trusted root
to check the exact signed output. Both operations require the explicit observation time.
Verification checks authenticity and freshness; it does not replace the client's
save, shell, protocol, channel and anti-replay decisions.

Generate test evidence with `GODOT_BIN=godot bash tools/test-updatepublisher.sh`.
That command uses disposable test keys and runs the resulting command output through
the actual native client verifier. Never reuse its test keys for production.

Root custody, leaf access, endpoint configuration, rotation state and immutable pack
recovery remain separate rollout work. See [the decision](../adr/0013-publish-update-signatures-with-offline-opt-in-tooling.md)
and the [distribution design](distribution-and-self-update.md).
