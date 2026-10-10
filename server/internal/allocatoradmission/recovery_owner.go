package allocatoradmission

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
	"sync/atomic"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

const RecoveryOwnerCollection = "world_at_ruin_allocator_recovery_owners"

type RecoveryStorage interface {
	Storage
	allocatorjournal.JournalStorage
}

// RecoveryOwnerConfig contains independently retained original handoff pins.
// An owner ID is a correlation value, never a credential or a resume token.
type RecoveryOwnerConfig struct {
	Enabled        bool
	Storage        RecoveryStorage
	Binding        allocatorjournal.JournalBinding
	HandoffVersion string
	OwnerID        string
}

// RecoveryOwner copies share one local attempt. Even an unsuccessful read
// consumes that attempt; another process must still create the same durable row.
type RecoveryOwner struct{ state *recoveryOwnerState }
type recoveryOwnerState struct {
	cfg              RecoveryOwnerConfig
	attempted        atomic.Bool
	accepted         atomic.Pointer[RecoveryOwnerObservation]
	recoveryConsumed atomic.Bool
}

// RecoveryReservation requires the originating live process's complete ACK.
// Diagnostic readback cannot reconstruct it or authorize GameServer writes.
type RecoveryReservation struct {
	owner       *recoveryOwnerState
	observation *RecoveryOwnerObservation
}

type RecoveryOwnerObservation struct {
	OwnerID        string
	Version        string
	HandoffVersion string
	Handoff        Observation
}

// RecoveryOwnerKey arbitrates the generation, independent of all incarnations,
// owner IDs, handoff versions and digests. There is no replacement or takeover.
func RecoveryOwnerKey(generationID string) string {
	value, _ := json.Marshal(generationID)
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-recovery-owner-key/v1\n"), value...))
	return hex.EncodeToString(digest[:])
}

func NewRecoveryOwner(cfg RecoveryOwnerConfig) (*RecoveryOwner, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if isNil(cfg.Storage) || !validVersion(cfg.Binding.Version) || !validVersion(cfg.HandoffVersion) || !handoffidentity.OpaqueUTF8(cfg.OwnerID, 128) {
		return nil, ErrClosed
	}
	cfg.Binding.MemberPodUIDs = slices.Clone(cfg.Binding.MemberPodUIDs)
	return &RecoveryOwner{state: &recoveryOwnerState{cfg: cfg}}, nil
}

// Reserve verifies the complete pinned drain before one private create-only
// write. Read and write share a single deadline. A lost reply leaves a permanent
// exclusion row but no usable reservation, even for the same owner ID.
func (o *RecoveryOwner) Reserve(ctx context.Context) (RecoveryReservation, error) {
	if o == nil || o.state == nil || !o.state.attempted.CompareAndSwap(false, true) {
		return RecoveryReservation{}, ErrClosed
	}
	ctx, cancel := context.WithTimeout(ctx, handoffRequestLimit)
	defer cancel()
	cfg := o.state.cfg
	handoff, err := ReadHandoff(ctx, HandoffReadConfig{Enabled: true, Storage: cfg.Storage, Binding: cfg.Binding, Version: cfg.HandoffVersion})
	if err != nil {
		return RecoveryReservation{}, unknown(ctx, err)
	}
	got := RecoveryOwnerObservation{OwnerID: cfg.OwnerID, HandoffVersion: cfg.HandoffVersion, Handoff: handoff}
	value, err := EncodeRecoveryOwner(got)
	if err != nil || ctx.Err() != nil {
		return RecoveryReservation{}, unknown(ctx, err)
	}
	key := RecoveryOwnerKey(cfg.Binding.GenerationID)
	acks, err := cfg.Storage.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: RecoveryOwnerCollection, Key: key, UserID: "", Value: value, Version: "*", PermissionRead: 0, PermissionWrite: 0}})
	if err != nil || ctx.Err() != nil || len(acks) != 1 || acks[0] == nil || acks[0].GetCollection() != RecoveryOwnerCollection || acks[0].GetKey() != key || acks[0].GetUserId() != nakamastorage.SystemOwnerID || !validVersion(acks[0].GetVersion()) {
		return RecoveryReservation{}, unknown(ctx, err)
	}
	got.Version = acks[0].GetVersion()
	o.state.accepted.Store(&got)
	return RecoveryReservation{owner: o.state, observation: &got}, nil
}

