package claimrpc

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kubetesting "k8s.io/client-go/testing"
)

// The real private claim service, lease store and resource adapter run together;
// only Nakama and Kubernetes transports are replaced. In particular, cleanup
// must carry the original UID precondition all the way to the Kubernetes call.
func TestClaimedSessionEndsThroughPinnedAgonesCleanup(t *testing.T) {
	for _, scenario := range []string{"ended", "recreated GameServer", "restart after cleanup failure"} {
		t.Run(scenario, func(t *testing.T) {
			ctx := context.Background()
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			adapter, kube, gs := f.resourceResolver(t)
			client, _ := f.serve(t, adapter.Resolve)
			if err := client.Claim(ctx, f.binding, f.token, 1); err != nil {
				t.Fatal(err)
			}
			claimed, err := f.store.LoadForClaim(ctx, f.binding.LeaseObjectID)
			if err != nil {
				t.Fatal(err)
			}
			fence := nakamalease.SessionFence{
				LeaseObjectID: f.binding.LeaseObjectID, LeaseVersion: claimed.Version,
				AttemptDigest: f.binding.AttemptDigest, AllocationID: f.binding.AllocationID,
				GameServerUID: f.binding.GameServerUID, Generation: claimed.Lease.ClaimedAt,
			}
			if scenario == "recreated GameServer" {
				gs.UID = "replacement-uid"
				if _, err := kube.AgonesV1().GameServers("world").Update(ctx, gs, metav1.UpdateOptions{}); err != nil {
					t.Fatal(err)
				}
			}
			failDelete := scenario == "restart after cleanup failure"
			deletes := 0
			kube.PrependReactor("delete", "gameservers", func(action kubetesting.Action) (bool, runtime.Object, error) {
				deletes++
				deletion, ok := action.(kubetesting.DeleteAction)
				if !ok {
					t.Fatal("expected Kubernetes delete action")
				}
				options := deletion.GetDeleteOptions()
				if deletion.GetName() != "zone-1" || options.Preconditions == nil || options.Preconditions.UID == nil || string(*options.Preconditions.UID) != "uid-1" {
					t.Fatal("cleanup lost exact GameServer UID")
				}
				barrier, err := f.store.LoadForClaim(ctx, f.binding.LeaseObjectID)
				if err != nil || !barrier.Lease.Releasing || !barrier.Lease.ClaimedAt.IsZero() {
					t.Fatal("resource deletion preceded durable fence")
				}
				if failDelete {
					return true, nil, errors.New("private API server failure")
				}
				return false, nil, nil
			})
			err = f.store.EndSession(ctx, fence, adapter.Release)
			if failDelete {
				if err == nil {
					t.Fatal("failed cleanup released reservation")
				}
				failDelete = false
				restarted, err := nakamalease.NewStore(f.storage)
				if err != nil {
					t.Fatal(err)
				}
				if err := restarted.ReclaimExpired(ctx, time.Now(), adapter.Release); err != nil {
					t.Fatal(err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.LoadForClaim(ctx, f.binding.LeaseObjectID); !errors.Is(err, nakamalease.ErrNotFound) {
				t.Fatalf("ended session retained reservation: %v", err)
			}
			current, err := kube.AgonesV1().GameServers("world").Get(ctx, "zone-1", metav1.GetOptions{})
			if scenario == "recreated GameServer" {
				if err != nil || current.UID != "replacement-uid" || deletes != 0 {
					t.Fatal("old completion touched replacement GameServer")
				}
			} else if !apierrors.IsNotFound(err) || deletes == 0 {
				t.Fatalf("owned GameServer survived cleanup: %v", err)
			}
			if err := client.Claim(ctx, f.binding, f.token, 1); err == nil {
				t.Fatal("completed session admitted a stale token")
			}
		})
	}
}
