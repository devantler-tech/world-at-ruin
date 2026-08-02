// Package nakamacharacter persists server-authoritative character records
// under their verified Nakama account owner.
package nakamacharacter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/playerstate"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// Collection is the private Nakama collection for character records.
	Collection = "world_at_ruin_characters"
	// RecordKey is the legacy account-owned character key and the prefix for
	// account-bound system-owned character documents.
	RecordKey       = "character"
	systemOwnerID   = "00000000-0000-0000-0000-000000000000"
	ownerCutoverKey = "character-system-owner-cutover"

	schemaVersion     = 1
	ownerCutoverValue = `{"schema":1}`
	storeInitTimeout  = 5 * time.Second
)

var (
	// ErrNotFound means the verified account has no character record.
	ErrNotFound = errors.New("nakama character: not found")
	// ErrConflict means the record changed since the caller observed it.
	ErrConflict = playerstate.ErrConflict
	// ErrKeyConflict means an idempotency key names different character state.
	ErrKeyConflict = playerstate.ErrKeyConflict
	// ErrStorage means Nakama returned an invalid record or storage failure.
	ErrStorage = playerstate.ErrStorage
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

// Character is the server-owned identity and versioned client recipe for one
// player character.
type Character struct {
	ID          string
	DisplayName string
	Recipe      json.RawMessage
}

// Record pairs one character with the exact Nakama version that observed it.
type Record struct {
	Character Character
	Version   string
}

// SaveRequest conditionally creates or replaces one account's character.
type SaveRequest struct {
	SubjectID       string
	IdempotencyKey  string
	ExpectedVersion string
	Character       Character
}

// Store owns system-owned character records through Nakama storage. Player
// mutations use playerstate.Store so the record and its player-associated audit
// evidence commit atomically. The one-time legacy migration is a conditional
// create whose source remains intact for retry and rollback.
type Store struct {
	storage   storageClient
	mutations *playerstate.Store
	cutover   time.Time
}

// NewStore builds a character store and establishes the persistent ownership
// cutover before any authenticated request can observe legacy state.
func NewStore(storage storageClient) (*Store, error) {
	ctx, cancel := context.WithTimeout(context.Background(), storeInitTimeout)
	defer cancel()
	return newStore(ctx, storage)
}

func newStore(ctx context.Context, storage storageClient) (*Store, error) {
	if storage == nil {
		return nil, errors.New("nakama character: storage is required")
	}
	mutations, err := playerstate.NewStore(storage)
	if err != nil {
		return nil, err
	}
	store := &Store{
		storage:   storage,
		mutations: mutations,
	}
	cutover, err := store.ownerCutover(ctx)
	if err != nil {
		return nil, err
	}
	store.cutover = cutover
	return store, nil
}

// Load reads the private character belonging to one verified Nakama subject.
func (s *Store) Load(ctx context.Context, subjectID string) (Record, error) {
	subjectID, err := authenticatedSubjectID(ctx, subjectID)
	if err != nil {
		return Record{}, err
	}
	record, found, err := s.readSystemCharacter(ctx, subjectID)
	if err != nil || found {
		return record, err
	}
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: Collection,
			Key:        RecordKey,
			UserID:     subjectID,
		},
	})
	if err != nil {
		return Record{}, sanitizeStorageError(ctx, err)
	}
	if len(objects) == 0 {
		return Record{}, ErrNotFound
	}
	if len(objects) != 1 {
		return Record{}, ErrStorage
	}
	object := objects[0]
	if object == nil ||
		object.GetCollection() != Collection ||
		object.GetKey() != RecordKey ||
		object.GetUserId() != subjectID ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 ||
		!createdBeforeCutover(object, s.cutover) {
		return Record{}, ErrStorage
	}
	character, err := decodeCharacterDocument(object.GetValue())
	if err != nil {
		return Record{}, ErrStorage
	}
	return s.migrateLegacyCharacter(ctx, subjectID, object, character)
}

func (s *Store) readSystemCharacter(
	ctx context.Context,
	subjectID string,
) (Record, bool, error) {
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: Collection,
			Key:        characterRecordKey(subjectID),
			UserID:     "",
		},
	})
	if err != nil {
		return Record{}, false, sanitizeStorageError(ctx, err)
	}
	if len(objects) == 0 {
		return Record{}, false, nil
	}
	if len(objects) != 1 {
		return Record{}, false, ErrStorage
	}
	object := objects[0]
	if object == nil ||
		object.GetCollection() != Collection ||
		object.GetKey() != characterRecordKey(subjectID) ||
		object.GetUserId() != systemOwnerID ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 {
		return Record{}, false, ErrStorage
	}
	character, err := decodeCharacterDocument(object.GetValue())
	if err != nil {
		return Record{}, false, ErrStorage
	}
	return Record{
		Character: character,
		Version:   object.GetVersion(),
	}, true, nil
}

