package allocatoradmission

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

const HandoffCollection = "world_at_ruin_allocator_recovery_handoffs"
const handoffRequestLimit = 30 * time.Second

// HandoffKey is generation-wide, independent of publisher or reader incarnation.
func HandoffKey(generationID string) string {
	value, _ := json.Marshal(generationID)
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-recovery-handoff-key/v1\n"), value...))
	return hex.EncodeToString(digest[:])
}

// PublishHandoff attempts one private create from this writer's acknowledged
// drain. Returned pins are detached observations, never allocation authority.
// An ambiguous reply cannot be repaired by inspecting a visible row.
func (w *Writer) PublishHandoff(ctx context.Context, prior *Snapshot) (allocatorjournal.JournalBinding, string, error) {
	if w == nil || prior == nil || prior.owner != w || prior.observation.Phase != "draining" || w.failed.Load() {
		return allocatorjournal.JournalBinding{}, "", ErrClosed
	}
	if !w.handoff.CompareAndSwap(false, true) {
		return allocatorjournal.JournalBinding{}, "", ErrClosed
	}
	ctx, cancel := context.WithTimeout(ctx, handoffRequestLimit)
	defer cancel()
	if ctx.Err() != nil {
		w.failed.Store(true)
		return allocatorjournal.JournalBinding{}, "", unknown(ctx, nil)
	}
	value, err := encodeHandoff(prior.Observation())
	if err != nil {
		w.failed.Store(true)
		return allocatorjournal.JournalBinding{}, "", ErrUnknown
	}
	key := HandoffKey(prior.observation.Journal.Binding.GenerationID)
	acks, err := w.storage.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: HandoffCollection, Key: key, UserID: "", Value: value, Version: "*", PermissionRead: 0, PermissionWrite: 0}})
	if err != nil || ctx.Err() != nil || len(acks) != 1 || acks[0] == nil || acks[0].GetCollection() != HandoffCollection || acks[0].GetKey() != key || acks[0].GetUserId() != nakamastorage.SystemOwnerID || !validVersion(acks[0].GetVersion()) || w.failed.Load() {
		w.failed.Store(true)
		return allocatorjournal.JournalBinding{}, "", unknown(ctx, err)
	}
	return prior.Observation().Journal.Binding, acks[0].GetVersion(), nil
}

// HandoffReadConfig must be independently pinned before any storage access.
// The interface is read-only; readback cannot restore private writer snapshots.
type HandoffReadConfig struct {
	Enabled bool
	Storage allocatorjournal.JournalStorage
	Binding allocatorjournal.JournalBinding
	Version string
}

// ReadHandoff verifies both private documents at the original acknowledged
// versions. Neither document supplies its own trust expectations.
func ReadHandoff(ctx context.Context, cfg HandoffReadConfig) (Observation, error) {
	if !cfg.Enabled {
		return Observation{}, ErrDisabled
	}
	binding := cfg.Binding
	binding.MemberPodUIDs = slices.Clone(binding.MemberPodUIDs)
	if ctx.Err() != nil || isNil(cfg.Storage) || !validVersion(binding.Version) || !validVersion(cfg.Version) {
		return Observation{}, unknown(ctx, nil)
	}
	ctx, cancel := context.WithTimeout(ctx, handoffRequestLimit)
	defer cancel()
	key := HandoffKey(binding.GenerationID)
	rows, err := cfg.Storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: HandoffCollection, Key: key, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(rows) != 1 || rows[0] == nil {
		return Observation{}, unknown(ctx, err)
	}
	row := rows[0]
	if row.GetCollection() != HandoffCollection || row.GetKey() != key || row.GetUserId() != nakamastorage.SystemOwnerID || row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() != cfg.Version {
		return Observation{}, ErrUnknown
	}
	handoff, err := decodeHandoff(row.GetValue())
	if err != nil || !sameBinding(handoff.Journal.Binding, binding) {
		return Observation{}, ErrUnknown
	}
	root, err := Read(ctx, cfg.Storage, binding, "draining")
	if err != nil || !slices.Equal(root.Journal.Grants, handoff.Journal.Grants) || ctx.Err() != nil {
		return Observation{}, unknown(ctx, err)
	}
	return root, nil
}

func sameBinding(a, b allocatorjournal.JournalBinding) bool {
	return a.Version == b.Version && a.GenerationID == b.GenerationID && a.GenerationVersion == b.GenerationVersion && a.IncarnationID == b.IncarnationID && a.Namespace == b.Namespace && a.Fleet == b.Fleet && a.MemberSetDigest == b.MemberSetDigest && slices.Equal(a.MemberPodUIDs, b.MemberPodUIDs) && a.IssuedCount == b.IssuedCount && a.IssuedDigest == b.IssuedDigest
}

func encodeHandoff(got Observation) (string, error) {
	if got.Phase != "draining" || !validVersion(got.Journal.Binding.Version) {
		return "", ErrUnknown
	}
	admission, err := encodeAdmission(got)
	if err != nil {
		return "", err
	}
	value, err := json.Marshal(struct {
		Schema    int             `json:"schema"`
		Version   string          `json:"admission_version"`
		Admission json.RawMessage `json:"admission"`
	}{1, got.Journal.Binding.Version, json.RawMessage(admission)})
	if err != nil {
		return "", err
	}
	// Validate the exact bytes dispatched through the permanent reader.
	if _, err = decodeHandoff(string(value)); err != nil {
		return "", err
	}
	return string(value), nil
}

// decodeHandoff permanently preserves strict schema-1 complete inventory.
func decodeHandoff(value string) (Observation, error) {
	if len(value) > 265216 || !utf8.ValidString(value) {
		return Observation{}, ErrUnknown
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return Observation{}, ErrUnknown
	}
	var schema int
	var version string
	var admission json.RawMessage
	fields := map[string]any{"schema": &schema, "admission_version": &version, "admission": &admission}
	seen := map[string]bool{}
	for decoder.More() {
		token, e := decoder.Token()
		if e != nil {
			return Observation{}, ErrUnknown
		}
		name, ok := token.(string)
		target, known := fields[name]
		if !ok || !known || seen[name] {
			return Observation{}, ErrUnknown
		}
		seen[name] = true
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil || strings.TrimSpace(string(raw)) == "null" || json.Unmarshal(raw, target) != nil {
			return Observation{}, ErrUnknown
		}
	}
	if nakamastorage.EndObject(decoder) != nil || len(seen) != 3 || schema != 1 || !validVersion(version) {
		return Observation{}, ErrUnknown
	}
	got, err := decodeAdmission(string(admission))
	if err != nil || got.Phase != "draining" {
		return Observation{}, ErrUnknown
	}
	got.Journal.Binding.Version = version
	return got, nil
}
