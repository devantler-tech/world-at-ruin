package nakamainventory

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
)

const (
	testSubjectID  = "11111111-1111-4111-8111-111111111111"
	otherSubjectID = "22222222-2222-4222-8222-222222222222"
)

func newStore(t *testing.T, storage *nakamastoragetest.Fake) *Store {
	t.Helper()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	return store
}

func carried() Inventory {
	return Inventory{Stacks: []Stack{
		{ItemID: "iron-sword", Count: 1},
		{ItemID: "ash-hound-pelt", Count: 3},
	}}
}

func TestNewStoreRequiresStorage(t *testing.T) {
	t.Parallel()
	if _, err := NewStore(nil); err == nil {
		t.Fatal("NewStore(nil) accepted a missing storage client")
	}
}

func TestSaveCreatesAPrivateVersionedContainerAndLoadReturnsItSorted(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	ctx := nakamastoragetest.AuthenticatedContext(testSubjectID)

	if _, err := store.Load(ctx, testSubjectID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load before any save error = %v, want ErrNotFound", err)
	}
	err := store.Save(ctx, SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "loot:cave:1",
		ExpectedVersion: "*",
		Inventory:       carried(),
	})
	if err != nil {
		t.Fatalf("Save() error = %v", err)
	}

	record, err := store.Load(ctx, testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := Inventory{Stacks: []Stack{
		{ItemID: "ash-hound-pelt", Count: 3},
		{ItemID: "iron-sword", Count: 1},
	}}
	if !reflect.DeepEqual(record.Inventory, want) {
		t.Fatalf("Load() = %#v, want %#v (sorted by item id)", record.Inventory, want)
	}
	if record.Version == "" {
		t.Fatal("Load() returned no version")
	}

	object, ok := storage.Get(Collection, recordKey(testSubjectID), "")
	if !ok {
		t.Fatal("container was not written under the system owner")
	}
	if object.PermissionRead != 0 || object.PermissionWrite != 0 {
		t.Fatalf("container is not private: read=%d write=%d", object.PermissionRead, object.PermissionWrite)
	}
	wantValue := `{"schema":1,"stacks":[{"count":3,"item_id":"ash-hound-pelt"},{"count":1,"item_id":"iron-sword"}]}`
	// playerstate stores the canonical form: members sorted, no whitespace.
	if object.Value != wantValue {
		t.Fatalf("stored document = %s, want %s", object.Value, wantValue)
	}
	if _, ok := storage.Get(playerstate.AuditCollection, auditKeyFor(storage), ""); !ok {
		t.Fatal("no system-owned audit evidence was committed with the container")
	}
	if len(storage.WriteCalls) != 1 || len(storage.WriteCalls[0]) != 2 {
		t.Fatalf("container and audit must commit in ONE batch; got %d call(s)", len(storage.WriteCalls))
	}
}

// auditKeyFor finds the single audit object the fake holds; the key is a hash
// the playerstate boundary owns, so the test does not re-derive it.
func auditKeyFor(storage *nakamastoragetest.Fake) string {
	for _, call := range storage.WriteCalls {
		for _, write := range call {
			if write.Collection == playerstate.AuditCollection {
				return write.Key
			}
		}
	}
	return ""
}

func TestSaveAcceptsAnEmptyContainer(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	ctx := nakamastoragetest.AuthenticatedContext(testSubjectID)
	err := store.Save(ctx, SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "clear:1",
		ExpectedVersion: "*",
	})
	if err != nil {
		t.Fatalf("Save(empty) error = %v", err)
	}
	object, _ := storage.Get(Collection, recordKey(testSubjectID), "")
	if object.Value != `{"schema":1,"stacks":[]}` {
		t.Fatalf("stored document = %s, want an explicit empty stack list", object.Value)
	}
	record, err := store.Load(ctx, testSubjectID)
	if err != nil || len(record.Inventory.Stacks) != 0 {
		t.Fatalf("Load(empty) = %#v, %v", record.Inventory, err)
	}
}

