package nakamacharacter

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/savefixturetest"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	testSubjectID      = "11111111-1111-4111-8111-111111111111"
	testOtherSubjectID = "22222222-2222-4222-8222-222222222222"
)

type nakamaSessionContext struct {
	context.Context
	userID string
}

func (c nakamaSessionContext) Value(key any) any {
	if key == runtime.RUNTIME_CTX_USER_ID {
		return c.userID
	}
	return c.Context.Value(key)
}

func authenticatedContext(userID string) context.Context {
	return nakamaSessionContext{
		Context: context.Background(),
		userID:  userID,
	}
}

type storedObject = nakamastoragetest.Object

type fakeStorage struct {
	*nakamastoragetest.Fake
	systemReadOverride       []*api.StorageObject
	systemReadOverrideActive bool
}

func newFakeStorage() *fakeStorage {
	return &fakeStorage{Fake: nakamastoragetest.New()}
}

func (f *fakeStorage) seed(object storedObject) { f.Seed(object) }

// Malformed raw replies stay injectable without passing through the fake's
// normal object projection. A configured storage error retains precedence.
func (f *fakeStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	if f.ReadErr == nil && f.systemReadOverrideActive && len(reads) == 1 &&
		reads[0].Collection == Collection && reads[0].Key == characterRecordKey(testSubjectID) && reads[0].UserID == "" {
		f.ReadCalls++
		return f.systemReadOverride, nil
	}
	return f.Fake.StorageRead(ctx, reads)
}

func TestFakeStorageRejectsAnInvalidBatchBeforeAnyMutation(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	_, err := storage.StorageWrite(context.Background(), []*runtime.StorageWrite{
		{
			Collection:      Collection,
			Key:             RecordKey,
			UserID:          testSubjectID,
			Value:           `{}`,
			Version:         "*",
			PermissionRead:  0,
			PermissionWrite: 0,
		},
		{
			Collection:     "invalid-permission",
			Key:            "audit",
			UserID:         testSubjectID,
			Value:          `{}`,
			Version:        "*",
			PermissionRead: math.MaxInt32 + 1,
		},
	})
	if err == nil {
		t.Fatal("StorageWrite() error = nil")
	}
	if len(storage.Objects()) != 0 || storage.NextVersion() != 1 {
		t.Fatalf(
			"failed batch mutated storage: objects %d, next %d",
			len(storage.Objects()),
			storage.NextVersion(),
		)
	}
}

func TestSavePersistsPrivateVersionedCharacterForVerifiedAccount(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	firstSession, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	character := Character{
		ID:          "warden-1",
		DisplayName: "Asha",
		Recipe: json.RawMessage(
			`{"body_type":"hero","version":3}`,
		),
	}
	err = firstSession.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       character,
	})
	if err != nil {
		t.Fatalf("Save() error = %v", err)
	}

	if len(storage.WriteCalls) != 1 ||
		len(storage.WriteCalls[0]) != 2 {
		t.Fatalf(
			"atomic StorageWrite() calls = %#v, want one record+audit write",
			storage.WriteCalls,
		)
	}
	recordWrite := storage.WriteCalls[0][0]
	if recordWrite.Collection != Collection ||
		recordWrite.Key != "character:"+testSubjectID ||
		recordWrite.UserID != "" ||
		recordWrite.Version != "*" ||
		recordWrite.PermissionRead != 0 ||
		recordWrite.PermissionWrite != 0 {
		t.Fatalf("character write = %#v", recordWrite)
	}
	const wantValue = `{"character_id":"warden-1","display_name":"Asha",` +
		`"recipe":{"body_type":"hero","version":3},"schema":1}`
	if recordWrite.Value != wantValue {
		t.Fatalf("character value = %s, want %s", recordWrite.Value, wantValue)
	}

	laterSession, err := NewStore(storage)
	if err != nil {
		t.Fatalf("later NewStore() error = %v", err)
	}
	record, err := laterSession.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	)
	if err != nil {
		t.Fatalf("later Load() error = %v", err)
	}
	if record.Version == "" || !reflect.DeepEqual(record.Character, character) {
		t.Fatalf("later Load() = %#v, want %#v", record, character)
	}
}

// TestSaveRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage prevents an authenticated
// player from writing another player's character.
func TestSaveRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	err := store.Save(authenticatedContext(testOtherSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       canonicalCharacter(),
	})
	requireSaveRejectedBeforeStorage(t, storage, err)
}

