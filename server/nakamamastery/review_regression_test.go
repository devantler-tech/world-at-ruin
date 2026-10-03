package nakamamastery

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

func TestEncodedDocumentsRefuseBeforeWritingUnreadableState(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	state := emptyState()
	for i := 0; i < 64; i++ {
		state.Weapons[strings.Repeat("<", 125)+fmt.Sprintf("%03d", i)] = Track{0, 99}
	}
	seedState(t, storage, state)
	event, err := authority.Death(subject, "encoded-size", 100)
	if err != nil {
		t.Fatal(err)
	}
	before := storage.NextVersion()
	if _, err := store.Apply(ctx, event); err == nil {
		t.Fatal("persisted unreadable encoded documents")
	}
	after, _, err := store.Load(ctx, subject)
	if err != nil || !reflect.DeepEqual(after, state) || storage.NextVersion() != before || len(storage.Objects()) != 1 || len(storage.WriteCalls) != 0 {
		t.Fatalf("oversize changed storage: %v", err)
	}
}

func TestInvalidUTF8RefusesOriginalIdentitiesAndDocuments(t *testing.T) {
	_, authority, _, _ := setup(t)
	for _, id := range []string{"\xff", "\xfe"} {
		if _, err := authority.Award(subject, id, "axe", 1); err == nil {
			t.Fatal("accepted invalid UTF8 event")
		}
		if _, err := authority.Award(subject, "valid", id, 1); err == nil {
			t.Fatal("accepted invalid UTF8 weapon")
		}
	}
	raw := strings.Replace(cleanDocument, "axe", string([]byte{255}), 1)
	if _, err := decodeMasteryDocument(raw); err == nil {
		t.Fatal("accepted invalid UTF8 document")
	}
}

func TestImpossibleHistoricalOutcomesRefuse(t *testing.T) {
	state := State{Schema: 1, Weapons: map[string]Track{"axe": {100, 5}}, Stain: Stain{ID: "stain", Points: map[string]int64{"axe": 3}}}
	cases := []Outcome{
		{Schema: 1, Kind: "reclaim", Credited: 3, Dropped: map[string]int64{}, Destroyed: map[string]int64{}, State: state},
		{Schema: 1, Kind: "death", Dropped: map[string]int64{"axe": 4}, Destroyed: map[string]int64{}, State: state},
	}
	for _, out := range cases {
		raw, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := decodeOutcome(string(raw)); err == nil {
			t.Fatal("accepted impossible outcome")
		}
	}
	_, authority, _, _ := setup(t)
	death, err := authority.Death(subject, "historical", 50)
	if err != nil {
		t.Fatal(err)
	}
	out := Outcome{Schema: 1, Kind: "death", Dropped: map[string]int64{"axe": 3}, Destroyed: map[string]int64{}, State: state}
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := historical(playerstate.Result{Outcome: raw}, death); err == nil {
		t.Fatal("accepted foreign death identity")
	}
}

// The first two audit observations are both absent, but the second caller
// receives its observation after the first transaction commits.
type delayedMissingAudit struct {
	*nakamastoragetest.Fake
	mu               sync.Mutex
	reads            int
	ready, committed chan struct{}
	once             sync.Once
}

func (s *delayedMissingAudit) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	objects, err := s.Fake.StorageRead(ctx, reads)
	if err == nil && len(reads) == 1 && reads[0].Collection == "world_at_ruin_player_mutations" {
		s.mu.Lock()
		s.reads++
		count := s.reads
		if count == 2 {
			close(s.ready)
		}
		s.mu.Unlock()
		var wait <-chan struct{}
		switch count {
		case 1:
			wait = s.ready
		case 2:
			wait = s.committed
		default:
			return objects, err
		}
		select {
		case <-wait:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return objects, err
}
func (s *delayedMissingAudit) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, err := s.Fake.StorageWrite(ctx, writes)
	if err == nil {
		s.once.Do(func() { close(s.committed) })
	}
	return acks, err
}

func TestReplayAfterConcurrentTransitionRefusalReturnsOriginal(t *testing.T) {
	for _, kind := range []string{"reclaim", "award"} {
		t.Run(kind, func(t *testing.T) {
			_, authority, storage, ctx := setup(t)
			state := emptyState()
			var event Event
			var err error
			if kind == "reclaim" {
				state.Weapons["axe"] = Track{100, 5}
				state.Stain = Stain{ID: "standing", Points: map[string]int64{"axe": 3}}
				event, err = authority.Reclaim(subject, "same-event", "standing")
			} else {
				state.Weapons["axe"] = Track{9007199254740900, 90}
				event, err = authority.Award(subject, "same-event", "axe", 1)
			}
			if err != nil {
				t.Fatal(err)
			}
			seedState(t, storage, state)
			delayed := &delayedMissingAudit{Fake: storage, ready: make(chan struct{}), committed: make(chan struct{})}
			store, err := NewStore(delayed, authority)
			if err != nil {
				t.Fatal(err)
			}
			var group sync.WaitGroup
			outcomes := make(chan Outcome, 2)
			for range 2 {
				group.Go(func() {
					out, err := store.Apply(ctx, event)
					if err != nil {
						t.Errorf("concurrent replay = %v", err)
					} else {
						outcomes <- out
					}
				})
			}
			group.Wait()
			close(outcomes)
			results := []Outcome{}
			for out := range outcomes {
				results = append(results, out)
			}
			if len(results) != 2 || !reflect.DeepEqual(results[0], results[1]) || len(storage.WriteCalls) != 1 || len(storage.Objects()) != 2 {
				t.Fatal("concurrent replay lost original outcome")
			}
		})
	}
}
