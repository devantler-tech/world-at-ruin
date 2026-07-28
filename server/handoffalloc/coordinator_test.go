package handoffalloc

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	testUserID        = "d95d6008-7542-4a3b-9519-0e2c9b66c50a"
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
	testSystemOwnerID = "00000000-0000-0000-0000-000000000000"
)

var testNow = time.Unix(2_000_000_000, 123_456_789).UTC()

type memoryStorage struct {
	objects    map[string]*api.StorageObject
	version    int
	readErr    error
	writeErr   error
	writeErrAt int
	deleteErr  error
}

func newMemoryStorage() *memoryStorage {
	return &memoryStorage{objects: make(map[string]*api.StorageObject)}
}

func (s *memoryStorage) StorageList(
	_ context.Context,
	_ string,
	userID string,
	collection string,
	_ int,
	_ string,
) ([]*api.StorageObject, string, error) {
	if s.readErr != nil {
		return nil, "", s.readErr
	}
	objects := make([]*api.StorageObject, 0, len(s.objects))
	for _, object := range s.objects {
		if object.GetUserId() == userID &&
			object.GetCollection() == collection {
			cloned, ok := proto.Clone(object).(*api.StorageObject)
			if !ok {
				return nil, "", errors.New(
					"test storage: cloned object has an unexpected type",
				)
			}
			objects = append(objects, cloned)
		}
	}
	sort.Slice(objects, func(left, right int) bool {
		return objects[left].GetKey() < objects[right].GetKey()
	})
	return objects, "", nil
}

func (s *memoryStorage) StorageRead(
	_ context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	if s.readErr != nil {
		return nil, s.readErr
	}
	if len(reads) != 1 {
		return nil, errors.New("test storage: expected one read")
	}
	object, ok := s.objects[storageKey(reads[0].Collection, reads[0].Key)]
	if !ok {
		return nil, nil
	}
	cloned, ok := proto.Clone(object).(*api.StorageObject)
	if !ok {
		return nil, errors.New("test storage: cloned object has an unexpected type")
	}
	return []*api.StorageObject{
		cloned,
	}, nil
}

func (s *memoryStorage) StorageWrite(
	_ context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	if s.writeErr != nil {
		return nil, s.writeErr
	}
	if s.writeErrAt > 0 && s.version+1 == s.writeErrAt {
		s.writeErrAt = 0
		return nil, errors.New("test storage: injected write failure")
	}
	if len(writes) != 1 {
		return nil, errors.New("test storage: expected one write")
	}
	write := writes[0]
	if write.PermissionRead != 0 || write.PermissionWrite != 0 {
		return nil, errors.New("test storage: expected server-only permissions")
	}
	key := storageKey(write.Collection, write.Key)
	current, exists := s.objects[key]
	switch {
	case write.Version == "*" && exists:
		return nil, runtime.ErrStorageRejectedVersion
	case write.Version != "*" && (!exists || current.GetVersion() != write.Version):
		return nil, runtime.ErrStorageRejectedVersion
	}

	s.version++
	version := fmt.Sprintf("v%d", s.version)
	s.objects[key] = &api.StorageObject{
		Collection:      write.Collection,
		Key:             write.Key,
		UserId:          testSystemOwnerID,
		Value:           write.Value,
		Version:         version,
		PermissionRead:  0,
		PermissionWrite: 0,
	}
	return []*api.StorageObjectAck{
		{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     testSystemOwnerID,
			Version:    version,
		},
	}, nil
}

func (s *memoryStorage) StorageDelete(
	_ context.Context,
	deletes []*runtime.StorageDelete,
) error {
	if s.deleteErr != nil {
		return s.deleteErr
	}
	if len(deletes) != 1 {
		return errors.New("test storage: expected one delete")
	}
	deletion := deletes[0]
	key := storageKey(deletion.Collection, deletion.Key)
	current, exists := s.objects[key]
	if !exists || current.GetVersion() != deletion.Version {
		return runtime.ErrStorageRejectedVersion
	}
	delete(s.objects, key)
	return nil
}

func storageKey(collection, key string) string {
	return collection + "\x00" + key
}

