package playerstate

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/savefixturetest"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	testSubjectID           = "11111111-1111-4111-8111-111111111111"
	testAuditIdentityFields = `"idempotency_key":"quest:ember:reward",` +
		`"record_collection":"world_at_ruin_inventory",` +
		`"record_key":"carried",`
)

type storedObject = nakamastoragetest.Object

type fakeStorage struct {
	*nakamastoragetest.Fake
	writeErrBeforeApply error
	writeErrAfterApply  error
	panicAfterApply     bool
}

func newFakeStorage() *fakeStorage {
	return &fakeStorage{Fake: nakamastoragetest.New()}
}

func (f *fakeStorage) seed(object storedObject) { f.Seed(object) }

// Keep this suite's conditional-write and one-shot process-fault policy local.
func (f *fakeStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	f.BeforeWrite = func(_ int) error {
		if f.writeErrBeforeApply != nil {
			err := f.writeErrBeforeApply
			f.writeErrBeforeApply = nil
			return err
		}
		for _, write := range writes {
			if write.Version == "" {
				return runtime.ErrStorageRejectedVersion
			}
		}
		return nil
	}
	f.AfterWrite = func(_ int) error {
		if f.writeErrAfterApply != nil {
			err := f.writeErrAfterApply
			f.writeErrAfterApply = nil
			return err
		}
		if f.panicAfterApply {
			f.panicAfterApply = false
			panic("simulated process crash after storage commit")
		}
		return nil
	}
	return f.Fake.StorageWrite(ctx, writes)
}

func TestApplyCommitsPlayerRecordAndAuditInOneAtomicWrite(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}

	mutation := inventoryMutation(testSubjectID, "quest:ember:reward")
	// Retain unsorted input: this assertion also proves canonical serialization.
	mutation.Payload = json.RawMessage(`{"quantity":1,"item_id":"ash-blade"}`)
	mutation.Record.Value = json.RawMessage(`{"schema":1,"items":["ash-blade"]}`)
	result, err := store.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("Apply() outcome = %s", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf("StorageWrite() calls = %d, want 1", len(storage.WriteCalls))
	}
	writes := storage.WriteCalls[0]
	if len(writes) != 2 {
		t.Fatalf("atomic StorageWrite() batch size = %d, want 2", len(writes))
	}

	var recordWrite, auditWrite *runtime.StorageWrite
	for _, write := range writes {
		switch write.Collection {
		case "world_at_ruin_inventory":
			recordWrite = write
		case AuditCollection:
			auditWrite = write
		}
	}
	if recordWrite == nil || auditWrite == nil {
		t.Fatalf(
			"StorageWrite() collections = %q, %q",
			writes[0].Collection,
			writes[1].Collection,
		)
	}
	if recordWrite.UserID != testSubjectID ||
		recordWrite.Version != "observed" ||
		recordWrite.PermissionRead != 0 ||
		recordWrite.PermissionWrite != 0 {
		t.Fatalf("record write is not private compare-and-swap: %#v", recordWrite)
	}
	if recordWrite.Value != `{"items":["ash-blade"],"schema":1}` {
		t.Fatalf("record write value = %s", recordWrite.Value)
	}
	if auditWrite.UserID != "" ||
		auditWrite.Key !=
			"afd3896d75f47b66b0be65e77e3f40aede48b01b772292b29c9525779cc76233" ||
		auditWrite.Version != "*" ||
		auditWrite.PermissionRead != 0 ||
		auditWrite.PermissionWrite != 0 {
		t.Fatalf("audit write is not private append-only create: %#v", auditWrite)
	}
	if auditWrite.Value !=
		`{"schema":1,"idempotency_key":"quest:ember:reward","record_collection":"world_at_ruin_inventory","record_key":"carried","operation":"grant_item","payload":{"item_id":"ash-blade","quantity":1},"outcome":{"item_count":1}}` {
		t.Fatalf("audit write value = %s", auditWrite.Value)
	}
}

