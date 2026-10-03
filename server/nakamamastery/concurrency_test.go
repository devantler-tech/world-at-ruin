package nakamamastery

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

type simultaneousReads struct {
	*nakamastoragetest.Fake
	mu       sync.Mutex
	observed int
	ready    chan struct{}
}

func (s *simultaneousReads) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	objects, err := s.Fake.StorageRead(ctx, reads)
	if err == nil && len(reads) == 1 && reads[0].Collection == Collection {
		s.mu.Lock()
		s.observed++
		count := s.observed
		if count == 2 {
			close(s.ready)
		}
		s.mu.Unlock()
		if count <= 2 {
			select {
			case <-s.ready:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}
	return objects, err
}

func TestConcurrentDistinctAwardsConflictWithoutPartialAudit(t *testing.T) {
	_, authority, storage, ctx := setup(t)
	seedState(t, storage, State{Schema: 1, Weapons: map[string]Track{"axe": {100, 95}}, Stain: Stain{Points: map[string]int64{}}})
	barrier := &simultaneousReads{Fake: storage, ready: make(chan struct{})}
	store, err := NewStore(barrier, authority)
	if err != nil {
		t.Fatal(err)
	}
	events := []Event{award(t, authority, "race-1", 5), award(t, authority, "race-2", 5)}
	failures := make(chan Event, 2)
	var group sync.WaitGroup
	for _, event := range events {
		group.Go(func() {
			_, err := store.Apply(ctx, event)
			if errors.Is(err, playerstate.ErrConflict) {
				failures <- event
			} else if err != nil {
				t.Errorf("Apply = %v", err)
			}
		})
	}
	group.Wait()
	close(failures)
	var retry Event
	count := 0
	for event := range failures {
		retry = event
		count++
	}
	if count != 1 || len(storage.Objects()) != 2 {
		t.Fatal("race did not commit exactly one atomic event")
	}
	state, _, err := store.Load(ctx, subject)
	if err != nil || state.Weapons["axe"] != (Track{200, 0}) {
		t.Fatalf("first = %#v %v", state, err)
	}
	out, err := store.Apply(ctx, retry)
	if err != nil || out.State.Weapons["axe"] != (Track{200, 5}) || len(storage.Objects()) != 3 {
		t.Fatalf("same-event redecision = %#v %v", out, err)
	}
}

func TestCommittedButUnreadableOutcomeRemainsIndeterminate(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	storage.AfterWrite = func(int) error {
		storage.ReadErr = errors.New("private unavailable backend")
		return errors.New("lost acknowledgement")
	}
	event := award(t, authority, "uncertain", 105)
	if _, err := store.Apply(ctx, event); !errors.Is(err, playerstate.ErrIndeterminate) {
		t.Fatalf("uncertain = %v", err)
	}
	if len(storage.Objects()) != 2 || len(storage.WriteCalls) != 1 {
		t.Fatal("did not commit exactly once before the read failed")
	}
	storage.ReadErr = nil
	storage.AfterWrite = nil
	fresh, err := NewAuthority(Config{Enabled: true, SourceUID: "source-1", SourceIncarnation: "incarnation-1"})
	if err != nil {
		t.Fatal(err)
	}
	restarted, err := NewStore(storage, fresh)
	if err != nil {
		t.Fatal(err)
	}
	out, err := restarted.Resolve(ctx, award(t, fresh, "uncertain", 105))
	if err != nil || out.State.Weapons["axe"] != (Track{100, 5}) || len(storage.WriteCalls) != 1 {
		t.Fatalf("restart recovery = %#v %v", out, err)
	}
}
