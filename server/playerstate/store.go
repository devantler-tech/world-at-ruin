// Package playerstate commits server-authoritative player record mutations
// together with their private, append-only audit evidence.
package playerstate

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// AuditCollection stores private mutation identities, bindings, and
	// outcomes. Audit objects are create-only and have no client owner, so an
	// authenticated player cannot pre-create evidence for a server mutation.
	AuditCollection = "world_at_ruin_player_mutations"

	auditSchema   = 1
	systemOwnerID = "00000000-0000-0000-0000-000000000000"
)

var (
	// ErrConflict means the player record changed since the caller observed it.
	ErrConflict = errors.New("player state: version conflict")
	// ErrKeyConflict means an idempotency key was already bound to a different
	// mutation.
	ErrKeyConflict = errors.New("player state: idempotency key conflict")
	// ErrIndeterminate means storage returned no durable outcome after a write
	// was dispatched.
	ErrIndeterminate = errors.New("player state: indeterminate write outcome")
	// ErrStorage means Nakama storage did not complete a read operation or
	// returned malformed durable state.
	ErrStorage = errors.New("player state: storage operation failed")
)

type storageClient interface {
	StorageRead(
		context.Context,
		[]*runtime.StorageRead,
	) ([]*api.StorageObject, error)
	StorageWrite(
		context.Context,
		[]*runtime.StorageWrite,
	) ([]*api.StorageObjectAck, error)
}

// RecordWrite is one conditional create or version-checked replacement of a
// player record. SystemOwned keeps the authoritative record and its replay
// evidence outside the client's writable user namespace.
type RecordWrite struct {
	Collection      string
	Key             string
	ExpectedVersion string
	Value           json.RawMessage
	SystemOwned     bool
}

// Mutation binds one caller-stable logical identity to the exact operation
// and payload that produced a player record replacement.
type Mutation struct {
	SubjectID      string
	IdempotencyKey string
	Operation      string
	Payload        json.RawMessage
	Record         RecordWrite
	Outcome        json.RawMessage
}

// Result is the original normalized outcome of an applied mutation.
type Result struct {
	Outcome json.RawMessage
}

// Store commits player record mutations through Nakama storage.
type Store struct {
	storage storageClient
}

// NewStore builds a player mutation store over Nakama's runtime storage
// surface.
func NewStore(storage storageClient) (*Store, error) {
	if storage == nil {
		return nil, errors.New("player state: storage is required")
	}
	return &Store{storage: storage}, nil
}

type normalizedMutation struct {
	subjectID      string
	idempotencyKey string
	operation      string
	payload        json.RawMessage
	record         RecordWrite
	outcome        json.RawMessage
	auditKey       string
}

type auditDocument struct {
	Schema           int             `json:"schema"`
	IdempotencyKey   string          `json:"idempotency_key"`
	RecordCollection string          `json:"record_collection"`
	RecordKey        string          `json:"record_key"`
	Operation        string          `json:"operation"`
	Payload          json.RawMessage `json:"payload"`
	Outcome          json.RawMessage `json:"outcome"`
}

// Apply atomically replaces one player record and creates its audit evidence.
func (s *Store) Apply(ctx context.Context, mutation Mutation) (Result, error) {
	normalized, err := normalizeMutation(mutation)
	if err != nil {
		return Result{}, err
	}

	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: AuditCollection,
			Key:        normalized.auditKey,
			UserID:     auditOwner(normalized),
		},
	})
	if err != nil {
		return Result{}, sanitizeReadError(ctx, err)
	}
	if len(objects) != 0 {
		return resolveExistingAudit(objects, normalized)
	}

	auditValue, err := json.Marshal(auditDocument{
		Schema:           auditSchema,
		IdempotencyKey:   normalized.idempotencyKey,
		RecordCollection: normalized.record.Collection,
		RecordKey:        normalized.record.Key,
		Operation:        normalized.operation,
		Payload:          normalized.payload,
		Outcome:          normalized.outcome,
	})
	if err != nil {
		return Result{}, errors.New("player state: encode audit")
	}
	writes := []*runtime.StorageWrite{
		{
			Collection:      normalized.record.Collection,
			Key:             normalized.record.Key,
			UserID:          recordOwner(normalized),
			Value:           string(normalized.record.Value),
			Version:         normalized.record.ExpectedVersion,
			PermissionRead:  0,
			PermissionWrite: 0,
		},
		{
			Collection:      AuditCollection,
			Key:             normalized.auditKey,
			UserID:          auditOwner(normalized),
			Value:           string(auditValue),
			Version:         "*",
			PermissionRead:  0,
			PermissionWrite: 0,
		},
	}
	acks, err := s.storage.StorageWrite(ctx, writes)
	if err != nil {
		return s.resolveAfterWrite(ctx, normalized, err)
	}
	if !validAcks(acks, writes) {
		return s.resolveAfterWrite(ctx, normalized, ErrIndeterminate)
	}
	return Result{Outcome: cloneRaw(normalized.outcome)}, nil
}