func TestSaveRejectsAnOwnerDifferentFromTheAuthenticatedCallerBeforeStorage(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	cases := map[string]context.Context{
		"another account":  nakamastoragetest.AuthenticatedContext(otherSubjectID),
		"no session":       context.Background(),
		"the system owner": nakamastoragetest.AuthenticatedContext(nakamastorage.SystemOwnerID),
	}
	for name, ctx := range cases {
		err := store.Save(ctx, SaveRequest{
			SubjectID:       testSubjectID,
			IdempotencyKey:  "loot:1",
			ExpectedVersion: "*",
			Inventory:       carried(),
		})
		if err == nil {
			t.Fatalf("%s: Save() accepted a caller who does not own the container", name)
		}
	}
	if storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
		t.Fatalf("storage was touched: reads=%d writes=%d", storage.ReadCalls, len(storage.WriteCalls))
	}
}

func TestSaveRejectsInvalidContainersBeforeStorage(t *testing.T) {
	t.Parallel()
	tooMany := make([]Stack, MaxStacks+1)
	for index := range tooMany {
		tooMany[index] = Stack{ItemID: fmt.Sprintf("item-%d", index), Count: 1}
	}
	cases := map[string]SaveRequest{
		"empty observed version": {ExpectedVersion: "", Inventory: carried()},
		"blank item id":          {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: " ", Count: 1}}}},
		"nul in item id":         {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: "a\x00b", Count: 1}}}},
		"zero count":             {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: 0}}}},
		"negative count":         {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: -1}}}},
		"count over the cap":     {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: MaxStackCount + 1}}}},
		"repeated item id":       {ExpectedVersion: "*", Inventory: Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: 1}, {ItemID: "iron-sword", Count: 2}}}},
		"too many stacks":        {ExpectedVersion: "*", Inventory: Inventory{Stacks: tooMany}},
	}
	for name, request := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			store := newStore(t, storage)
			request.SubjectID = testSubjectID
			request.IdempotencyKey = "loot:1"
			err := store.Save(nakamastoragetest.AuthenticatedContext(testSubjectID), request)
			if err == nil {
				t.Fatal("Save() accepted an invalid container")
			}
			if len(storage.WriteCalls) != 0 {
				t.Fatalf("an invalid container reached storage: %d write call(s)", len(storage.WriteCalls))
			}
		})
	}
}

func TestSaveRefusesAStaleObservedVersion(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	ctx := nakamastoragetest.AuthenticatedContext(testSubjectID)
	if err := store.Save(ctx, SaveRequest{SubjectID: testSubjectID, IdempotencyKey: "loot:1", ExpectedVersion: "*", Inventory: carried()}); err != nil {
		t.Fatalf("first Save() error = %v", err)
	}
	current, err := store.Load(ctx, testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	stale := store.Save(ctx, SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "loot:2",
		ExpectedVersion: "not-" + current.Version,
		Inventory:       Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: 2}}},
	})
	if !errors.Is(stale, ErrConflict) {
		t.Fatalf("stale Save() error = %v, want ErrConflict", stale)
	}
	after, err := store.Load(ctx, testSubjectID)
	if err != nil {
		t.Fatalf("Load() after conflict error = %v", err)
	}
	if !reflect.DeepEqual(after, current) {
		t.Fatalf("a refused write changed the container: %#v -> %#v", current, after)
	}
	fresh := store.Save(ctx, SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "loot:3",
		ExpectedVersion: current.Version,
		Inventory:       Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: 2}}},
	})
	if fresh != nil {
		t.Fatalf("Save() with the observed version error = %v", fresh)
	}
}