// Accept returns detached diagnostics only from this live owner's exact ACK.
func (o *RecoveryOwner) Accept(r RecoveryReservation) (RecoveryOwnerObservation, error) {
	if o == nil || o.state == nil || r.owner != o.state || r.observation == nil || o.state.accepted.Load() != r.observation {
		return RecoveryOwnerObservation{}, ErrClosed
	}
	return cloneRecoveryObservation(r.observation), nil
}

// Consume grants one barrier-only attempt from the originating live ACK.
// Copies and independently constructed recovery clients share this terminal
// decision. Detached diagnostics and persisted owner rows cannot reconstruct it.
func (r RecoveryReservation) Consume() (RecoveryOwnerObservation, error) {
	if r.owner == nil || r.observation == nil || r.owner.accepted.Load() != r.observation || !r.owner.recoveryConsumed.CompareAndSwap(false, true) {
		return RecoveryOwnerObservation{}, ErrClosed
	}
	return cloneRecoveryObservation(r.observation), nil
}

func cloneRecoveryObservation(observation *RecoveryOwnerObservation) RecoveryOwnerObservation {
	got := *observation
	got.Handoff.Journal.Binding.MemberPodUIDs = slices.Clone(got.Handoff.Journal.Binding.MemberPodUIDs)
	got.Handoff.Journal.Grants = slices.Clone(got.Handoff.Journal.Grants)
	return got
}

// EncodeRecoveryOwner serializes diagnostics through the permanent reader. It
// neither reconstructs a reservation nor authorizes any storage mutation.
func EncodeRecoveryOwner(got RecoveryOwnerObservation) (string, error) {
	handoff, err := encodeHandoff(got.Handoff)
	if err != nil {
		return "", err
	}
	value, err := json.Marshal(struct {
		Schema         int             `json:"schema"`
		OwnerID        string          `json:"owner_id"`
		HandoffVersion string          `json:"handoff_version"`
		Handoff        json.RawMessage `json:"handoff"`
	}{1, got.OwnerID, got.HandoffVersion, json.RawMessage(handoff)})
	if err != nil {
		return "", err
	}
	if _, err = DecodeRecoveryOwner(string(value)); err != nil {
		return "", err
	}
	return string(value), nil
}

// DecodeRecoveryOwner is the permanent strict schema-1 diagnostic reader.
// Stored data supplies no trusted version and cannot restore a reservation.
func DecodeRecoveryOwner(value string) (RecoveryOwnerObservation, error) {
	if len(value) > 267264 || !utf8.ValidString(value) {
		return RecoveryOwnerObservation{}, ErrUnknown
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return RecoveryOwnerObservation{}, ErrUnknown
	}
	var schema int
	var got RecoveryOwnerObservation
	var handoff json.RawMessage
	fields := map[string]any{"schema": &schema, "owner_id": &got.OwnerID, "handoff_version": &got.HandoffVersion, "handoff": &handoff}
	seen := map[string]bool{}
	for decoder.More() {
		token, e := decoder.Token()
		if e != nil {
			return RecoveryOwnerObservation{}, ErrUnknown
		}
		name, ok := token.(string)
		target, known := fields[name]
		if !ok || !known || seen[name] {
			return RecoveryOwnerObservation{}, ErrUnknown
		}
		seen[name] = true
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil || strings.TrimSpace(string(raw)) == "null" || json.Unmarshal(raw, target) != nil {
			return RecoveryOwnerObservation{}, ErrUnknown
		}
	}
	if nakamastorage.EndObject(decoder) != nil || len(seen) != 4 || schema != 1 || !handoffidentity.OpaqueUTF8(got.OwnerID, 128) || !validVersion(got.HandoffVersion) {
		return RecoveryOwnerObservation{}, ErrUnknown
	}
	got.Handoff, err = decodeHandoff(string(handoff))
	if err != nil {
		return RecoveryOwnerObservation{}, ErrUnknown
	}
	return got, nil
}
