# ADR 0035 — Observe journals through the packaged Nakama candidate

Status: accepted for default-off candidate-reader evidence (#1293). Durable
writers, serving adoption, retained rollback compatibility and recovery remain
#793/#569 gates.

The inactive grant journal needs proof that the native candidate plugin can
read its complete private inventory through real Nakama storage. A source
fixture or substitute helper plugin cannot provide that proof.

The strict journal decoder and immutable binding live in a read-only leaf
package. The original gameserver-commit API wraps that same implementation,
preserving its sentinel errors and permanent historical fixture registration.
The new leaf retains a byte-identical schema fixture and its own reader ledger.
Production composition still rejects the authority-bearing gameserver-commit
and fence-reference packages; the guard has no exemption.

The ordinary candidate plugin invokes a startup probe before handoff
initialization. An absent or false runtime flag returns before dependencies or
subsettings are inspected. Explicit enablement takes a fixed independent
binding, performs a bounded read and logs only the complete observation hash
and grant count. Any unsuccessful, mismatched or canceled read reports no
partial inventory or provider diagnostic. No RPC or fixture writer is
registered.

The experimental native process suite seeds private journals directly in its
own fresh disposable databases. The actual built candidate binary and plugin
read complete inventories of zero, one and two grants. The suite binds every
scenario to architecture and artifact hashes and compares an independently
constructed full-observation fingerprint. Missing, stale, wrong-incarnation,
incomplete, malformed, future-schema, canceled and public-permission controls
remain unknown. Readback leaves object bytes, version and privacy unchanged
and makes no allocation request. Both native Linux architectures are required.

An explicit cancellation control exercises the same candidate's read error
path. It affects only the probe's child context and grants no authority. The
normal invocation leaves all probe flags absent. Existing generation and
lease compatibility scenarios remain required.

This evidence identifies the candidate reader; it does not identify a live
serving rollout or the actual retained rollback artifact. Those artifacts must
accept proposed documents before activation. Journal observations remain
detached diagnostics and cannot recreate capabilities or fence receipts,
reopen admission, drain owners, replay barriers or release quarantine.

References: [ADR 0032](0032-read-issued-grant-journals-without-restoring-authority.md),
[native acceptance](../../server/nakamaruntime/README.md#experimental-native-nakama-acceptance).
