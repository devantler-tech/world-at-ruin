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

const testSubjectID = "11111111-1111-4111-8111-111111111111"

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
	objects    map[string]storedObject
	readCalls  int
	readErr    error
	writeCalls [][]*runtime.StorageWrite
	next       int
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
	objects := make([]*api.StorageObject, 0, len(reads))
	for _, read := range reads {
		object, ok := f.objects[storageObjectID(
			read.Collection,
			read.Key,
			read.UserID,
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
		current, exists := f.objects[storageObjectID(
			write.Collection,
			write.Key,
			write.UserID,
		)]
		switch {
		case write.Version == "*" && exists:
			return nil, runtime.ErrStorageRejectedVersion
		case write.Version != "*" &&
			(!exists || write.Version != current.version):
			return nil, runtime.ErrStorageRejectedVersion
		}
	}

	acks := make([]*api.StorageObjectAck, 0, len(writes))
	for _, write := range writes {
		if write.PermissionRead < math.MinInt32 ||
			write.PermissionRead > math.MaxInt32 ||
			write.PermissionWrite < math.MinInt32 ||
			write.PermissionWrite > math.MaxInt32 {
			return nil, errors.New("invalid permission")
		}
		version := fmt.Sprintf("v%d", f.next)
		f.next++
		f.objects[storageObjectID(
			write.Collection,
			write.Key,
			write.UserID,
		)] = storedObject{
			collection:      write.Collection,
			key:             write.Key,
			userID:          write.UserID,
			value:           write.Value,
			version:         version,
			permissionRead:  int32(write.PermissionRead),
			permissionWrite: int32(write.PermissionWrite),
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     write.UserID,
			Version:    version,
		})
	}
	return acks, nil
}

func storageObjectID(collection, key, userID string) string {
	return collection + "\x00" + key + "\x00" + userID
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
	err = firstSession.Save(context.Background(), SaveRequest{
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
		recordWrite.Key != RecordKey ||
		recordWrite.UserID != testSubjectID ||
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
	record, err := laterSession.Load(context.Background(), testSubjectID)
	if err != nil {
		t.Fatalf("later Load() error = %v", err)
	}
	if record.Version == "" || !reflect.DeepEqual(record.Character, character) {
		t.Fatalf("later Load() = %#v, want %#v", record, character)
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
	if err := store.Save(context.Background(), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:create:warden-1",
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}

	character.DisplayName = "Asha the Restorer"
	err = store.Save(context.Background(), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "character:rename:warden-1",
		ExpectedVersion: "stale-version",
		Character:       character,
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("stale Save() error = %v, want %v", err, ErrConflict)
	}
	if len(storage.writeCalls) != 1 {
		t.Fatalf("StorageWrite() calls = %d, want 1", len(storage.writeCalls))
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
	if err := store.Save(context.Background(), SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  idempotencyKey,
		ExpectedVersion: "*",
		Character:       character,
	}); err != nil {
		t.Fatalf("initial Save() error = %v", err)
	}
	record, err := store.Load(context.Background(), testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	character.Recipe = json.RawMessage(`{"body_type":"hero","version":3}`)
	err = store.Save(context.Background(), SaveRequest{
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

func TestSaveCannotOverwriteMalformedDurableCharacterWithItsVersion(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		collection:      Collection,
		key:             RecordKey,
		userID:          testSubjectID,
		value:           `{"schema":1,"character_id":"warden-1"}`,
		version:         "observed-version",
		permissionRead:  0,
		permissionWrite: 0,
	})
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	err = store.Save(context.Background(), SaveRequest{
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
			key:             RecordKey,
			userID:          testSubjectID,
			value:           strings.TrimSpace(string(goldenBytes)),
			version:         "durable-version",
			permissionRead:  0,
			permissionWrite: 0,
		})
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore() error = %v", err)
		}
		record, err := store.Load(context.Background(), testSubjectID)
		if err != nil {
			t.Fatalf("Load(schema %d) error = %v", version, err)
		}
		if record.Character.ID != "warden-1" ||
			record.Character.DisplayName != "Asha" {
			t.Fatalf("Load(schema %d) = %#v", version, record)
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
				key:             RecordKey,
				userID:          testSubjectID,
				value:           test.value,
				version:         "durable-version",
				permissionRead:  test.permissionRead,
				permissionWrite: test.permissionWrite,
			})
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			_, err = store.Load(context.Background(), testSubjectID)
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("Load() error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestLoadRejectsAnUnverifiedSubjectBeforeStorage(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	if _, err := store.Load(
		context.Background(),
		"client-picked-subject",
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
			storage.readErr = test.readErr
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			_, err = store.Load(context.Background(), testSubjectID)
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
