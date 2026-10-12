# Prove original process and message ownership

Status: Accepted for a default-off disposable experiment; gameplay authority unproven.

## Problem

An attested role can belong to more than one process. A PID string or connection
identity cannot establish that each message came from the original launched child.
Issue #1359 supplies the process/sender increment of #1345 before executable sealing
and original claim custody are composed.

## Decision

Keep a separate unpublished Linux diagnostic module and image. The trusted launch
captures `SysProcAttr.PidFD`; its explicit descriptor remains owned through stop
and the single `Cmd.Wait`. Signals use that descriptor. Missing capture refuses
control; closing the owned helper input may still permit a bounded natural join.
An unresolved join retains surrounding containment ownership without PID signaling.

Receive complete local `SOCK_SEQPACKET` frames with `SO_PASSCRED` enabled before
traffic. Require one valid kernel credential record, the exact launched PID/UID/GID,
the diagnostic frame and an observed live pidfd. Reject truncation, missing
credentials and unexpected rights; close every delivered descriptor before refusal.
Connection-time credentials are an intentionally isolated comparison only.

The explicitly selected root controller uses the existing SETUID/SETGID/KILL
profile. Helpers share UID/GID 10001, with empty supplementary groups, matching
real/effective/saved identities, no capabilities and inherited no-new-privileges.
The default image user remains non-root; missing opt-in starts no helper. Diagnostic
socket paths contain no secret state. Their traversable directory and connectable
socket provide transport only; no path or connection supplies sender authority.

Serialize diagnostic effects and irreversible retirement under one boundary lock.
Retire before stop and on observed death, unreadable handle, incomplete controller
output or connection loss. Require terminal `ProcessState` from the sole owned join
before closing the explicit descriptor. A signal exit can be a successful join.
The local authorization point is the locked live-handle check and counter increment;
it is not atomic with physical process death.

## Evidence and protected floors

Require native amd64 and arm64 results. The original child must increment twice;
actual transferred and inherited same-user socket senders must increment zero while
that child lives. The connection-only comparison must increment twice on those
same received packets, proving the refusal reaches the vulnerable boundary. Observe
the same connected socket inode and every sender's kernel status. Require malformed,
data/control truncation, unexpected-rights and missing-credential refusals.

Require natural death, observed SIGKILL of a TERM-resistant helper, connection loss,
queued-message refusal, duplicate stop, missing-capture cleanup, excess/malformed
output refusal and an unrelated canary. Both native jobs feed required CI; non-success
cannot become a skipped aggregate success. The actual tagged test graph is scanned.
The shared containment wrapper retains the issuer profile and fails an incomplete
verdict or unverified container absence. Ordinary gameplay, server/Nakama graphs,
production images and player data remain intact; no production activation follows.

## Limits and follow-up

A pidfd identifies a process lifetime, not an immutable executable. Executable
sealing, raw fork without exec, TSYNC and gameplay admission remain #1345.
In-process code and the original child's proxying remain outside this proof.
The same-user inherited replacement is a distinct exec-launched process; it is
not a raw-fork control. PID reuse protection follows the kernel handle contract;
this experiment does not claim to exercise actual PID reuse.

SPIRE role identity and original claim/custody composition remain #1346; independent
monotonic witness authority remains #1341. Production completion stays #1318/#567.
Remove the disposable build/run gates and tooling through #1192 after separately
reviewed adoption, with a decision review due by 2026-11-12.

Contracts: [Go descriptor ownership](https://github.com/golang/go/blob/go1.27.2/src/os/pidfd_linux.go),
[launch capture](https://github.com/golang/go/blob/go1.27.2/src/syscall/exec_linux.go),
[Linux UNIX messages](https://github.com/mkerrisk/man-pages/blob/master/man7/unix.7),
[pidfd lifetime](https://github.com/mkerrisk/man-pages/blob/master/man2/pidfd_open.2).
