package nakamacharacter

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

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

type storedObject struct {
	collection      string
	key             string
	userID          string
	value           string
	version         string
	permissionRead  int32
	permissionWrite int32
}

type fakeStorage struct {
	objects                  map[string]storedObject
	readCalls                int
	readErr                  error
	writeCalls               [][]*runtime.StorageWrite
	next                     int
	systemReadOverride       []*api.StorageObject
	systemReadOverrideActive bool
}

func newFakeStorage() *fakeStorage {
	return &fakeStorage{
		objects: make(map[string]storedObject),
		next:    1,
	}
}

func (f *fakeStorage) seed(object storedObject) {
	f.objects[storageObjectID(object.collection, object.key, object.userID)] = object
}

func (f *fakeStorage) StorageRead(
	_ context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	f.readCalls++
	if f.readErr != nil {
		return nil, f.readErr
	}
	if f.systemReadOverrideActive && len(reads) == 1 &&
		reads[0].Collection == Collection &&
		reads[0].Key == characterRecordKey(testSubjectID) &&
		reads[0].UserID == "" {
		return f.systemReadOverride, nil
	}
	objects := make([]*api.StorageObject, 0, len(reads))
	for _, read := range reads {
		ownerID := read.UserID
		if ownerID == "" {
			ownerID = systemOwnerID
		}
		object, ok := f.objects[storageObjectID(
			read.Collection,
			read.Key,
			ownerID,
		)]
		if !ok {
			continue
		}
		objects = append(objects, &api.StorageObject{
			Collection:      object.collection,
			Key:             object.key,
			UserId:          object.userID,
			Value:           object.value,
			Version:         object.version,
			PermissionRead:  object.permissionRead,
			PermissionWrite: object.permissionWrite,
		})
	}
	return objects, nil
}

func (f *fakeStorage) StorageWrite(
	_ context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	call := make([]*runtime.StorageWrite, len(writes))
	copy(call, writes)
	f.writeCalls = append(f.writeCalls, call)

	for _, write := range writes {
		ownerID := write.UserID
		if ownerID == "" {
			ownerID = systemOwnerID
		}
		current, exists := f.objects[storageObjectID(
			write.Collection,
			write.Key,
			ownerID,
		)]
		switch {
		case write.Version == "*" && exists:
			return nil, runtime.ErrStorageRejectedVersion
		case write.Version != "" &&
			write.Version != "*" &&
			(!exists || write.Version != current.version):
			return nil, runtime.ErrStorageRejectedVersion
		}
	}

	type permissions struct {
		read  int32
		write int32
	}
	validatedPermissions := make([]permissions, len(writes))
	for index, write := range writes {
		if write.PermissionRead < math.MinInt32 ||
			write.PermissionRead > math.MaxInt32 ||
			write.PermissionWrite < math.MinInt32 ||
			write.PermissionWrite > math.MaxInt32 {
			return nil, errors.New("invalid permission")
		}
		validatedPermissions[index] = permissions{
			read:  int32(write.PermissionRead),
			write: int32(write.PermissionWrite),
		}
	}

	acks := make([]*api.StorageObjectAck, 0, len(writes))
	for index, write := range writes {
		ownerID := write.UserID
		if ownerID == "" {
			ownerID = systemOwnerID
		}
		version := fmt.Sprintf("v%d", f.next)
		f.next++
		f.objects[storageObjectID(
			write.Collection,
			write.Key,
			ownerID,
		)] = storedObject{
			collection:      write.Collection,
			key:             write.Key,
			userID:          ownerID,
			value:           write.Value,
			version:         version,
			permissionRead:  validatedPermissions[index].read,
			permissionWrite: validatedPermissions[index].write,
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     ownerID,
			Version:    version,
		})
	}
	return acks, nil
}

