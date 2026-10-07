package nakamalease

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Any read or write is counted before failing, even if its error is ignored.
// Other storage methods deliberately have no implementation and panic if used.
type claimedReplayStorage struct {
	storageClient
	calls int
}

func (s *claimedReplayStorage) StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.calls++
	return nil, errors.New("unexpected read")
}

func (s *claimedReplayStorage) StorageWrite(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.calls++
	return nil, errors.New("unexpected write")
}

// Claimed replays must rebind to durable state before returning ownership.
// An unavailable backend cannot establish that the stored schema is writable.
func TestClaimedReplayRefusesUnavailableDurableObservation(t *testing.T) {
	storage := &claimedReplayStorage{}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	lease := validLease()
	lease.ClaimedAt = lease.ExpiresAt.Add(-time.Second)
	observed := Record{Lease: lease, Version: "observed-version"}
	got, err := store.Claim(context.Background(), observed, lease.AttemptID, lease.ClaimedAt.Add(time.Second))
	if !errors.Is(err, ErrStorage) || got != (Record{}) || storage.calls != 1 {
		t.Fatalf("claimed replay bypassed durable state: got=%+v err=%v calls=%d", got, err, storage.calls)
	}
}

// A claimed legacy row replays idempotently only after its exact durable observation matches.
func TestClaimedReplayReturnsExactDurableRecordWithoutWriting(t *testing.T) {
	storage, store := newLeaseStoreFixture(t)
	lease := validLease()
	current := mustCreateLease(t, store, lease)
	claimed, err := store.Claim(t.Context(), current, lease.AttemptID, lease.ExpiresAt.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	writes := len(storage.writes)
	got, err := store.Claim(t.Context(), claimed, lease.AttemptID, lease.ExpiresAt)
	if err != nil || got != claimed || len(storage.writes) != writes {
		t.Fatalf("claimed replay = %+v, %v; writes=%d, want exact durable record without a write", got, err, len(storage.writes)-writes)
	}
}
