package nakamalease

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

// LoadForClaim reads one private lease through its non-secret allocation locator.
// Raw player and reservation IDs are neither needed nor returned. This lookup
// is routing only; the private claim service must independently authenticate it.
func (s *Store) LoadForClaim(ctx context.Context, key string) (Record, error) {
	decoded, err := hex.DecodeString(key)
	if err != nil || len(decoded) != 32 || strings.ToLower(key) != key {
		return Record{}, ErrStorage
	}
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: Collection, Key: key, UserID: ""}})
	if err != nil {
		return Record{}, nakamastorage.SanitizeError(ctx, err, ErrStorage)
	}
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	if len(objects) == 0 {
		return Record{}, ErrNotFound
	}
	if len(objects) != 1 {
		return Record{}, ErrStorage
	}
	object := objects[0]
	if !validListedObject(object) || object.GetKey() != key || object.GetVersion() == "*" || len(object.GetVersion()) > 1024 || !unambiguousLeaseObject(object.GetValue()) {
		return Record{}, ErrStorage
	}
	lease, err := leaseFrom(object.GetValue(), "", "")
	if err != nil {
		return Record{}, ErrStorage
	}
	return Record{Lease: lease, Version: object.GetVersion()}, nil
}

// ClaimByKey conditionally admits the exact record independently verified by the
// private service. The existing schema and Claim/BeginRelease version race are
// preserved. A lost acknowledgement is read back once, never blindly rewritten;
// cancellation refuses admission without undoing a possibly committed claim.
func (s *Store) ClaimByKey(ctx context.Context, key string, current Record, at time.Time) (Record, error) {
	if current.Version == "" || current.Version == "*" || current.Lease.UserID != "" || current.Lease.ReservationID != "" {
		return Record{}, ErrConflict
	}
	if at.IsZero() || at.UnixNano() <= 0 || !at.Before(current.Lease.ExpiresAt) {
		return Record{}, ErrExpired
	}
	latest, err := s.LoadForClaim(ctx, key)
	if err != nil {
		return Record{}, err
	}
	if matchingClaim(latest, current) {
		return latest, nil
	}
	if latest != current {
		return Record{}, ErrConflict
	}
	if current.Lease.Releasing {
		return Record{}, ErrReleasing
	}
	if current.Lease.Staging {
		return Record{}, ErrStaging
	}
	claimed := current.Lease
	claimed.ClaimedAt = time.Unix(0, at.UnixNano()).UTC()
	written, err := s.writeKey(ctx, key, claimed, current.Version)
	if cancellation := ctx.Err(); cancellation != nil {
		return Record{}, cancellation
	}
	if err == nil {
		return written, nil
	}
	// Both a rejected CAS and a lost success response can mean this exact
	// allocation was claimed by another call. A changed allocation never can.
	latest, readErr := s.LoadForClaim(ctx, key)
	if readErr == nil && matchingClaim(latest, current) {
		return latest, nil
	}
	if errors.Is(err, ErrConflict) {
		return Record{}, ErrConflict
	}
	return Record{}, err
}

func matchingClaim(latest, expected Record) bool {
	if latest.Lease.ClaimedAt.IsZero() {
		return false
	}
	left, right := latest.Lease, expected.Lease
	left.ClaimedAt, right.ClaimedAt = time.Time{}, time.Time{}
	return left == right
}