func TestClientOwnedAuditPreseedCannotReplayASystemMutation(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	mutation := inventoryMutation(
		testSubjectID,
		"quest:ember:reward",
	)
	mutation.Record.ExpectedVersion = "*"
	mutation.Record.SystemOwned = true
	storage.seed(storedObject{
		Collection: AuditCollection,
		Key: auditKey(
			testSubjectID,
			mutation.Record.Collection,
			mutation.Record.Key,
			mutation.IdempotencyKey,
		),
		UserID: testSubjectID,
		Value: `{"schema":1,` + testAuditIdentityFields +
			`"operation":"grant_item",` +
			`"payload":{"item_id":"ash-blade","quantity":1},` +
			`"outcome":{"item_count":999}}`,
		Version:         "attacker-version",
		PermissionRead:  0,
		PermissionWrite: 0,
	})

	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	result, err := store.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("Apply() outcome = %s", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf("StorageWrite() calls = %d, want 1", len(storage.WriteCalls))
	}
	writes := storage.WriteCalls[0]
	if len(writes) != 2 || writes[1].Collection != AuditCollection ||
		writes[1].UserID != "" {
		t.Fatalf("system mutation writes = %#v", writes)
	}
}

func TestApplyReplaysTheOriginalOutcomeWithoutWritingAgain(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	mutation := inventoryMutation(testSubjectID, "quest:ember:reward")
	// Retain unsorted input: this assertion also proves canonical serialization.
	mutation.Payload = json.RawMessage(`{"quantity":1,"item_id":"ash-blade"}`)
	mutation.Record.Value = json.RawMessage(`{"schema":1,"items":["ash-blade"]}`)
	if _, err := store.Apply(context.Background(), mutation); err != nil {
		t.Fatalf("first Apply() error = %v", err)
	}

	mutation.Record.ExpectedVersion = "stale-observation"
	mutation.Record.Value = json.RawMessage(
		`{"schema":1,"items":["ash-blade","wrong-replay"]}`,
	)
	mutation.Outcome = json.RawMessage(`{"item_count":999}`)
	result, err := store.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("replayed Apply() error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("replayed Apply() outcome = %s", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf(
			"StorageWrite() calls after replay = %d, want 1",
			len(storage.WriteCalls),
		)
	}
}

func TestApplyIgnoresClientOwnedAuditAtDerivedKey(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	mutation := inventoryMutation(testSubjectID, "quest:ember:reward")
	auditObjectKey := auditKey(
		testSubjectID,
		mutation.Record.Collection,
		mutation.Record.Key,
		mutation.IdempotencyKey,
	)
	storage.seed(storedObject{
		Collection: AuditCollection,
		Key:        auditObjectKey,
		UserID:     testSubjectID,
		Value: `{"schema":1,` +
			`"idempotency_key":"quest:ember:reward",` +
			`"record_collection":"world_at_ruin_inventory",` +
			`"record_key":"carried","operation":"grant_item",` +
			`"payload":{"item_id":"ash-blade","quantity":1},` +
			`"outcome":{"item_count":999}}`,
		Version:         "client-owned",
		PermissionRead:  0,
		PermissionWrite: 0,
	})
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}

	result, err := store.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("Apply() outcome = %s, want authoritative outcome", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf("StorageWrite() calls = %d, want 1", len(storage.WriteCalls))
	}
	if _, ok := storage.Get(AuditCollection, auditObjectKey, systemOwnerID); !ok {
		t.Fatal("Apply() did not create server-owned audit evidence")
	}
}

