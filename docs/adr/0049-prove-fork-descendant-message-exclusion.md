# Prove fork descendant message exclusion

Status: Accepted for the default-off disposable experiment; gameplay authority unproven.

## Decision

Issue #1362 requires an actual fork without exec from the multithreaded original
worker. Use one architecture-specific assembly trampoline with copied memory,
CLONE_PIDFD and SIGCHLD. Block catchable signals, capture the pidfd in the kernel's
parent slot and restore/read back the exact parent mask before returning to Go.
An uncertain mask restoration terminates the worker instead of resuming Go.

The child never calls Go or a library. It opens its own proc status, performs
bounded reads including an EOF probe, sends the fixed frame with MSG_DONTWAIT and
MSG_NOSIGNAL, writes one private nonblocking evidence record below PIPE_BUF, and
exits or sleeps for a fixed five seconds. All pointers and buffers are prepared
before clone. The private record, not copy-on-write memory, conveys child evidence.
The finite sleep permits a bounded pidfd-only TERM/KILL cleanup control.

The original alone consumes waitid(P_PIDFD, WEXITED|WNOHANG), validating exact
terminal PID, UID, code and status before closing the handle. Duplicate cleanup
returns its cached result. Missing capture, partial evidence, failed send and
uncertain join refuse the verdict. An original-parent death scenario runs in a
separate container and must refuse with containment retained until verified removal.

## Protected floors and limits

Both native architectures retain the existing profile, identities, groups, NNP,
capabilities, exec seal, original positives, unrelated canary and named-test gates.
Audit the compiled child branch: no calls, stack growth, exec or child return.
The process boundary rejects the fork frame while an isolated connection-only
comparison accepts that exact packet. It does not prevent fork or in-process
proxying, establish claim custody or prove independent gameplay authority.
Those remain #1345/#1346/#1341. Retirement remains #1192.

Contracts: [clone and pidfds](https://man7.org/linux/man-pages/man2/clone.2.html),
[exact terminal waits](https://man7.org/linux/man-pages/man2/wait.2.html),
[multithreaded Go fork constraints](https://github.com/golang/go/blob/go1.27.2/src/syscall/exec_linux.go).
