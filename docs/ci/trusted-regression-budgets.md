# Trusted regression deadlines

Trusted setup and cleanup finish within finite host-owned budgets. A failed setup prints its phase
and exits nonzero without claiming that a scene ran. GNU coreutils `timeout` is required on the
host; hosted Ubuntu supplies it, and macOS developers can install coreutils through Homebrew.

| Phase | Budget | Purpose |
| --- | --- | --- |
| Runtime build and base-image pull | 15 minutes | Build the reviewed image around the verified engine. |
| Host import-cache validator build | 15 minutes | Compile the reviewed validator with the host Go toolchain. |
| Image identity inspection | 30 seconds | Require an exact local digest before candidate execution. |
| Editor import | 10 minutes | Build disposable import state and the class-name cache. |
| Sandbox execution | 180 seconds | Bound engine and isolation probes. |
| Owned container cleanup | 30 seconds total | Remove only privately recorded names and verify their absence. |
| Sandbox CI step | 45 minutes | Include setup, containment controls and every base-selected scene. |
| Client smoke CI job | 75 minutes | Include other client contracts and ordinary regression coverage. |

Each host phase forwards termination to its child process group, then allows five seconds before
forced termination. Controller cancellation forwards to its active child before cleaning private
state. Controllers check for child exit every 100 milliseconds, allowing the phase its full
five-second grace plus a one-second scheduling margin. They return earlier after an acknowledged
exit; this controller margin is separate from the 30-second container cleanup budget. Container names use an invocation-private random identifier, recorded outside every mounted
candidate directory. A parent cleans those records after a child exits, including when the existing
scene watchdog kills the child. Cleanup uses bounded Docker calls and an exact-name absence query;
unknown cleanup fails the invocation and retains its private records. It never enumerates or removes
another invocation's resources.

The existing scene verdict runner still uses its 180-second watchdog and requires a positive
`TEST PASS` marker with no failure marker or engine error. Trusted scene selection, historical
fixtures, read-only mounts, non-root execution, credential exclusion and network isolation stay with
the reviewed controller. Setup budgets do not change which scenes run.

Host-owned `WAR_TRUSTED_BUILD_SECONDS`, `WAR_TRUSTED_INSPECT_SECONDS`,
`WAR_TRUSTED_IMPORT_SECONDS`, `WAR_TRUSTED_PROBE_SECONDS` and
`WAR_TRUSTED_TERMINATION_SECONDS` can shorten budgets for injected failure controls. Zero,
non-integer and larger-than-reviewed budgets fail before starting a command. Candidate engine
processes do not receive these settings.

The CI budgets provide headroom above successful sandbox runs of 18m30s and 18m56s, and complete
client jobs of 40m14s and 41m51s. Timing receipts are linked on [issue #1310](https://github.com/devantler-tech/world-at-ruin/issues/1310).
The real-container trial also holds an engine probe, requires timeout failure and verifies removal
before running every base-selected scene. Local injected controls additionally cover cancellation,
descendant retirement, preservation of unrelated work, invalid budgets and ordinary failure status.