func TestSaveReplaysTheSameMutationOnceAndRefusesAReusedKey(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	ctx := nakamastoragetest.AuthenticatedContext(testSubjectID)
	request := SaveRequest{SubjectID: testSubjectID, IdempotencyKey: "loot:1", ExpectedVersion: "*", Inventory: carried()}
	if err := store.Save(ctx, request); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	committed, err := store.Load(ctx, testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	// The same mutation again — with the observed version it was made against,
	// which is now stale — is the transport retry case: one effect, no error.
	if err := store.Save(ctx, request); err != nil {
		t.Fatalf("replayed Save() error = %v", err)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf("a replay reached storage: %d write call(s), want 1", len(storage.WriteCalls))
	}
	replayed, err := store.Load(ctx, testSubjectID)
	if err != nil || !reflect.DeepEqual(replayed, committed) {
		t.Fatalf("replay changed the container: %#v -> %#v (%v)", committed, replayed, err)
	}

	// The same key naming a different container is a caller defect, not a retry.
	reused := store.Save(ctx, SaveRequest{
		SubjectID:       testSubjectID,
		IdempotencyKey:  "loot:1",
		ExpectedVersion: committed.Version,
		Inventory:       Inventory{Stacks: []Stack{{ItemID: "iron-sword", Count: 5}}},
	})
	if !errors.Is(reused, ErrKeyConflict) {
		t.Fatalf("reused-key Save() error = %v, want ErrKeyConflict", reused)
	}
}

func TestSaveCannotOverwriteAMalformedDurableContainerWithItsVersion(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	storage.Seed(nakamastoragetest.Object{
		Collection: Collection,
		Key:        recordKey(testSubjectID),
		Value:      `{"schema":1,"stacks":[{"item_id":"iron-sword","count":1.5}]}`,
		Version:    "durable",
	})
	store := newStore(t, storage)
	ctx := nakamastoragetest.AuthenticatedContext(testSubjectID)
	err := store.Save(ctx, SaveRequest{SubjectID: testSubjectID, IdempotencyKey: "loot:1", ExpectedVersion: "durable", Inventory: carried()})
	if !errors.Is(err, ErrStorage) {
		t.Fatalf("Save() over a malformed container error = %v, want ErrStorage", err)
	}
	if len(storage.WriteCalls) != 0 {
		t.Fatal("a malformed durable container was overwritten")
	}
}

func TestLoadRejectsMalformedOrPublicContainers(t *testing.T) {
	t.Parallel()
	cases := map[string]nakamastoragetest.Object{
		"unknown field":         {Value: `{"schema":1,"stacks":[],"gold":5}`},
		"missing stacks":        {Value: `{"schema":1}`},
		"null stacks":           {Value: `{"schema":1,"stacks":null}`},
		"missing schema":        {Value: `{"stacks":[]}`},
		"newer schema":          {Value: `{"schema":2,"stacks":[]}`},
		"duplicate field":       {Value: `{"schema":1,"schema":1,"stacks":[]}`},
		"fractional count":      {Value: `{"schema":1,"stacks":[{"item_id":"a","count":1.5}]}`},
		"string count":          {Value: `{"schema":1,"stacks":[{"item_id":"a","count":"1"}]}`},
		"zero count":            {Value: `{"schema":1,"stacks":[{"item_id":"a","count":0}]}`},
		"count over the cap":    {Value: `{"schema":1,"stacks":[{"item_id":"a","count":1000001}]}`},
		"repeated item id":      {Value: `{"schema":1,"stacks":[{"item_id":"a","count":1},{"item_id":"a","count":1}]}`},
		"unknown stack field":   {Value: `{"schema":1,"stacks":[{"item_id":"a","count":1,"bound":true}]}`},
		"missing stack field":   {Value: `{"schema":1,"stacks":[{"item_id":"a"}]}`},
		"trailing content":      {Value: `{"schema":1,"stacks":[]} {}`},
		"not an object":         {Value: `[]`},
		"publicly readable":     {Value: `{"schema":1,"stacks":[]}`, PermissionRead: 2},
		"client writable":       {Value: `{"schema":1,"stacks":[]}`, PermissionWrite: 1},
		"empty durable version": {Value: `{"schema":1,"stacks":[]}`, Version: "-"},
	}
	for name, object := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			object.Collection = Collection
			object.Key = recordKey(testSubjectID)
			if object.Version == "" {
				object.Version = "durable"
			} else if object.Version == "-" {
				object.Version = ""
			}
			storage.Seed(object)
			store := newStore(t, storage)
			_, err := store.Load(nakamastoragetest.AuthenticatedContext(testSubjectID), testSubjectID)
			if !errors.Is(err, ErrStorage) {
				t.Fatalf("Load() error = %v, want ErrStorage", err)
			}
		})
	}
}

func TestLoadAcceptsAnUnsortedDurableContainerAsContent(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	storage.Seed(nakamastoragetest.Object{
		Collection: Collection,
		Key:        recordKey(testSubjectID),
		Value:      `{"schema":1,"stacks":[{"item_id":"iron-sword","count":1},{"item_id":"ash-hound-pelt","count":3}]}`,
		Version:    "durable",
	})
	store := newStore(t, storage)
	record, err := store.Load(nakamastoragetest.AuthenticatedContext(testSubjectID), testSubjectID)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if record.Inventory.Stacks[0].ItemID != "ash-hound-pelt" {
		t.Fatalf("Load() did not return the canonical order: %#v", record.Inventory)
	}
}

