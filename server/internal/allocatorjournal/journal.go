// Package allocatorjournal reads detached journal inventory without allocation or fence authority.
package allocatorjournal

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"k8s.io/apimachinery/pkg/util/validation"
)

const maxGrants = 256

var (
	ErrDisabled = errors.New("allocatorjournal: explicit enablement is required")
	ErrInvalid  = errors.New("allocatorjournal: invalid binding")
	ErrUnknown  = errors.New("allocatorjournal: observation remains unknown")
)

// JournalCollection is private reader inventory, not activated writer storage.
const JournalCollection = "world_at_ruin_allocator_grant_journals"

// JournalStorage grants only reads; a writer cannot be reached through this API.
type JournalStorage interface {
	StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error)
}

// JournalGrant preserves attribution and the exact frozen target version.
// Metadata alone cannot reconstruct the complete allocation mutation or authority.
type JournalGrant struct {
	ActorUID      string `json:"actor_uid"`
	AttemptID     string `json:"attempt_id"`
	Name          string `json:"name"`
	UID           string `json:"uid"`
	SourceVersion string `json:"source_version"`
}

// JournalBinding contains independently pinned expectations. Version names the
// journal object, while GenerationVersion names its generation source record.
type JournalBinding struct {
	GenerationID, GenerationVersion, MemberSetDigest       string
	MemberPodUIDs                                          []string
	IncarnationID, Namespace, Fleet, IssuedDigest, Version string
	IssuedCount                                            int
}

// JournalObservation is detached diagnostic data, never a fence receipt.
type JournalObservation struct {
	Binding JournalBinding
	Grants  []JournalGrant
}

// JournalReaderConfig enables only an inactive reader with fixed expectations.
type JournalReaderConfig struct {
	Enabled bool
	Storage JournalStorage
	Binding JournalBinding
}

// JournalReader has no journal write, grant restoration or receipt acceptance API.
type JournalReader struct {
	storage JournalStorage
	binding JournalBinding
	key     string
}

// NewJournalReader copies canonical, bounded expectations before any read.
func NewJournalReader(cfg JournalReaderConfig) (*JournalReader, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if nilJournalStorage(cfg.Storage) || !validJournalBinding(cfg.Binding) {
		return nil, ErrInvalid
	}
	b := cfg.Binding
	b.MemberPodUIDs = slices.Clone(b.MemberPodUIDs)
	identity, err := json.Marshal([]string{b.GenerationID, b.IncarnationID})
	if err != nil {
		return nil, ErrInvalid
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-grant-journal-key/v1\n"), identity...))
	return &JournalReader{storage: cfg.Storage, binding: b, key: hex.EncodeToString(digest[:])}, nil
}

// nilJournalStorage rejects nil interfaces and typed nil implementations.
func nilJournalStorage(storage JournalStorage) bool {
	if storage == nil {
		return true
	}
	value := reflect.ValueOf(storage)
	kind := value.Kind()
	if kind == reflect.Chan || kind == reflect.Func || kind == reflect.Interface ||
		kind == reflect.Map || kind == reflect.Pointer || kind == reflect.Slice {
		return value.IsNil()
	}
	return false
}

// validJournalBinding validates immutable source identity and exact versions;
// it neither authenticates writers nor establishes complete issuance.
func validJournalBinding(b JournalBinding) bool {
	return ValidGenerationBinding(b.GenerationID, b.GenerationVersion, b.MemberPodUIDs, b.MemberSetDigest) && handoffidentity.OpaqueUTF8(b.IncarnationID, 128) &&
		b.Version != "*" && handoffidentity.OpaqueUTF8(b.Version, 1024) &&
		len(validation.IsDNS1123Label(b.Namespace)) == 0 && len(validation.IsDNS1123Subdomain(b.Fleet)) == 0 && len(b.Fleet) <= 63 &&
		b.IssuedCount >= 0 && b.IssuedCount <= maxGrants && handoffidentity.SHA256Hex(b.IssuedDigest)
}

// Load requires one complete successful private read at the independently
// pinned version. An error, cancellation or mismatch returns no inventory.
func (r *JournalReader) Load(ctx context.Context) (JournalObservation, error) {
	if r == nil || r.storage == nil {
		return JournalObservation{}, ErrInvalid
	}
	if ctx.Err() != nil {
		return JournalObservation{}, unknown(ctx)
	}
	rows, err := r.storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: JournalCollection, Key: r.key, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(rows) != 1 {
		return JournalObservation{}, journalReadError(ctx, err)
	}
	row := rows[0]
	if row == nil || row.GetCollection() != JournalCollection || row.GetKey() != r.key || row.GetUserId() != nakamastorage.SystemOwnerID ||
		row.GetPermissionRead() != 0 || row.GetPermissionWrite() != 0 || row.GetVersion() != r.binding.Version {
		return JournalObservation{}, unknown(ctx)
	}
	got, err := decodeJournal(row.GetValue())
	if err != nil {
		return JournalObservation{}, unknown(ctx)
	}
	got.Binding.Version = row.GetVersion()
	if !sameJournalBinding(got.Binding, r.binding) || ctx.Err() != nil {
		return JournalObservation{}, unknown(ctx)
	}
	return got, nil
}

// journalReadError retains only the caller's cancellation/deadline identity.
func journalReadError(ctx context.Context, err error) error {
	if cancellation := nakamastorage.ContextError(ctx, err); cancellation != nil {
		return errors.Join(ErrUnknown, cancellation)
	}
	return ErrUnknown
}

// sameJournalBinding refuses source or incarnation substitution and never
// learns complete-set expectations from the object being observed.
func sameJournalBinding(a, b JournalBinding) bool {
	return a.GenerationID == b.GenerationID && a.GenerationVersion == b.GenerationVersion &&
		a.MemberSetDigest == b.MemberSetDigest && slices.Equal(a.MemberPodUIDs, b.MemberPodUIDs) &&
		a.IncarnationID == b.IncarnationID && a.Namespace == b.Namespace && a.Fleet == b.Fleet &&
		a.IssuedCount == b.IssuedCount && a.IssuedDigest == b.IssuedDigest && a.Version == b.Version
}

// decodeJournal preserves schema-1 inventory and rejects partial/ambiguous JSON.
// Storage version belongs to the enclosing Nakama object, not this document.
func decodeJournal(value string) (JournalObservation, error) {
	if len(value) > 262144 || !journalUnicode(value) {
		return JournalObservation{}, ErrUnknown
	}
	var schema int
	var got JournalObservation
	var rawGrants []json.RawMessage
	b := &got.Binding
	fields := map[string]any{"schema": &schema, "generation_id": &b.GenerationID, "generation_source_version": &b.GenerationVersion,
		"member_pod_uids": &b.MemberPodUIDs, "member_set_digest": &b.MemberSetDigest, "authority_incarnation": &b.IncarnationID,
		"namespace": &b.Namespace, "fleet": &b.Fleet, "grant_count": &b.IssuedCount, "grant_set_digest": &b.IssuedDigest, "grants": &rawGrants}
	if journalObject(value, fields) != nil || schema != 1 || rawGrants == nil || len(rawGrants) > maxGrants || len(rawGrants) != b.IssuedCount {
		return JournalObservation{}, ErrUnknown
	}
	// Validate document context without inventing a persisted journal version.
	candidate := *b
	candidate.Version = "source-reader-validation"
	if !validJournalBinding(candidate) {
		return JournalObservation{}, ErrUnknown
	}
	got.Grants = make([]JournalGrant, 0, len(rawGrants))
	names := make(map[string]bool)
	for _, raw := range rawGrants {
		var grant JournalGrant
		if journalObject(string(raw), map[string]any{"actor_uid": &grant.ActorUID, "attempt_id": &grant.AttemptID,
			"name": &grant.Name, "uid": &grant.UID, "source_version": &grant.SourceVersion}) != nil ||
			!slices.Contains(b.MemberPodUIDs, grant.ActorUID) || !handoffidentity.CorrelationID(grant.AttemptID) ||
			len(validation.IsDNS1123Subdomain(grant.Name)) != 0 || !handoffidentity.OpaqueUTF8(grant.UID, 128) ||
			grant.SourceVersion == "*" || !handoffidentity.OpaqueUTF8(grant.SourceVersion, 1024) || names[grant.Name] ||
			(len(got.Grants) > 0 && grant.UID <= got.Grants[len(got.Grants)-1].UID) {
			return JournalObservation{}, ErrUnknown
		}
		names[grant.Name] = true
		got.Grants = append(got.Grants, grant)
	}
	encoded, err := json.Marshal(got.Grants)
	if err != nil {
		return JournalObservation{}, ErrUnknown
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), encoded...))
	if b.IssuedDigest != hex.EncodeToString(digest[:]) {
		return JournalObservation{}, ErrUnknown
	}
	return got, nil
}