// TestSaveRejectsAnEmptyObservedVersionBeforeStorage rejects a write without an observed version
// before reading or mutating storage.
func TestSaveRejectsAnEmptyObservedVersionBeforeStorage(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:      testSubjectID,
		IdempotencyKey: "character:create:warden-1",
		Character:      canonicalCharacter(),
	})
	requireSaveRejectedBeforeStorage(t, storage, err)
}

// TestSaveRefusesAStaleObservedVersion preserves the stored character when a replacement uses an
// obsolete version.
func TestSaveRefusesAStaleObservedVersion(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	character := canonicalCharacter()
	createCharacter(t, store, character, "character:create:warden-1")

	character.DisplayName = "Asha the Restorer"
	err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:rename:warden-1",
		ExpectedVersion: "stale-version",
		Character:       character,
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("stale Save() error = %v, want %v", err, ErrConflict)
	}
	if len(storage.WriteCalls) != 2 {
		t.Fatalf("StorageWrite() calls = %d, want 2", len(storage.WriteCalls))
	}
	record, err := store.Load(authenticatedContext(testSubjectID), testSubjectID)
	if err != nil {
		t.Fatalf("Load() after stale write error = %v", err)
	}
	if record.Character.DisplayName != "Asha" {
		t.Fatalf(
			"character after stale write = %#v, want original",
			record.Character,
		)
	}
}

// TestSaveRejectsIdempotencyKeyReuseForDifferentCharacterState prevents one committed operation key
// from authorizing a different replacement.
func TestSaveRejectsIdempotencyKeyReuseForDifferentCharacterState(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	character := canonicalCharacter()
	const idempotencyKey = "character:create:warden-1"
	createCharacter(t, store, character, idempotencyKey)
	record, err := store.Load(authenticatedContext(testSubjectID), testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	character.Recipe = json.RawMessage(`{"body_type":"hero","version":3}`)
	err = store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  idempotencyKey,
		ExpectedVersion: record.Version,
		Character:       character,
	})
	if !errors.Is(err, ErrKeyConflict) {
		t.Fatalf(
			"reused-key Save() error = %v, want %v",
			err,
			ErrKeyConflict,
		)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf(
			"StorageWrite() calls after rejected reuse = %d, want 1",
			len(storage.WriteCalls),
		)
	}
}

// TestSaveReplaysACommittedReplacementWithItsStaleObservedVersion allows an exact retry to recover
// its prior success without rewriting the character.
func TestSaveReplaysACommittedReplacementWithItsStaleObservedVersion(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	character := canonicalCharacter()
	createCharacter(t, store, character, "character:create:warden-1")
	record, err := store.Load(authenticatedContext(testSubjectID), testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	character.DisplayName = "Asha the Restorer"
	request := SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:rename:warden-1",
		ExpectedVersion: record.Version,
		Character:       character,
	}
	if err := store.Save(authenticatedContext(testSubjectID), request); err != nil {
		t.Fatalf("replacement Save() error = %v", err)
	}
	if err := store.Save(authenticatedContext(testSubjectID), request); err != nil {
		t.Fatalf("replayed Save() error = %v, want nil", err)
	}
	if len(storage.WriteCalls) != 2 {
		t.Fatalf(
			"StorageWrite() calls after replay = %d, want 2",
			len(storage.WriteCalls),
		)
	}
}

// TestSaveCannotOverwriteMalformedDurableCharacterWithItsVersion prevents an observed version from
// laundering invalid stored character data.
func TestSaveCannotOverwriteMalformedDurableCharacterWithItsVersion(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		Collection:      Collection,
		Key:             characterRecordKey(testSubjectID),
		UserID:          systemOwnerID,
		Value:           `{"schema":1,"character_id":"warden-1"}`,
		Version:         "observed-version",
		PermissionRead:  0,
		PermissionWrite: 0,
	})
	store := mustCharacterStore(t, storage)
	err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:repair:warden-1",
		ExpectedVersion: "observed-version",
		Character:       canonicalCharacter(),
	})
	if !errors.Is(err, ErrStorage) {
		t.Fatalf("Save() error = %v, want %v", err, ErrStorage)
	}
	if len(storage.WriteCalls) != 0 {
		t.Fatalf(
			"StorageWrite() calls after quarantine = %d, want 0",
			len(storage.WriteCalls),
		)
	}
}