func TestApplyReconcilesACommittedMutationWhoseResponseWasLost(
	t *testing.T,
) {
	t.Parallel()

	storage := newFakeStorage()
	storage.seed(storedObject{
		Collection:      "world_at_ruin_inventory",
		Key:             "carried",
		UserID:          testSubjectID,
		Value:           `{"items":[],"schema":1}`,
		Version:         "observed",
		PermissionRead:  0,
		PermissionWrite: 0,
	})
	storage.writeErrAfterApply = errors.New("connection reset after commit")
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	mutation := Mutation{
		SubjectID:      testSubjectID,
		IdempotencyKey: "quest:ember:reward",
		Operation:      "grant_item",
		Payload: json.RawMessage(
			`{"item_id":"ash-blade","quantity":1}`,
		),
		Record: RecordWrite{
			Collection:      "world_at_ruin_inventory",
			Key:             "carried",
			ExpectedVersion: "observed",
			Value: json.RawMessage(
				`{"items":["ash-blade"],"schema":1}`,
			),
		},
		Outcome: json.RawMessage(`{"item_count":1}`),
	}

	result, err := store.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("Apply() after committed response loss error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("reconciled Apply() outcome = %s", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf("StorageWrite() calls = %d, want 1", len(storage.WriteCalls))
	}

	if _, err := store.Apply(context.Background(), mutation); err != nil {
		t.Fatalf("later replay Apply() error = %v", err)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf(
			"StorageWrite() calls after later replay = %d, want 1",
			len(storage.WriteCalls),
		)
	}
}

func TestApplyReplayAfterProcessCrashDoesNotWriteAgain(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	storage.panicAfterApply = true
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	mutation := inventoryMutation(
		testSubjectID,
		"quest:ember:reward",
	)

	func() {
		defer func() {
			if recovered := recover(); recovered == nil {
				t.Fatal("Apply() did not simulate a process crash")
			}
		}()
		_, _ = store.Apply(context.Background(), mutation)
	}()

	restartedStore, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() after crash error = %v", err)
	}
	mutation.Record.ExpectedVersion = "stale-after-crash"
	mutation.Record.Value = json.RawMessage(
		`{"items":["ash-blade","duplicate"],"schema":1}`,
	)
	mutation.Outcome = json.RawMessage(`{"item_count":2}`)
	result, err := restartedStore.Apply(context.Background(), mutation)
	if err != nil {
		t.Fatalf("Apply() after process crash error = %v", err)
	}
	if string(result.Outcome) != `{"item_count":1}` {
		t.Fatalf("Apply() after process crash outcome = %s", result.Outcome)
	}
	if len(storage.WriteCalls) != 1 {
		t.Fatalf(
			"StorageWrite() calls after process crash replay = %d, want 1",
			len(storage.WriteCalls),
		)
	}
}

func TestApplySanitizesStorageFailures(t *testing.T) {
	t.Parallel()

	const sensitiveMessage = "postgres player row 42"
	tests := []struct {
		name      string
		configure func(*fakeStorage)
		want      error
	}{
		{
			name: "read",
			configure: func(storage *fakeStorage) {
				storage.ReadErr = errors.New(sensitiveMessage)
			},
			want: ErrStorage,
		},
		{
			name: "write",
			configure: func(storage *fakeStorage) {
				storage.writeErrBeforeApply = errors.New(sensitiveMessage)
			},
			want: ErrIndeterminate,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := seededInventoryStorage()
			test.configure(storage)
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}

			_, err = store.Apply(
				context.Background(),
				inventoryMutation(testSubjectID, "quest:ember:reward"),
			)
			if !errors.Is(err, test.want) {
				t.Fatalf("Apply() error = %v, want %v", err, test.want)
			}
			if strings.Contains(err.Error(), sensitiveMessage) {
				t.Fatalf("Apply() leaked storage error = %v", err)
			}
		})
	}
}

func TestApplyPreservesCancellationAfterWriteDispatch(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	storage.writeErrBeforeApply = context.Canceled
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}

	_, err = store.Apply(
		context.Background(),
		inventoryMutation(testSubjectID, "quest:ember:reward"),
	)
	if !errors.Is(err, ErrIndeterminate) ||
		!errors.Is(err, context.Canceled) {
		t.Fatalf(
			"Apply() error = %v, want %v and %v",
			err,
			ErrIndeterminate,
			context.Canceled,
		)
	}
}

