# 0017: Retain authenticated update floors at locked acceptance

Status: Accepted

The opt-in installed-client check admits an eligible update only after writing and reading back
its authenticated history. The history lives separately from character, progression and recovery
data at `user://update_history.json`; `WAR_UPDATE_HISTORY_PATH` is an installation-owned test seam.
Boot tests redirect all four stores and suppress ambient networking before loading the game.
The feature remains disabled unless `WAR_UPDATE_CHECK=1` and explicit trust configuration is present.

Version 1 stores the installation stream scope, accepted key epoch, per-epoch manifest sequence,
revocation floor and canonical UTC observation time. Its 4 KiB bounded canonical document uses
exact nonnegative counters no larger than 2^53 - 1. The historical fixture and append-only reader
ledger pin the format. Corrupt, future, oversized or mismatched state is preserved and latches
read-only for the process, including after that file disappears. Missing history starts at zero.
Case aliases of player stores and trust configuration, locks, private stage names, directories and
paths with linked ancestors are refused; exhausting the ancestry inspection also refuses the path.

Scope binds the normalized installation root, channel and independent revocation-head URL. Moving
the manifest mirror preserves that scope. Every admission requires a root-certified signing key;
there is no unsigned or legacy-key fallback after restart. A higher certified epoch starts a new
sequence line while revocation and time remain monotonic. The retained revocation floor is the
maximum authenticated list version and independent head floor. An unchanged list above an older
head floor remains eligible; a replayed list below retained knowledge does not. Verification uses
the latest of the checker's verified observation, the current acceptance clock and retained accepted
time. A rollback during the verification-to-history handoff cannot erase an authenticated observation,
and a clock advance still refuses evidence expired at acceptance. Refused or incompatible candidates
advance none of these facts.

Network work finishes before the history lock is acquired. The acceptance path reloads current
history under that lock and re-verifies the entire signed chain before staging. It compares the
bounded destination identity and lock ownership immediately before rename, rechecks the private
stage and reads back the replacement before returning trusted advice. Pre-rename refusal preserves
the destination. A failed readback after rename reports refusal without promising rollback. These
are cooperative-lock and readback visibility guarantees; they are not an OS-atomic compare-and-swap
against noncooperating writers or proof of survival through power loss.

The native proof authenticates loopback HTTPS using ephemeral keys, observes committed history
from Go and starts fresh Godot processes to exercise retained revocation knowledge. Native fixtures
also cover schema refusal, epoch and sequence replay, clock rollback, foreign replacement, lost
ownership and changed private stages. The ten-second checker budget covers network and signature
verification; the bounded locked history transaction follows it. This advisory feature does not
download or mount executable content. Production configuration and immutable startup recovery
remain #1114 work.