type recordingResources struct {
	provisioned            Provisioned
	provisions             []handoff.AllocationRequest
	resolutions            []nakamalease.Lease
	releases               []nakamalease.Lease
	events                 []string
	provisionErr           error
	provisionCheck         func(handoff.AllocationRequest, time.Time) error
	resolveErr             error
	releaseErr             error
	stagedOnProvisionError bool
	releaseCheck           func(nakamalease.Lease) error
	releaseContextCheck    func(context.Context) error
}

func (r *recordingResources) Provision(
	_ context.Context,
	request handoff.AllocationRequest,
	expiresAt time.Time,
) (Provisioned, error) {
	r.provisions = append(r.provisions, request)
	r.events = append(r.events, "provision:"+request.AttemptID)
	if r.provisionCheck != nil {
		if err := r.provisionCheck(request, expiresAt); err != nil {
			return Provisioned{}, err
		}
	}
	if r.provisionErr != nil {
		if r.stagedOnProvisionError {
			return r.provisioned, r.provisionErr
		}
		return Provisioned{}, r.provisionErr
	}
	return r.provisioned, nil
}

func (r *recordingResources) Resolve(
	_ context.Context,
	lease nakamalease.Lease,
) (handoff.Allocation, error) {
	r.resolutions = append(r.resolutions, lease)
	r.events = append(r.events, "resolve:"+lease.AttemptID)
	if r.resolveErr != nil {
		return handoff.Allocation{}, r.resolveErr
	}
	return r.provisioned.Allocation, nil
}

func (r *recordingResources) Release(
	ctx context.Context,
	lease nakamalease.Lease,
) error {
	r.releases = append(r.releases, lease)
	r.events = append(r.events, "release:"+lease.AttemptID)
	if r.releaseContextCheck != nil {
		if err := r.releaseContextCheck(ctx); err != nil {
			return err
		}
	}
	if r.releaseCheck != nil {
		if err := r.releaseCheck(lease); err != nil {
			return err
		}
	}
	return r.releaseErr
}

func validAllocation() handoff.Allocation {
	return handoff.Allocation{
		ID:              "gameserver-17",
		ServerName:      "zone-17.edge.example",
		Port:            8443,
		Observer:        sim.EntityID(42),
		AdmissionSecret: bytes.Repeat([]byte{0x42}, 32),
		LeaseExpiresAt:  testNow.Add(time.Minute),
	}
}

func validRequest() handoff.AllocationRequest {
	return handoff.AllocationRequest{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
	}
}

func newLeaseStore(t *testing.T, storage *memoryStorage) *nakamalease.Store {
	t.Helper()
	store, err := nakamalease.NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	return store
}

func TestNewCoordinatorRejectsMissingDependenciesAndUnsafeLeaseDurations(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{}

	for _, test := range []struct {
		name      string
		resources GameServerResources
		store     *nakamalease.Store
		leaseTTL  time.Duration
	}{
		{
			name:     "missing resources",
			store:    store,
			leaseTTL: time.Minute,
		},
		{
			name:      "missing lease store",
			resources: resources,
			leaseTTL:  time.Minute,
		},
		{
			name:      "subsecond lease",
			resources: resources,
			store:     store,
			leaseTTL:  time.Second - time.Nanosecond,
		},
		{
			name:      "lease beyond ceiling",
			resources: resources,
			store:     store,
			leaseTTL:  MaxLeaseTTL + time.Nanosecond,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			coordinator, err := NewCoordinator(
				test.resources,
				test.store,
				Config{LeaseTTL: test.leaseTTL},
			)
			if err == nil {
				t.Fatalf("NewCoordinator returned %+v, nil error; want refusal", coordinator)
			}
			if coordinator != nil {
				t.Fatalf("refused coordinator = %+v, want nil", coordinator)
			}
		})
	}
}

