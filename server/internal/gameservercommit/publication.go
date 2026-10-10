package gameservercommit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync/atomic"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

// RecoveryProofCollection holds generation-scoped private complete evidence.
const RecoveryProofCollection = "world_at_ruin_allocator_recovery_proofs"

// PublicationConfig is explicitly enabled only by the unpublished experiment.
type PublicationConfig struct {
	Enabled bool
	Storage nakamastorage.Client
}

// PublicationPins are detached diagnostics retained independently of a reader.
// They cannot reconstruct originating publication or allocation authority.
type PublicationPins struct {
	Version  string
	Recovery RecoveryObservation
}

// RecoveryPublisher copies refer to one originating complete result.
type RecoveryPublisher struct{ state *publicationState }
type publicationState struct {
	cfg      PublicationConfig
	result   RecoveryResult
	accepted atomic.Pointer[PublicationPins]
}

// PublicationResult is accepted only by its live originating publisher.
type PublicationResult struct {
	state *publicationState
	pins  *PublicationPins
}

// NewRecoveryPublisher never reconstructs authority from diagnostic observations.
func NewRecoveryPublisher(cfg PublicationConfig, result RecoveryResult) (*RecoveryPublisher, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if !publicationStoragePresent(cfg.Storage) || result.state == nil || result.observation == nil || result.state.accepted.Load() != result.observation {
		return nil, ErrClosed
	}
	return &RecoveryPublisher{state: &publicationState{cfg: cfg, result: result}}, nil
}

// Publish spends the complete result's shared attempt before storage I/O.
func (p *RecoveryPublisher) Publish(ctx context.Context) (PublicationResult, error) {
	if p == nil || p.state == nil {
		return PublicationResult{}, ErrClosed
	}
	complete, err := p.state.result.consumePublication()
	if err != nil {
		return PublicationResult{}, ErrClosed
	}
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	value, err := encodeRecoveryProof(complete)
	if err != nil || ctx.Err() != nil {
		return PublicationResult{}, publicationUnknown(ctx, err)
	}
	key := RecoveryProofKey(complete.Owner.Handoff.Journal.Binding.GenerationID)
	acks, err := p.state.cfg.Storage.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: RecoveryProofCollection, Key: key, UserID: "", Value: value, Version: "*", PermissionRead: 0, PermissionWrite: 0}})
	if err != nil || ctx.Err() != nil || len(acks) != 1 || acks[0] == nil || acks[0].GetCollection() != RecoveryProofCollection || acks[0].GetKey() != key || acks[0].GetUserId() != nakamastorage.SystemOwnerID || !publicationVersion(acks[0].GetVersion()) {
		return PublicationResult{}, publicationUnknown(ctx, err)
	}
	pins := PublicationPins{Version: acks[0].GetVersion(), Recovery: complete}
	if _, err = ReadRecoveryPublication(ctx, PublicationReadConfig{Enabled: true, Storage: p.state.cfg.Storage, Pins: pins}); err != nil || ctx.Err() != nil {
		return PublicationResult{}, publicationUnknown(ctx, err)
	}
	p.state.accepted.Store(&pins)
	return PublicationResult{state: p.state, pins: &pins}, nil
}

// Accept exports only the originating publisher's exact acknowledged pins.
func (p *RecoveryPublisher) Accept(result PublicationResult) (PublicationPins, error) {
	if p == nil || p.state == nil || result.state != p.state || result.pins == nil || p.state.accepted.Load() != result.pins {
		return PublicationPins{}, ErrClosed
	}
	return PublicationPins{Version: result.pins.Version, Recovery: cloneRecovery(&result.pins.Recovery)}, nil
}

// RecoveryProofKey arbitrates the original generation independently of owners,
// incarnations and supplied pins. There is no replace or takeover operation.
func RecoveryProofKey(generationID string) string {
	value, _ := json.Marshal(generationID)
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-recovery-proof-key/v1\n"), value...))
	return hex.EncodeToString(digest[:])
}

// PublicationReadConfig has only read access and independently retained pins.
type PublicationReadConfig struct {
	Enabled bool
	Storage allocatorjournal.JournalStorage
	Pins    PublicationPins
}

