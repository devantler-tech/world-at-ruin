# Disposable original-child process proof

This diagnostic experiment has no gameplay or serving caller. Build and run require
explicit opt-in; the image is never published. It provides the launch-time process
handle and per-message sender increment of #1345, separately from SPIRE roles and
claim custody. The process policy is in [ADR 0047](../adr/0047-prove-original-process-message-ownership.md);
trusted startup exec sealing is in [ADR 0048](../adr/0048-seal-owned-child-exec-before-diagnostic-admission.md);
raw fork descendants are in [ADR 0049](../adr/0049-prove-fork-descendant-message-exclusion.md).

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
fault test, plus the native exec, architecture-policy mismatch, ABI-reporting and
separate filter-table tests. Source race tests, correctness lint and the actual test-executable
vulnerability graph remain separately required.

Diagnostic admission starts closed. Trusted workers install an additional seccomp
filter under observed no-new-privileges before reporting readiness. Only raw TSYNC
return zero and errno zero admit effects; a positive failing-thread ID or syscall
error permanently refuses them. The controller is unsealed. Native execve and
execveat return EPERM after synchronized sealing. Foreign audit architectures kill
the process; the x32 namespace returns EACCES so added denial can be distinguished
from an inherited EPERM without broadening containment.

The controls retain actual preexisting locked threads and establish Go's template
thread before installation. They snapshot all task IDs before the syscall and
immediately afterward, then force a retained future thread absent from both sets,
within 32 additional threads and two seconds. Both exec syscalls use existing and
proven future threads. Each successful unsealed, unsynchronized, divergent-filter
or syscall-error control replaces its own process with a fixed static marker. The
execveat control uses a pre-opened executable and AT_EMPTY_PATH. Direct raw exec
is bounded disposable evidence, not a general Go exec/clone coordination API.

A separately retained thread attaches an allow-only divergent filter. Another
thread's actual TSYNC result must name that TID with errno zero, admit zero effects
and still allow the marker exec. A real native syscall with an intentionally wrong
architecture policy must terminate with SIGSYS. This is distinct from executing a
foreign ABI. The amd64 x32 probes use numbers 520 and 545 in the x32 namespace with
null arguments; changed denial can attribute the number filter, but never proves
successful compat executable support. Equal inherited/added results are reported
as unproved attribution. Actual foreign-ABI executable controls remain unproved on
both architectures without a compatible helper and verified runner support.

The original worker connects a private seqpacket socket. Each received diagnostic
frame is evaluated using its own SCM_CREDENTIALS and the retained launch pidfd.
Transferring that connected endpoint through SCM_RIGHTS or inheriting it into
another same-user process changes the per-message sender, while SO_PEERCRED still
names the original connection process. Refuse both replacement messages and require
another original positive. The isolated connection-only comparison accepts those
same two packets; it cannot alter the secured diagnostic counter.

The original also forks without exec while retaining three distinct OS threads.
The native assembly trampoline uses copied memory and CLONE_PIDFD|SIGCHLD, with
no shared memory, thread, vfork or namespace flags. It blocks catchable signals
and restores/readbacks the exact parent mask before returning to Go, including
the documented CLONE_PARENT_SETTID conflict's EINVAL control. Uncertain restoration
terminates the worker. Every child operation stays in raw assembly: opening its
own proc status, bounded read and EOF probe, nonblocking sendmsg with MSG_NOSIGNAL,
one atomic private-pipe record, and raw exit or a finite sleep (five seconds for
resistance/delay controls; thirty seconds for the separate orphan control).
Both built executable variants undergo a compiled assembly audit. Child COW
writes never constitute parent-visible evidence; only the launch-time kernel
pidfd store and the complete private record are consumed by the original.

The real fork packet has its own TGID, matching unprivileged identities, empty
groups, zero effective/permitted/inheritable/ambient capabilities and NNP. Its
restricted bounding set matches the original. Diagnostic effects remain zero
for that packet while the connection-only comparison accepts the same packet;
the original and unrelated canary remain usable after cleanup. The original
alone consumes exact waitid(P_PIDFD, WEXITED|WNOHANG), requiring the captured
child's PID/UID and terminal code/status before retiring its pidfd. Repeated
cleanup retains the same terminal result. A TERM-resistant child must require
actual SIGKILL. Native EPIPE/EBADF, incomplete status/record, delayed-child cleanup,
missing-capture and uncertain-wait interface faults cannot count as proof.

Parent death is intentionally outside the passing cleanup suite. A separate
container invocation kills the original before its raw descendant joins. The
controller deliberately pauses before killing the original, so the orphan hold
must outlast delayed progress as well as the original-death and reader deadlines.
original's Cmd.Wait completes, but descendant join remains unproved and the
verdict must fail with containment retained. The wrapper requires that precise
nonzero refusal and verifies container removal before reporting its own success.

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
point; physical death can race that point. Trusted startup exec denial does not
prove immutable in-process code, independent validation of a dishonest sealing
report, prevention of fork or in-process proxying, original allocation/claim
authority or rollback-resistant custody. Those remain #1345/#1346/#1341. The
experiment retirement decision belongs to #1192, due for review by 2026-11-12.