func TestAllocateReturnsOnlyAfterTheAttemptLeaseIsDurable(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	if !reflect.DeepEqual(got, validAllocation()) {
		t.Fatalf("allocated resource = %+v, want %+v", got, validAllocation())
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load durable allocation lease: %v", err)
	}
	wantLease := nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		AllocationID:  "gameserver-17",
		Observer:      sim.EntityID(42),
		SecretRef:     "zone-admission-gameserver-17",
		ExpiresAt:     testNow.Add(time.Minute),
	}
	if record.Lease != wantLease {
		t.Fatalf("durable allocation lease = %+v, want %+v", record.Lease, wantLease)
	}
	for _, object := range storage.objects {
		if bytes.Contains(
			[]byte(object.GetValue()),
			resources.provisioned.Allocation.AdmissionSecret,
		) {
			t.Fatal("durable allocation lease persisted raw admission-secret bytes")
		}
	}
	if len(resources.provisions) != 1 || resources.provisions[0] != validRequest() {
		t.Fatalf("resource provisions = %+v, want one exact attempt", resources.provisions)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("released successful allocation = %+v, want none", resources.releases)
	}
}

func TestAllocatePersistsARecoverableIntentBeforeProvisioning(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	resources.provisionCheck = func(
		request handoff.AllocationRequest,
		expiresAt time.Time,
	) error {
		durable, err := store.Load(
			context.Background(),
			request.UserID,
			request.ReservationID,
		)
		switch {
		case err != nil:
			return fmt.Errorf("load staging intent before provision: %w", err)
		case durable.State(testNow) != nakamalease.StateStaging:
			return fmt.Errorf(
				"pre-provision state = %q, want %q",
				durable.State(testNow),
				nakamalease.StateStaging,
			)
		case durable.Lease.AttemptID != request.AttemptID ||
			!durable.Lease.ExpiresAt.Equal(expiresAt):
			return fmt.Errorf(
				"pre-provision intent = %+v, want exact attempt and expiry",
				durable.Lease,
			)
		case durable.Lease.AllocationID != "" ||
			durable.Lease.Observer != 0 ||
			durable.Lease.SecretRef != "":
			return fmt.Errorf(
				"pre-provision intent contains resource material: %+v",
				durable.Lease,
			)
		default:
			return nil
		}
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
}

func TestAllocateRecoversAStagingIntentAfterProcessRestart(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	staging := nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		ExpiresAt:     testNow.Add(time.Minute),
		Staging:       true,
	}
	before, err := store.Create(context.Background(), staging)
	if err != nil {
		t.Fatalf("create crash-surviving staging intent: %v", err)
	}
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("recovered Allocate returned an error: %v", err)
	}
	if !reflect.DeepEqual(got, validAllocation()) {
		t.Fatalf("recovered allocation = %+v, want %+v", got, validAllocation())
	}
	after, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	)
	if err != nil {
		t.Fatalf("load finalized recovered intent: %v", err)
	}
	if after.Version == before.Version ||
		after.Lease.Staging ||
		after.Lease.AllocationID != validAllocation().ID {
		t.Fatalf(
			"recovered durable lease = %+v, want finalized newer record",
			after,
		)
	}
	if len(resources.provisions) != 1 {
		t.Fatalf(
			"recovered intent provisions = %d, want one idempotent replay",
			len(resources.provisions),
		)
	}
}

func TestAllocateReplayResolvesTheDurableAttemptWithoutProvisioningAgain(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	first, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	before, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	replayed, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("replayed Allocate returned an error: %v", err)
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load replayed allocation lease: %v", err)
	}

	if !reflect.DeepEqual(replayed, first) {
		t.Fatalf("replayed allocation = %+v, want original %+v", replayed, first)
	}
	if before != after {
		t.Fatalf("replay changed durable lease from %+v to %+v", before, after)
	}
	if len(resources.provisions) != 1 {
		t.Fatalf("resource provisions = %d, want one", len(resources.provisions))
	}
	if len(resources.resolutions) != 1 ||
		resources.resolutions[0] != before.Lease {
		t.Fatalf(
			"resource resolutions = %+v, want durable lease %+v",
			resources.resolutions,
			before.Lease,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("released replayed allocation = %+v, want none", resources.releases)
	}
}

func TestAllocateReplayCannotResolveAnAttemptWhoseReleaseHasBegun(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	if _, err := store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	); err != nil {
		t.Fatalf("BeginRelease returned an error: %v", err)
	}
	resources.events = nil
	resources.resolutions = nil

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, nakamalease.ErrReleasing) {
		t.Fatalf("replay during release error = %v, want ErrReleasing", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("replay during release returned %+v, want zero allocation", got)
	}
	if len(resources.events) != 0 || len(resources.resolutions) != 0 {
		t.Fatalf("replay during release touched resources: %v", resources.events)
	}
}

