package playerstate

import (
	"context"
	"errors"
	"testing"
)

func TestLookupReturnsOriginalOutcomeWithoutAReplacement(t *testing.T) {
	storage := seededInventoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	mutation := inventoryMutation(testSubjectID, "lookup-event")
	request := LookupRequest{SubjectID: mutation.SubjectID, IdempotencyKey: mutation.IdempotencyKey, Operation: mutation.Operation, Payload: mutation.Payload, RecordCollection: mutation.Record.Collection, RecordKey: mutation.Record.Key}
	if _, found, err := store.Lookup(context.Background(), request); err != nil || found {
		t.Fatalf("missing lookup = %v, %v", found, err)
	}
	if _, err := store.Apply(context.Background(), mutation); err != nil {
		t.Fatal(err)
	}
	before := storage.NextVersion()
	got, found, err := store.Lookup(context.Background(), request)
	if err != nil || !found || string(got.Outcome) != `{"item_count":1}` {
		t.Fatalf("lookup = %s, %v, %v", got.Outcome, found, err)
	}
	if storage.NextVersion() != before {
		t.Fatal("lookup wrote storage")
	}
	request.Operation = "different-operation"
	if _, _, err := store.Lookup(context.Background(), request); !errors.Is(err, ErrKeyConflict) {
		t.Fatalf("changed binding = %v", err)
	}
}
