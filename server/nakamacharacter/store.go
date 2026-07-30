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

	"github.com/devantler-tech/world-at-ruin/server/playerstate"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// Collection is the private Nakama collection for character records.
	Collection = "world_at_ruin_characters"
	// RecordKey is the one account-owned character document.
	RecordKey = "character"

	schemaVersion = 1
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

// Store owns character records through Nakama storage. Player-owned writes use
// playerstate.Store so the record and its private audit evidence commit
// atomically, as required by docs/design/server-state-durability.md.
type Store struct {
	storage   storageClient
	mutations *playerstate.Store
}

// NewStore builds a character store over Nakama's runtime storage surface.
func NewStore(storage storageClient) (*Store, error) {
	if storage == nil {
		return nil, errors.New("nakama character: storage is required")
	}
	mutations, err := playerstate.NewStore(storage)
	if err != nil {
		return nil, err
	}
	return &Store{
		storage:   storage,
		mutations: mutations,
	}, nil
}

// Load reads the private character belonging to one verified Nakama subject.
func (s *Store) Load(ctx context.Context, subjectID string) (Record, error) {
	subjectID, err := authenticatedSubjectID(ctx, subjectID)
	if err != nil {
		return Record{}, err
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
		object.GetPermissionWrite() != 0 {
		return Record{}, ErrStorage
	}
	character, err := decodeCharacterDocument(object.GetValue())
	if err != nil {
		return Record{}, ErrStorage
	}
	return Record{
		Character: character,
		Version:   object.GetVersion(),
	}, nil
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
			Key:             RecordKey,
			ExpectedVersion: request.ExpectedVersion,
			Value:           value,
		},
		Outcome: outcome,
	})
	return err
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
