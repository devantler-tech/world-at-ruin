// Package allocatoradmission implements an explicitly enabled candidate storage
// experiment. Its snapshots are diagnostic data, never GameServer capabilities.
package allocatoradmission

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"k8s.io/apimachinery/pkg/util/validation"
)

const Collection = "world_at_ruin_allocator_admissions"

var ErrDisabled = errors.New("allocator admission: disabled")
var ErrUnknown = errors.New("allocator admission: outcome unknown")
var ErrClosed = errors.New("allocator admission: closed or invalid transition")

type Storage interface {
	StorageWrite(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error)
}
type Config struct {
	Enabled bool
	Storage Storage
	Journal string
}
type Observation struct {
	Phase   string
	Journal allocatorjournal.JournalObservation
}

// Snapshot carries a private writer origin. Observation cannot restore it.
type Snapshot struct {
	owner       *Writer
	observation Observation
}
type Writer struct {
	storage Storage
	initial allocatorjournal.JournalObservation
	key     string
	created atomic.Bool
	failed  atomic.Bool
	handoff atomic.Bool
}

// Key arbitrates the generation independently of authority incarnation.
func Key(generationID string) string {
	encoded, _ := json.Marshal(generationID)
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-admission-key/v1\n"), encoded...))
	return hex.EncodeToString(digest[:])
}

// NewWriter validates an empty strict journal without accessing storage.
// Disabled construction returns before inspecting any dependency or input.
func NewWriter(cfg Config) (*Writer, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	initial, err := allocatorjournal.DecodeJournal(cfg.Journal)
	if err != nil || len(initial.Grants) != 0 || isNil(cfg.Storage) {
		return nil, ErrClosed
	}
	return &Writer{storage: cfg.Storage, initial: initial, key: Key(initial.Binding.GenerationID)}, nil
}

// Create is attempted once. A second process cannot elect another incarnation
// using a different journal key; both must create the same generation root.
func (w *Writer) Create(ctx context.Context) (*Snapshot, error) {
	if ctx.Err() != nil {
		return nil, unknown(ctx, nil)
	}
	if !w.created.CompareAndSwap(false, true) || w.failed.Load() {
		return nil, ErrClosed
	}
	return w.write(ctx, Observation{Phase: "open", Journal: w.initial}, "*")
}

// Register never refreshes a frozen target or retries a rejected CAS.
func (w *Writer) Register(ctx context.Context, prior *Snapshot, grant allocatorjournal.JournalGrant) (*Snapshot, error) {
	if !w.valid(prior) || !handoffidentity.OpaqueUTF8(grant.ActorUID, 128) || !slices.Contains(prior.observation.Journal.Binding.MemberPodUIDs, grant.ActorUID) || !handoffidentity.CorrelationID(grant.AttemptID) || len(validation.IsDNS1123Subdomain(grant.Name)) != 0 || !handoffidentity.OpaqueUTF8(grant.UID, 128) || grant.SourceVersion == "*" || !handoffidentity.OpaqueUTF8(grant.SourceVersion, 1024) {
		return nil, ErrClosed
	}
	next := prior.Observation()
	next.Journal.Grants = append(next.Journal.Grants, grant)
	slices.SortFunc(next.Journal.Grants, func(a, b allocatorjournal.JournalGrant) int { return strings.Compare(a.UID, b.UID) })
	next.Journal.Binding.IssuedCount = len(next.Journal.Grants)
	encoded, err := json.Marshal(next.Journal.Grants)
	if err != nil {
		return nil, ErrClosed
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), encoded...))
	next.Journal.Binding.IssuedDigest = hex.EncodeToString(digest[:])
	return w.write(ctx, next, prior.observation.Journal.Binding.Version)
}

// Drain freezes the same document and exact version used by registration.
// It does not barrier outstanding GameServer writes or restore a receipt.
func (w *Writer) Drain(ctx context.Context, prior *Snapshot) (*Snapshot, error) {
	if !w.valid(prior) {
		return nil, ErrClosed
	}
	next := prior.Observation()
	next.Phase = "draining"
	return w.write(ctx, next, prior.observation.Journal.Binding.Version)
}
func (w *Writer) valid(prior *Snapshot) bool {
	return prior != nil && prior.owner == w && prior.observation.Phase == "open" && !w.failed.Load()
}
func (w *Writer) write(ctx context.Context, next Observation, version string) (*Snapshot, error) {
	if ctx.Err() != nil || w.failed.Load() {
		return nil, unknown(ctx, nil)
	}
	value, err := encodeAdmission(next)
	if err != nil {
		return nil, ErrClosed
	}
	// Validate the exact bytes sent, including duplicate/oversized grants.
	if _, err = decodeAdmission(value); err != nil {
		return nil, ErrClosed
	}
	acks, err := w.storage.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: Collection, Key: w.key, UserID: "", Value: value, Version: version, PermissionRead: 0, PermissionWrite: 0}})
	if err != nil || ctx.Err() != nil || len(acks) != 1 || acks[0] == nil || acks[0].GetCollection() != Collection || acks[0].GetKey() != w.key || acks[0].GetUserId() != nakamastorage.SystemOwnerID || !validVersion(acks[0].GetVersion()) || acks[0].GetVersion() == version {
		w.failed.Store(true)
		return nil, unknown(ctx, err)
	}
	// A concurrent ambiguous operation poisons further source success too.
	if w.failed.Load() {
		return nil, ErrUnknown
	}
	next.Journal.Binding.Version = acks[0].GetVersion()
	return &Snapshot{owner: w, observation: next}, nil
}