// Save atomically commits one conditional character replacement and its
// append-only mutation evidence.
func (s *Store) Save(ctx context.Context, request SaveRequest) error {
	subjectID, err := authenticatedSubjectID(ctx, request.SubjectID)
	if err != nil {
		return err
	}
	if request.ExpectedVersion == "" {
		return errors.New("nakama character: observed version is required")
	}
	if request.ExpectedVersion != "*" {
		_, err := s.Load(ctx, subjectID)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
	}
	value, err := encodeCharacterDocument(request.Character)
	if err != nil {
		return err
	}
	outcome, err := json.Marshal(struct {
		Schema int `json:"schema"`
	}{
		Schema: schemaVersion,
	})
	if err != nil {
		return errors.New("nakama character: encode mutation outcome")
	}
	_, err = s.mutations.Apply(ctx, playerstate.Mutation{
		SubjectID:      subjectID,
		IdempotencyKey: request.IdempotencyKey,
		Operation:      "save_character",
		Payload:        value,
		Record: playerstate.RecordWrite{
			Collection:      Collection,
			Key:             characterRecordKey(subjectID),
			ExpectedVersion: request.ExpectedVersion,
			Value:           value,
			SystemOwned:     true,
		},
		Outcome: outcome,
	})
	return err
}

func characterRecordKey(subjectID string) string {
	return RecordKey + ":" + subjectID
}

func (s *Store) ownerCutover(ctx context.Context) (time.Time, error) {
	cutover, found, err := s.readOwnerCutover(ctx)
	if err != nil || found {
		return cutover, err
	}
	acks, writeErr := s.storage.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      Collection,
			Key:             ownerCutoverKey,
			UserID:          "",
			Value:           ownerCutoverValue,
			Version:         "*",
			PermissionRead:  0,
			PermissionWrite: 0,
		},
	})
	if writeErr == nil && !validSystemAck(acks, ownerCutoverKey) {
		writeErr = ErrStorage
	}
	cutover, found, readErr := s.readOwnerCutover(ctx)
	if readErr != nil {
		return time.Time{}, readErr
	}
	if found {
		return cutover, nil
	}
	if writeErr != nil {
		return time.Time{}, sanitizeStorageError(ctx, writeErr)
	}
	return time.Time{}, ErrStorage
}

func (s *Store) readOwnerCutover(
	ctx context.Context,
) (time.Time, bool, error) {
	objects, err := s.storage.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: Collection,
			Key:        ownerCutoverKey,
			UserID:     "",
		},
	})
	if err != nil {
		return time.Time{}, false, sanitizeStorageError(ctx, err)
	}
	if len(objects) == 0 {
		return time.Time{}, false, nil
	}
	if len(objects) != 1 {
		return time.Time{}, false, ErrStorage
	}
	object := objects[0]
	createdAt := object.GetCreateTime()
	if object == nil ||
		object.GetCollection() != Collection ||
		object.GetKey() != ownerCutoverKey ||
		object.GetUserId() != systemOwnerID ||
		object.GetValue() != ownerCutoverValue ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 ||
		createdAt == nil || createdAt.CheckValid() != nil {
		return time.Time{}, false, ErrStorage
	}
	return createdAt.AsTime(), true, nil
}

func createdBeforeCutover(object *api.StorageObject, cutover time.Time) bool {
	createdAt := object.GetCreateTime()
	return createdAt != nil &&
		createdAt.CheckValid() == nil &&
		createdAt.AsTime().Before(cutover)
}

func (s *Store) migrateLegacyCharacter(
	ctx context.Context,
	subjectID string,
	legacy *api.StorageObject,
	character Character,
) (Record, error) {
	acks, writeErr := s.storage.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      Collection,
			Key:             characterRecordKey(subjectID),
			UserID:          "",
			Value:           legacy.GetValue(),
			Version:         "*",
			PermissionRead:  0,
			PermissionWrite: 0,
		},
	})
	if writeErr == nil && validSystemAck(acks, characterRecordKey(subjectID)) {
		return Record{Character: character, Version: acks[0].GetVersion()}, nil
	}
	record, found, readErr := s.readSystemCharacter(ctx, subjectID)
	if readErr != nil {
		return Record{}, readErr
	}
	if found {
		return record, nil
	}
	if writeErr != nil {
		return Record{}, sanitizeStorageError(ctx, writeErr)
	}
	return Record{}, ErrStorage
}