func TestApplyRejectsKeyReuseForADifferentMutation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		change func(*Mutation)
	}{
		{
			name: "operation",
			change: func(mutation *Mutation) {
				mutation.Operation = "remove_item"
			},
		},
		{
			name: "payload",
			change: func(mutation *Mutation) {
				mutation.Payload = json.RawMessage(
					`{"item_id":"ember-shield","quantity":1}`,
				)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := seededInventoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			mutation := inventoryMutation(
				testSubjectID,
				"quest:ember:reward",
			)
			if _, err := store.Apply(
				context.Background(),
				mutation,
			); err != nil {
				t.Fatalf("first Apply() error = %v", err)
			}

			test.change(&mutation)
			_, err = store.Apply(context.Background(), mutation)
			if !errors.Is(err, ErrKeyConflict) {
				t.Fatalf(
					"reused-key Apply() error = %v, want %v",
					err,
					ErrKeyConflict,
				)
			}
			if len(storage.WriteCalls) != 1 {
				t.Fatalf(
					"StorageWrite() calls after conflict = %d, want 1",
					len(storage.WriteCalls),
				)
			}
		})
	}
}

func TestApplyKeepsDistinctKeysForTheSameEffectDistinct(t *testing.T) {
	t.Parallel()

	storage := seededInventoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	first := inventoryMutation(testSubjectID, "quest:ember:first")
	if _, err := store.Apply(context.Background(), first); err != nil {
		t.Fatalf("first Apply() error = %v", err)
	}

	second := inventoryMutation(testSubjectID, "quest:ember:second")
	second.Record.ExpectedVersion = "v1"
	if _, err := store.Apply(context.Background(), second); err != nil {
		t.Fatalf("second Apply() error = %v", err)
	}
	if len(storage.WriteCalls) != 2 {
		t.Fatalf("StorageWrite() calls = %d, want 2", len(storage.WriteCalls))
	}

	auditCount := 0
	for _, object := range storage.Objects() {
		if object.Collection == AuditCollection {
			auditCount++
		}
	}
	if auditCount != 2 {
		t.Fatalf("append-only audit objects = %d, want 2", auditCount)
	}
}

func TestApplyScopesTheSameRawKeyBySubjectAndRecord(t *testing.T) {
	t.Parallel()

	const secondSubjectID = "22222222-2222-4222-8222-222222222222"
	tests := []struct {
		name       string
		subjectID  string
		recordKey  string
		recordSeed storedObject
	}{
		{
			name:      "subject",
			subjectID: secondSubjectID,
			recordKey: "carried",
			recordSeed: storedObject{
				Collection:      "world_at_ruin_inventory",
				Key:             "carried",
				UserID:          secondSubjectID,
				Value:           `{"items":[],"schema":1}`,
				Version:         "second-observed",
				PermissionRead:  0,
				PermissionWrite: 0,
			},
		},
		{
			name:      "record",
			subjectID: testSubjectID,
			recordKey: "stash",
			recordSeed: storedObject{
				Collection:      "world_at_ruin_inventory",
				Key:             "stash",
				UserID:          testSubjectID,
				Value:           `{"items":[],"schema":1}`,
				Version:         "second-observed",
				PermissionRead:  0,
				PermissionWrite: 0,
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := seededInventoryStorage()
			storage.seed(test.recordSeed)
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			first := inventoryMutation(testSubjectID, "reward")
			if _, err := store.Apply(
				context.Background(),
				first,
			); err != nil {
				t.Fatalf("first Apply() error = %v", err)
			}

			second := inventoryMutation(test.subjectID, "reward")
			second.Record.Key = test.recordKey
			second.Record.ExpectedVersion = "second-observed"
			if _, err := store.Apply(
				context.Background(),
				second,
			); err != nil {
				t.Fatalf("second Apply() error = %v", err)
			}

			auditKeys := make(map[string]struct{})
			for _, object := range storage.Objects() {
				if object.Collection == AuditCollection {
					auditKeys[object.Key] = struct{}{}
				}
			}
			if len(auditKeys) != 2 {
				t.Fatalf(
					"%s-scoped audit keys = %d, want 2",
					test.name,
					len(auditKeys),
				)
			}
		})
	}
}