func TestAllocateReplayRefusesResourceMaterialOutsideTheDurableLease(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	resources.provisioned.Allocation.ID = "gameserver-other"

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, ErrInvalidResource) {
		t.Fatalf("replay with mismatched resource error = %v, want ErrInvalidResource", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("mismatched replay returned %+v, want zero allocation", got)
	}
	if len(resources.provisions) != 1 {
		t.Fatalf("mismatched replay provisions = %d, want original one", len(resources.provisions))
	}
}

func TestAllocateNewAttemptReleasesAndReplacesTheUnclaimedLease(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	previous, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}

	nextAllocation := validAllocation()
	nextAllocation.ID = "gameserver-18"
	nextAllocation.ServerName = "zone-18.edge.example"
	nextAllocation.Observer = sim.EntityID(84)
	nextAllocation.AdmissionSecret = bytes.Repeat([]byte{0x84}, 32)
	resources.provisioned = Provisioned{
		Allocation: nextAllocation,
		SecretRef:  "zone-admission-gameserver-18",
	}
	resources.events = nil
	resources.releaseCheck = func(released nakamalease.Lease) error {
		durable, loadErr := store.Load(
			context.Background(),
			testUserID,
			testReservationID,
		)
		switch {
		case loadErr != nil:
			return fmt.Errorf("load replacement barrier: %w", loadErr)
		case durable.State(testNow) != nakamalease.StateReleasing:
			return fmt.Errorf(
				"replacement barrier state = %q, want %q",
				durable.State(testNow),
				nakamalease.StateReleasing,
			)
		case released != durable.Lease:
			return fmt.Errorf(
				"released replacement lease = %+v, want durable %+v",
				released,
				durable.Lease,
			)
		default:
			return nil
		}
	}
	nextRequest := validRequest()
	nextRequest.AttemptID = "attempt-8"

	got, err := coordinator.Allocate(context.Background(), nextRequest)
	if err != nil {
		t.Fatalf("replacement Allocate returned an error: %v", err)
	}
	if !reflect.DeepEqual(got, nextAllocation) {
		t.Fatalf("replacement allocation = %+v, want %+v", got, nextAllocation)
	}
	if !reflect.DeepEqual(
		resources.events,
		[]string{"release:attempt-7", "provision:attempt-8"},
	) {
		t.Fatalf(
			"replacement resource order = %v, want old release before new provision",
			resources.events,
		)
	}
	releasingPrevious := previous.Lease
	releasingPrevious.Releasing = true
	if len(resources.releases) != 1 || resources.releases[0] != releasingPrevious {
		t.Fatalf(
			"released resources = %+v, want old lease %+v",
			resources.releases,
			releasingPrevious,
		)
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load replacement allocation lease: %v", err)
	}
	if current.Version == previous.Version {
		t.Fatalf("replacement kept lease version %q", current.Version)
	}
	if current.Lease.AttemptID != "attempt-8" ||
		current.Lease.AllocationID != "gameserver-18" ||
		current.Lease.Observer != sim.EntityID(84) ||
		current.Lease.SecretRef != "zone-admission-gameserver-18" {
		t.Fatalf("replacement durable lease = %+v, want attempt-8 resource", current.Lease)
	}
}

func TestAllocateDetachesSupersededResourceCleanupFromCallerCancellation(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	resources.releaseContextCheck = func(cleanupCtx context.Context) error {
		cancel()
		return cleanupCtx.Err()
	}
	next := validRequest()
	next.AttemptID = "attempt-8"
	resources.provisioned.Allocation.ID = "gameserver-18"
	resources.provisioned.SecretRef = "zone-admission-gameserver-18"

	if _, err := coordinator.Allocate(ctx, next); errors.Is(err, ErrReconciliation) {
		t.Fatalf("caller cancellation prevented durable resource cleanup: %v", err)
	}
	if len(resources.releases) != 1 ||
		resources.releases[0].AttemptID != testAttemptID ||
		!resources.releases[0].Releasing {
		t.Fatalf(
			"detached cleanup releases = %+v, want exact releasing predecessor",
			resources.releases,
		)
	}
}