// journalObject requires each declared field exactly once, including nested
// grant objects, and rejects null, unknown names and trailing JSON values.
func journalObject(value string, fields map[string]any) error {
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return ErrUnknown
	}
	seen := make(map[string]bool)
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

// journalUnicode rejects encoding/json's lossy replacement of malformed UTF-8
// and unpaired UTF-16 escapes; valid paired escapes retain their full identity.
func journalUnicode(value string) bool {
	if !utf8.ValidString(value) {
		return false
	}
	for index := 0; index < len(value); index++ {
		if value[index] != '\\' {
			continue
		}
		index++
		if index >= len(value) {
			return false
		}
		if value[index] != 'u' {
			continue
		}
		if index+5 > len(value) {
			return false
		}
		unit, err := strconv.ParseUint(value[index+1:index+5], 16, 16)
		if err != nil {
			return false
		}
		index += 4
		switch {
		case unit >= 0xdc00 && unit <= 0xdfff:
			return false
		case unit >= 0xd800 && unit <= 0xdbff:
			if index+7 > len(value) || value[index+1:index+3] != `\u` {
				return false
			}
			low, err := strconv.ParseUint(value[index+3:index+7], 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			index += 6
		}
	}
	return true
}

// ValidGenerationBinding checks only canonical source identity and membership.
// It never authorizes a writer or restores allocation capabilities.
func ValidGenerationBinding(id, version string, members []string, digest string) bool {
	if !handoffidentity.OpaqueUTF8(id, 128) || version == "*" || !handoffidentity.OpaqueUTF8(version, 1024) || len(members) == 0 || len(members) > maxGrants {
		return false
	}
	for i, member := range members {
		if !handoffidentity.OpaqueUTF8(member, 128) || (i > 0 && member <= members[i-1]) {
			return false
		}
	}
	encoded, err := json.Marshal(members)
	if err != nil {
		return false
	}
	sum := sha256.Sum256(append([]byte("world-at-ruin/allocator-generation-members/v1\n"), encoded...))
	return digest == hex.EncodeToString(sum[:])
}

// DecodeJournal exposes the same strict source decoder to retained compatibility wrappers.
func DecodeJournal(value string) (JournalObservation, error) { return decodeJournal(value) }

func unknown(ctx context.Context) error {
	if ctx.Err() != nil {
		return errors.Join(ErrUnknown, ctx.Err())
	}
	return ErrUnknown
}
