package nakamaauth

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	testBoundUserID  = "11111111-1111-4111-8111-111111111111"
	testWinnerUserID = "22222222-2222-4222-8222-222222222222"
)

type bindingMemoryStorage struct {
	mu             sync.Mutex
	object         *api.StorageObject
	writes         []*runtime.StorageWrite
	readErr        error
	writeErr       error
	conflictWinner string
}

func (s *bindingMemoryStorage) StorageRead(
	_ context.Context,
	_ []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readErr != nil {
		return nil, s.readErr
	}
	if s.object == nil {
		return nil, nil
	}
	return []*api.StorageObject{{
		Collection:      s.object.GetCollection(),
		Key:             s.object.GetKey(),
		UserId:          s.object.GetUserId(),
		Value:           s.object.GetValue(),
		Version:         s.object.GetVersion(),
		PermissionRead:  s.object.GetPermissionRead(),
		PermissionWrite: s.object.GetPermissionWrite(),
	}}, nil
}

func (s *bindingMemoryStorage) StorageWrite(
	_ context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, write := range writes {
		copy := *write
		s.writes = append(s.writes, &copy)
	}
	if s.conflictWinner != "" && s.object == nil {
		s.object = bindingObjectForTest(
			writes[0].Key,
			s.conflictWinner,
			"winner-version",
		)
		return nil, runtime.ErrStorageRejectedVersion
	}
	if s.writeErr != nil {
		return nil, s.writeErr
	}
	if s.object != nil {
		return nil, runtime.ErrStorageRejectedVersion
	}
	s.object = bindingObjectForTest(writes[0].Key, testBoundUserID, "created-version")
	return []*api.StorageObjectAck{{
		Collection: googleBindingCollection,
		Key:        writes[0].Key,
		UserId:     googleBindingSystemOwnerID,
		Version:    "created-version",
	}}, nil
}

func bindingObjectForTest(key string, userID string, version string) *api.StorageObject {
	value, _ := json.Marshal(map[string]any{
		"schema":  1,
		"user_id": userID,
	})
	return &api.StorageObject{
		Collection:      googleBindingCollection,
		Key:             key,
		UserId:          googleBindingSystemOwnerID,
		Value:           string(value),
		Version:         version,
		PermissionRead:  0,
		PermissionWrite: 0,
	}
}

func TestNakamaGoogleBindingStoreCreatesPrivateImmutableBinding(t *testing.T) {
	storage := &bindingMemoryStorage{}
	store, err := NewNakamaGoogleBindingStore(storage)
	if err != nil {
		t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
	}
	key := googleBindingKey([]byte(testNakamaIdentityKey), testGoogleSubject)

	userID, found, err := store.ResolveGoogleBinding(context.Background(), key)
	if err != nil || found || userID != "" {
		t.Fatalf(
			"empty ResolveGoogleBinding = (%q, %t, %v), want empty, false, nil",
			userID,
			found,
			err,
		)
	}
	first, err := store.BindGoogleIdentity(context.Background(), key, testBoundUserID)
	if err != nil || first != testBoundUserID {
		t.Fatalf("first BindGoogleIdentity = (%q, %v), want bound user", first, err)
	}
	repeated, err := store.BindGoogleIdentity(context.Background(), key, testWinnerUserID)
	if err != nil || repeated != testBoundUserID {
		t.Fatalf(
			"repeated BindGoogleIdentity = (%q, %v), want immutable first user %q",
			repeated,
			err,
			testBoundUserID,
		)
	}

	storage.mu.Lock()
	defer storage.mu.Unlock()
	if len(storage.writes) != 1 {
		t.Fatalf("StorageWrite calls = %d, want 1", len(storage.writes))
	}
	write := storage.writes[0]
	if write.UserID != "" ||
		write.Version != "*" ||
		write.PermissionRead != 0 ||
		write.PermissionWrite != 0 {
		t.Fatalf("binding write was not system-owned create-only private storage: %+v", write)
	}
}

func TestNakamaGoogleBindingStoreAdoptsConcurrentWinner(t *testing.T) {
	storage := &bindingMemoryStorage{conflictWinner: testWinnerUserID}
	store, err := NewNakamaGoogleBindingStore(storage)
	if err != nil {
		t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
	}
	key := googleBindingKey([]byte(testNakamaIdentityKey), testGoogleSubject)

	userID, err := store.BindGoogleIdentity(context.Background(), key, testBoundUserID)
	if err != nil {
		t.Fatalf("BindGoogleIdentity returned an error: %v", err)
	}
	if userID != testWinnerUserID {
		t.Fatalf("BindGoogleIdentity user ID = %q, want winner %q", userID, testWinnerUserID)
	}
}

func TestNakamaGoogleBindingStoreRejectsMalformedDurableRecord(t *testing.T) {
	tests := []struct {
		name      string
		configure func(*api.StorageObject)
	}{
		{
			name: "client writable",
			configure: func(object *api.StorageObject) {
				object.PermissionWrite = 1
			},
		},
		{
			name: "system owner as player",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"00000000-0000-0000-0000-000000000000"}`
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			key := googleBindingKey([]byte(testNakamaIdentityKey), testGoogleSubject)
			storage := &bindingMemoryStorage{
				object: bindingObjectForTest(key, testBoundUserID, "v1"),
			}
			test.configure(storage.object)
			store, err := NewNakamaGoogleBindingStore(storage)
			if err != nil {
				t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
			}

			_, _, err = store.ResolveGoogleBinding(context.Background(), key)
			if !errors.Is(err, ErrGoogleBindingStorage) {
				t.Fatalf(
					"ResolveGoogleBinding error = %v, want ErrGoogleBindingStorage",
					err,
				)
			}
		})
	}
}