func TestAllocateNewAttemptCannotTouchAClaimedLease(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	if _, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		testNow.Add(30*time.Second),
	); err != nil {
		t.Fatalf("claim first allocation lease: %v", err)
	}
	resources.events = nil
	resources.releases = nil
	resources.provisions = nil
	nextRequest := validRequest()
	nextRequest.AttemptID = "attempt-8"

	got, err := coordinator.Allocate(context.Background(), nextRequest)
	if !errors.Is(err, nakamalease.ErrClaimed) {
		t.Fatalf("replacement of claimed lease error = %v, want ErrClaimed", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("replacement of claimed lease = %+v, want zero allocation", got)
	}
	if len(resources.events) != 0 {
		t.Fatalf("claimed replacement touched resources: %v", resources.events)
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load claimed allocation lease after refusal: %v", err)
	}
	if after.Lease.AttemptID != testAttemptID ||
		after.Lease.ClaimedAt.IsZero() {
		t.Fatalf("claimed lease changed after refusal: %+v", after.Lease)
	}
}

func TestAllocateReplacementKeepsTheReleasingLeaseWhenResourceReleaseFails(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	before, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	resources.events = nil
	resources.provisions = nil
	resources.releases = nil
	resources.releaseErr = errors.New(
		"resource backend exposed " + testReservationID + " and " + testAttemptID,
	)
	nextRequest := validRequest()
	nextRequest.AttemptID = "attempt-8"

	got, allocateErr := coordinator.Allocate(context.Background(), nextRequest)
	if !errors.Is(allocateErr, ErrReconciliation) {
		t.Fatalf(
			"replacement cleanup error = %v, want ErrReconciliation",
			allocateErr,
		)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("replacement cleanup returned %+v, want zero allocation", got)
	}
	if !reflect.DeepEqual(resources.events, []string{"release:attempt-7"}) {
		t.Fatalf("replacement cleanup events = %v, want only old release", resources.events)
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load lease after failed resource release: %v", err)
	}
	want := before
	want.Lease.Releasing = true
	if after.Lease != want.Lease {
		t.Fatalf(
			"failed resource release left lease %+v, want releasing lease %+v",
			after.Lease,
			want.Lease,
		)
	}
	if after.Version == before.Version {
		t.Fatalf("failed resource release did not durably advance the lease version")
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(allocateErr.Error(), leaked) {
			t.Fatalf("replacement cleanup leaked %q: %v", leaked, allocateErr)
		}
	}
}

func TestAllocateLeaseWriteFailureReleasesOnlyTheStagedResource(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeErr = errors.New(
		"storage exposed " + testReservationID + " and zone-admission-gameserver-17",
	)
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, nakamalease.ErrStorage) {
		t.Fatalf("Allocate storage failure = %v, want ErrStorage", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("Allocate storage failure returned %+v, want zero allocation", got)
	}
	if len(resources.events) != 0 || len(resources.releases) != 0 {
		t.Fatalf(
			"failed staging write touched external resources: events=%v releases=%+v",
			resources.events,
			resources.releases,
		)
	}
	for _, leaked := range []string{
		testReservationID,
		"zone-admission-gameserver-17",
	} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("storage failure leaked %q: %v", leaked, err)
		}
	}
}

func TestAllocateCleansAStagedResourceAfterTheRequestIsCanceled(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeErr = errors.New("storage unavailable")
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		releaseContextCheck: func(ctx context.Context) error {
			return ctx.Err()
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	got, err := coordinator.Allocate(ctx, validRequest())
	if !errors.Is(err, nakamalease.ErrStorage) {
		t.Fatalf("Allocate canceled storage failure = %v, want ErrStorage", err)
	}
	if errors.Is(err, ErrReconciliation) {
		t.Fatalf("canceled request prevented staged cleanup: %v", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("canceled Allocate returned %+v, want zero allocation", got)
	}
	if len(resources.events) != 0 {
		t.Fatalf(
			"canceled staging write touched external resources: %v",
			resources.events,
		)
	}
}

func TestAllocateProvisionFailurePreservesStatusWithoutBackendText(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: status.Error(
			codes.Unavailable,
			"resource backend exposed "+testReservationID+" and "+testAttemptID,
		),
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("provision failure status = %s, want Unavailable", status.Code(err))
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("provision failure returned %+v, want zero allocation", got)
	}
	if len(resources.releases) != 1 ||
		resources.releases[0].AttemptID != testAttemptID ||
		!resources.releases[0].Staging ||
		!resources.releases[0].Releasing {
		t.Fatalf(
			"provision failure did not reconcile durable attempt: %+v",
			resources.releases,
		)
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("provision failure leaked %q: %v", leaked, err)
		}
	}
}

