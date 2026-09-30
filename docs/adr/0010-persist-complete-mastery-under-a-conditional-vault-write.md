# Persist complete mastery under a conditional vault write

Date: 2026-09-30

Status: Accepted

## Context

Mastery includes banked and unbanked points plus one standing bloodstain. Reclaim
moves points out of that stain into weapon tracks. Combining concurrent snapshots
by maximum or union can duplicate points or restore an already consumed stain.
The retained immutable v0.93.1 whole app reads vault v5 and preserves the exact
integer boundaries while writing unrelated progress. Its reproduction evidence
is in `docs/evidence/issue-658-mastery-retention/`.

## Decision

Observe complete ledger transitions after award, death, or reclaim. Restore and
no-op operations emit no transition. Save the complete snapshot synchronously
through the existing cross-process vault lock and guarded replacement path.

Compare the on-disk mastery with the exact mastery snapshot acknowledged by this
session. Capture the complete vault's byte identity before loading the latest
document, preserve its unrelated fields, and pass that identity to guarded
replacement. An absent mastery observation is an expectation, never permission
to overwrite another session's snapshot.

Temporary storage refusal coalesces pending transitions and retries after 1, 2,
4, 8, 16, then at most 30 seconds. Successful persistence resets the delay. A
different mastery snapshot permanently fences this session's writer and tells
the player to reopen the client. A clean exit makes one final attempt; completed
transitions must survive abrupt process termination without relying on exit.
An encoded document above the vault's read ceiling is a permanent refusal,
not temporary storage trouble; it leaves the accepted save readable and intact.

Only a real mastery mutation originates vault v5. Older unrelated writes keep
their historical schema until their document actually carries newer state.
Publish write capability 7 and append it to the permanent capability ledger.

## Consequences

The writer preserves every shipped snapshot and opaque future weapon ID.
Transient storage failure can still leave pending session-only progress; the HUD
reports that limitation. Conflicting sessions do not silently rebase economic
state. The byte comparison detects foreign edits before rename but does not
provide an operating-system lock against non-cooperating writers across the
rename syscall.

Combat award sources and interactive death/reclaim flows remain separate work.
This decision delivers persistence for ledger mutations, not a playable combat
progression loop. No production gameplay caller invokes these economic mutations.
Before one does, authoritative source identities and atomic state-plus-audit
writes must satisfy [#926](https://github.com/devantler-tech/world-at-ruin/issues/926).
The local snapshot writer does not provide that economic audit trail.
