package playerstate

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/runtime"
)

// LookupRequest carries immutable replay bindings, without proposing a record
// replacement, expected version, or new outcome.
type LookupRequest struct {
	SubjectID        string
	IdempotencyKey   string
	Operation        string
	Payload          json.RawMessage
	RecordCollection string
	RecordKey        string
}

// Lookup reads existing audit evidence. A missing audit means only that this
// read did not observe an outcome; it cannot establish that a dispatched write
// failed. Callers must keep an uncertain write indeterminate.
func (s *Store) Lookup(ctx context.Context, request LookupRequest) (Result, bool, error) {
	if ctx == nil || !nakamastorage.ValidSubjectID(request.SubjectID) ||
		nakamastorage.InvalidIdentityPart(request.IdempotencyKey) || nakamastorage.InvalidIdentityPart(request.Operation) ||
		nakamastorage.InvalidIdentityPart(request.RecordCollection) || request.RecordCollection == AuditCollection ||
		nakamastorage.InvalidIdentityPart(request.RecordKey) {
		return Result{}, false, errors.New("player state: invalid replay binding")
	}
	payload, err := nakamastorage.CanonicalObject(request.Payload)
	if err != nil {
		return Result{}, false, errors.New("player state: invalid replay payload")
	}
	mutation := normalizedMutation{subjectID: request.SubjectID, idempotencyKey: request.IdempotencyKey, operation: request.Operation, payload: payload,
		record:   RecordWrite{Collection: request.RecordCollection, Key: request.RecordKey, SystemOwned: true},
		auditKey: auditKey(request.SubjectID, request.RecordCollection, request.RecordKey, request.IdempotencyKey)}
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: AuditCollection, Key: mutation.auditKey, UserID: ""}})
	if err != nil {
		return Result{}, false, nakamastorage.SanitizeError(ctx, err, ErrStorage)
	}
	if len(objects) == 0 {
		return Result{}, false, nil
	}
	result, err := resolveExistingAudit(objects, mutation)
	return result, err == nil, err
}
