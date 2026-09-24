package nakamalease

import (
	"context"
	"errors"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

// SessionFence identifies one claimed allocation lifetime, not one socket.
// Generation is its persisted claim stamp. This descriptor is not authority:
// only a trusted caller that has independently proved session end may use it.
type SessionFence struct {
	LeaseObjectID string
	LeaseVersion  string
	AttemptDigest string
	AllocationID  string
	GameServerUID string
	Generation    time.Time
}

// EndSession fences an exact claimed session before external resource cleanup.
// Capture the fence at admission, never by looking up a newer claim in response
// to an old completion. Socket loss and elapsed time do not prove session end.
// The callback must honor its context and idempotently delete only the pinned
// allocation UID. Failed cleanup retains the existing releasing representation
// for ReclaimExpired; an old claim receipt cannot resume a releasing record.
func (s *Store) EndSession(ctx context.Context, fence SessionFence, reclaim func(context.Context, Lease) error) error {
	if !validSessionFence(fence) || reclaim == nil {
		return ErrConflict
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	current, err := s.LoadForClaim(ctx, fence.LeaseObjectID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if current.Lease.Releasing {
		return ErrReleasing
	}
	if !sessionMatches(current, fence) {
		return ErrConflict
	}
	ending := current.Lease
	ending.ClaimedAt = time.Time{}
	ending.Releasing = true
	_, writeErr := s.writeKey(ctx, fence.LeaseObjectID, ending, current.Version)
	if err := ctx.Err(); err != nil {
		return err
	}
	// Always verify the durable barrier, including malformed or lost write
	// acknowledgements. Never repeat a write against a freshly adopted version.
	barrier, err := s.LoadForClaim(ctx, fence.LeaseObjectID)
	if err != nil {
		return nakamastorage.SanitizeError(ctx, err, ErrStorage)
	}
	if barrier.Lease != ending {
		if writeErr != nil {
			return writeErr
		}
		return ErrConflict
	}
	if err := reclaim(ctx, barrier.Lease); err != nil {
		return nakamastorage.SanitizeError(ctx, err, ErrStorage)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.deleteEndedSession(ctx, fence.LeaseObjectID, barrier)
}

func validSessionFence(fence SessionFence) bool {
	return fence.LeaseVersion != "" && fence.LeaseVersion != "*" && len(fence.LeaseVersion) <= 1024 &&
		handoffidentity.Fingerprint(fence.AttemptDigest) &&
		handoffidentity.CorrelationID(fence.AllocationID) &&
		handoffidentity.GameServerUID(fence.GameServerUID) && fence.GameServerUID != "." && fence.GameServerUID != ".." &&
		!fence.Generation.IsZero() && fence.Generation.UnixNano() > 0
}

func sessionMatches(current Record, fence SessionFence) bool {
	digest, err := agones.CorrelationLabel(current.Lease.AttemptID)
	return err == nil && current.Version == fence.LeaseVersion &&
		!current.Lease.Staging && !current.Lease.ClaimedAt.IsZero() &&
		current.Lease.ClaimedAt.Equal(fence.Generation) && digest == fence.AttemptDigest &&
		current.Lease.AllocationID == fence.AllocationID &&
		admissionref.ReferenceBinds(current.Lease.SecretRef, fence.GameServerUID)
}

func (s *Store) deleteEndedSession(ctx context.Context, key string, barrier Record) error {
	err := s.storage.StorageDelete(ctx, []*runtime.StorageDelete{{
		Collection: Collection, Key: key, UserID: "", Version: barrier.Version,
	}})
	if cancellation := ctx.Err(); cancellation != nil {
		return cancellation
	}
	if err == nil {
		return nil
	}
	// A lost delete acknowledgement is read back once. A replacement never
	// inherits this completion, even if it reuses the same reservation key.
	latest, readErr := s.LoadForClaim(ctx, key)
	switch {
	case errors.Is(readErr, ErrNotFound):
		return nil
	case readErr != nil:
		return nakamastorage.SanitizeError(ctx, readErr, ErrStorage)
	case latest != barrier:
		return ErrConflict
	default:
		return ErrStorage
	}
}