func validSystemAck(acks []*api.StorageObjectAck, key string) bool {
	return len(acks) == 1 &&
		acks[0] != nil &&
		acks[0].GetCollection() == Collection &&
		acks[0].GetKey() == key &&
		acks[0].GetUserId() == systemOwnerID &&
		acks[0].GetVersion() != ""
}

type characterDocument struct {
	Schema      int
	CharacterID string
	DisplayName string
	Recipe      json.RawMessage
}

func encodeCharacterDocument(
	character Character,
) (json.RawMessage, error) {
	if invalidIdentityPart(character.ID) ||
		strings.TrimSpace(character.DisplayName) == "" {
		return nil, errors.New(
			"nakama character: valid character is required",
		)
	}
	recipe, err := canonicalObject(character.Recipe)
	if err != nil {
		return nil, errors.New(
			"nakama character: recipe must be a JSON object",
		)
	}
	normalized := Character{
		ID:          character.ID,
		DisplayName: character.DisplayName,
		Recipe:      recipe,
	}
	value, err := json.Marshal(struct {
		Schema      int             `json:"schema"`
		CharacterID string          `json:"character_id"`
		DisplayName string          `json:"display_name"`
		Recipe      json.RawMessage `json:"recipe"`
	}{
		Schema:      schemaVersion,
		CharacterID: normalized.ID,
		DisplayName: normalized.DisplayName,
		Recipe:      normalized.Recipe,
	})
	if err != nil {
		return nil, errors.New(
			"nakama character: encode character",
		)
	}
	return value, nil
}

func decodeCharacterDocument(value string) (Character, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return Character{}, errors.New("invalid character object")
	}
	document := characterDocument{}
	seen := make(map[string]struct{}, 4)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return Character{}, err
		}
		key, ok := token.(string)
		if !ok {
			return Character{}, errors.New("invalid character field")
		}
		if _, duplicate := seen[key]; duplicate {
			return Character{}, errors.New("duplicate character field")
		}
		seen[key] = struct{}{}
		switch key {
		case "schema":
			err = decoder.Decode(&document.Schema)
		case "character_id":
			err = decoder.Decode(&document.CharacterID)
		case "display_name":
			err = decoder.Decode(&document.DisplayName)
		case "recipe":
			err = decoder.Decode(&document.Recipe)
		default:
			return Character{}, errors.New("unknown character field")
		}
		if err != nil {
			return Character{}, err
		}
	}
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') {
		return Character{}, errors.New("invalid character object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Character{}, errors.New("trailing character content")
	}
	for _, required := range []string{
		"schema",
		"character_id",
		"display_name",
		"recipe",
	} {
		if _, ok := seen[required]; !ok {
			return Character{}, errors.New("missing character field")
		}
	}
	if document.Schema != schemaVersion ||
		invalidIdentityPart(document.CharacterID) ||
		strings.TrimSpace(document.DisplayName) == "" {
		return Character{}, errors.New("invalid character identity")
	}
	recipe, err := canonicalObject(document.Recipe)
	if err != nil {
		return Character{}, err
	}
	return Character{
		ID:          document.CharacterID,
		DisplayName: document.DisplayName,
		Recipe:      recipe,
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

func authenticatedSubjectID(
	ctx context.Context,
	requestedSubjectID string,
) (string, error) {
	if ctx == nil {
		return "", errors.New(
			"nakama character: authenticated subject is required",
		)
	}
	callerSubjectID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	callerSubjectID = strings.ToLower(callerSubjectID)
	requestedSubjectID = strings.ToLower(requestedSubjectID)
	if !ok ||
		!validSubjectID(callerSubjectID) ||
		!validSubjectID(requestedSubjectID) ||
		callerSubjectID != requestedSubjectID {
		return "", errors.New(
			"nakama character: authenticated subject must own the character",
		)
	}
	return callerSubjectID, nil
}

func isHexDigit(char rune) bool {
	return (char >= '0' && char <= '9') ||
		(char >= 'a' && char <= 'f') ||
		(char >= 'A' && char <= 'F')
}

func invalidIdentityPart(value string) bool {
	return strings.TrimSpace(value) == "" ||
		strings.ContainsRune(value, '\x00')
}

func sanitizeStorageError(ctx context.Context, err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case ctx.Err() != nil:
		return ctx.Err()
	default:
		return ErrStorage
	}
}
