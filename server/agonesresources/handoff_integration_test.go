package agonesresources

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/handoffalloc"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"k8s.io/apimachinery/pkg/types"
)

// The transport and storage are fake; allocation, envelope validation,
// persistence, restart recovery and resource cleanup all use production code.
func handoffCoordinator(
	t *testing.T, f *fixture, storage *nakamastoragetest.Fake, now *time.Time,
) (*handoffalloc.Coordinator, *nakamalease.Store) {
	t.Helper()
	store, err := nakamalease.NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	coordinator, err := handoffalloc.NewCoordinator(f.adapter, store, handoffalloc.Config{
		LeaseTTL: time.Minute, Now: func() time.Time { return *now },
	})
	if err != nil {
		t.Fatal(err)
	}
	return coordinator, store
}

func assertHandoffAllocation(t *testing.T, got handoff.Allocation, name string, expiry time.Time) {
	t.Helper()
	if got.ID != name || got.ServerName != "node-a.zones.example" || got.Port != 8443 ||
		got.Observer != 42 || !got.LeaseExpiresAt.Equal(expiry) ||
		!bytes.Equal(got.AdmissionSecret, secretFor(name)) {
		t.Fatalf("handoff did not resolve the expected server, observer, expiry and secret for %s", name)
	}
}

func assertSecretsAbsent(t *testing.T, storage *nakamastoragetest.Fake, names ...string) {
	t.Helper()
	for _, object := range storage.Objects() {
		assertPrivateLeaseValue(t, object.Value, object.PermissionRead == 0 && object.PermissionWrite == 0, names)
	}
	for _, writes := range storage.WriteCalls {
		for _, write := range writes {
			assertPrivateLeaseValue(t, write.Value, write.PermissionRead == 0 && write.PermissionWrite == 0, names)
		}
	}
}

func assertPrivateLeaseValue(t *testing.T, value string, private bool, names []string) {
	t.Helper()
	if !private {
		t.Fatal("handoff wrote a client-accessible record")
	}
	for _, name := range names {
		secret := secretFor(name)
		if bytes.Contains([]byte(value), secret) ||
			strings.Contains(value, base64.StdEncoding.EncodeToString(secret)) ||
			strings.Contains(value, base64.RawURLEncoding.EncodeToString(secret)) {
			t.Fatal("handoff wrote raw or encoded admission-secret bytes")
		}
	}
}

// Skipping Finalize must fail here before restart can adopt a staging record.
func TestHandoffIntegrationPersistsBeforeReturningAndResolvesAfterRestart(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-one", "uid-one"))
	storage := nakamastoragetest.New()
	now := testExpiry.Add(-time.Minute)
	coordinator, store := handoffCoordinator(t, f, storage, &now)
	got, err := coordinator.Allocate(context.Background(), request())
	if err != nil {
		t.Fatal(err)
	}
	assertHandoffAllocation(t, got, "zone-one", testExpiry)
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil || record.Lease.Staging || record.Lease.Dispatched || record.Lease.Releasing ||
		record.Lease.AttemptID != testAttemptID || record.Lease.AllocationID != "zone-one" ||
		record.Lease.SecretRef != f.expectedReference("zone-one") || record.Lease.Observer != 42 ||
		!record.Lease.ExpiresAt.Equal(testExpiry) {
		t.Fatalf("allocation returned without a complete durable lease: %v", err)
	}
	assertSecretsAbsent(t, storage, "zone-one")
	writeCount := len(storage.WriteCalls)
	restarted, _ := handoffCoordinator(t, f, storage, &now)
	retry := request()
	retry.AttemptID = "transport-retry"
	got, err = restarted.Allocate(context.Background(), retry)
	if err != nil {
		t.Fatal(err)
	}
	assertHandoffAllocation(t, got, "zone-one", testExpiry)
	if f.allocations.count() != 1 || len(storage.WriteCalls) != writeCount || f.actions("delete") != 0 {
		t.Fatal("restart failed to reuse the persisted allocation without dispatch or mutation")
	}
}