func TestApplyRejectsMalformedAuditDocuments(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		value string
	}{
		{
			name: "duplicate required field",
			value: `{"schema":1,` +
				testAuditIdentityFields +
				`"operation":"remove_item",` +
				`"operation":"grant_item",` +
				`"payload":{"item_id":"ash-blade","quantity":1},` +
				`"outcome":{"item_count":1}}`,
		},
		{
			name: "unknown field",
			value: `{"schema":1,` +
				testAuditIdentityFields +
				`"operation":"grant_item",` +
				`"payload":{"item_id":"ash-blade","quantity":1},` +
				`"outcome":{"item_count":1},` +
				`"extra":true}`,
		},
		{
			name: "missing required field",
			value: `{"schema":1,` +
				testAuditIdentityFields +
				`"operation":"grant_item",` +
				`"payload":{"item_id":"ash-blade","quantity":1}}`,
		},
		{
			name: "trailing content",
			value: `{"schema":1,` +
				testAuditIdentityFields +
				`"operation":"grant_item",` +
				`"payload":{"item_id":"ash-blade","quantity":1},` +
				`"outcome":{"item_count":1}} []`,
		},
		{
			name: "unsupported schema",
			value: `{"schema":2,` +
				testAuditIdentityFields +
				`"operation":"grant_item",` +
				`"payload":{"item_id":"ash-blade","quantity":1},` +
				`"outcome":{"item_count":1}}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := seededInventoryStorage()
			storage.seed(storedObject{
				Collection: AuditCollection,
				Key: auditKey(
					testSubjectID,
					"world_at_ruin_inventory",
					"carried",
					"quest:ember:reward",
				),
				UserID:          systemOwnerID,
				Value:           test.value,
				Version:         "audit-version",
				PermissionRead:  0,
				PermissionWrite: 0,
			})
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}

			_, err = store.Apply(
				context.Background(),
				inventoryMutation(testSubjectID, "quest:ember:reward"),
			)
			if !errors.Is(err, ErrStorage) {
				t.Fatalf("Apply() error = %v, want %v", err, ErrStorage)
			}
			if len(storage.WriteCalls) != 0 {
				t.Fatalf(
					"StorageWrite() calls = %d, want 0",
					len(storage.WriteCalls),
				)
			}
		})
	}
}

func TestApplyRejectsInvalidMutationBeforeStorage(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		change func(*Mutation)
	}{
		{
			name: "subject",
			change: func(mutation *Mutation) {
				mutation.SubjectID = "client-picked-subject"
			},
		},
		{
			name: "idempotency key",
			change: func(mutation *Mutation) {
				mutation.IdempotencyKey = ""
			},
		},
		{
			name: "operation",
			change: func(mutation *Mutation) {
				mutation.Operation = ""
			},
		},
		{
			name: "audit collection as record",
			change: func(mutation *Mutation) {
				mutation.Record.Collection = AuditCollection
			},
		},
		{
			name: "blind record version",
			change: func(mutation *Mutation) {
				mutation.Record.ExpectedVersion = ""
			},
		},
		{
			name: "payload",
			change: func(mutation *Mutation) {
				mutation.Payload = json.RawMessage(`[]`)
			},
		},
		{
			name: "record value",
			change: func(mutation *Mutation) {
				mutation.Record.Value = json.RawMessage(`null`)
			},
		},
		{
			name: "outcome",
			change: func(mutation *Mutation) {
				mutation.Outcome = json.RawMessage(`"granted"`)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			storage := seededInventoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore() error = %v", err)
			}
			mutation := inventoryMutation(
				testSubjectID,
				"quest:ember:reward",
			)
			test.change(&mutation)
			if _, err := store.Apply(
				context.Background(),
				mutation,
			); err == nil {
				t.Fatal("Apply() error = nil")
			}
			if storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
				t.Fatalf(
					"storage calls before rejection = reads %d, writes %d",
					storage.ReadCalls,
					len(storage.WriteCalls),
				)
			}
		})
	}
}

func TestApplyCreatesAPlayerRecordConditionallyWithItsAudit(t *testing.T) {
	t.Parallel()

	storage := newFakeStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	mutation := inventoryMutation(testSubjectID, "account:first-inventory")
	mutation.Record.ExpectedVersion = "*"

	if _, err := store.Apply(context.Background(), mutation); err != nil {
		t.Fatalf("Apply() create error = %v", err)
	}
	if len(storage.WriteCalls) != 1 ||
		len(storage.WriteCalls[0]) != 2 {
		t.Fatalf(
			"atomic StorageWrite() calls = %#v",
			storage.WriteCalls,
		)
	}
	recordWrite := storage.WriteCalls[0][0]
	if recordWrite.Version != "*" {
		t.Fatalf("record create version = %q, want *", recordWrite.Version)
	}
}

// TestEveryShippedAuditSchemaStaysReadable pins every persisted audit field to
// independent expectations, including the outcome used to replay a mutation.
func TestEveryShippedAuditSchemaStaysReadable(t *testing.T) {
	t.Parallel()

	fixtures := savefixturetest.Read(t, "audit")
	wantDocuments := []auditDocument{
		{
			Schema:           1,
			IdempotencyKey:   "quest:ember:reward",
			RecordCollection: "world_at_ruin_inventory",
			RecordKey:        "carried",
			Operation:        "grant_item",
			Payload:          json.RawMessage(`{"item_id":"ash-blade","quantity":1}`),
			Outcome:          json.RawMessage(`{"item_count":1}`),
		},
	}
	if len(fixtures) != len(wantDocuments) {
		t.Fatalf("audit ledger has %d versions, but preservation is checked for %d", len(fixtures), len(wantDocuments))
	}
	for index, wantDocument := range wantDocuments {
		fixture := fixtures[index]
		version := fixture.Version
		goldenBytes := fixture.Bytes
		document, err := decodeAuditDocument(
			strings.TrimSpace(string(goldenBytes)),
		)
		if err != nil {
			t.Fatalf("decode audit schema %d golden: %v", version, err)
		}
		if !reflect.DeepEqual(document, wantDocument) {
			t.Fatalf(
				"audit schema %d lost historical semantics: got %+v, want %+v",
				version,
				document,
				wantDocument,
			)
		}
	}
	if head := fixtures[len(fixtures)-1].Version; head != auditSchema {
		t.Fatalf("audit schema ledger head = %d, writer = %d", head, auditSchema)
	}
}

func seededInventoryStorage() *fakeStorage {
	storage := newFakeStorage()
	storage.seed(storedObject{
		Collection:      "world_at_ruin_inventory",
		Key:             "carried",
		UserID:          testSubjectID,
		Value:           `{"items":[],"schema":1}`,
		Version:         "observed",
		PermissionRead:  0,
		PermissionWrite: 0,
	})
	return storage
}

func inventoryMutation(subjectID, idempotencyKey string) Mutation {
	return Mutation{
		SubjectID:      subjectID,
		IdempotencyKey: idempotencyKey,
		Operation:      "grant_item",
		Payload: json.RawMessage(
			`{"item_id":"ash-blade","quantity":1}`,
		),
		Record: RecordWrite{
			Collection:      "world_at_ruin_inventory",
			Key:             "carried",
			ExpectedVersion: "observed",
			Value: json.RawMessage(
				`{"items":["ash-blade"],"schema":1}`,
			),
		},
		Outcome: json.RawMessage(`{"item_count":1}`),
	}
}