// TestClientOwnedCharacterPreseedCannotBecomeAuthoritative rejects forged records in the
// player-owned storage namespace.
func TestClientOwnedCharacterPreseedCannotBecomeAuthoritative(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	seedUntrustedCharacter(storage, "character:"+testSubjectID)
	store := mustCharacterStore(t, storage)
	if _, err := store.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() error = %v, want %v", err, ErrNotFound)
	}
	storage.systemReadOverrideActive = true
	seeded, _ := storage.Get(Collection, "character:"+testSubjectID, testSubjectID)
	storage.systemReadOverride = []*api.StorageObject{
		{
			Collection:      Collection,
			Key:             "character:" + testSubjectID,
			UserId:          testSubjectID,
			Value:           seeded.Value,
			Version:         "wrong-owner-version",
			PermissionRead:  0,
			PermissionWrite: 0,
		},
	}
	if _, err := store.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	); !errors.Is(err, ErrStorage) {
		t.Fatalf("Load() wrong-owner error = %v, want %v", err, ErrStorage)
	}
	storage.systemReadOverrideActive = false
	if err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       canonicalCharacter(),
	}); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	record, err := store.Load(authenticatedContext(testSubjectID), testSubjectID)
	if err != nil {
		t.Fatalf("Load() after Save error = %v", err)
	}
	if record.Character.ID != "warden-1" {
		t.Fatalf("authoritative character ID = %q", record.Character.ID)
	}
}

// TestLegacyPlayerOwnedCharacterCannotBecomeAuthoritative keeps legacy player-owned records outside
// the authoritative character path.
func TestLegacyPlayerOwnedCharacterCannotBecomeAuthoritative(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	seedUntrustedCharacter(storage, RecordKey)
	store := mustCharacterStore(t, storage)
	if _, err := store.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() error = %v, want %v", err, ErrNotFound)
	}
	if len(storage.WriteCalls) != 0 {
		t.Fatalf("legacy object triggered writes: %#v", storage.WriteCalls)
	}
}

// TestLoadKeepsEveryShippedCharacterSchemaReadable uses independent historical fixtures to preserve
// all shipped character readers.
func TestLoadKeepsEveryShippedCharacterSchemaReadable(t *testing.T) {
	t.Parallel()

	for _, fixture := range savefixturetest.Read(t, "character") {
		version, goldenBytes := fixture.Version, fixture.Bytes
		storage := newFakeStorage()
		storage.seed(storedObject{
			Collection:      Collection,
			Key:             characterRecordKey(testSubjectID),
			UserID:          systemOwnerID,
			Value:           strings.TrimSpace(string(goldenBytes)),
			Version:         "durable-version",
			PermissionRead:  0,
			PermissionWrite: 0,
		})
		store := mustCharacterStore(t, storage)
		record, err := store.Load(
			authenticatedContext(testSubjectID),
			testSubjectID,
		)
		if err != nil {
			t.Fatalf("Load(schema %d) error = %v", version, err)
		}
		want := Character{
			ID:          "warden-1",
			DisplayName: "Asha",
			Recipe: json.RawMessage(
				`{"body_type":"hero","version":3}`,
			),
		}
		if !reflect.DeepEqual(record.Character, want) {
			t.Fatalf(
				"Load(schema %d) = %#v, want %#v",
				version,
				record.Character,
				want,
			)
		}
	}
}