func TestAllocateProvisionFailureReclaimsTheReportedStagedResource(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionErr: status.Error(
			codes.Unavailable,
			"resource backend exposed "+testReservationID+" and "+testAttemptID,
		),
		stagedOnProvisionError: true,
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("staged provision failure status = %s, want Unavailable", status.Code(err))
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("staged provision failure returned %+v, want zero allocation", got)
	}
	if !reflect.DeepEqual(
		resources.events,
		[]string{"provision:attempt-7", "release:attempt-7"},
	) {
		t.Fatalf(
			"staged provision failure resource order = %v, want cleanup",
			resources.events,
		)
	}
	if len(resources.releases) != 1 ||
		resources.releases[0].AllocationID != "gameserver-17" ||
		resources.releases[0].SecretRef != "zone-admission-gameserver-17" {
		t.Fatalf(
			"staged provision failure released %+v, want exact staged resource",
			resources.releases,
		)
	}
}

func TestAllocateProvisionFailureReclaimsTheReportedCanonicalExpiry(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	allocation := validAllocation()
	allocation.LeaseExpiresAt = testNow.Add(59 * time.Second)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: allocation,
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionErr:           status.Error(codes.Unavailable, "backend detail"),
		stagedOnProvisionError: true,
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); status.Code(err) != codes.Unavailable {
		t.Fatalf(
			"staged provision failure status = %s, want Unavailable",
			status.Code(err),
		)
	}
	if len(resources.releases) != 1 ||
		!resources.releases[0].ExpiresAt.Equal(allocation.LeaseExpiresAt) {
		t.Fatalf(
			"staged cleanup expiry = %+v, want canonical resource expiry %s",
			resources.releases,
			allocation.LeaseExpiresAt,
		)
	}
}

func TestAllocatePersistsTheCanonicalExpiryReturnedByAnIdempotentResource(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	allocation := validAllocation()
	allocation.LeaseExpiresAt = testNow.Add(59 * time.Second)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: allocation,
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	if !got.LeaseExpiresAt.Equal(allocation.LeaseExpiresAt) {
		t.Fatalf(
			"returned expiry = %s, want canonical resource expiry %s",
			got.LeaseExpiresAt,
			allocation.LeaseExpiresAt,
		)
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load canonical allocation lease: %v", err)
	}
	if !record.Lease.ExpiresAt.Equal(allocation.LeaseExpiresAt) {
		t.Fatalf(
			"durable expiry = %s, want canonical resource expiry %s",
			record.Lease.ExpiresAt,
			allocation.LeaseExpiresAt,
		)
	}
}

func TestAllocateRefusesAProvisionedResourceWithADifferentLeaseExpiry(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	allocation := validAllocation()
	allocation.LeaseExpiresAt = testNow.Add(2 * time.Minute)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: allocation,
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, ErrInvalidResource) {
		t.Fatalf("mismatched provision expiry error = %v, want ErrInvalidResource", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("mismatched provision returned %+v, want zero allocation", got)
	}
	if !reflect.DeepEqual(
		resources.events,
		[]string{"provision:attempt-7", "release:attempt-7"},
	) {
		t.Fatalf("mismatched provision resource events = %v", resources.events)
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("mismatched provision wrote a lease: %v", err)
	}
}

