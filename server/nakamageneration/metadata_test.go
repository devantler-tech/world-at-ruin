package nakamageneration

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

func TestInvalidStorageMetadataNeverAuthorizesReplacement(t *testing.T) {
	t.Parallel()
	cases := map[string]func([]*api.StorageObject) []*api.StorageObject{
		"nil":        func([]*api.StorageObject) []*api.StorageObject { return []*api.StorageObject{nil} },
		"multiple":   func(o []*api.StorageObject) []*api.StorageObject { return append(o, o[0]) },
		"collection": func(o []*api.StorageObject) []*api.StorageObject { o[0].Collection = "foreign"; return o },
		"key":        func(o []*api.StorageObject) []*api.StorageObject { o[0].Key = "foreign"; return o },
		"owner": func(o []*api.StorageObject) []*api.StorageObject {
			o[0].UserId = "11111111-1111-4111-8111-111111111111"
			return o
		},
		"public":           func(o []*api.StorageObject) []*api.StorageObject { o[0].PermissionRead = 2; return o },
		"client-writable":  func(o []*api.StorageObject) []*api.StorageObject { o[0].PermissionWrite = 1; return o },
		"empty-version":    func(o []*api.StorageObject) []*api.StorageObject { o[0].Version = ""; return o },
		"wildcard-version": func(o []*api.StorageObject) []*api.StorageObject { o[0].Version = "*"; return o },
		"oversize-version": func(o []*api.StorageObject) []*api.StorageObject { o[0].Version = strings.Repeat("v", 1025); return o },
		"control-version":  func(o []*api.StorageObject) []*api.StorageObject { o[0].Version = "v\x00"; return o },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "generation-1", Value: goldenDocument(t), Version: "v1"})
			before := storage.Objects()
			storage.read = func(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
				objects, err := storage.Fake.StorageRead(ctx, reads)
				if err != nil {
					return nil, err
				}
				return mutate(objects), nil
			}
			_, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-b"})
			if !errors.Is(err, ErrStorage) || len(storage.WriteCalls) != 0 || !reflect.DeepEqual(before, storage.Objects()) {
				t.Fatalf("metadata refusal changed state: %v", err)
			}
		})
	}
}

func TestClientOwnedObjectCannotPreseedGeneration(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	foreign := nakamastoragetest.Object{Collection: Collection, Key: "generation-1", UserID: "11111111-1111-4111-8111-111111111111", Value: "client-data", Version: "client-version", PermissionRead: 1, PermissionWrite: 1}
	storage.Seed(foreign)
	got, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
	if err != nil || got.Version != "v1" {
		t.Fatalf("client object interfered with authoritative create: %+v, %v", got, err)
	}
	kept, _ := storage.Get(Collection, foreign.Key, foreign.UserID)
	if kept != foreign || len(storage.Objects()) != 2 {
		t.Fatal("client namespace was changed")
	}
}

func TestInitialStorageFailureIsSanitizedWithoutWriting(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	storage.ReadErr = errors.New("secret backend detail")
	_, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
	if !errors.Is(err, ErrStorage) || err.Error() != ErrStorage.Error() || len(storage.WriteCalls) != 0 {
		t.Fatalf("read error escaped or authorized a write: %v", err)
	}
	storage.ReadErr = nil
	if _, err := newTestStore(t, storage).Load(t.Context(), "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing read: %v", err)
	}
	if store, err := NewStore(nil); store != nil || !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("nil storage accepted: %v", err)
	}
}

func TestEncodedRecordSizeIsBoundedBeforeStorage(t *testing.T) {
	t.Parallel()
	members := make([]string, 256)
	for index := range members {
		members[index] = strings.Repeat("<", 120) + fmt.Sprint(index)
	}
	storage := nakamastoragetest.New()
	_, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", members)
	if !errors.Is(err, ErrInvalidArgument) || storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
		t.Fatalf("oversize encoding reached storage: %v", err)
	}
}
