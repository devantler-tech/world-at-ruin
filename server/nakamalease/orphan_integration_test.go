package nakamalease

import (
	"context"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/orphanreaper"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kuberuntime "k8s.io/apimachinery/pkg/runtime"
	clienttesting "k8s.io/client-go/testing"
)

func TestOrphanSweepPreservesTheRealLeaseLifecycle(t *testing.T) {
	for _, terminal := range []string{"claim", "release"} {
		t.Run(terminal, func(t *testing.T) {
			ctx := context.Background()
			storage := newMemoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			staging := Lease{UserID: testUserID, ReservationID: testReservationID, AttemptID: testAttemptID, Staging: true, ExpiresAt: time.Now().Add(time.Hour)}
			current, err := store.Create(ctx, staging)
			if err != nil {
				t.Fatal(err)
			}
			digest, err := agones.CorrelationLabel(staging.AttemptID)
			if err != nil {
				t.Fatal(err)
			}
			server := &agonesv1.GameServer{ObjectMeta: metav1.ObjectMeta{Namespace: "world", Name: testAllocationID, UID: "original-uid", ResourceVersion: "1", Labels: map[string]string{agones.FleetLabel: "zone", agones.AttemptLabel: digest}}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated}}
			resources := agonesfake.NewSimpleClientset(server)
			resources.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, kuberuntime.Object, error) {
				return true, &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "1"}, Items: []agonesv1.GameServer{*server.DeepCopy()}}, nil
			})
			reaper, err := orphanreaper.New(resources.AgonesV1().GameServers("world"), store, orphanreaper.Config{Namespace: "world", Fleet: "zone"})
			if err != nil {
				t.Fatal(err)
			}
			assertProtected := func() {
				t.Helper()
				writes, deletes := len(storage.writes), len(storage.deletes)
				report, err := reaper.Sweep(ctx)
				if err != nil || report.Protected != 1 || report.Waiting != 0 || report.Deleted != 0 {
					t.Fatalf("live lease was treated as an orphan: %+v, %v", report, err)
				}
				if len(storage.writes) != writes || len(storage.deletes) != deletes {
					t.Fatal("orphan observer mutated lease ownership")
				}
			}
			assertProtected()
			var dispatch bool
			current, dispatch, err = store.BeginDispatch(ctx, current, staging.AttemptID)
			if err != nil || !dispatch {
				t.Fatalf("dispatch = %v, %v", dispatch, err)
			}
			assertProtected()
			allocated := staging
			allocated.Staging = false
			allocated.AllocationID = testAllocationID
			allocated.Observer = 1
			allocated.SecretRef = testSecretRef
			current, err = store.Finalize(ctx, current, allocated)
			if err != nil {
				t.Fatal(err)
			}
			assertProtected()
			if terminal == "claim" {
				_, err = store.Claim(ctx, current, staging.AttemptID, time.Now())
			} else {
				_, err = store.BeginRelease(ctx, current, staging.AttemptID)
			}
			if err != nil {
				t.Fatal(err)
			}
			assertProtected()
			for _, action := range resources.Actions() {
				if action.GetVerb() != "list" {
					t.Fatal("orphan observer touched a leased GameServer")
				}
			}
		})
	}
}
