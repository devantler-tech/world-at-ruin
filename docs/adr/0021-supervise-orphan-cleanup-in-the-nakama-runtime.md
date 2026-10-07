# Supervise orphan cleanup in the Nakama runtime

Status: accepted for the default-off source runtime, part of #4.

## Decision

The enabled handoff module may additionally opt into orphan reconciliation with
WAR_HANDOFF_ORPHANS_ENABLED. Its scope is the existing validated namespace and
Fleet, and its dependencies are the module's namespaced GameServer API and
private lease store. The flag is false by default and unused orphan settings
are not read. Grace, interval, deadline and page budget are bounded before
credentials or transports are acquired.

The worker starts only after public RPC, optional private listener and shutdown
registration succeed. It sweeps at startup and then serially on its cadence.
Complete GameServer enumeration precedes a complete private lease scan. Every
stored attempt protects its resources regardless of expiry or lifecycle state;
uncertain, malformed or partial evidence permits no deletion. Repeated absence
plus grace leads to a fresh identity/state check and UID/resource-version-pinned
delete. Errors reset unsafe observation history and recovery continues on the
next sweep. Each process begins with fresh observation history.

Shutdown cancels admission and both reconcilers. Transport retirement occurs
only after both workers and admitted handlers actually return. An exhausted
shutdown deadline ends the hook's wait, but does not close a transport underneath
an in-flight operation: completion of the drain retires it exactly once.
Nakama receives only aggregate counts and a closed sanitized outcome vocabulary.

## Boundaries

This composition does not infer allocator fencing or irreversible session
termination from Kubernetes observations. An extant lease remains protected,
and the existing coordinator owns expiry and releasing-barrier recovery. There
are no schema, writer capability, credential or RBAC changes. No deployment is
activated by this source change. Actual runtime artifact compatibility, cluster
rollout/readback and flag retirement are separate acceptance under #4 and #1177.
