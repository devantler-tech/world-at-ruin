# Disposable original-child process proof

This diagnostic experiment has no gameplay or serving caller. Build and run require
explicit opt-in; the image is never published. It provides the launch-time process
handle and per-message sender increment of #1345, separately from SPIRE roles and
claim custody. The policy and limits are in [ADR 0047](../adr/0047-prove-original-process-message-ownership.md).

On a native Linux Docker host, from the repository root:

```bash
docker build --build-arg EXPERIMENTAL=true \
  -f tools/owned-child-trial/Dockerfile -t war-owned-child:local .
bash tools/smoke-owned-child-native.sh war-owned-child:local --experimental
```

The wrapper first requires a missing-opt-in refusal with no helpers, then selects
the same narrow controller profile as the separate issuer trial: read-only root,
no network, a private non-executable tmpfs and only SETUID/SETGID/KILL. All helpers
have empty groups, UID/GID 10001, zero capabilities and inherited no-new-privileges.
Both native architecture jobs require every named process, retirement and cleanup
fault test. Source race tests, correctness lint and the actual test-executable
vulnerability graph remain separately required.

The original worker connects a private seqpacket socket. Each received diagnostic
frame is evaluated using its own SCM_CREDENTIALS and the retained launch pidfd.
Transferring that connected endpoint through SCM_RIGHTS or inheriting it into
another same-user process changes the per-message sender, while SO_PEERCRED still
names the original connection process. Refuse both replacement messages and require
another original positive. The isolated connection-only comparison accepts those
same two packets; it cannot alter the secured diagnostic counter.

Diagnostic retirement is permanent. It precedes stop signaling and follows observed
death, lost control or incomplete helper output. Stop sends TERM through the retained
pidfd, escalates to KILL after 300 ms and bounds the owned join to three seconds.
The resistant control checks its actual SIGKILL terminal state. One Cmd.Wait owns
reaping; a controller-owned output pipe survives that wait. Received descriptors
are closed even on a zero-data refusal. Failed joins retain process and containment
ownership; incomplete output stays a failed verdict across repeated cleanup calls.

The missing-capture fault removes the descriptor from the controller interface
before any effects; the test retains the real descriptor through join. The helper
must then exit normally through input EOF. This tests fail-closed cleanup without
claiming an unsupported-kernel launch happened natively.

An observed live pidfd followed by a counter increment is a local authorization
point; physical death can race that point. This does not prove executable continuity,
raw-fork resistance, prevention of in-process proxying, original allocation/claim
authority or rollback-resistant custody. Those remain #1345/#1346/#1341. The
experiment retirement decision belongs to #1192, due for review by 2026-11-12.
