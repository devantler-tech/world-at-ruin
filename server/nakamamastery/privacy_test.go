package nakamamastery

import (
	"errors"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

func TestClientOwnedPreseedCannotShadowOrReplaceServerMastery(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	client := nakamastoragetest.Object{Collection: Collection, Key: "mastery:" + subject, UserID: subject, Value: cleanDocument, Version: "client-version", PermissionRead: 1, PermissionWrite: 1}
	storage.Seed(client)
	if _, _, err := store.Load(ctx, subject); !errors.Is(err, ErrNotFound) {
		t.Fatalf("client shadow = %v", err)
	}
	out, err := store.Apply(ctx, award(t, authority, "server-create", 8))
	if err != nil || out.State.Weapons["axe"] != (Track{0, 8}) {
		t.Fatalf("server create = %#v %v", out, err)
	}
	retained, ok := storage.Get(Collection, "mastery:"+subject, subject)
	if !ok || !reflect.DeepEqual(retained, client) {
		t.Fatal("overwrote client namespace")
	}
	if len(storage.Objects()) != 3 {
		t.Fatal("server record and audit were not independently created")
	}
}

func TestMalformedPrivateStateRefusesWithoutAuditOrWrite(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "mastery:" + subject, Value: `{"schema":1,"weapons":{},"stain":null}`, Version: "invalid"})
	before := storage.NextVersion()
	if _, err := store.Apply(ctx, award(t, authority, "invalid-state", 8)); !errors.Is(err, ErrStorage) {
		t.Fatalf("invalid = %v", err)
	}
	if storage.NextVersion() != before || len(storage.Objects()) != 1 || len(storage.WriteCalls) != 0 {
		t.Fatal("invalid private state changed storage")
	}
}
