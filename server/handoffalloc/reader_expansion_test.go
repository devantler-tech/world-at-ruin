package handoffalloc

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

func expandedLeaseShapes(t *testing.T) []json.RawMessage {
	t.Helper()
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
	return shapes
}

// Restart and retry must preserve the durable quarantine before any external
// resource method runs, for every expanded lifecycle including empty bindings.
func TestExpandedLeaseRestartHoldsAllResourceOperations(t *testing.T) {
	shapes := expandedLeaseShapes(t)
	for index, raw := range shapes {
		for _, operation := range []string{"same-attempt", "new-attempt", "release", "expiry", "progressed", "resolve", "resource-cleanup", "canceled", "deadline"} {
			t.Run(operation+"/shape-"+strconv.Itoa(index+1), func(t *testing.T) {
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

// Observation outcomes cannot unlock a bound durable dispatch. A legacy control
// proves the resource seam is reachable rather than accidentally unconfigured.
func TestExpandedDispatchRestartIgnoresAllocatorObservationOutcomes(t *testing.T) {
	shapes := expandedLeaseShapes(t)
	for _, observation := range []string{"missing allocator", "replaced allocator", "draining generation"} {
		t.Run(observation, func(t *testing.T) {
			key := nakamalease.ReservationKey(testUserID, testReservationID)
			// The same dispatched shape under the active schema reaches the seam.
			var legacy map[string]json.RawMessage
			if err := json.Unmarshal(shapes[1], &legacy); err != nil {
				t.Fatal(err)
			}
			legacy["schema"] = json.RawMessage("3")
			for _, field := range []string{"allocator_generation_id", "allocator_member_set_digest", "allocator_pod_uid"} {
				delete(legacy, field)
			}
			value, err := json.Marshal(legacy)
			if err != nil {
				t.Fatal(err)
			}
			control := nakamastoragetest.New()
			control.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: key, Value: string(value), Version: "legacy-dispatch"})
			controlResources := &recordingResources{reconcileErr: errors.New(observation)}
			coordinator, err := NewCoordinator(controlResources, newLeaseStore(t, control), Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow.Add(-time.Second) }})
			if err != nil {
				t.Fatal(err)
			}
			if allocation, err := coordinator.Allocate(t.Context(), validRequest()); err == nil || allocation.ID != "" || len(controlResources.reconciliations) != 1 {
				t.Fatalf("legacy observation seam was not reached: %+v, %v", allocation, err)
			}
			for _, shape := range []int{1, 6} {
				for _, operation := range []string{"same attempt", "new attempt", "release", "expiry"} {
					t.Run(operation+"/shape-"+strconv.Itoa(shape+1), func(t *testing.T) {
						storage := nakamastoragetest.New()
						storage.Seed(nakamastoragetest.Object{Collection: nakamalease.Collection, Key: key, Value: string(shapes[shape]), Version: "bound-expanded-dispatch"})
						before := storage.Objects()
						resources := &recordingResources{reconcileErr: errors.New(observation), resolveErr: errors.New(observation), releaseErr: errors.New(observation)}
						for range 2 {
							coordinator, err := NewCoordinator(resources, newLeaseStore(t, storage), Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow.Add(time.Second) }})
							if err != nil {
								t.Fatal(err)
							}
							request := validRequest()
							var allocation handoff.Allocation
							switch operation {
							case "same attempt":
								allocation, err = coordinator.Allocate(t.Context(), request)
							case "new attempt":
								request.AttemptID = "attempt-8"
								allocation, err = coordinator.Allocate(t.Context(), request)
							case "release":
								err = coordinator.Release(t.Context(), request)
							case "expiry":
								err = coordinator.ReconcileExpired(t.Context())
							}
							if err == nil || allocation.ID != "" || len(allocation.AdmissionSecret) != 0 {
								t.Fatalf("observation unlocked expanded dispatch: %+v, %v", allocation, err)
							}
						}
						if len(resources.provisions)+len(resources.reconciliations)+len(resources.resolutions)+len(resources.releases) != 0 {
							t.Fatal("expanded dispatch reached resource observation or cleanup")
						}
						if len(storage.WriteCalls) != 0 || !reflect.DeepEqual(before, storage.Objects()) {
							t.Fatal("observation changed durable dispatch")
						}
					})
				}
			}
		})
	}
}