func recordOwner(mutation normalizedMutation) string {
	if mutation.record.SystemOwned {
		return ""
	}
	return mutation.subjectID
}

func auditOwner(_ normalizedMutation) string {
	return ""
}

func expectedStorageOwner(owner string) string {
	if owner == "" {
		return systemOwnerID
	}
	return owner
}

func (s *Store) resolveAfterWrite(
	ctx context.Context,
	mutation normalizedMutation,
	writeErr error,
) (Result, error) {
	objects, readErr := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: AuditCollection,
			Key:        mutation.auditKey,
			UserID:     auditOwner(mutation),
		},
	})
	if readErr != nil {
		return Result{}, indeterminateError(ctx, writeErr)
	}
	if len(objects) != 0 {
		return resolveExistingAudit(objects, mutation)
	}
	if errors.Is(writeErr, runtime.ErrStorageRejectedVersion) {
		return Result{}, ErrConflict
	}
	return Result{}, indeterminateError(ctx, writeErr)
}

func normalizeMutation(mutation Mutation) (normalizedMutation, error) {
	if !validSubjectID(mutation.SubjectID) {
		return normalizedMutation{}, errors.New(
			"player state: valid subject is required",
		)
	}
	if invalidIdentityPart(mutation.IdempotencyKey) {
		return normalizedMutation{}, errors.New(
			"player state: idempotency key is required",
		)
	}
	if invalidIdentityPart(mutation.Operation) {
		return normalizedMutation{}, errors.New(
			"player state: operation is required",
		)
	}
	if invalidIdentityPart(mutation.Record.Collection) ||
		mutation.Record.Collection == AuditCollection ||
		invalidIdentityPart(mutation.Record.Key) ||
		mutation.Record.ExpectedVersion == "" {
		return normalizedMutation{}, errors.New(
			"player state: valid observed record is required",
		)
	}
	payload, err := canonicalObject(mutation.Payload)
	if err != nil {
		return normalizedMutation{}, errors.New(
			"player state: payload must be a JSON object",
		)
	}
	value, err := canonicalObject(mutation.Record.Value)
	if err != nil {
		return normalizedMutation{}, errors.New(
			"player state: record value must be a JSON object",
		)
	}
	outcome, err := canonicalObject(mutation.Outcome)
	if err != nil {
		return normalizedMutation{}, errors.New(
			"player state: outcome must be a JSON object",
		)
	}
	record := mutation.Record
	record.Value = value
	return normalizedMutation{
		subjectID:      mutation.SubjectID,
		idempotencyKey: mutation.IdempotencyKey,
		operation:      mutation.Operation,
		payload:        payload,
		record:         record,
		outcome:        outcome,
		auditKey: auditKey(
			mutation.SubjectID,
			record.Collection,
			record.Key,
			mutation.IdempotencyKey,
		),
	}, nil
}

