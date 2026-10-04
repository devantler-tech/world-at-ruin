package handoffalloc

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

// Restart and retry must preserve the durable quarantine before any external
// resource method runs, for every expanded lifecycle including empty bindings.
func TestExpandedLeaseRestartHoldsAllResourceOperations(t *testing.T) {
	data, err := os.ReadFile("../nakamalease/testdata/golden_lease_v4.json")
	if err != nil {
		t.Fatal(err)
	}
	var shapes []json.RawMessage
	if err := json.Unmarshal(data, &shapes); err != nil {
		t.Fatal(err)
	}
	if len(shapes) != 7 {
		t.Fatalf("expanded lifecycle shapes = %d, want 7", len(shapes))
	}
	for index, raw := range shapes {
		for _, operation := range []string{"same-attempt", "new-attempt", "release", "expiry", "progressed", "resolve", "resource-cleanup", "canceled", "deadline"} {
			t.Run(operation+"/shape-"+string(rune('1'+index)), func(t *testing.T) {
				storage := nakamastoragetest.New()
				key := nakamalease.ReservationKey(testUserID, testReservationID)
				storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: key, Value: string(raw), Version: "golden-v4"})
				before := storage.Objects()
				store := newLeaseStore(t, storage)
				loaded, err := store.Load(t.Context(), testUserID, testReservationID)
				if err != nil || !loaded.Lease.ReaderOnly() {
					t.Fatalf("expanded durable fixture: %+v, %v", loaded, err)
				}
				resources := &recordingResources{provisioned: validProvisioned()}
				for range 2 {
					coordinator, err := NewCoordinator(resources, store, Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow.Add(time.Hour) }})
					if err != nil {
						t.Fatal(err)
					}
					var allocation handoff.Allocation
					switch operation {
					case "same-attempt":
						allocation, err = coordinator.Allocate(t.Context(), validRequest())
					case "new-attempt":
						request := validRequest()
						request.AttemptID = "attempt-8"
						allocation, err = coordinator.Allocate(t.Context(), request)
					case "release":
						err = coordinator.Release(t.Context(), validRequest())
					case "expiry":
						err = coordinator.ReconcileExpired(t.Context())
					case "progressed":
						allocation, _, err = coordinator.resolveProgressedAttempt(t.Context(), validRequest())
					case "resolve":
						allocation, err = coordinator.resolveDurable(t.Context(), loaded.Lease)
					case "resource-cleanup":
						err = coordinator.releaseResource(t.Context(), loaded.Lease)
					case "canceled":
						ctx, cancel := context.WithCancel(t.Context())
						cancel()
						allocation, err = coordinator.Allocate(ctx, validRequest())
					case "deadline":
						ctx, cancel := context.WithDeadline(t.Context(), time.Unix(1, 0))
						allocation, err = coordinator.Allocate(ctx, validRequest())
						cancel()
					}
					if err == nil || allocation.ID != "" || len(allocation.AdmissionSecret) != 0 {
						t.Fatalf("expanded lease exposed resource work or admission: %+v, %v", allocation, err)
					}
				}
				if len(resources.provisions)+len(resources.reconciliations)+len(resources.resolutions)+len(resources.releases) != 0 {
					t.Fatalf("external resource work crossed quarantine: %+v", resources.events)
				}
				if len(storage.WriteCalls) != 0 || !reflect.DeepEqual(storage.Objects(), before) {
					t.Fatal("restart/retry changed expanded durable quarantine")
				}
			})
		}
	}
}