func TestClientOwnedContainerPreseedCannotBecomeAuthoritative(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	storage.Seed(nakamastoragetest.Object{
		Collection: Collection,
		Key:        recordKey(testSubjectID),
		UserID:     testSubjectID,
		Value:      `{"schema":1,"stacks":[{"item_id":"crown-of-ruin","count":1}]}`,
		Version:    "durable",
	})
	store := newStore(t, storage)
	if _, err := store.Load(nakamastoragetest.AuthenticatedContext(testSubjectID), testSubjectID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() over a client-owned preseed error = %v, want ErrNotFound", err)
	}
}

func TestLoadRejectsAnOwnerDifferentFromTheAuthenticatedCallerBeforeStorage(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newStore(t, storage)
	if _, err := store.Load(nakamastoragetest.AuthenticatedContext(otherSubjectID), testSubjectID); err == nil {
		t.Fatal("Load() served another account's container")
	}
	if storage.ReadCalls != 0 {
		t.Fatalf("storage was read %d time(s) for a caller who does not own the container", storage.ReadCalls)
	}
}

func TestLoadSanitizesStorageFailuresAndPreservesCancellation(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		readErr error
		want    error
	}{
		"storage failure": {errors.New("nakama: table missing"), ErrStorage},
		"cancellation":    {context.Canceled, context.Canceled},
		"deadline":        {context.DeadlineExceeded, context.DeadlineExceeded},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := nakamastoragetest.New()
			storage.ReadErr = tc.readErr
			store := newStore(t, storage)
			_, err := store.Load(nakamastoragetest.AuthenticatedContext(testSubjectID), testSubjectID)
			if !errors.Is(err, tc.want) {
				t.Fatalf("Load() error = %v, want %v", err, tc.want)
			}
			if tc.want == ErrStorage && strings.Contains(err.Error(), "table") {
				t.Fatalf("Load() leaked the storage error: %v", err)
			}
		})
	}
}

// Every schema that ever shipped stays readable forever (no-resets law). The
// ledger is append-only and each version has a golden this test loads.
func TestLoadKeepsEveryShippedInventorySchemaReadable(t *testing.T) {
	t.Parallel()
	ledgerBytes, err := os.ReadFile(filepath.Join("testdata", "shipped_inventory_versions.txt"))
	if err != nil {
		t.Fatalf("read inventory schema ledger: %v", err)
	}
	versions := strings.Fields(string(ledgerBytes))
	if len(versions) == 0 {
		t.Fatal("inventory schema ledger is empty")
	}
	for index, rawVersion := range versions {
		version, err := strconv.Atoi(rawVersion)
		if err != nil {
			t.Fatalf("schema ledger entry %q: %v", rawVersion, err)
		}
		if version != index+1 {
			t.Fatalf("schema ledger[%d] = %d, want %d", index, version, index+1)
		}
		goldenBytes, err := os.ReadFile(filepath.Join("testdata", fmt.Sprintf("golden_inventory_v%d.json", version)))
		if err != nil {
			t.Fatalf("read inventory schema %d golden: %v", version, err)
		}
		storage := nakamastoragetest.New()
		storage.Seed(nakamastoragetest.Object{
			Collection: Collection,
			Key:        recordKey(testSubjectID),
			Value:      strings.TrimSpace(string(goldenBytes)),
			Version:    "durable",
		})
		store := newStore(t, storage)
		record, err := store.Load(nakamastoragetest.AuthenticatedContext(testSubjectID), testSubjectID)
		if err != nil {
			t.Fatalf("Load(schema %d) error = %v", version, err)
		}
		want := Inventory{Stacks: []Stack{
			{ItemID: "ash-hound-pelt", Count: 3},
			{ItemID: "iron-sword", Count: 1},
		}}
		if !reflect.DeepEqual(record.Inventory, want) {
			t.Fatalf("Load(schema %d) = %#v, want %#v", version, record.Inventory, want)
		}
	}
}
