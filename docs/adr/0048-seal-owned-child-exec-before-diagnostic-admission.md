# Seal owned-child exec before diagnostic admission

Status: Accepted for the default-off disposable experiment; gameplay authority unproven.

## Problem

A process handle survives exec. Exact message credentials and a live handle alone
cannot establish continuity of the trusted startup executable. Issue #1361 requires
a process-wide seal, including threads created through Go's runtime template.

## Decision

Install an additional native seccomp filter in the owned worker under observed
no-new-privileges. Keep the inherited container filter. Deny execve and execveat
with EPERM, reject foreign audit architectures, and reject amd64 x32 numbers.
Only the complete raw TSYNC result `(0, 0)` opens diagnostic admission. A positive
failing-thread ID or syscall error permanently refuses it. The controller remains
unsealed so it can launch and clean up its explicitly owned helpers.

Establish the Go template via LockOSThread before installation. Retain distinct
locked threads, record all task IDs before installation and immediately after
successful synchronization, then retain further locked threads until one ID is
absent from both snapshots. Bound that search by thread count and deadline.
Call both exec syscalls directly on existing and proven future threads. A fixed
static marker executable and pre-opened executable descriptor provide successful
unsealed and deliberately unsynchronized controls in fresh owned processes.

## Evidence and protected floors

Both native architecture jobs require synchronized denial, successful control
exec, positive-TID divergence refusal, syscall-error refusal and a real native
architecture-policy mismatch. Policy-table tests are separate from native calls.
Actual foreign-ABI execution remains unproved without a compatible helper; equal
inherited x32 refusals cannot attribute denial to the additional filter.

Retain the existing offline, read-only, capability-restricted containment, default
non-root user, missing-opt-in refusal, launch-time pidfd, sole terminal join,
TERM/KILL deadlines, unrelated canary and verified container removal. No serving
image, gameplay call or player data is changed.

## Limits

Trusted startup reporting is not independent validation of a dishonest worker.
Exec denial does not make in-process code immutable, prevent raw fork or proxying,
establish original claim custody or make effects atomic with physical death.
Those remain #1345/#1346/#1341. The experiment's adoption/removal decision remains
#1192, due for review by 2026-11-12.

Contracts: [Linux synchronization and filter attachment](https://github.com/torvalds/linux/blob/v6.8/kernel/seccomp.c),
[Go template-thread establishment](https://github.com/golang/go/blob/go1.27.2/src/runtime/proc.go),
[execveat descriptor semantics](https://github.com/mkerrisk/man-pages/blob/master/man2/execveat.2).
