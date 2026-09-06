package nakamastoragetest

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

type listingStorage interface {
	StorageList(context.Context, string, string, string, int, string) ([]*api.StorageObject, string, error)
	StorageDelete(context.Context, []*runtime.StorageDelete) error
}

func leaseStorage(t *testing.T, fake *Fake) listingStorage {
	t.Helper()
	storage, ok := any(fake).(listingStorage)
	if !ok {
		t.Fatal("shared storage fake cannot back the real lease store")
	}
	return storage
}

// A positional cursor skips live leases when cleanup deletes the preceding page.
func TestListContinuesAfterDeletingThePreviousPage(t *testing.T) {
	fake := New()
	storage := leaseStorage(t, fake)
	for _, key := range []string{"a", "b", "c", "d", "e"} {
		fake.Seed(Object{Collection: "leases", Key: key, Version: "v1", Value: `{}`})
	}
	fake.Seed(Object{Collection: "other", Key: "a", Version: "v1"})
	fake.Seed(Object{Collection: "leases", Key: "a", UserID: "player", Version: "v1"})
	ctx := context.Background()
	var keys []string
	cursor := ""
	for {
		objects, next, err := storage.StorageList(ctx, "", nakamastorage.SystemOwnerID, "leases", 2, cursor)
		if err != nil || len(objects) == 0 || len(objects) > 2 {
			t.Fatalf("page = %v, %q, %v", objects, next, err)
		}
		for _, object := range objects {
			keys = append(keys, object.GetKey())
			if err := storage.StorageDelete(ctx, []*runtime.StorageDelete{{
				Collection: "leases", Key: object.GetKey(), Version: object.GetVersion(),
			}}); err != nil {
				t.Fatal(err)
			}
		}
		if next == "" {
			break
		}
		if next == cursor {
			t.Fatal("cursor did not advance")
		}
		cursor = next
	}
	if !reflect.DeepEqual(keys, []string{"a", "b", "c", "d", "e"}) {
		t.Fatalf("visited keys = %v", keys)
	}
	for _, object := range []Object{{Collection: "other", Key: "a"}, {Collection: "leases", Key: "a", UserID: "player"}} {
		if _, ok := fake.Get(object.Collection, object.Key, object.UserID); !ok {
			t.Fatal("cleanup deleted an object outside its owner/collection")
		}
	}
}

// One stale delete must not remove the earlier members of its batch.
func TestDeleteIsConditionalAndAtomic(t *testing.T) {
	fake := New()
	storage := leaseStorage(t, fake)
	for _, key := range []string{"a", "b"} {
		fake.Seed(Object{Collection: "leases", Key: key, Version: "v1"})
	}
	batch := []*runtime.StorageDelete{
		{Collection: "leases", Key: "a", Version: "v1"},
		{Collection: "leases", Key: "b", Version: "stale"},
	}
	if err := storage.StorageDelete(context.Background(), batch); !errors.Is(err, runtime.ErrStorageRejectedVersion) {
		t.Fatalf("stale delete = %v", err)
	}
	for _, key := range []string{"a", "b"} {
		if _, ok := fake.Get("leases", key, ""); !ok {
			t.Fatalf("rejected batch deleted %s", key)
		}
	}
	batch[1].Version = "v1"
	if err := storage.StorageDelete(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
	for _, deletion := range batch {
		deletion.Version = ""
	}
	if err := storage.StorageDelete(context.Background(), batch); err != nil {
		t.Fatalf("unconditional delete of absent objects = %v", err)
	}
}

func TestListHonorsOwnerPermissionsAndBindsItsCursor(t *testing.T) {
	fake := New()
	for _, object := range []Object{
		{Key: "a", UserID: "alice", PermissionRead: 0},
		{Key: "b", UserID: "alice", PermissionRead: 1},
		{Key: "c", UserID: "alice", PermissionRead: 2},
		{Key: "d", UserID: "bob", PermissionRead: 2},
		{Key: "e", PermissionRead: 0},
	} {
		object.Collection = "records"
		object.Version = "v1"
		fake.Seed(object)
	}
	for _, tc := range []struct {
		name, caller, user string
		keys               []string
	}{
		{"system can see private player records", "", "alice", []string{"a", "b", "c"}},
		{"owner cannot see server-only records", "alice", "alice", []string{"b", "c"}},
		{"other player only sees public records", "bob", "alice", []string{"c"}},
		{"public collection crosses owners", "alice", "", []string{"c", "d"}},
		{"system records have an explicit owner", "", nakamastorage.SystemOwnerID, []string{"e"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			objects, cursor, err := fake.StorageList(context.Background(), tc.caller, tc.user, "records", 100, "")
			if err != nil || cursor != "" {
				t.Fatalf("list = %q, %v", cursor, err)
			}
			var keys []string
			for _, object := range objects {
				keys = append(keys, object.GetKey())
				object.Value = "caller mutation"
			}
			if !reflect.DeepEqual(keys, tc.keys) {
				t.Fatalf("visible keys = %v, want %v", keys, tc.keys)
			}
		})
	}
	for _, object := range fake.Objects() {
		if object.Value == "caller mutation" {
			t.Fatal("mutating a list response changed storage")
		}
	}
	_, cursor, err := fake.StorageList(context.Background(), "", "alice", "records", 1, "")
	if err != nil || cursor == "" {
		t.Fatalf("first page = %q, %v", cursor, err)
	}
	for _, tc := range []struct{ caller, user, collection, cursor string }{
		{"", "bob", "records", cursor},
		{"alice", "alice", "records", cursor},
		{"", "alice", "other", cursor},
		{"", "alice", "records", "invalid cursor"},
	} {
		if _, _, err := fake.StorageList(context.Background(), tc.caller, tc.user, tc.collection, 1, tc.cursor); err == nil {
			t.Fatal("list accepted an invalid cursor or one from another query")
		}
	}
}

func TestCanceledStorageCannotReadOrMutate(t *testing.T) {
	fake := New()
	fake.Seed(Object{Collection: "records", Key: "a", Version: "v1"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := fake.StorageRead(ctx, []*runtime.StorageRead{{Collection: "records", Key: "a"}}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled read = %v", err)
	}
	if _, err := fake.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: "records", Key: "a", Version: "v1", Value: `{}`}}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled write = %v", err)
	}
	if _, _, err := fake.StorageList(ctx, "", nakamastorage.SystemOwnerID, "records", 100, ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled list = %v", err)
	}
	if err := fake.StorageDelete(ctx, []*runtime.StorageDelete{{Collection: "records", Key: "a"}}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled delete = %v", err)
	}
	object, ok := fake.Get("records", "a", "")
	if !ok || object.Value != "" || object.Version != "v1" {
		t.Fatal("canceled calls changed durable state")
	}
}
