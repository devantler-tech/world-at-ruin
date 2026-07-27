// Package nakamalease persists allocation lease ownership through Nakama's
// storage engine.
package nakamalease

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// Collection is the private Nakama collection that owns handoff leases.
	Collection = "world_at_ruin_handoff_leases"

	schemaVersion = 1
)

var (
	// ErrNotFound means no lease exists for the user/reservation key.
	ErrNotFound = errors.New("nakama lease: not found")
	// ErrConflict means the lease changed since the caller observed it.
	ErrConflict = errors.New("nakama lease: version conflict")
	// ErrStaleAttempt means an operation does not own the observed lease.
	ErrStaleAttempt = errors.New("nakama lease: stale attempt")
	// ErrExpired means an unclaimed lease has reached its no-show deadline.
	ErrExpired = errors.New("nakama lease: expired")
	// ErrClaimed means a connected player already owns the allocation.
	ErrClaimed = errors.New("nakama lease: claimed")
	// ErrStorage means Nakama storage did not complete the requested operation.
	ErrStorage = errors.New("nakama lease: storage operation failed")
)

type storageClient interface {
	StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error)
	StorageWrite(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error)
	StorageDelete(context.Context, []*runtime.StorageDelete) error
}

// Lease is the durable ownership material for one allocation attempt. The raw
// user and reservation identifiers select the Nakama object but are not
// repeated inside its JSON value.
type Lease struct {
	UserID        string
	ReservationID string
	AttemptID     string
	AllocationID  string
	Observer      sim.EntityID
	SecretRef     string
	ExpiresAt     time.Time
	ClaimedAt     time.Time
}

// Record is a lease paired with the exact Nakama version that observed it.
type Record struct {
	Lease   Lease
	Version string
}

// State is the coordinator-relevant lifecycle of a lease record.
type State string

const (
	// StateUnclaimed can still be admitted before its no-show deadline.
	StateUnclaimed State = "unclaimed"
	// StateExpired reached its no-show deadline without admission.
	StateExpired State = "expired"
	// StateClaimed is owned by the player that completed zone admission.
	StateClaimed State = "claimed"
)

// State reports claim ownership before applying the no-show deadline.
func (r Record) State(now time.Time) State {
	if !r.Lease.ClaimedAt.IsZero() {
		return StateClaimed
	}
	if !now.Before(r.Lease.ExpiresAt) {
		return StateExpired
	}
	return StateUnclaimed
}

// Store persists handoff leases through the narrow storage surface implemented
// by Nakama's runtime module.
type Store struct {
	storage storageClient
}

// NewStore builds a lease store over Nakama runtime storage.
func NewStore(storage storageClient) (*Store, error) {
	if storage == nil {
		return nil, errors.New("nakama lease: storage is required")
	}
	return &Store{storage: storage}, nil
}

// Create writes a new private lease only when no object already owns the same
// user/reservation key.
func (s *Store) Create(ctx context.Context, lease Lease) (Record, error) {
	normalized, err := normalizeLease(lease)
	if err != nil {
		return Record{}, err
	}
	if !normalized.ClaimedAt.IsZero() {
		return Record{}, ErrClaimed
	}
	current, err := s.Load(ctx, normalized.UserID, normalized.ReservationID)
	switch {
	case err == nil && current.Lease == normalized:
		return current, nil
	case err == nil:
		return Record{}, ErrConflict
	case !errors.Is(err, ErrNotFound):
		return Record{}, err
	}

	return s.write(ctx, normalized, "*")
}

// Replace atomically transfers an observed lease key to a distinct attempt.
// A stale Record version cannot overwrite the current owner.
func (s *Store) Replace(
	ctx context.Context,
	current Record,
	next Lease,
) (Record, error) {
	observed, err := normalizeLease(current.Lease)
	if err != nil || current.Version == "" || current.Version == "*" {
		return Record{}, errors.New("nakama lease: invalid observed record")
	}
	normalized, err := normalizeLease(next)
	if err != nil {
		return Record{}, err
	}
	if !normalized.ClaimedAt.IsZero() {
		return Record{}, ErrClaimed
	}
	if observed.UserID != normalized.UserID ||
		observed.ReservationID != normalized.ReservationID {
		return Record{}, errors.New("nakama lease: replacement identity changed")
	}
	if observed.AttemptID == normalized.AttemptID {
		if observed != normalized {
			return Record{}, ErrConflict
		}
		latest, err := s.Load(ctx, observed.UserID, observed.ReservationID)
		if err != nil {
			return Record{}, err
		}
		if latest.Version != current.Version || latest.Lease != observed {
			return Record{}, ErrConflict
		}
		return latest, nil
	}
	if !observed.ClaimedAt.IsZero() {
		return Record{}, ErrClaimed
	}
	return s.write(ctx, normalized, current.Version)
}