func storageObjectID(collection, key, userID string) string {
	return collection + "\x00" + key + "\x00" + userID
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
	if len(storage.objects) != 0 || storage.next != 1 {
		t.Fatalf(
			"failed batch mutated storage: objects %d, next %d",
			len(storage.objects),
			storage.next,
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

	if len(storage.writeCalls) != 1 ||
		len(storage.writeCalls[0]) != 2 {
		t.Fatalf(
			"atomic StorageWrite() calls = %#v, want one record+audit write",
			storage.writeCalls,
		)
	}
	recordWrite := storage.writeCalls[0][0]
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

func TestSaveRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	err = store.Save(authenticatedContext(testOtherSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character: Character{
			ID:          "warden-1",
			DisplayName: "Asha",
			Recipe:      json.RawMessage(`{"version":3}`),
		},
	})
	if err == nil {
		t.Fatal("Save() error = nil")
	}
	if storage.readCalls != 0 || len(storage.writeCalls) != 0 {
		t.Fatalf(
			"storage calls before rejection = reads %d, writes %d",
			storage.readCalls,
			len(storage.writeCalls),
		)
	}
}

func TestSaveRejectsAnEmptyObservedVersionBeforeStorage(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	err = store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:      testSubjectID,
		IdempotencyKey: "character:create:warden-1",
		Character: Character{
			ID:          "warden-1",
			DisplayName: "Asha",
			Recipe:      json.RawMessage(`{"version":3}`),
		},
	})
	if err == nil {
		t.Fatal("Save() error = nil")
	}
	if storage.readCalls != 0 || len(storage.writeCalls) != 0 {
		t.Fatalf(
			"storage calls before rejection = reads %d, writes %d",
			storage.readCalls,
			len(storage.writeCalls),
		)
	}
}

func TestSaveRefusesAStaleObservedVersion(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	character := Character{
		ID:          "warden-1",
		DisplayName: "Asha",
		Recipe:      json.RawMessage(`{"version":3}`),
	}
	if err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}

	character.DisplayName = "Asha the Restorer"
	err = store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:rename:warden-1",
		ExpectedVersion: "stale-version",
		Character:       character,
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("stale Save() error = %v, want %v", err, ErrConflict)
	}
	if len(storage.writeCalls) != 2 {
		t.Fatalf("StorageWrite() calls = %d, want 2", len(storage.writeCalls))
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

func TestSaveRejectsIdempotencyKeyReuseForDifferentCharacterState(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	character := Character{
		ID:          "warden-1",
		DisplayName: "Asha",
		Recipe:      json.RawMessage(`{"version":3}`),
	}
	const idempotencyKey = "character:create:warden-1"
	if err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  idempotencyKey,
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}
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
	if len(storage.writeCalls) != 1 {
		t.Fatalf(
			"StorageWrite() calls after rejected reuse = %d, want 1",
			len(storage.writeCalls),
		)
	}
}

func TestSaveReplaysACommittedReplacementWithItsStaleObservedVersion(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	character := Character{
		ID:          "warden-1",
		DisplayName: "Asha",
		Recipe:      json.RawMessage(`{"version":3}`),
	}
	if err := store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}
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
	if len(storage.writeCalls) != 2 {
		t.Fatalf(
			"StorageWrite() calls after replay = %d, want 2",
			len(storage.writeCalls),
		)
	}
}

func TestSaveCannotOverwriteMalformedDurableCharacterWithItsVersion(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		collection:      Collection,
		key:             characterRecordKey(testSubjectID),
		userID:          systemOwnerID,
		value:           `{"schema":1,"character_id":"warden-1"}`,
		version:         "observed-version",
		permissionRead:  0,
		permissionWrite: 0,
	})
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	err = store.Save(authenticatedContext(testSubjectID), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:repair:warden-1",
		ExpectedVersion: "observed-version",
		Character: Character{
			ID:          "warden-1",
			DisplayName: "Asha",
			Recipe:      json.RawMessage(`{"version":3}`),
		},
	})
	if !errors.Is(err, ErrStorage) {
		t.Fatalf("Save() error = %v, want %v", err, ErrStorage)
	}
	if len(storage.writeCalls) != 0 {
		t.Fatalf(
			"StorageWrite() calls after quarantine = %d, want 0",
			len(storage.writeCalls),
		)
	}
}