// ReadRecoveryPublication verifies the exact private proof and original pinned
// owner, handoff and root. Its diagnostics cannot restore any opaque authority.
func ReadRecoveryPublication(ctx context.Context, cfg PublicationReadConfig) (RecoveryObservation, error) {
	if !cfg.Enabled {
		return RecoveryObservation{}, ErrDisabled
	}
	if !publicationStoragePresent(cfg.Storage) || !publicationVersion(cfg.Pins.Version) {
		return RecoveryObservation{}, unknown(ctx)
	}
	ctx, cancel := context.WithTimeout(ctx, requestLimit)
	defer cancel()
	expected := cloneRecovery(&cfg.Pins.Recovery)
	if _, err := encodeRecoveryProof(expected); err != nil || ctx.Err() != nil {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	key := RecoveryProofKey(expected.Owner.Handoff.Journal.Binding.GenerationID)
	rows, err := cfg.Storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: RecoveryProofCollection, Key: key, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(rows) != 1 || rows[0] == nil {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	row := rows[0]
	if row.GetCollection() != RecoveryProofCollection || row.GetKey() != key || row.GetUserId() != nakamastorage.SystemOwnerID || row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() != cfg.Pins.Version {
		return RecoveryObservation{}, unknown(ctx)
	}
	got, err := DecodeRecoveryProof(row.GetValue())
	if err != nil || !reflect.DeepEqual(got, expected) {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	owner := expected.Owner
	ownerKey := allocatoradmission.RecoveryOwnerKey(owner.Handoff.Journal.Binding.GenerationID)
	rows, err = cfg.Storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: allocatoradmission.RecoveryOwnerCollection, Key: ownerKey, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(rows) != 1 || rows[0] == nil {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	row = rows[0]
	if row.GetCollection() != allocatoradmission.RecoveryOwnerCollection || row.GetKey() != ownerKey || row.GetUserId() != nakamastorage.SystemOwnerID || row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() != owner.Version {
		return RecoveryObservation{}, unknown(ctx)
	}
	observed, err := allocatoradmission.DecodeRecoveryOwner(row.GetValue())
	observed.Version = row.GetVersion()
	if err != nil || !reflect.DeepEqual(observed, owner) {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	handoff, err := allocatoradmission.ReadHandoff(ctx, allocatoradmission.HandoffReadConfig{Enabled: true, Storage: cfg.Storage, Binding: owner.Handoff.Journal.Binding, Version: owner.HandoffVersion})
	if err != nil || ctx.Err() != nil || !reflect.DeepEqual(handoff, owner.Handoff) {
		return RecoveryObservation{}, publicationUnknown(ctx, err)
	}
	return got, nil
}

// publicationUnknown preserves only the caller's cancellation alongside the
// closed outcome. Underlying storage text and private evidence never escape.
func publicationUnknown(ctx context.Context, err error) error {
	if cancellation := nakamastorage.ContextError(ctx, err); cancellation != nil {
		return errors.Join(ErrUnknown, cancellation)
	}
	return ErrUnknown
}

// publicationStoragePresent refuses both nil interfaces and typed nil adapters.
func publicationStoragePresent(storage any) bool {
	if storage == nil {
		return false
	}
	v := reflect.ValueOf(storage)
	kind := v.Kind()
	nilable := kind == reflect.Chan || kind == reflect.Func || kind == reflect.Interface || kind == reflect.Map || kind == reflect.Pointer || kind == reflect.Slice
	return !nilable || !v.IsNil()
}

// publicationVersion retains exact opaque versions and refuses create sentinels.
func publicationVersion(version string) bool {
	return version != "*" && handoffidentity.OpaqueUTF8(version, 1024)
}

type recoveryProofGrant struct {
	ActorUID       string  `json:"actor_uid"`
	AttemptID      string  `json:"attempt_id"`
	Namespace      string  `json:"namespace"`
	Name           string  `json:"name"`
	UID            string  `json:"uid"`
	SourceVersion  string  `json:"source_version"`
	BarrierVersion string  `json:"barrier_version"`
	Outcome        Outcome `json:"outcome"`
}

// encodeRecoveryProof validates the exact complete bytes before dispatch.
func encodeRecoveryProof(got RecoveryObservation) (string, error) {
	owner, err := allocatoradmission.EncodeRecoveryOwner(got.Owner)
	if err != nil {
		return "", ErrUnknown
	}
	grants := make([]recoveryProofGrant, len(got.Grants))
	for i, g := range got.Grants {
		grants[i] = recoveryProofGrant{g.ActorUID, g.AttemptID, g.Namespace, g.Name, g.UID, g.SourceVersion, g.BarrierVersion, g.Outcome}
	}
	raw, err := json.Marshal(struct {
		Schema       int                  `json:"schema"`
		OwnerVersion string               `json:"owner_version"`
		Owner        json.RawMessage      `json:"owner"`
		Grants       []recoveryProofGrant `json:"grants"`
	}{1, got.Owner.Version, json.RawMessage(owner), grants})
	if err != nil {
		return "", ErrUnknown
	}
	if _, err = DecodeRecoveryProof(string(raw)); err != nil {
		return "", ErrUnknown
	}
	return string(raw), nil
}

// DecodeRecoveryProof permanently reads strict schema-1 complete diagnostics.
// Stored versions, owners and outcomes never reconstruct originating authority.
func DecodeRecoveryProof(value string) (RecoveryObservation, error) {
	if len(value) > 1<<20 || !utf8.ValidString(value) {
		return RecoveryObservation{}, ErrUnknown
	}
	var schema int
	var version string
	var owner json.RawMessage
	var grants []json.RawMessage
	if decodePublicationObject(value, map[string]any{"schema": &schema, "owner_version": &version, "owner": &owner, "grants": &grants}) != nil || schema != 1 || !publicationVersion(version) {
		return RecoveryObservation{}, ErrUnknown
	}
	parsed, err := allocatoradmission.DecodeRecoveryOwner(string(owner))
	if err != nil || len(grants) != len(parsed.Handoff.Journal.Grants) {
		return RecoveryObservation{}, ErrUnknown
	}
	parsed.Version = version
	got := RecoveryObservation{Owner: parsed, Grants: make([]GenerationGrantObservation, 0, len(grants))}
	barriers := make(map[string]bool, len(grants))
	for i, raw := range grants {
		var g recoveryProofGrant
		if decodePublicationObject(string(raw), map[string]any{"actor_uid": &g.ActorUID, "attempt_id": &g.AttemptID, "namespace": &g.Namespace, "name": &g.Name, "uid": &g.UID, "source_version": &g.SourceVersion, "barrier_version": &g.BarrierVersion, "outcome": &g.Outcome}) != nil {
			return RecoveryObservation{}, ErrUnknown
		}
		original := parsed.Handoff.Journal.Grants[i]
		if g.ActorUID != original.ActorUID || g.AttemptID != original.AttemptID || g.Name != original.Name || g.UID != original.UID || g.SourceVersion != original.SourceVersion || g.Namespace != parsed.Handoff.Journal.Binding.Namespace || !publicationVersion(g.BarrierVersion) || g.BarrierVersion == g.SourceVersion || barriers[g.BarrierVersion] || (g.Outcome != Uncommitted && g.Outcome != Allocated) {
			return RecoveryObservation{}, ErrUnknown
		}
		barriers[g.BarrierVersion] = true
		got.Grants = append(got.Grants, GenerationGrantObservation{ActorUID: g.ActorUID, AttemptID: g.AttemptID, Observation: Observation{Namespace: g.Namespace, Name: g.Name, UID: g.UID, SourceVersion: g.SourceVersion, BarrierVersion: g.BarrierVersion, Outcome: g.Outcome}})
	}
	return got, nil
}

// decodePublicationObject requires every exact field once, including false/zero
// values, and refuses null, aliases, unknown names and trailing JSON content.
func decodePublicationObject(value string, fields map[string]any) error {
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return ErrUnknown
	}
	seen := make(map[string]bool, len(fields))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return ErrUnknown
		}
		name, ok := token.(string)
		target, known := fields[name]
		if !ok || !known || seen[name] {
			return ErrUnknown
		}
		seen[name] = true
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil || strings.TrimSpace(string(raw)) == "null" || json.Unmarshal(raw, target) != nil {
			return ErrUnknown
		}
	}
	if nakamastorage.EndObject(decoder) != nil || len(seen) != len(fields) {
		return ErrUnknown
	}
	return nil
}
