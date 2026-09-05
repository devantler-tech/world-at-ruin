package nakamalease

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
)

// ProtectedAttempts returns the full attempt digests protected by every stored
// lease, including expired, dispatched, claimed and releasing records. Only the
// coordinator may retire those records through its exact-version barriers.
//
// No partial result is returned: unknown schemas, changed pagination, excessive
// pages and storage failures cannot be mistaken for absence. The caller supplies
// a deadline and a page budget (1..1000); each page holds at most 100 records.
func (s *Store) ProtectedAttempts(ctx context.Context, maxPages int) (map[string]struct{}, error) {
	if maxPages < 1 || maxPages > 1000 {
		return nil, errors.New("nakama lease: invalid scan budget")
	}
	protected := make(map[string]struct{})
	keys := make(map[string]struct{})
	cursors := map[string]bool{"": true}
	cursor := ""
	for range maxPages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		objects, next, err := s.storage.StorageList(ctx, "", systemOwnerID, Collection, 100, cursor)
		if err != nil {
			return nil, nakamastorage.SanitizeError(ctx, err, ErrStorage)
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if len(objects) > 100 || len(next) > 16384 {
			return nil, ErrStorage
		}
		for _, object := range objects {
			if !validListedObject(object) || object.GetVersion() == "*" || len(object.GetVersion()) > 1024 || !unambiguousLeaseObject(object.GetValue()) {
				return nil, ErrStorage
			}
			if _, duplicate := keys[object.GetKey()]; duplicate {
				return nil, ErrStorage
			}
			keys[object.GetKey()] = struct{}{}
			lease, err := leaseFrom(object.GetValue(), "", "")
			if err != nil {
				return nil, ErrStorage
			}
			digest, err := agones.CorrelationLabel(lease.AttemptID)
			if err != nil {
				return nil, ErrStorage
			}
			protected[digest] = struct{}{}
		}
		if next == "" {
			return protected, nil
		}
		if cursors[next] {
			return nil, ErrStorage
		}
		cursors[next] = true
		cursor = next
	}
	return nil, ErrStorage
}

// A corrupt duplicate member cannot hide one attempt behind another. Keep the
// general reader's accepted field casing, but reject every repeated spelling.
func unambiguousLeaseObject(value string) bool {
	if len(value) > 65536 {
		return false
	}
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return false
	}
	seen := make(map[string]bool)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		key, ok := token.(string)
		if !ok {
			return false
		}
		key = strings.ToLower(key)
		if seen[key] {
			return false
		}
		seen[key] = true
		var member json.RawMessage
		if err := decoder.Decode(&member); err != nil {
			return false
		}
	}
	return nakamastorage.EndObject(decoder) == nil
}