func TestClientOwnedCharacterPreseedCannotBecomeAuthoritative(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		collection: Collection,
		key:        "character:" + testSubjectID,
		userID:     testSubjectID,
		value: `{"schema":1,"character_id":"attacker-seeded",` +
			`"display_name":"Mallory","recipe":{"gold":999999}}`,
		version:         "client-created-version",
		permissionRead:  0,
		permissionWrite: 0,
	})
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	if _, err := store.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() error = %v, want %v", err, ErrNotFound)
	}
	storage.systemReadOverrideActive = true
	storage.systemReadOverride = []*api.StorageObject{
		{
			Collection: Collection,
			Key:        "character:" + testSubjectID,
			UserId:     testSubjectID,
			Value: storage.objects[storageObjectID(
				Collection,
				"character:"+testSubjectID,
				testSubjectID,
			)].value,
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
		Character: Character{
			ID:          "warden-1",
			DisplayName: "Asha",
			Recipe:      json.RawMessage(`{"version":3}`),
		},
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

func TestLegacyPlayerOwnedCharacterCannotBecomeAuthoritative(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		collection: Collection,
		key:        RecordKey,
		userID:     testSubjectID,
		value: `{"schema":1,"character_id":"attacker-seeded",` +
			`"display_name":"Mallory","recipe":{"gold":999999}}`,
		version:         "client-created-version",
		permissionRead:  0,
		permissionWrite: 0,
	})
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	if _, err := store.Load(
		authenticatedContext(testSubjectID),
		testSubjectID,
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() error = %v, want %v", err, ErrNotFound)
	}
	if len(storage.writeCalls) != 0 {
		t.Fatalf("legacy object triggered writes: %#v", storage.writeCalls)
	}
}

func TestLoadKeepsEveryShippedCharacterSchemaReadable(t *testing.T) {
	t.Parallel()

	ledgerBytes, err := os.ReadFile(filepath.Join(
		"testdata",
		"shipped_character_versions.txt",
	))
	if err != nil {
		t.Fatalf("read character schema ledger: %v", err)
	}
	versions := strings.Fields(string(ledgerBytes))
	if len(versions) == 0 {
		t.Fatal("character schema ledger is empty")
	}
	for index, rawVersion := range versions {
		version, err := strconv.Atoi(rawVersion)
		if err != nil {
			t.Fatalf("schema ledger entry %q: %v", rawVersion, err)
		}
		if version != index+1 {
			t.Fatalf("schema ledger[%d] = %d, want %d", index, version, index+1)
		}
		goldenBytes, err := os.ReadFile(filepath.Join(
			"testdata",
			fmt.Sprintf("golden_character_v%d.json", version),
		))
		if err != nil {
			t.Fatalf("read character schema %d golden: %v", version, err)
		}
		storage := newFakeStorage()
		storage.seed(storedObject{
			collection:      Collection,
			key:             characterRecordKey(testSubjectID),
			userID:          systemOwnerID,
			value:           strings.TrimSpace(string(goldenBytes)),
			version:         "durable-version",
			permissionRead:  0,
			permissionWrite: 0,
		})
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore() error = %v", err)
		}
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
				collection:      Collection,
				key:             characterRecordKey(testSubjectID),
				userID:          systemOwnerID,
				value:           test.value,
				version:         "durable-version",
				permissionRead:  test.permissionRead,
				permissionWrite: test.permissionWrite,
			})
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			_, err = store.Load(
				authenticatedContext(testSubjectID),
				testSubjectID,
			)
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("Load() error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestLoadRejectsAnOwnerDifferentFromAuthenticatedCallerBeforeStorage(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	if _, err := store.Load(
		authenticatedContext(testOtherSubjectID),
		testSubjectID,
	); err == nil {
		t.Fatal("Load() error = nil")
	}
	if storage.readCalls != 0 {
		t.Fatalf("StorageRead() calls = %d, want 0", storage.readCalls)
	}
}

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
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			storage.readErr = test.readErr
			_, err = store.Load(
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