// Claim marks an observed lease as admitted using an exact-version write.
func (s *Store) Claim(
	ctx context.Context,
	current Record,
	attemptID string,
	claimedAt time.Time,
) (Record, error) {
	observed, err := normalizeLease(current.Lease)
	if err != nil || current.Version == "" || current.Version == "*" {
		return Record{}, errors.New("nakama lease: invalid observed record")
	}
	if attemptID != observed.AttemptID {
		return Record{}, ErrStaleAttempt
	}
	if !observed.ClaimedAt.IsZero() {
		return current, nil
	}
	if claimedAt.IsZero() || claimedAt.UnixNano() <= 0 {
		return Record{}, errors.New("nakama lease: invalid claim time")
	}
	if !claimedAt.Before(observed.ExpiresAt) {
		return Record{}, ErrExpired
	}
	observed.ClaimedAt = claimedAt
	claimed, err := normalizeLease(observed)
	if err != nil {
		return Record{}, err
	}
	return s.write(ctx, claimed, current.Version)
}

// Release conditionally removes an unclaimed lease. Replaying a release after
// the record is gone is idempotent.
func (s *Store) Release(
	ctx context.Context,
	userID string,
	reservationID string,
	attemptID string,
) error {
	current, err := s.Load(ctx, userID, reservationID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if current.Lease.AttemptID != attemptID {
		return ErrStaleAttempt
	}
	if !current.Lease.ClaimedAt.IsZero() {
		return ErrClaimed
	}
	key := reservationKey(reservationID)
	err = s.storage.StorageDelete(ctx, []*runtime.StorageDelete{
		{
			Collection: Collection,
			Key:        key,
			UserID:     userID,
			Version:    current.Version,
		},
	})
	if errors.Is(err, runtime.ErrStorageRejectedVersion) {
		return ErrConflict
	}
	if err != nil {
		return ErrStorage
	}
	return nil
}

func (s *Store) write(
	ctx context.Context,
	lease Lease,
	version string,
) (Record, error) {
	value, err := json.Marshal(documentFrom(lease))
	if err != nil {
		return Record{}, errors.New("nakama lease: encode lease")
	}
	key := reservationKey(lease.ReservationID)
	acks, err := s.storage.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      Collection,
			Key:             key,
			UserID:          lease.UserID,
			Value:           string(value),
			Version:         version,
			PermissionRead:  0,
			PermissionWrite: 0,
		},
	})
	if errors.Is(err, runtime.ErrStorageRejectedVersion) {
		return Record{}, ErrConflict
	}
	if err != nil {
		return Record{}, ErrStorage
	}
	if len(acks) != 1 ||
		acks[0].GetCollection() != Collection ||
		acks[0].GetKey() != key ||
		acks[0].GetUserId() != lease.UserID ||
		acks[0].GetVersion() == "" {
		return Record{}, ErrStorage
	}
	return Record{
		Lease:   lease,
		Version: acks[0].GetVersion(),
	}, nil
}

// Load reads and strictly validates one private lease record.
func (s *Store) Load(
	ctx context.Context,
	userID string,
	reservationID string,
) (Record, error) {
	if !validUserID(userID) || !validOpaqueID(reservationID) {
		return Record{}, errors.New("nakama lease: invalid identity")
	}
	key := reservationKey(reservationID)
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: Collection,
			Key:        key,
			UserID:     userID,
		},
	})
	if err != nil {
		return Record{}, ErrStorage
	}
	if len(objects) == 0 {
		return Record{}, ErrNotFound
	}
	if len(objects) != 1 {
		return Record{}, ErrStorage
	}
	object := objects[0]
	if object.GetCollection() != Collection ||
		object.GetKey() != key ||
		object.GetUserId() != userID ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 {
		return Record{}, ErrStorage
	}
	lease, err := leaseFrom(object.GetValue(), userID, reservationID)
	if err != nil {
		return Record{}, err
	}
	return Record{
		Lease:   lease,
		Version: object.GetVersion(),
	}, nil
}

