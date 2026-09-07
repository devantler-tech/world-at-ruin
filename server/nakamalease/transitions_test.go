package nakamalease

import (
	"context"
	"errors"
	"strings"
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

// An already-claimed observation is an idempotent local replay. It preserves
// the caller's record and does not turn a backend outage into a second claim.
func TestClaimedReplayReturnsObservedRecordWithoutStorage(t *testing.T) {
	storage := &claimedReplayStorage{}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	lease := validLease()
	lease.UserID = strings.ToUpper(testCanonicalID)
	lease.ClaimedAt = lease.ExpiresAt.Add(-time.Second)
	observed := Record{Lease: lease, Version: "observed-version"}
	got, err := store.Claim(context.Background(), observed, lease.AttemptID, lease.ClaimedAt.Add(time.Second))
	if err != nil || got != observed || storage.calls != 0 {
		t.Fatalf("claimed replay changed record or used storage: got=%+v err=%v calls=%d", got, err, storage.calls)
	}
}