func TestAllocateFailsClosedWhenStagedCleanupCannotBeReconciled(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeErrAt = 2
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		releaseErr: errors.New(
			"resource backend exposed " + testReservationID + " and attempt-7",
		),
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, ErrReconciliation) {
		t.Fatalf("ambiguous cleanup error = %v, want ErrReconciliation", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("ambiguous cleanup returned %+v, want zero allocation", got)
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("ambiguous cleanup leaked %q: %v", leaked, err)
		}
	}
}

func TestReconcileExpiredReclaimsTheExactNoShowAllocation(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	resources.releases = nil
	resources.events = nil
	now = testNow.Add(time.Minute)

	if err := coordinator.ReconcileExpired(context.Background()); err != nil {
		t.Fatalf("ReconcileExpired returned an error: %v", err)
	}
	if len(resources.releases) != 1 {
		t.Fatalf(
			"expired allocation releases = %+v, want one",
			resources.releases,
		)
	}
	released := resources.releases[0]
	if released.UserID != "" ||
		released.ReservationID != "" ||
		released.AttemptID != testAttemptID ||
		released.AllocationID != validAllocation().ID ||
		released.SecretRef != "zone-admission-gameserver-17" ||
		!released.Releasing {
		t.Fatalf(
			"expired cleanup lease = %+v, want exact persisted resource without raw identity",
			released,
		)
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("expired lease after reconciliation = %v, want ErrNotFound", err)
	}
}

func TestReconcileExpiredRecoversACrashedPreProvisionAttempt(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow.Add(time.Minute)
	staging := nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		ExpiresAt:     testNow.Add(time.Minute),
		Staging:       true,
	}
	if _, err := store.Create(context.Background(), staging); err != nil {
		t.Fatalf("create crash-surviving staging intent: %v", err)
	}
	resources := &recordingResources{}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	if err := coordinator.ReconcileExpired(context.Background()); err != nil {
		t.Fatalf("ReconcileExpired returned an error: %v", err)
	}
	if len(resources.releases) != 1 ||
		resources.releases[0].AttemptID != testAttemptID ||
		!resources.releases[0].Staging ||
		!resources.releases[0].Releasing ||
		resources.releases[0].AllocationID != "" {
		t.Fatalf(
			"crashed-attempt cleanup = %+v, want discoverable staging attempt",
			resources.releases,
		)
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("staging lease after reconciliation = %v, want ErrNotFound", err)
	}
}

func TestReconcileExpiredCannotReclaimAClaimedAllocation(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return now },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	current, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	)
	if err != nil {
		t.Fatalf("load allocation lease: %v", err)
	}
	claimed, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		testNow.Add(30*time.Second),
	)
	if err != nil {
		t.Fatalf("claim allocation lease: %v", err)
	}
	resources.releases = nil
	now = testNow.Add(time.Minute)

	if err := coordinator.ReconcileExpired(context.Background()); err != nil {
		t.Fatalf("ReconcileExpired returned an error: %v", err)
	}
	if len(resources.releases) != 0 {
		t.Fatalf(
			"expiry reconciliation released claimed resources: %+v",
			resources.releases,
		)
	}
	after, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	)
	if err != nil {
		t.Fatalf("load claimed lease after reconciliation: %v", err)
	}
	if after != claimed {
		t.Fatalf(
			"expiry reconciliation changed claimed lease from %+v to %+v",
			claimed,
			after,
		)
	}
}

func TestReleaseMarksTheLeaseBeforeExactResourceCleanup(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease: %v", err)
	}
	resources.events = nil
	resources.releases = nil
	resources.releaseCheck = func(released nakamalease.Lease) error {
		durable, loadErr := store.Load(
			context.Background(),
			testUserID,
			testReservationID,
		)
		switch {
		case loadErr != nil:
			return fmt.Errorf("lease was not durable during resource cleanup: %w", loadErr)
		case durable.Version == current.Version:
			return fmt.Errorf(
				"durable lease version during cleanup = %q, want newer than %q",
				durable.Version,
				current.Version,
			)
		case !durable.Lease.Releasing:
			return fmt.Errorf(
				"durable lease during cleanup = %+v, want releasing barrier",
				durable,
			)
		case released != durable.Lease:
			return fmt.Errorf(
				"released lease = %+v, want exact durable lease %+v",
				released,
				durable.Lease,
			)
		default:
			return nil
		}
	}

	if err := coordinator.Release(context.Background(), validRequest()); err != nil {
		t.Fatalf("Release returned an error: %v", err)
	}
	if !reflect.DeepEqual(resources.events, []string{"release:attempt-7"}) {
		t.Fatalf("release resource events = %v, want exact current attempt", resources.events)
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("lease after successful release = %v, want ErrNotFound", err)
	}
}