type document struct {
	Schema         int    `json:"schema"`
	AttemptID      string `json:"attempt_id"`
	AllocationID   string `json:"allocation_id"`
	Observer       uint64 `json:"observer"`
	SecretRef      string `json:"secret_ref"`
	ExpiresAtNanos int64  `json:"expires_at_nanos"`
	ClaimedAtNanos *int64 `json:"claimed_at_nanos"`
}

func documentFrom(lease Lease) document {
	var claimedAtNanos *int64
	if !lease.ClaimedAt.IsZero() {
		value := lease.ClaimedAt.UnixNano()
		claimedAtNanos = &value
	}
	return document{
		Schema:         schemaVersion,
		AttemptID:      lease.AttemptID,
		AllocationID:   lease.AllocationID,
		Observer:       uint64(lease.Observer),
		SecretRef:      lease.SecretRef,
		ExpiresAtNanos: lease.ExpiresAt.UnixNano(),
		ClaimedAtNanos: claimedAtNanos,
	}
}

func leaseFrom(value, userID, reservationID string) (Lease, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.DisallowUnknownFields()
	var stored document
	if err := decoder.Decode(&stored); err != nil {
		return Lease{}, errors.New("nakama lease: invalid stored lease")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Lease{}, errors.New("nakama lease: invalid stored lease")
	}
	if stored.Schema != schemaVersion ||
		stored.ExpiresAtNanos <= 0 ||
		(stored.ClaimedAtNanos != nil && *stored.ClaimedAtNanos <= 0) {
		return Lease{}, errors.New("nakama lease: invalid stored lease")
	}
	lease := Lease{
		UserID:        userID,
		ReservationID: reservationID,
		AttemptID:     stored.AttemptID,
		AllocationID:  stored.AllocationID,
		Observer:      sim.EntityID(stored.Observer),
		SecretRef:     stored.SecretRef,
		ExpiresAt:     time.Unix(0, stored.ExpiresAtNanos).UTC(),
	}
	if stored.ClaimedAtNanos != nil {
		lease.ClaimedAt = time.Unix(0, *stored.ClaimedAtNanos).UTC()
	}
	return normalizeLease(lease)
}

func normalizeLease(lease Lease) (Lease, error) {
	if !validUserID(lease.UserID) ||
		!validOpaqueID(lease.ReservationID) ||
		!validOpaqueID(lease.AttemptID) ||
		!validOpaqueID(lease.AllocationID) ||
		lease.Observer == 0 ||
		!validSecretRef(lease.SecretRef) ||
		lease.ExpiresAt.IsZero() ||
		lease.ExpiresAt.UnixNano() <= 0 {
		return Lease{}, errors.New("nakama lease: invalid lease")
	}
	lease.ExpiresAt = time.Unix(0, lease.ExpiresAt.UnixNano()).UTC()
	if !lease.ClaimedAt.IsZero() {
		lease.ClaimedAt = time.Unix(0, lease.ClaimedAt.UnixNano()).UTC()
		if lease.ClaimedAt.After(lease.ExpiresAt) {
			return Lease{}, errors.New("nakama lease: invalid lease")
		}
	}
	return lease, nil
}

func reservationKey(reservationID string) string {
	digest := sha256.Sum256([]byte(reservationID))
	return hex.EncodeToString(digest[:])
}

func validUserID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, char := range value {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdefABCDEF", char) {
				return false
			}
		}
	}
	return true
}

func validOpaqueID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') &&
			char != '-' &&
			char != '_' {
			return false
		}
	}
	return true
}

func validSecretRef(value string) bool {
	if value == "" || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !validSecretLabel(label) {
			return false
		}
	}
	return true
}

func validSecretLabel(value string) bool {
	if value == "" || len(value) > 63 ||
		value[0] == '-' || value[len(value)-1] == '-' {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < '0' || char > '9') &&
			char != '-' {
			return false
		}
	}
	return true
}