// TestLoadRejectsMalformedOrPublicCharacterRecords rejects invalid character data and records with
// public storage permissions.
func TestLoadRejectsMalformedOrPublicCharacterRecords(t *testing.T) {
	t.Parallel()

	const valid = `{"schema":1,"character_id":"warden-1",` +
		`"display_name":"Asha","recipe":{"version":3}}`
	tests := []struct {
		name            string
		value           string
		permissionRead  int32
		permissionWrite int32
		wantErr         error
	}{
		{
			name: "duplicate field",
			value: `{"schema":1,"schema":1,"character_id":"warden-1",` +
				`"display_name":"Asha","recipe":{"version":3}}`,
			wantErr: ErrStorage,
		},
		{
			name:    "unknown field",
			value:   strings.TrimSuffix(valid, "}") + `,"extra":true}`,
			wantErr: ErrStorage,
		},
		{
			name: "missing required field",
			value: `{"schema":1,"character_id":"warden-1",` +
				`"display_name":"Asha"}`,
			wantErr: ErrStorage,
		},
		{
			name:    "trailing content",
			value:   valid + ` []`,
			wantErr: ErrStorage,
		},
		{
			name:    "unsupported schema",
			value:   strings.Replace(valid, `"schema":1`, `"schema":2`, 1),
			wantErr: ErrStorage,
		},
		{
			name:           "client-readable",
			value:          valid,
			permissionRead: 2,
			wantErr:        ErrStorage,
		},
		{
			name:            "client-writable",
			value:           valid,
			permissionWrite: 1,
			wantErr:         ErrStorage,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := newFakeStorage()
			storage.seed(storedObject{
				Collection:      Collection,
				Key:             characterRecordKey(testSubjectID),
				UserID:          systemOwnerID,
				Value:           test.value,
				Version:         "durable-version",
				PermissionRead:  test.permissionRead,
				PermissionWrite: test.permissionWrite,
			})
			store := mustCharacterStore(t, storage)
			_, err := store.Load(
				authenticatedContext(testSubjectID),
				testSubjectID,
			)
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("Load() error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

// TestLoadRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage prevents a player from
// loading another player's character before storage access.
func TestLoadRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store := mustCharacterStore(t, storage)
	if _, err := store.Load(
		authenticatedContext(testOtherSubjectID),
		testSubjectID,
	); err == nil {
		t.Fatal("Load() error = nil")
	}
	if storage.ReadCalls != 0 {
		t.Fatalf("StorageRead() calls = %d, want 0", storage.ReadCalls)
	}
}

// TestLoadSanitizesStorageFailuresAndPreservesCancellation keeps backend details private while
// preserving cancellation and stable error codes.
func TestLoadSanitizesStorageFailuresAndPreservesCancellation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		readErr error
		wantErr error
	}{
		{
			name:    "storage details",
			readErr: errors.New("database host and credential detail"),
			wantErr: ErrStorage,
		},
		{
			name:    "canceled",
			readErr: context.Canceled,
			wantErr: context.Canceled,
		},
		{
			name:    "deadline",
			readErr: context.DeadlineExceeded,
			wantErr: context.DeadlineExceeded,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := newFakeStorage()
			store := mustCharacterStore(t, storage)
			storage.ReadErr = test.readErr
			_, err := store.Load(
				authenticatedContext(testSubjectID),
				testSubjectID,
			)
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("Load() error = %v, want %v", err, test.wantErr)
			}
			if errors.Is(test.wantErr, ErrStorage) &&
				strings.Contains(err.Error(), "database host") {
				t.Fatalf("Load() leaked storage detail: %v", err)
			}
		})
	}
}

// mustCharacterStore constructs the real character store around the requested storage fixture.
func mustCharacterStore(t *testing.T, storage *fakeStorage) *Store {
	t.Helper()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	return store
}

// canonicalCharacter returns a fresh canonical character, including independently owned recipe
// bytes.
func canonicalCharacter() Character {
	return Character{
		ID:          "warden-1",
		DisplayName: "Asha",
		Recipe:      json.RawMessage(`{"version":3}`),
	}
}

// createCharacter saves the initial character through the real create-only, authenticated store
// path.
func createCharacter(t *testing.T, store *Store, character Character, key string) {
	t.Helper()
	if err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  key,
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}
}

// seedUntrustedCharacter inserts a forged player-owned record to test the authoritative ownership
// boundary.
func seedUntrustedCharacter(storage *fakeStorage, key string) {
	storage.seed(storedObject{
		Collection:      Collection,
		Key:             key,
		UserID:          testSubjectID,
		Value:           `{"schema":1,"character_id":"attacker-seeded","display_name":"Mallory","recipe":{"gold":999999}}`,
		Version:         "client-created-version",
		PermissionRead:  0,
		PermissionWrite: 0,
	})
}

// requireSaveRejectedBeforeStorage requires an error with no storage reads or writes.
func requireSaveRejectedBeforeStorage(t *testing.T, storage *fakeStorage, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("Save() error = nil")
	}
	if storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
		t.Fatalf("storage calls before rejection = reads %d, writes %d", storage.ReadCalls, len(storage.WriteCalls))
	}
}
