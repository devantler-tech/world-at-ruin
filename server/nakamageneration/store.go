// Package nakamageneration persists immutable allocator-generation membership.
// An open record alone never authorizes dispatch or clears a quarantine.
package nakamageneration

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Collection holds private allocator-generation records under the system owner.
const (
	Collection       = "world_at_ruin_allocator_generations"
	reconcileTimeout = 5 * time.Second
)

var (
	// ErrInvalidArgument reports an invalid generation identity or member set.
	ErrInvalidArgument = errors.New("nakama generation: invalid argument")
	// ErrNotFound reports an absent generation during a standalone read.
	ErrNotFound = errors.New("nakama generation: not found")
	// ErrStorage reports unreadable or invalid durable state without exposing it.
	ErrStorage = errors.New("nakama generation: storage unavailable or invalid")
	// ErrConflict reports generation-ID reuse with different durable membership.
	ErrConflict = errors.New("nakama generation: conflicting membership")
	// ErrIndeterminate means a dispatched create could not be resolved; retry
	// the same generation ID and membership, never substitute a new identity.
	ErrIndeterminate = errors.New("nakama generation: create outcome indeterminate")
)

// Record contains the complete schema-1 generation and its exact storage version.
// MemberPodUIDs is owned by the caller; mutating it cannot change durable state.
type Record struct {
	GenerationID    string
	MemberPodUIDs   []string
	MemberSetDigest string
	State           string
	Version         string
}

// Store creates and reads generation membership; it has no overwrite/delete API.
type Store struct{ storage nakamastorage.Client }

// NewStore builds a generation store over Nakama's authoritative storage API.
func NewStore(storage nakamastorage.Client) (*Store, error) {
	if storage == nil {
		return nil, ErrInvalidArgument
	}
	return &Store{storage: storage}, nil
}

// CreateOpen persists immutable membership or adopts an identical durable replay.
func (s *Store) CreateOpen(ctx context.Context, generationID string, memberPodUIDs []string) (Record, error) {
	want, err := openDocument(generationID, memberPodUIDs)
	if err != nil {
		return Record{}, err
	}
	value, err := json.Marshal(want)
	if err != nil || len(value) > maxDocumentBytes {
		return Record{}, ErrInvalidArgument
	}
	existing, err := s.Load(ctx, generationID)
	if err == nil {
		return adopt(existing, want)
	}
	if !errors.Is(err, ErrNotFound) {
		return Record{}, err
	}
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	acks, writeErr := s.storage.StorageWrite(ctx, []*runtime.StorageWrite{{
		Collection: Collection, Key: generationID, UserID: "", Value: string(value),
		Version: "*", PermissionRead: 0, PermissionWrite: 0,
	}})
	if writeErr == nil && validAcknowledgement(acks, generationID) {
		return want.record(acks[0].GetVersion()), nil
	}
	// Once StorageWrite is entered, a lost or malformed acknowledgement cannot
	// establish absence. Read the immutable identity with an independent bound.
	reconcileCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), reconcileTimeout)
	defer cancel()
	existing, err = s.Load(reconcileCtx, generationID)
	if err != nil {
		return Record{}, errors.Join(ErrIndeterminate, nakamastorage.ContextError(ctx, writeErr))
	}
	return adopt(existing, want)
}

// Load returns the private, validated generation at its exact durable version.
func (s *Store) Load(ctx context.Context, generationID string) (Record, error) {
	if !validIdentity(generationID, maxIdentityBytes) {
		return Record{}, ErrInvalidArgument
	}
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	object, err := nakamastorage.ReadSystemOwned(ctx, s.storage, Collection, generationID)
	if cancellation := ctx.Err(); cancellation != nil {
		return Record{}, cancellation
	}
	if err != nil {
		if errors.Is(err, nakamastorage.ErrObjectMissing) {
			return Record{}, ErrNotFound
		}
		return Record{}, nakamastorage.SanitizeError(ctx, err, ErrStorage)
	}
	if !validVersion(object.GetVersion()) {
		return Record{}, ErrStorage
	}
	document, err := decodeDocument(object.GetValue())
	if err != nil || document.GenerationID != generationID {
		return Record{}, ErrStorage
	}
	return document.record(object.GetVersion()), nil
}

// adopt distinguishes an immutable replay from reuse of a generation identity.
func adopt(existing Record, want document) (Record, error) {
	if existing.GenerationID != want.GenerationID || existing.State != want.State ||
		existing.MemberSetDigest != want.MemberSetDigest || !slices.Equal(existing.MemberPodUIDs, want.MemberPodUIDs) {
		return Record{}, ErrConflict
	}
	return existing, nil
}

// validAcknowledgement requires the exact private write identity and a usable version.
func validAcknowledgement(acks []*api.StorageObjectAck, generationID string) bool {
	return len(acks) == 1 && acks[0] != nil && acks[0].GetCollection() == Collection &&
		acks[0].GetKey() == generationID && acks[0].GetUserId() == nakamastorage.SystemOwnerID &&
		validVersion(acks[0].GetVersion())
}

// validVersion refuses wildcard, empty, ambiguous and unbounded storage tokens.
func validVersion(version string) bool {
	return version != "*" && validIdentity(version, 1024)
}