// Expiry may replace an old lease only after releasing its exact GameServer UID.
func TestHandoffIntegrationExpiredRetryReleasesAndAllocatesANewAttempt(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-old", "uid-old"))
	storage := nakamastoragetest.New()
	now := testExpiry.Add(-time.Minute)
	coordinator, _ := handoffCoordinator(t, f, storage, &now)
	if _, err := coordinator.Allocate(context.Background(), request()); err != nil {
		t.Fatal(err)
	}
	now = testExpiry.Add(time.Second)
	f.seed(f.readyGameServer("zone-new", "uid-new"))
	restarted, store := handoffCoordinator(t, f, storage, &now)
	retry := request()
	retry.AttemptID = "attempt-new"
	got, err := restarted.Allocate(context.Background(), retry)
	if err != nil {
		t.Fatal(err)
	}
	assertHandoffAllocation(t, got, "zone-new", now.Add(time.Minute))
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil || record.Lease.AttemptID != "attempt-new" || record.Lease.AllocationID != "zone-new" {
		t.Fatalf("replacement did not become durable: %v", err)
	}
	if f.allocations.count() != 2 || f.exists("zone-old") || !f.exists("zone-new") ||
		!reflect.DeepEqual(f.deletedUIDs(), []types.UID{"uid-old"}) {
		t.Fatal("retry did not release only the expired UID before replacing it")
	}
	assertSecretsAbsent(t, storage, "zone-old", "zone-new")
}

// A lost response after commit must be adopted through observation, never redispatched.
func TestHandoffIntegrationRecoversAnAmbiguousCommittedDispatch(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-late", "uid-late"))
	f.allocations.setHandler(func(req *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		if _, err := f.commitAllocation(req); err != nil {
			return nil, err
		}
		return nil, status.Error(codes.Unavailable, "response lost after commit")
	})
	storage := nakamastoragetest.New()
	now := testExpiry.Add(-time.Minute)
	coordinator, store := handoffCoordinator(t, f, storage, &now)
	got, err := coordinator.Allocate(context.Background(), request())
	if status.Code(err) != codes.Unavailable || !isZeroAllocation(got) {
		t.Fatalf("ambiguous dispatch = %v, want unavailable without connection material", err)
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil || !record.Lease.Staging || !record.Lease.Dispatched || record.Lease.DispatchID == "" {
		t.Fatalf("ambiguous dispatch lost its durable quarantine: %v", err)
	}
	restarted, _ := handoffCoordinator(t, f, storage, &now)
	got, err = restarted.Allocate(context.Background(), request())
	if err != nil {
		t.Fatal(err)
	}
	assertHandoffAllocation(t, got, "zone-late", testExpiry)
	if f.allocations.count() != 1 || f.actions("delete") != 0 {
		t.Fatal("recovery redispatched or deleted the committed GameServer")
	}
	assertSecretsAbsent(t, storage, "zone-late")
}

// The sweep's paged scan must not skip leases as it deletes each earlier page.
func TestHandoffIntegrationExpirySweepTraversesEveryPage(t *testing.T) {
	f := newFixture(t, nil)
	storage := nakamastoragetest.New()
	now := testExpiry.Add(-time.Minute)
	coordinator, _ := handoffCoordinator(t, f, storage, &now)
	for index := range 103 {
		name := fmt.Sprintf("zone-%03d", index)
		f.seed(f.readyGameServer(name, types.UID("uid-"+name)))
		req := request()
		req.ReservationID = fmt.Sprintf("reservation-%03d", index)
		req.AttemptID = fmt.Sprintf("attempt-%03d", index)
		if _, err := coordinator.Allocate(context.Background(), req); err != nil {
			t.Fatalf("seed handoff %d: %v", index, err)
		}
	}
	now = testExpiry.Add(time.Second)
	f.seed(f.readyGameServer("zone-ready", "uid-ready"))
	restarted, _ := handoffCoordinator(t, f, storage, &now)
	if err := restarted.ReconcileExpired(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(storage.Objects()) != 0 || len(f.deletedUIDs()) != 103 || !f.exists("zone-ready") {
		t.Fatal("sweep skipped expired leases or touched the unrelated Ready pool")
	}
	if err := restarted.ReconcileExpired(context.Background()); err != nil || len(f.deletedUIDs()) != 103 {
		t.Fatalf("repeated cleanup was not idempotent: %v", err)
	}
}

// Recreating a name must not let an expired lease delete its new incarnation.
func TestHandoffIntegrationExpiryPreservesARecreatedGameServer(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-reused", "uid-original"))
	storage := nakamastoragetest.New()
	now := testExpiry.Add(-time.Minute)
	coordinator, store := handoffCoordinator(t, f, storage, &now)
	if _, err := coordinator.Allocate(context.Background(), request()); err != nil {
		t.Fatal(err)
	}
	f.replace(f.allocatedGameServer("zone-reused", "uid-recreated", testAttemptID))
	now = testExpiry.Add(time.Second)
	if err := coordinator.ReconcileExpired(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !f.exists("zone-reused") || f.actions("delete") != 0 {
		t.Fatal("expired lease deleted a recreated GameServer")
	}
	if _, err := store.Load(context.Background(), testUserID, testReservationID); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("old lease remained after its exact resource was gone: %v", err)
	}
}