func TestReleaseResourceFailureKeepsTheReleasingLeaseAndSanitizesTheError(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	before, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease: %v", err)
	}
	resources.releaseErr = errors.New(
		"resource backend exposed " + testReservationID + " and " + testAttemptID,
	)
	resources.events = nil
	resources.releases = nil

	releaseErr := coordinator.Release(context.Background(), validRequest())
	if !errors.Is(releaseErr, ErrReconciliation) {
		t.Fatalf("resource release error = %v, want ErrReconciliation", releaseErr)
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(releaseErr.Error(), leaked) {
			t.Fatalf("resource release leaked %q: %v", leaked, releaseErr)
		}
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease after failed release: %v", err)
	}
	want := before.Lease
	want.Releasing = true
	if after.Lease != want || after.Version == before.Version {
		t.Fatalf(
			"failed resource release lease = %+v, want releasing %+v at a newer version",
			after,
			want,
		)
	}
}

func TestReleaseRetriesCleanupFromTheDurableBarrier(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	resources.releaseErr = errors.New("resource backend unavailable")
	if err := coordinator.Release(
		context.Background(),
		validRequest(),
	); !errors.Is(err, ErrReconciliation) {
		t.Fatalf("first Release error = %v, want ErrReconciliation", err)
	}
	resources.releaseErr = nil

	if err := coordinator.Release(context.Background(), validRequest()); err != nil {
		t.Fatalf("retried Release returned an error: %v", err)
	}
	if len(resources.releases) != 2 ||
		resources.releases[0] != resources.releases[1] ||
		!resources.releases[1].Releasing {
		t.Fatalf(
			"retried releases = %+v, want the exact releasing resource twice",
			resources.releases,
		)
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("lease after retried release = %v, want ErrNotFound", err)
	}
}

func TestReleaseStaleAttemptCannotTouchTheCurrentResource(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	before, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease: %v", err)
	}
	resources.events = nil
	resources.releases = nil
	stale := validRequest()
	stale.AttemptID = "attempt-older"

	if err := coordinator.Release(context.Background(), stale); err != nil {
		t.Fatalf("stale Release error = %v, want successful no-op", err)
	}
	if len(resources.events) != 0 {
		t.Fatalf("stale Release touched resources: %v", resources.events)
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease after stale release: %v", err)
	}
	if after != before {
		t.Fatalf("stale Release changed lease from %+v to %+v", before, after)
	}
}

func TestReleaseClaimedAttemptCannotTouchThePlayerResource(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load allocation lease: %v", err)
	}
	claimed, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		testNow.Add(30*time.Second),
	)
	if err != nil {
		t.Fatalf("claim allocation lease: %v", err)
	}
	resources.events = nil
	resources.releases = nil

	if err := coordinator.Release(
		context.Background(),
		validRequest(),
	); !errors.Is(err, nakamalease.ErrClaimed) {
		t.Fatalf("claimed Release error = %v, want ErrClaimed", err)
	}
	if len(resources.events) != 0 {
		t.Fatalf("claimed Release touched resources: %v", resources.events)
	}
	after, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load claimed allocation lease after release refusal: %v", err)
	}
	if after != claimed {
		t.Fatalf("claimed Release changed lease from %+v to %+v", claimed, after)
	}
}

func TestReleaseReplayIsIdempotentAfterTheLeaseIsGone(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	if err := coordinator.Release(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Release returned an error: %v", err)
	}
	resources.events = nil
	resources.releases = nil

	if err := coordinator.Release(context.Background(), validRequest()); err != nil {
		t.Fatalf("replayed Release returned an error: %v", err)
	}
	if len(resources.events) != 0 {
		t.Fatalf("replayed Release touched resources: %v", resources.events)
	}
}

var _ handoff.Allocator = (*Coordinator)(nil)