func canonicalObject(raw json.RawMessage) (json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil || object == nil {
		return nil, errors.New("invalid JSON object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("trailing JSON content")
	}
	encoded, err := json.Marshal(object)
	if err != nil {
		return nil, err
	}
	return encoded, nil
}

func resolveExistingAudit(
	objects []*api.StorageObject,
	mutation normalizedMutation,
) (Result, error) {
	if len(objects) != 1 {
		return Result{}, ErrStorage
	}
	object := objects[0]
	expectedOwner := expectedStorageOwner(auditOwner(mutation))
	if object == nil ||
		object.GetCollection() != AuditCollection ||
		object.GetKey() != mutation.auditKey ||
		object.GetUserId() != expectedOwner ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 {
		return Result{}, ErrStorage
	}
	document, err := decodeAuditDocument(object.GetValue())
	if err != nil || document.Schema != auditSchema {
		return Result{}, ErrStorage
	}
	payload, err := canonicalObject(document.Payload)
	if err != nil {
		return Result{}, ErrStorage
	}
	outcome, err := canonicalObject(document.Outcome)
	if err != nil {
		return Result{}, ErrStorage
	}
	if document.IdempotencyKey != mutation.idempotencyKey ||
		document.RecordCollection != mutation.record.Collection ||
		document.RecordKey != mutation.record.Key ||
		document.Operation != mutation.operation ||
		!bytes.Equal(payload, mutation.payload) {
		return Result{}, ErrKeyConflict
	}
	return Result{Outcome: outcome}, nil
}

func decodeAuditDocument(value string) (auditDocument, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return auditDocument{}, errors.New("invalid audit object")
	}
	document := auditDocument{}
	seen := make(map[string]struct{}, 7)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return auditDocument{}, err
		}
		key, ok := token.(string)
		if !ok {
			return auditDocument{}, errors.New("invalid audit field")
		}
		if _, duplicate := seen[key]; duplicate {
			return auditDocument{}, errors.New("duplicate audit field")
		}
		seen[key] = struct{}{}
		switch key {
		case "schema":
			err = decoder.Decode(&document.Schema)
		case "idempotency_key":
			err = decoder.Decode(&document.IdempotencyKey)
		case "record_collection":
			err = decoder.Decode(&document.RecordCollection)
		case "record_key":
			err = decoder.Decode(&document.RecordKey)
		case "operation":
			err = decoder.Decode(&document.Operation)
		case "payload":
			err = decoder.Decode(&document.Payload)
		case "outcome":
			err = decoder.Decode(&document.Outcome)
		default:
			return auditDocument{}, errors.New("unknown audit field")
		}
		if err != nil {
			return auditDocument{}, err
		}
	}
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') {
		return auditDocument{}, errors.New("invalid audit object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return auditDocument{}, errors.New("trailing audit content")
	}
	for _, required := range []string{
		"schema",
		"idempotency_key",
		"record_collection",
		"record_key",
		"operation",
		"payload",
		"outcome",
	} {
		if _, ok := seen[required]; !ok {
			return auditDocument{}, errors.New("missing audit field")
		}
	}
	if invalidIdentityPart(document.IdempotencyKey) ||
		invalidIdentityPart(document.RecordCollection) ||
		document.RecordCollection == AuditCollection ||
		invalidIdentityPart(document.RecordKey) ||
		invalidIdentityPart(document.Operation) {
		return auditDocument{}, errors.New("invalid audit identity")
	}
	return document, nil
}

func auditKey(subjectID, collection, recordKey, idempotencyKey string) string {
	sum := sha256.Sum256([]byte(
		subjectID + "\x00" +
			collection + "\x00" +
			recordKey + "\x00" +
			idempotencyKey,
	))
	return hex.EncodeToString(sum[:])
}

func invalidIdentityPart(value string) bool {
	return strings.TrimSpace(value) == "" || strings.ContainsRune(value, '\x00')
}

func validSubjectID(subjectID string) bool {
	if len(subjectID) != 36 ||
		subjectID == "00000000-0000-0000-0000-000000000000" {
		return false
	}
	for index, char := range subjectID {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if !isHexDigit(char) {
				return false
			}
		}
	}
	return true
}

func isHexDigit(char rune) bool {
	return (char >= '0' && char <= '9') ||
		(char >= 'a' && char <= 'f') ||
		(char >= 'A' && char <= 'F')
}

func validAcks(
	acks []*api.StorageObjectAck,
	writes []*runtime.StorageWrite,
) bool {
	if len(acks) != len(writes) {
		return false
	}
	for index, ack := range acks {
		expectedOwner := expectedStorageOwner(writes[index].UserID)
		if ack == nil ||
			ack.GetCollection() != writes[index].Collection ||
			ack.GetKey() != writes[index].Key ||
			ack.GetUserId() != expectedOwner ||
			ack.GetVersion() == "" {
			return false
		}
	}
	return true
}

func sanitizeReadError(ctx context.Context, err error) error {
	if cancellation := contextError(ctx, err); cancellation != nil {
		return cancellation
	}
	return ErrStorage
}

func contextError(ctx context.Context, err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case ctx.Err() != nil:
		return ctx.Err()
	default:
		return nil
	}
}

func indeterminateError(ctx context.Context, err error) error {
	if cancellation := contextError(ctx, err); cancellation != nil {
		return errors.Join(ErrIndeterminate, cancellation)
	}
	return ErrIndeterminate
}

func cloneRaw(raw json.RawMessage) json.RawMessage {
	return append(json.RawMessage(nil), raw...)
}
