package nakamalease

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

var bindingKeys = [...]string{"allocator_generation_id", "allocator_member_set_digest", "allocator_pod_uid"}

// leaseMembers rejects ambiguous field aliases before the struct decoder can
// discard an earlier schema, attempt or binding. EqualFold matches JSON's field
// routing, including escaped spellings and the Unicode long-s alias.
func leaseMembers(value string) (map[string]json.RawMessage, error) {
	if len(value) > 65536 || !nakamastorage.ValidJSONUnicode(value) {
		return nil, ErrStorage
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return nil, ErrStorage
	}
	known := []string{"schema", "attempt_id", "allocation_id", "observer", "secret_ref", "expires_at_nanos", "claimed_at_nanos", "staging", "dispatched", "dispatch_id", "releasing"}
	known = append(known, bindingKeys[:]...)
	members := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, ErrStorage
		}
		key, ok := token.(string)
		if !ok {
			return nil, ErrStorage
		}
		canonical := ""
		for _, candidate := range known {
			if strings.EqualFold(key, candidate) {
				canonical = candidate
				break
			}
		}
		if canonical == "" {
			return nil, ErrStorage
		}
		if _, duplicate := members[canonical]; duplicate {
			return nil, ErrStorage
		}
		var member json.RawMessage
		if err := decoder.Decode(&member); err != nil {
			return nil, ErrStorage
		}
		members[canonical] = member
	}
	if nakamastorage.EndObject(decoder) != nil {
		return nil, ErrStorage
	}
	return members, nil
}

// validLeaseVersion rejects wildcard and ambiguous exact-version observations.
func validLeaseVersion(version string) bool {
	return version != "*" && handoffidentity.OpaqueUTF8(version, 1024)
}

// requireWriterKey rebinds mutation eligibility to fresh durable schema and
// version. A reconstructed caller observation cannot erase reader-only status.
func (s *Store) requireWriterKey(ctx context.Context, key, version string) error {
	if !validLeaseVersion(version) {
		return ErrConflict
	}
	current, err := s.LoadForClaim(ctx, key)
	if err != nil {
		return err
	}
	if current.Lease.ReaderOnly() {
		return ErrReaderOnly
	}
	if current.Version != version {
		return ErrConflict
	}
	return nil
}

// validBindingMembers separates readable schema 4 from all legacy shapes.
// Null is never an empty binding, and only the claim stamp may be null.
func validBindingMembers(members map[string]json.RawMessage, schema int) bool {
	if schema != readableSchemaVersion {
		for _, key := range bindingKeys {
			if _, exists := members[key]; exists {
				return false
			}
		}
		return true
	}
	required := []string{"schema", "attempt_id", "allocation_id", "observer", "secret_ref", "expires_at_nanos", "claimed_at_nanos"}
	required = append(required, bindingKeys[:]...)
	for _, key := range required {
		if _, exists := members[key]; !exists {
			return false
		}
	}
	for key, value := range members {
		if key != "claimed_at_nanos" && strings.TrimSpace(string(value)) == "null" {
			return false
		}
	}
	return true
}

// validAllocatorBinding retains a complete tuple after transient dispatch flags
// disappear. Only an undispatched staging record may have an empty tuple.
func validAllocatorBinding(lease Lease) bool {
	b := lease.AllocatorBinding
	empty := b == (AllocatorBinding{})
	if !empty && (!handoffidentity.OpaqueUTF8(b.GenerationID, 128) || !handoffidentity.SHA256Hex(b.MemberSetDigest) || !handoffidentity.OpaqueUTF8(b.PodUID, 128)) {
		return false
	}
	return !lease.readerOnly || empty == (lease.Staging && !lease.Dispatched)
}
