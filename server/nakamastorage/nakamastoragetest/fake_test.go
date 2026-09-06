package nakamastoragetest

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	aliceID = "d95d6008-7542-4a3b-9519-0e2c9b66c50a"
	bobID   = "b4612819-0400-4bd6-bd06-fcf0bc85060e"
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
	fake.Seed(Object{Collection: "leases", Key: "a", UserID: aliceID, Version: "v1"})
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
	for _, object := range []Object{{Collection: "other", Key: "a"}, {Collection: "leases", Key: "a", UserID: aliceID}} {
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
	if err := storage.StorageDelete(context.Background(), batch); err == nil || errors.Is(err, runtime.ErrStorageRejectedVersion) {
		t.Fatalf("stale delete = %v, want an ordinary delete error rather than a write-conflict sentinel", err)
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

func TestListHonorsOwnerPermissions(t *testing.T) {
	fake := New()
	for _, object := range []Object{
		{Key: "a", UserID: aliceID, PermissionRead: 0},
		{Key: "b", UserID: aliceID, PermissionRead: 1},
		{Key: "c", UserID: aliceID, PermissionRead: 2},
		{Key: "d", UserID: bobID, PermissionRead: 2},
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
		{"system can see private player records", "", aliceID, []string{"a", "b", "c"}},
		{"system can scan every owner", "", "", []string{"a", "b", "c", "d", "e"}},
		{"explicit system caller bypasses permissions", nakamastorage.SystemOwnerID, "", []string{"a", "b", "c", "d", "e"}},
		{"owner cannot see server-only records", aliceID, aliceID, []string{"b", "c"}},
		{"other player only sees public records", bobID, aliceID, []string{"c"}},
		{"public collection crosses owners", aliceID, "", []string{"c", "d"}},
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
	_, cursor, err := fake.StorageList(context.Background(), "", aliceID, "records", 1, "")
	if err != nil || cursor == "" {
		t.Fatalf("first page = %q, %v", cursor, err)
	}
	for _, tc := range []struct{ caller, user, collection string }{
		{"", bobID, "records"},
		{aliceID, aliceID, "records"},
		{"", aliceID, "other"},
	} {
		if _, _, err := fake.StorageList(context.Background(), tc.caller, tc.user, tc.collection, 1, cursor); err != nil {
			t.Fatal("fake added query-binding validation to a storage cursor")
		}
	}
	if _, _, err := fake.StorageList(context.Background(), "", aliceID, "records", 1, "invalid cursor"); err == nil {
		t.Fatal("list accepted a malformed cursor")
	}
}

func TestListRejectsMalformedUUIDs(t *testing.T) {
	fake := New()
	for _, tc := range []struct{ caller, user string }{
		{"alice", ""}, {"", "alice"}, {aliceID, "invalid"}, {"invalid", aliceID},
	} {
		objects, cursor, err := fake.StorageList(context.Background(), tc.caller, tc.user, "records", 100, "")
		if err == nil || objects != nil || cursor != "" {
			t.Fatal("list accepted a malformed caller or owner UUID")
		}
	}
}

func TestListFindsObjectsWrittenWithEquivalentUUIDText(t *testing.T) {
	fake := New()
	ctx := context.Background()
	upper := strings.ToUpper(aliceID)
	if _, err := fake.StorageWrite(ctx, []*runtime.StorageWrite{{
		Collection: "records", Key: "written", UserID: upper, Value: `{}`,
	}}); err != nil {
		t.Fatal(err)
	}
	fake.Seed(Object{Collection: "records", Key: "seeded", UserID: upper, Version: "v1"})
	objects, _, err := fake.StorageList(ctx, "", upper, "records", 100, "")
	if err != nil || len(objects) != 2 {
		t.Fatalf("equivalent owner UUID did not find both objects: count=%d err=%v", len(objects), err)
	}
	for _, object := range objects {
		if object.GetUserId() != aliceID {
			t.Fatal("storage did not normalize the owner UUID")
		}
		if _, ok := fake.Get("records", object.GetKey(), aliceID); !ok {
			t.Fatal("canonical owner UUID did not identify the listed object")
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
