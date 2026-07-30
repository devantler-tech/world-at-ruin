package nakamaauth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const (
	testBoundUserID  = "11111111-1111-4111-8111-111111111111"
	testWinnerUserID = "22222222-2222-4222-8222-222222222222"
)

type bindingMemoryStorage struct {
	mu              sync.Mutex
	object          *api.StorageObject
	writes          []*runtime.StorageWrite
	readErr         error
	writeErr        error
	conflictWinner  string
	accountErr      error
	accountDisabled bool
	accountUserID   string
	accountCalls    int
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
		stored := *write
		s.writes = append(s.writes, &stored)
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
	document, err := decodeGoogleBindingDocument(writes[0].Value)
	if err != nil {
		return nil, err
	}
	s.object = bindingObjectForTest(writes[0].Key, document.UserID, "created-version")
	return []*api.StorageObjectAck{{
		Collection: googleBindingCollection,
		Key:        writes[0].Key,
		UserId:     googleBindingSystemOwnerID,
		Version:    "created-version",
	}}, nil
}

func (s *bindingMemoryStorage) AccountGetId(
	_ context.Context,
	userID string,
) (*api.Account, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accountCalls++
	if s.accountErr != nil {
		return nil, s.accountErr
	}
	if s.accountUserID != "" {
		userID = s.accountUserID
	}
	account := &api.Account{User: &api.User{Id: userID}}
	if s.accountDisabled {
		account.DisableTime = timestamppb.Now()
	}
	return account, nil
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
	document, err := decodeGoogleBindingDocument(write.Value)
	if err != nil {
		t.Fatalf("binding write value is invalid: %v", err)
	}
	if document.Schema != googleBindingSchema || document.UserID != testBoundUserID {
		t.Fatalf("binding write document = %+v, want schema and bound user", document)
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

func TestNakamaGoogleBindingStoreChecksAuthoritativeAccountStatus(t *testing.T) {
	tests := []struct {
		name        string
		configure   func(*bindingMemoryStorage)
		wantCode    codes.Code
		wantStorage bool
	}{
		{
			name: "active",
		},
		{
			name: "disabled",
			configure: func(storage *bindingMemoryStorage) {
				storage.accountDisabled = true
			},
			wantCode: codes.PermissionDenied,
		},
		{
			name: "mismatched account",
			configure: func(storage *bindingMemoryStorage) {
				storage.accountUserID = testWinnerUserID
			},
			wantStorage: true,
		},
		{
			name: "lookup failure",
			configure: func(storage *bindingMemoryStorage) {
				storage.accountErr = errors.New("database details")
			},
			wantStorage: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			storage := &bindingMemoryStorage{}
			if test.configure != nil {
				test.configure(storage)
			}
			store, err := NewNakamaGoogleBindingStore(storage)
			if err != nil {
				t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
			}

			err = store.VerifyGoogleBoundAccount(context.Background(), testBoundUserID)
			switch {
			case test.wantStorage && !errors.Is(err, ErrGoogleBindingStorage):
				t.Fatalf("VerifyGoogleBoundAccount error = %v, want storage error", err)
			case test.wantCode != codes.OK && status.Code(err) != test.wantCode:
				t.Fatalf(
					"VerifyGoogleBoundAccount code = %s, want %s",
					status.Code(err),
					test.wantCode,
				)
			case !test.wantStorage && test.wantCode == codes.OK && err != nil:
				t.Fatalf("VerifyGoogleBoundAccount returned an error: %v", err)
			}
			if storage.accountCalls != 1 {
				t.Fatalf("AccountGetId calls = %d, want 1", storage.accountCalls)
			}
		})
	}
}

func TestNakamaGoogleBindingStorePreservesContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	key := googleBindingKey([]byte(testNakamaIdentityKey), testGoogleSubject)

	readStorage := &bindingMemoryStorage{readErr: errors.New("read details")}
	readStore, err := NewNakamaGoogleBindingStore(readStorage)
	if err != nil {
		t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
	}
	if _, _, err := readStore.ResolveGoogleBinding(ctx, key); !errors.Is(
		err,
		context.Canceled,
	) {
		t.Fatalf("canceled ResolveGoogleBinding error = %v, want context.Canceled", err)
	}

	writeStorage := &bindingMemoryStorage{writeErr: errors.New("write details")}
	writeStore, err := NewNakamaGoogleBindingStore(writeStorage)
	if err != nil {
		t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
	}
	if _, err := writeStore.BindGoogleIdentity(
		ctx,
		key,
		testBoundUserID,
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled BindGoogleIdentity error = %v, want context.Canceled", err)
	}

	accountStorage := &bindingMemoryStorage{accountErr: errors.New("account details")}
	accountStore, err := NewNakamaGoogleBindingStore(accountStorage)
	if err != nil {
		t.Fatalf("NewNakamaGoogleBindingStore returned an error: %v", err)
	}
	if err := accountStore.VerifyGoogleBoundAccount(
		ctx,
		testBoundUserID,
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled VerifyGoogleBoundAccount error = %v, want context.Canceled", err)
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
			name: "client readable",
			configure: func(object *api.StorageObject) {
				object.PermissionRead = 1
			},
		},
		{
			name: "system owner as player",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"00000000-0000-0000-0000-000000000000"}`
			},
		},
		{
			name: "duplicate user ID",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"11111111-1111-4111-8111-111111111111","user_id":"22222222-2222-4222-8222-222222222222"}`
			},
		},
		{
			name: "duplicate schema",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"schema":1,"user_id":"11111111-1111-4111-8111-111111111111"}`
			},
		},
		{
			name: "case-aliased schema",
			configure: func(object *api.StorageObject) {
				object.Value = `{"Schema":1,"user_id":"11111111-1111-4111-8111-111111111111"}`
			},
		},
		{
			name: "case-aliased duplicate user ID",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"11111111-1111-4111-8111-111111111111","USER_ID":"22222222-2222-4222-8222-222222222222"}`
			},
		},
		{
			name: "unknown JSON field",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"11111111-1111-4111-8111-111111111111","future":true}`
			},
		},
		{
			name: "missing schema",
			configure: func(object *api.StorageObject) {
				object.Value = `{"user_id":"11111111-1111-4111-8111-111111111111"}`
			},
		},
		{
			name: "missing user ID",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1}`
			},
		},
		{
			name: "trailing JSON",
			configure: func(object *api.StorageObject) {
				object.Value = `{"schema":1,"user_id":"11111111-1111-4111-8111-111111111111"} {}`
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

func TestEveryShippedGoogleBindingSchemaStaysReadable(t *testing.T) {
	ledgerBytes, err := os.ReadFile(filepath.Join(
		"testdata",
		"shipped_google_binding_versions.txt",
	))
	if err != nil {
		t.Fatalf("read Google binding schema ledger: %v", err)
	}
	versions := strings.Fields(string(ledgerBytes))
	if len(versions) == 0 {
		t.Fatal("Google binding schema ledger is empty")
	}
	for index, entry := range versions {
		version, err := strconv.Atoi(entry)
		if err != nil {
			t.Fatalf("Google binding schema ledger entry %q: %v", entry, err)
		}
		if version != index+1 {
			t.Fatalf(
				"Google binding schema ledger[%d] = %d, want %d",
				index,
				version,
				index+1,
			)
		}
		golden, err := os.ReadFile(filepath.Join(
			"testdata",
			fmt.Sprintf("golden_google_binding_v%d.json", version),
		))
		if err != nil {
			t.Fatalf("read Google binding schema %d golden: %v", version, err)
		}
		document, err := decodeGoogleBindingDocument(
			strings.TrimSpace(string(golden)),
		)
		if err != nil {
			t.Fatalf("decode Google binding schema %d golden: %v", version, err)
		}
		if document.Schema != version {
			t.Fatalf(
				"Google binding schema %d golden declares %d",
				version,
				document.Schema,
			)
		}
	}
	head, err := strconv.Atoi(versions[len(versions)-1])
	if err != nil || head != googleBindingSchema {
		t.Fatalf(
			"Google binding schema ledger head = %q, writer = %d",
			versions[len(versions)-1],
			googleBindingSchema,
		)
	}
}
