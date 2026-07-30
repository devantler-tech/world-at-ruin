package nakamaauth

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	googleBindingCollection    = "world_at_ruin_google_identity_bindings"
	googleBindingSystemOwnerID = "00000000-0000-0000-0000-000000000000"
	googleBindingSchema        = 1
)

// ErrGoogleBindingStorage reports an absent, corrupt, or failed authoritative
// Nakama storage operation without exposing its durable identity data.
var ErrGoogleBindingStorage = errors.New("nakama auth: Google binding storage failed")

type googleBindingStorageClient interface {
	StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error)
	StorageWrite(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error)
	AccountGetId(context.Context, string) (*api.Account, error)
}

// NakamaGoogleBindingStore persists immutable provider bindings in private,
// system-owned Nakama runtime storage.
type NakamaGoogleBindingStore struct {
	storage googleBindingStorageClient
}

// NewNakamaGoogleBindingStore builds the production Google binding store over
// Nakama's authoritative runtime storage surface.
func NewNakamaGoogleBindingStore(
	storage googleBindingStorageClient,
) (*NakamaGoogleBindingStore, error) {
	if storage == nil {
		return nil, errors.New("nakama auth: Google binding storage is required")
	}
	return &NakamaGoogleBindingStore{storage: storage}, nil
}

type googleBindingDocument struct {
	Schema int    `json:"schema"`
	UserID string `json:"user_id"`
}

// ResolveGoogleBinding reads one strictly validated private binding.
func (s *NakamaGoogleBindingStore) ResolveGoogleBinding(
	ctx context.Context,
	key string,
) (string, bool, error) {
	if !validGoogleBindingKey(key) {
		return "", false, errors.New("nakama auth: invalid Google binding key")
	}
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{{
		Collection: googleBindingCollection,
		Key:        key,
		UserID:     "",
	}})
	if err != nil {
		return "", false, sanitizeGoogleBindingStorageError(ctx, err)
	}
	if len(objects) == 0 {
		return "", false, nil
	}
	if len(objects) != 1 {
		return "", false, ErrGoogleBindingStorage
	}
	object := objects[0]
	if object == nil ||
		object.GetCollection() != googleBindingCollection ||
		object.GetKey() != key ||
		object.GetUserId() != googleBindingSystemOwnerID ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 {
		return "", false, ErrGoogleBindingStorage
	}
	document, err := decodeGoogleBindingDocument(object.GetValue())
	if err != nil {
		return "", false, err
	}
	return strings.ToLower(document.UserID), true, nil
}

// BindGoogleIdentity creates one private binding or adopts the concurrently
// committed winner. No update or delete operation is exposed.
func (s *NakamaGoogleBindingStore) BindGoogleIdentity(
	ctx context.Context,
	key string,
	userID string,
) (string, error) {
	if !validGoogleBindingKey(key) || !validNakamaUserID(userID) {
		return "", errors.New("nakama auth: invalid Google binding")
	}
	userID = strings.ToLower(userID)
	current, found, err := s.ResolveGoogleBinding(ctx, key)
	if err != nil {
		return "", err
	}
	if found {
		return current, nil
	}

	value, err := json.Marshal(googleBindingDocument{
		Schema: googleBindingSchema,
		UserID: userID,
	})
	if err != nil {
		return "", ErrGoogleBindingStorage
	}
	acks, writeErr := s.storage.StorageWrite(ctx, []*runtime.StorageWrite{{
		Collection:      googleBindingCollection,
		Key:             key,
		UserID:          "",
		Value:           string(value),
		Version:         "*",
		PermissionRead:  0,
		PermissionWrite: 0,
	}})
	if writeErr == nil &&
		len(acks) == 1 &&
		acks[0] != nil &&
		acks[0].GetCollection() == googleBindingCollection &&
		acks[0].GetKey() == key &&
		acks[0].GetUserId() == googleBindingSystemOwnerID &&
		acks[0].GetVersion() != "" {
		return userID, nil
	}

	// A create-only conflict and an error returned after commit are both
	// reconciled through the authoritative record. This store never overwrites
	// whichever user ID won the first write.
	winner, found, resolveErr := s.ResolveGoogleBinding(ctx, key)
	if resolveErr != nil {
		return "", resolveErr
	}
	if found {
		return winner, nil
	}
	if writeErr != nil {
		return "", sanitizeGoogleBindingStorageError(ctx, writeErr)
	}
	return "", ErrGoogleBindingStorage
}

// VerifyGoogleBoundAccount confirms the immutable winner still names an active
// Nakama account without relying on its mutable email credential.
func (s *NakamaGoogleBindingStore) VerifyGoogleBoundAccount(
	ctx context.Context,
	userID string,
) error {
	if !validNakamaUserID(userID) {
		return ErrGoogleBindingStorage
	}
	userID = strings.ToLower(userID)
	account, err := s.storage.AccountGetId(ctx, userID)
	if err != nil {
		return sanitizeGoogleBindingStorageError(ctx, err)
	}
	if account == nil ||
		account.GetUser() == nil ||
		!strings.EqualFold(account.GetUser().GetId(), userID) {
		return ErrGoogleBindingStorage
	}
	if account.GetDisableTime() != nil {
		return status.Error(codes.PermissionDenied, "Google-bound account is disabled")
	}
	return nil
}

func decodeGoogleBindingDocument(value string) (googleBindingDocument, error) {
	if err := rejectDuplicateGoogleBindingMembers(value); err != nil {
		return googleBindingDocument{}, err
	}
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.DisallowUnknownFields()
	var document googleBindingDocument
	if err := decoder.Decode(&document); err != nil {
		return googleBindingDocument{}, ErrGoogleBindingStorage
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return googleBindingDocument{}, ErrGoogleBindingStorage
	}
	if document.Schema != googleBindingSchema || !validNakamaUserID(document.UserID) {
		return googleBindingDocument{}, ErrGoogleBindingStorage
	}
	return document, nil
}

func rejectDuplicateGoogleBindingMembers(value string) error {
	decoder := json.NewDecoder(strings.NewReader(value))
	token, err := decoder.Token()
	delimiter, ok := token.(json.Delim)
	if err != nil || !ok || delimiter != '{' {
		return ErrGoogleBindingStorage
	}
	seen := make(map[string]struct{}, 2)
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return ErrGoogleBindingStorage
		}
		switch key {
		case "schema", "user_id":
		default:
			// encoding/json matches struct fields case-insensitively. Refuse
			// aliases here so a differently-cased member cannot bypass strict
			// schema names or overwrite a canonical member.
			return ErrGoogleBindingStorage
		}
		if _, duplicate := seen[key]; duplicate {
			return ErrGoogleBindingStorage
		}
		seen[key] = struct{}{}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return ErrGoogleBindingStorage
		}
	}
	token, err = decoder.Token()
	delimiter, ok = token.(json.Delim)
	if err != nil || !ok || delimiter != '}' {
		return ErrGoogleBindingStorage
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return ErrGoogleBindingStorage
	}
	return nil
}

func validGoogleBindingKey(value string) bool {
	if len(value) != 64 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func validNakamaUserID(value string) bool {
	if len(value) != 36 || strings.EqualFold(value, googleBindingSystemOwnerID) {
		return false
	}
	for index, character := range value {
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdefABCDEF", character) {
				return false
			}
		}
	}
	return true
}

func sanitizeGoogleBindingStorageError(ctx context.Context, err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case ctx.Err() != nil:
		return ctx.Err()
	default:
		return ErrGoogleBindingStorage
	}
}
