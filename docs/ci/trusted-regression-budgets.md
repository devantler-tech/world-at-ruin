# Trusted regression deadlines

Trusted setup and cleanup finish within finite host-owned budgets. A failed setup prints its phase
and exits nonzero without claiming that a scene ran. GNU coreutils `timeout` is required on the
host; hosted Ubuntu supplies it, and macOS developers can install coreutils through Homebrew.
The phase launcher also uses GNU `env` (or Homebrew's `genv`) to restore normal INT/TERM
before exec without moving the child out of the owned process group.

| Phase | Budget | Purpose |
| --- | --- | --- |
| Runtime build and base-image pull | 15 minutes | Build the reviewed image around the verified engine. |
| Host import-cache validator build | 15 minutes | Compile the reviewed validator with the host Go toolchain. |
| Image identity inspection | 30 seconds | Require an exact local digest before candidate execution. |
| Editor import | 10 minutes | Build disposable import state and the class-name cache. |
| Sandbox execution | 180 seconds | Bound engine and isolation probes. |
| Owned container cleanup | 30 seconds total | Remove only privately recorded names and verify their absence. |
| Sandbox CI step | 45 minutes | Include setup, containment controls and every base-selected scene. |
| Ordinary client proof job | 75 minutes | Structural guards, ordinary regressions, interoperability and concurrent-save controls. |
| Ordinary client step | 45 minutes maximum | Own the step process group; existing inner import and scene deadlines also apply. |
| Trusted sandbox client proof job | 75 minutes | Independent checkout, verified engine and the complete sandbox step. |
| Stable Client smoke boot gate | 5 minutes | Require both successful, cleaned proofs of the event integration SHA. |

Each host phase forwards termination to its child process group, then polls the entire group every
100 milliseconds for up to five seconds. It returns earlier when the group is absent; resistant
descendants retain the full grace before forced termination. A complete process-state snapshot must
acknowledge terminal members after forced termination within two seconds. Unreadable, empty or
malformed inspection refuses cleanup and retains private state. Duplicate forwarded signals cannot
interrupt retirement of a scene's separate engine group. Caught no-op signal handlers preserve
normal signal behavior in newly launched children. Launches defer cancellation until their child handles are published, including watchdog
sleeps. A host-owned phase wrapper records the direct child verdict after join; timeout cannot
replace a refused cleanup verdict with an ordinary cancellation. Missing records and unexpected
signal termination retain ownership and fail the proof. Controller cancellation forwards to its active child before cleaning private
state. Controllers check for child exit every 100 milliseconds, allowing the phase its full
five-second grace, two-second observation allowance and a one-second scheduling margin. They retain
private state and return infrastructure failure when a child refuses cleanup or requires forced
supervisor termination. They return earlier after an acknowledged
exit; this controller margin is separate from the 30-second container cleanup budget. Container names use an invocation-private random identifier, recorded outside every mounted
candidate directory. A parent cleans those records after a child exits, including when the existing
scene watchdog kills the child. Cleanup uses bounded Docker calls and an exact-name absence query;
unknown cleanup fails the invocation and retains its private records. It never enumerates or removes
another invocation's resources.

The existing scene verdict runner still uses its 180-second watchdog and requires a positive
`TEST PASS` marker with no failure marker or engine error. Trusted scene selection, historical
fixtures, read-only mounts, non-root execution, credential exclusion and network isolation stay with
the reviewed controller. Setup budgets do not change which scenes run.

The two candidate proof jobs use separate checkouts and job-private save seams. Both participants
in each ordinary parallel-save pair share that same seam; their distinct resolved probes still
prove concurrent isolation. Every ordinary shell step has an outer group owner, and scene runners
retain their shorter two-second termination grace so nested cleanup finishes before the outer
five-second force limit. Host group ownership does not claim control of arbitrary processes that
escape into a separate session; candidate sandbox containment remains a separate proof.

Only each worker's final step removes its own save seam and publishes completion with the actual
checked-out integration SHA. The stable gate requires literal success and matching completion from
both workers. The required aggregate treats a skipped or otherwise unsuccessful stable gate as
failure. The independently required trusted workflow stays enforced.

Host-owned `WAR_TRUSTED_BUILD_SECONDS`, `WAR_TRUSTED_INSPECT_SECONDS`,
`WAR_TRUSTED_IMPORT_SECONDS`, `WAR_TRUSTED_PROBE_SECONDS` and
`WAR_TRUSTED_TERMINATION_SECONDS` can shorten budgets for injected failure controls. Zero,
non-integer and larger-than-reviewed budgets fail before starting a command. Candidate engine
processes do not receive these settings.

The candidate sandbox probe explicitly selects `WAR_TRUSTED_RUNTIME_FOOTPRINT=1`
to measure its already-built image. Other invocations default to no measurement;
unknown selections refuse startup. The repository-local Go diagnostic requests
only Docker's numeric logical layer size and streams one image export through
Go's best-speed gzip encoder. It retains no archive and publishes one complete
JSON record with the image configuration digest, logical layer bytes, raw Docker
archive bytes, compressed bytes, codec, Go version and measurement duration.
The configuration digest is not an archive digest or artifact provenance.
Both streams are capped at 2 GiB. The command's 25-second lifetime and one-second
process join margin fit within the existing 30-second inspection phase.
Partial or failed inspection/export, cancellation and overflow produce no report.
The same probe must still finish containment, every selected scene and cleanup.
These candidate-owned measurements grant no reusable executor admission or cached
verdict; #1397 retains producer authority, warm-use proof and storage/retention.

The CI budgets provide headroom above successful sandbox runs of 18m30s and 18m56s, and complete
client jobs of 40m14s and 41m51s. Timing receipts are linked on [issue #1310](https://github.com/devantler-tech/world-at-ruin/issues/1310).
The real-container trial also holds an engine probe, requires timeout failure and verifies removal
before running every base-selected scene. Local injected controls additionally cover cancellation,
descendant retirement, preservation of unrelated work, invalid budgets and ordinary failure status.
