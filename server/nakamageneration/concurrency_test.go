package nakamageneration

import (
	"context"
	"errors"
	"reflect"
	"sync/atomic"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

func TestConcurrentCreatorsCannotReplaceMembership(t *testing.T) {
	t.Parallel()
	for _, conflicting := range []bool{false, true} {
		t.Run(map[bool]string{false: "identical", true: "conflicting"}[conflicting], func(t *testing.T) {
			t.Parallel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			var reads atomic.Int32
			bothAbsent := make(chan struct{})
			storage.read = func(ctx context.Context, requests []*runtime.StorageRead) ([]*api.StorageObject, error) {
				objects, err := storage.Fake.StorageRead(ctx, requests)
				// Both initial reads must observe absence before either can write.
				switch reads.Add(1) {
				case 1:
					select {
					case <-bothAbsent:
					case <-ctx.Done():
						return nil, ctx.Err()
					}
				case 2:
					close(bothAbsent)
				}
				return objects, err
			}
			type result struct {
				record Record
				err    error
			}
			results := make(chan result, 2)
			members := [][]string{{"pod-a"}, {"pod-a"}}
			if conflicting {
				members[1] = []string{"pod-b"}
			}
			for _, set := range members {
				store := newTestStore(t, storage)
				go func() {
					record, err := store.CreateOpen(t.Context(), "generation-1", set)
					results <- result{record, err}
				}()
			}
			first, second := <-results, <-results
			if first.err != nil {
				first, second = second, first
			}
			if first.err != nil || first.record.Version != "v1" {
				t.Fatalf("no durable winner: %+v / %+v", first, second)
			}
			if conflicting {
				if !errors.Is(second.err, ErrConflict) {
					t.Fatalf("loser replaced membership: %+v", second)
				}
			} else if second.err != nil || !reflect.DeepEqual(first.record, second.record) {
				t.Fatalf("identical creators diverged: %+v / %+v", first, second)
			}
			loaded, err := newTestStore(t, storage.Fake).Load(t.Context(), "generation-1")
			if err != nil || !reflect.DeepEqual(loaded, first.record) || len(storage.Objects()) != 1 {
				t.Fatalf("winner not durable: %+v, %v", loaded, err)
			}
			if len(storage.WriteCalls) != 2 {
				t.Fatalf("did not exercise the create race: %d writes", len(storage.WriteCalls))
			}
			for _, batch := range storage.WriteCalls {
				if len(batch) != 1 || batch[0].Version != "*" {
					t.Fatal("raced creator attempted an overwrite")
				}
			}
		})
	}
}
