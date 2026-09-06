// Package nakamacharacter persists server-authoritative character records in
// Nakama's system-owned namespace, keyed by verified account identity.
package nakamacharacter

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// Collection is the private Nakama collection for character records.
	Collection = "world_at_ruin_characters"
	// RecordKey is the prefix for account-bound system-owned character documents.
	RecordKey     = "character"
	systemOwnerID = nakamastorage.SystemOwnerID

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

// Store owns system-owned character records through Nakama storage. Writes use
// playerstate.Store so the record and its system-owned audit evidence commit
// atomically, as required by docs/design/server-state-durability.md.
type Store struct {
	storage   nakamastorage.Client
	mutations *playerstate.Store
}

// NewStore builds a character store over Nakama's runtime storage surface.
func NewStore(storage nakamastorage.Client) (*Store, error) {
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
			Key:        characterRecordKey(subjectID),
			UserID:     "",
		},
	})
	if err != nil {
		return Record{}, nakamastorage.SanitizeError(ctx, err, ErrStorage)
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
		object.GetKey() != characterRecordKey(subjectID) ||
		object.GetUserId() != systemOwnerID ||
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

type characterDocument struct {
	Schema      int
	CharacterID string
	DisplayName string
	Recipe      json.RawMessage
}

func encodeCharacterDocument(
	character Character,
) (json.RawMessage, error) {
	if nakamastorage.InvalidIdentityPart(character.ID) ||
		strings.TrimSpace(character.DisplayName) == "" {
		return nil, errors.New(
			"nakama character: valid character is required",
		)
	}
	recipe, err := nakamastorage.CanonicalObject(character.Recipe)
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
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return Character{}, err
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
	if err := nakamastorage.EndObject(decoder); err != nil {
		return Character{}, err
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
		nakamastorage.InvalidIdentityPart(document.CharacterID) ||
		strings.TrimSpace(document.DisplayName) == "" {
		return Character{}, errors.New("invalid character identity")
	}
	recipe, err := nakamastorage.CanonicalObject(document.Recipe)
	if err != nil {
		return Character{}, err
	}
	return Character{
		ID:          document.CharacterID,
		DisplayName: document.DisplayName,
		Recipe:      recipe,
	}, nil
}

func authenticatedSubjectID(
	ctx context.Context,
	requestedSubjectID string,
) (string, error) {
	subjectID, ok := nakamastorage.AuthenticatedSubjectID(ctx, requestedSubjectID)
	if !ok {
		return "", errors.New(
			"nakama character: authenticated subject must own the character",
		)
	}
	return subjectID, nil
}