// Observation returns detached diagnostic data without the private writer origin.
func (s *Snapshot) Observation() Observation {
	got := s.observation
	got.Journal.Binding.MemberPodUIDs = slices.Clone(got.Journal.Binding.MemberPodUIDs)
	got.Journal.Grants = slices.Clone(got.Journal.Grants)
	return got
}

// Read observes one private exact-version document against independently pinned
// phase and complete-set expectations. It cannot create a writer or snapshot.
func Read(ctx context.Context, storage allocatorjournal.JournalStorage, binding allocatorjournal.JournalBinding, phase string) (Observation, error) {
	if ctx.Err() != nil || isNil(storage) || !validVersion(binding.Version) || (phase != "open" && phase != "draining") {
		return Observation{}, unknown(ctx, nil)
	}
	key := Key(binding.GenerationID)
	rows, err := storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: Collection, Key: key, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(rows) != 1 || rows[0] == nil {
		return Observation{}, unknown(ctx, err)
	}
	row := rows[0]
	if row.GetCollection() != Collection || row.GetKey() != key || row.GetUserId() != nakamastorage.SystemOwnerID || row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() != binding.Version {
		return Observation{}, ErrUnknown
	}
	got, err := decodeAdmission(row.GetValue())
	if err != nil || got.Phase != phase {
		return Observation{}, ErrUnknown
	}
	got.Journal.Binding.Version = row.GetVersion()
	a, b := got.Journal.Binding, binding
	if a.GenerationID != b.GenerationID || a.GenerationVersion != b.GenerationVersion || a.IncarnationID != b.IncarnationID || a.Namespace != b.Namespace || a.Fleet != b.Fleet || a.MemberSetDigest != b.MemberSetDigest || !slices.Equal(a.MemberPodUIDs, b.MemberPodUIDs) || a.IssuedCount != b.IssuedCount || a.IssuedDigest != b.IssuedDigest || ctx.Err() != nil {
		return Observation{}, unknown(ctx, nil)
	}
	return got, nil
}
func validVersion(v string) bool { return v != "*" && handoffidentity.OpaqueUTF8(v, 1024) }
func unknown(ctx context.Context, err error) error {
	if cancellation := nakamastorage.ContextError(ctx, err); cancellation != nil {
		return errors.Join(ErrUnknown, cancellation)
	}
	return ErrUnknown
}
func encodeAdmission(got Observation) (string, error) {
	b := got.Journal.Binding
	journal := struct {
		Schema            int                             `json:"schema"`
		GenerationID      string                          `json:"generation_id"`
		GenerationVersion string                          `json:"generation_source_version"`
		Members           []string                        `json:"member_pod_uids"`
		MemberDigest      string                          `json:"member_set_digest"`
		Incarnation       string                          `json:"authority_incarnation"`
		Namespace         string                          `json:"namespace"`
		Fleet             string                          `json:"fleet"`
		Count             int                             `json:"grant_count"`
		Digest            string                          `json:"grant_set_digest"`
		Grants            []allocatorjournal.JournalGrant `json:"grants"`
	}{1, b.GenerationID, b.GenerationVersion, b.MemberPodUIDs, b.MemberSetDigest, b.IncarnationID, b.Namespace, b.Fleet, b.IssuedCount, b.IssuedDigest, got.Journal.Grants}
	value, err := json.Marshal(struct {
		Schema  int    `json:"schema"`
		Phase   string `json:"phase"`
		Journal any    `json:"journal"`
	}{1, got.Phase, journal})
	return string(value), err
}

// decodeAdmission is the permanent strict schema-1 reader. The embedded journal
// uses the existing read-only decoder; no inventory format is widened.
func decodeAdmission(value string) (Observation, error) {
	if len(value) > 263168 || !utf8.ValidString(value) {
		return Observation{}, ErrUnknown
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return Observation{}, ErrUnknown
	}
	var schema int
	var phase string
	var journal json.RawMessage
	fields := map[string]any{"schema": &schema, "phase": &phase, "journal": &journal}
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
	if nakamastorage.EndObject(decoder) != nil || len(seen) != 3 || schema != 1 || (phase != "open" && phase != "draining") {
		return Observation{}, ErrUnknown
	}
	got, err := allocatorjournal.DecodeJournal(string(journal))
	if err != nil {
		return Observation{}, ErrUnknown
	}
	return Observation{Phase: phase, Journal: got}, nil
}

func isNil(value any) bool {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	kind := v.Kind()
	if kind == reflect.Pointer || kind == reflect.Interface || kind == reflect.Map || kind == reflect.Slice || kind == reflect.Func || kind == reflect.Chan {
		return v.IsNil()
	}
	return false
}
