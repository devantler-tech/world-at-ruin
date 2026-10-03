package nakamacharacter

import (
	"errors"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"google.golang.org/protobuf/proto"
)

func TestLoadSystemOwnedEnvelope(t *testing.T) {
	t.Parallel()
	value, err := encodeCharacterDocument(canonicalCharacter())
	if err != nil {
		t.Fatal(err)
	}
	valid := &api.StorageObject{Collection: Collection, Key: characterRecordKey(testSubjectID), UserId: systemOwnerID, Value: string(value), Version: "observed"}
	mutations := map[string]func(*api.StorageObject){"collection": func(o *api.StorageObject) { o.Collection = "other" }, "key": func(o *api.StorageObject) { o.Key = "other" }, "owner": func(o *api.StorageObject) { o.UserId = testSubjectID }, "version": func(o *api.StorageObject) { o.Version = "" }, "public read": func(o *api.StorageObject) { o.PermissionRead = 2 }, "public write": func(o *api.StorageObject) { o.PermissionWrite = 1 }}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			object, ok := proto.Clone(valid).(*api.StorageObject)
			if !ok {
				t.Fatal("cloned storage object has the wrong type")
			}
			mutate(object)
			storage := newFakeStorage()
			storage.systemReadOverrideActive = true
			storage.systemReadOverride = []*api.StorageObject{object}
			_, err := mustCharacterStore(t, storage).Load(authenticatedContext(testSubjectID), testSubjectID)
			if !errors.Is(err, ErrStorage) {
				t.Fatalf("Load error=%v want storage refusal", err)
			}
		})
	}
	for name, objects := range map[string][]*api.StorageObject{"missing": {}, "nil": {nil}, "multiple": {valid, valid}, "valid": {valid}} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := newFakeStorage()
			storage.systemReadOverrideActive = true
			storage.systemReadOverride = objects
			record, err := mustCharacterStore(t, storage).Load(authenticatedContext(testSubjectID), testSubjectID)
			switch name {
			case "missing":
				if !errors.Is(err, ErrNotFound) {
					t.Fatalf("missing=%v", err)
				}
			case "valid":
				if err != nil || record.Version != "observed" || record.Character.ID != "warden-1" {
					t.Fatalf("valid=%#v %v", record, err)
				}
			default:
				if !errors.Is(err, ErrStorage) {
					t.Fatalf("invalid=%v", err)
				}
			}
		})
	}
}
