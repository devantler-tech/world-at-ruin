package handoffalloc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
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
	mu                    sync.Mutex
	objects               map[string]*api.StorageObject
	version               int
	readErr               error
	writeErr              error
	writeErrAt            int
	writeAfterCommitErr   error
	writeAfterCommitErrAt int
	deleteErr             error
	respectContext        bool
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
	s.mu.Lock()
	defer s.mu.Unlock()
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
	ctx context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.respectContext && ctx.Err() != nil {
		return nil, ctx.Err()
	}
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
	ctx context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.respectContext && ctx.Err() != nil {
		return nil, ctx.Err()
	}
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
	if s.writeAfterCommitErr != nil &&
		(s.writeAfterCommitErrAt == 0 || s.version == s.writeAfterCommitErrAt) {
		err := s.writeAfterCommitErr
		s.writeAfterCommitErr = nil
		return nil, err
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
	ctx context.Context,
	deletes []*runtime.StorageDelete,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.respectContext && ctx.Err() != nil {
		return ctx.Err()
	}
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
	reconciliations        []handoff.AllocationRequest
	resolutions            []nakamalease.Lease
	releases               []nakamalease.Lease
	events                 []string
	provisionErr           error
	reconcileErr           error
	provisionCheck         func(handoff.AllocationRequest, time.Time) error
	resolveErr             error
	releaseErr             error
	stagedOnProvisionError bool
	releaseCheck           func(nakamalease.Lease) error
	releaseContextCheck    func(context.Context) error
}

type fixedVerifier string

func (v fixedVerifier) VerifySession(context.Context, string) (string, error) {
	return string(v), nil
}

type concurrentResources struct {
	provisioned      Provisioned
	provisionStarted chan struct{}
	allowProvision   chan struct{}
	provisionDone    chan struct{}
	reconcileStarted chan struct{}
	mu               sync.Mutex
	provisionCalls   int
	reconcileCalls   int
}

type overlappingReconcileResources struct {
	provisioned       Provisioned
	reconcilesReady   chan struct{}
	allowReconciles   chan struct{}
	mu                sync.Mutex
	reconcileRequests []handoff.AllocationRequest
	releases          []nakamalease.Lease
}

type adopterWinsResources struct {
	provisioned      Provisioned
	provisionStarted chan struct{}
	allowProvision   chan struct{}
	provisionErr     error
}

func newAdopterWinsResources() *adopterWinsResources {
	return &adopterWinsResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionStarted: make(chan struct{}),
		allowProvision:   make(chan struct{}),
	}
}

func (r *adopterWinsResources) Provision(
	context.Context,
	handoff.AllocationRequest,
	time.Time,
) (Provisioned, error) {
	close(r.provisionStarted)
	<-r.allowProvision
	return r.provisioned, r.provisionErr
}

func (r *adopterWinsResources) Reconcile(
	context.Context,
	handoff.AllocationRequest,
	time.Time,
) (Provisioned, error) {
	return r.provisioned, nil
}

func (r *adopterWinsResources) Resolve(
	context.Context,
	nakamalease.Lease,
) (handoff.Allocation, error) {
	return r.provisioned.Allocation, nil
}

func (r *adopterWinsResources) Release(context.Context, nakamalease.Lease) error {
	return errors.New("test resources: shared winner was released")
}

func newOverlappingReconcileResources() *overlappingReconcileResources {
	return &overlappingReconcileResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		reconcilesReady: make(chan struct{}),
		allowReconciles: make(chan struct{}),
	}
}

func (r *overlappingReconcileResources) Provision(
	context.Context,
	handoff.AllocationRequest,
	time.Time,
) (Provisioned, error) {
	return Provisioned{}, errors.New("test resources: unexpected redispatch")
}

func (r *overlappingReconcileResources) Reconcile(
	_ context.Context,
	request handoff.AllocationRequest,
	_ time.Time,
) (Provisioned, error) {
	r.mu.Lock()
	r.reconcileRequests = append(r.reconcileRequests, request)
	if len(r.reconcileRequests) == 2 {
		close(r.reconcilesReady)
	}
	r.mu.Unlock()
	<-r.allowReconciles
	return r.provisioned, nil
}

func (r *overlappingReconcileResources) Resolve(
	context.Context,
	nakamalease.Lease,
) (handoff.Allocation, error) {
	return r.provisioned.Allocation, nil
}

func (r *overlappingReconcileResources) Release(
	_ context.Context,
	lease nakamalease.Lease,
) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.releases = append(r.releases, lease)
	return nil
}

func newConcurrentResources() *concurrentResources {
	return &concurrentResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionStarted: make(chan struct{}),
		allowProvision:   make(chan struct{}),
		provisionDone:    make(chan struct{}),
		reconcileStarted: make(chan struct{}),
	}
}

func (r *concurrentResources) Provision(
	_ context.Context,
	_ handoff.AllocationRequest,
	_ time.Time,
) (Provisioned, error) {
	r.mu.Lock()
	r.provisionCalls++
	r.mu.Unlock()
	close(r.provisionStarted)
	<-r.allowProvision
	close(r.provisionDone)
	return r.provisioned, nil
}

func (r *concurrentResources) Reconcile(
	_ context.Context,
	_ handoff.AllocationRequest,
	_ time.Time,
) (Provisioned, error) {
	r.mu.Lock()
	r.reconcileCalls++
	r.mu.Unlock()
	close(r.reconcileStarted)
	<-r.provisionDone
	return r.provisioned, nil
}

func (r *concurrentResources) Resolve(
	_ context.Context,
	_ nakamalease.Lease,
) (handoff.Allocation, error) {
	return r.provisioned.Allocation, nil
}

func (r *concurrentResources) Release(
	_ context.Context,
	_ nakamalease.Lease,
) error {
	return nil
}

func (r *concurrentResources) calls() (int, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.provisionCalls, r.reconcileCalls
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

func (r *recordingResources) Reconcile(
	_ context.Context,
	request handoff.AllocationRequest,
	_ time.Time,
) (Provisioned, error) {
	r.reconciliations = append(r.reconciliations, request)
	r.events = append(r.events, "reconcile:"+request.AttemptID)
	return r.provisioned, r.reconcileErr
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

func retainedAllocation(allocation handoff.Allocation) handoff.Allocation {
	allocation.RetainOnFailure = true
	return allocation
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
	if !reflect.DeepEqual(got, retainedAllocation(validAllocation())) {
		t.Fatalf("allocated resource = %+v, want retained %+v", got, validAllocation())
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

func TestAllocatePersistsDispatchBarrierBeforeProvisioning(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	sawDispatched := false
	sawDispatchID := false
	resources := &recordingResources{}
	resources.provisionCheck = func(
		_ handoff.AllocationRequest,
		_ time.Time,
	) error {
		if len(storage.objects) != 1 {
			return fmt.Errorf("stored lease count = %d, want 1", len(storage.objects))
		}
		for _, object := range storage.objects {
			var document map[string]any
			if err := json.Unmarshal([]byte(object.GetValue()), &document); err != nil {
				return fmt.Errorf("decode pre-dispatch lease: %w", err)
			}
			sawDispatched, _ = document["dispatched"].(bool)
			dispatchID, _ := document["dispatch_id"].(string)
			sawDispatchID = dispatchID != ""
		}
		return status.Error(codes.Unavailable, "ambiguous allocation result")
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
		t.Fatalf("ambiguous dispatch status = %s, want Unavailable", status.Code(err))
	}
	if !sawDispatched || !sawDispatchID {
		t.Fatal("external dispatch ran before its durable identified dispatch barrier")
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load quarantined dispatch: %v", err)
	}
	if !record.Lease.Staging {
		t.Fatalf("quarantined lease = %+v, want staging", record.Lease)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("ambiguous dispatch released resources: %+v", resources.releases)
	}
}

func TestAllocateProvisionsAfterACommittedDispatchBarrierLosesItsAcknowledgement(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeAfterCommitErrAt = 2
	storage.writeAfterCommitErr = errors.New("lost dispatch acknowledgement")
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
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("Allocate after lost barrier acknowledgement returned an error: %v", err)
	}
	if !reflect.DeepEqual(got, retainedAllocation(validAllocation())) || len(resources.provisions) != 1 {
		t.Fatalf(
			"lost-ack allocation = %+v with %d provisions, want one exact provision",
			got,
			len(resources.provisions),
		)
	}
}

func TestAllocateQuarantinesCanceledAndAmbiguousDispatchOutcomes(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
	}{
		{name: "canceled", err: context.Canceled},
		{name: "deadline exceeded", err: context.DeadlineExceeded},
		{name: "ambiguous backend failure", err: errors.New("unknown allocation outcome")},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := newMemoryStorage()
			store := newLeaseStore(t, storage)
			resources := &recordingResources{provisionErr: test.err}
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
			); err == nil {
				t.Fatal("ambiguous dispatch returned nil, want sanitized error")
			} else if errors.Is(test.err, context.Canceled) &&
				!errors.Is(err, context.Canceled) {
				t.Fatalf("canceled dispatch error = %v, want context.Canceled", err)
			} else if errors.Is(test.err, context.DeadlineExceeded) &&
				!errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("deadline dispatch error = %v, want context deadline", err)
			}
			record, err := store.Load(
				context.Background(),
				testUserID,
				testReservationID,
			)
			if err != nil {
				t.Fatalf("load dispatch quarantine: %v", err)
			}
			if !record.Lease.Staging || !record.Lease.Dispatched {
				t.Fatalf("dispatch quarantine = %+v, want dispatched staging", record.Lease)
			}
			if len(resources.releases) != 0 {
				t.Fatalf("ambiguous dispatch released resources: %+v", resources.releases)
			}
		})
	}
}

func TestServiceFailureCleanupPreservesAmbiguousDispatchQuarantine(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
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
	service, err := handoff.NewService(
		fixedVerifier(testUserID),
		coordinator,
		handoff.Config{
			ZoneDomain: "edge.example",
			Now:        func() time.Time { return testNow },
			NewAttemptID: func() (string, error) {
				return testAttemptID, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("handoff.NewService returned an error: %v", err)
	}

	if _, err := service.CreateHandoff(
		context.Background(),
		handoff.Request{
			Session:       "signed-session",
			ReservationID: testReservationID,
		},
	); status.Code(err) != codes.Unavailable {
		t.Fatalf("CreateHandoff status = %s, want Unavailable", status.Code(err))
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load outer-service dispatch quarantine: %v", err)
	}
	if !record.Lease.Staging ||
		!record.Lease.Dispatched ||
		record.Lease.Releasing {
		t.Fatalf(
			"outer-service dispatch quarantine = %+v, want dispatched staging",
			record.Lease,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("outer-service failure released ambiguous resources: %+v", resources.releases)
	}
}

func TestServiceRetryReconcilesTheQuarantinedAttemptWithoutRedispatch(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	attempts := []string{testAttemptID, "attempt-8"}
	service, err := handoff.NewService(
		fixedVerifier(testUserID),
		coordinator,
		handoff.Config{
			ZoneDomain: "edge.example",
			Now:        func() time.Time { return testNow },
			NewAttemptID: func() (string, error) {
				attempt := attempts[0]
				attempts = attempts[1:]
				return attempt, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("handoff.NewService returned an error: %v", err)
	}
	request := handoff.Request{
		Session:       "signed-session",
		ReservationID: testReservationID,
	}

	if _, err := service.CreateHandoff(context.Background(), request); status.Code(err) != codes.Unavailable {
		t.Fatalf("first CreateHandoff status = %s, want Unavailable", status.Code(err))
	}
	resources.provisionErr = nil
	resources.provisioned = Provisioned{
		Allocation: validAllocation(),
		SecretRef:  "zone-admission-gameserver-17",
	}
	handoffResult, err := service.CreateHandoff(context.Background(), request)
	if err != nil {
		t.Fatalf("retry CreateHandoff returned an error: %v", err)
	}
	if handoffResult.ServerName != validAllocation().ServerName {
		t.Fatalf("retry handoff = %+v, want reconciled allocation", handoffResult)
	}
	if len(resources.provisions) != 1 ||
		len(resources.reconciliations) != 1 ||
		resources.reconciliations[0].AttemptID != testAttemptID {
		t.Fatalf(
			"retry calls = provisions %+v/reconciliations %+v, want one dispatch then attempt-7 observation",
			resources.provisions,
			resources.reconciliations,
		)
	}
}

func TestServiceRetryRetainsAReconciledAttemptWhenLaterStageFails(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	attempts := []string{testAttemptID, "attempt-8"}
	service, err := handoff.NewService(
		fixedVerifier(testUserID),
		coordinator,
		handoff.Config{
			ZoneDomain: "edge.example",
			Now:        func() time.Time { return testNow },
			NewAttemptID: func() (string, error) {
				attempt := attempts[0]
				attempts = attempts[1:]
				return attempt, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("handoff.NewService returned an error: %v", err)
	}
	request := handoff.Request{
		Session:       "signed-session",
		ReservationID: testReservationID,
	}
	if _, err := service.CreateHandoff(context.Background(), request); status.Code(err) != codes.Unavailable {
		t.Fatalf("first CreateHandoff status = %s, want Unavailable", status.Code(err))
	}
	invalid := validAllocation()
	invalid.ServerName = "outside.example"
	resources.provisionErr = nil
	resources.provisioned = Provisioned{
		Allocation: invalid,
		SecretRef:  "zone-admission-gameserver-17",
	}

	if _, err := service.CreateHandoff(context.Background(), request); err == nil {
		t.Fatal("retry with an invalid reconciled endpoint returned nil, want an error")
	}
	if len(resources.releases) != 0 {
		t.Fatalf(
			"retry cleanup releases = %+v, want the reused allocation retained",
			resources.releases,
		)
	}
	record, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	)
	if err != nil {
		t.Fatalf("load retained reconciled attempt: %v", err)
	}
	if record.Lease.AttemptID != testAttemptID ||
		record.State(testNow) != nakamalease.StateUnclaimed {
		t.Fatalf("retained reconciled attempt = %+v, want unclaimed attempt-7", record.Lease)
	}
}

func TestServiceRetryReusesFinalizedAllocationWithoutRedispatch(t *testing.T) {
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
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	attempts := []string{testAttemptID, "attempt-8"}
	service, err := handoff.NewService(
		fixedVerifier(testUserID),
		coordinator,
		handoff.Config{
			ZoneDomain: "edge.example",
			Now:        func() time.Time { return testNow },
			NewAttemptID: func() (string, error) {
				attempt := attempts[0]
				attempts = attempts[1:]
				return attempt, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("handoff.NewService returned an error: %v", err)
	}
	request := handoff.Request{
		Session:       "signed-session",
		ReservationID: testReservationID,
	}
	if _, err := service.CreateHandoff(context.Background(), request); err != nil {
		t.Fatalf("first CreateHandoff returned an error: %v", err)
	}
	resources.events = nil
	resources.resolutions = nil

	got, err := service.CreateHandoff(context.Background(), request)
	if err != nil {
		t.Fatalf("transport retry returned an error: %v", err)
	}
	if got.ServerName != validAllocation().ServerName {
		t.Fatalf("transport retry handoff = %+v, want durable allocation", got)
	}
	if len(resources.provisions) != 1 ||
		len(resources.resolutions) != 1 ||
		resources.resolutions[0].AttemptID != testAttemptID {
		t.Fatalf(
			"transport retry calls = provisions %+v/resolutions %+v, want one dispatch then attempt-7 resolve",
			resources.provisions,
			resources.resolutions,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("transport retry released durable allocation: %+v", resources.releases)
	}
}

func TestOverlappingTransportRetriesRetainTheSharedDurableAllocation(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	staging, err := store.Create(context.Background(), nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		ExpiresAt:     testNow.Add(time.Minute),
		Staging:       true,
	})
	if err != nil {
		t.Fatalf("create staging lease: %v", err)
	}
	if _, dispatch, err := store.BeginDispatch(
		context.Background(),
		staging,
		testAttemptID,
	); err != nil || !dispatch {
		t.Fatalf("begin durable dispatch = %t, %v; want dispatch owner", dispatch, err)
	}
	resources := newOverlappingReconcileResources()
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	type result struct {
		allocation handoff.Allocation
		err        error
	}
	results := make(chan result, 2)
	for _, attemptID := range []string{"attempt-8", "attempt-9"} {
		request := validRequest()
		request.AttemptID = attemptID
		go func() {
			allocation, allocateErr := coordinator.Allocate(context.Background(), request)
			results <- result{allocation: allocation, err: allocateErr}
		}()
	}
	<-resources.reconcilesReady
	close(resources.allowReconciles)

	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatalf("overlapping transport retry returned an error: %v", got.err)
		}
		if got.allocation.ID != validAllocation().ID || !got.allocation.RetainOnFailure {
			t.Fatalf("overlapping retry allocation = %+v, want retained durable allocation", got.allocation)
		}
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load shared durable allocation: %v", err)
	}
	if record.Lease.AttemptID != testAttemptID ||
		record.State(testNow) != nakamalease.StateUnclaimed {
		t.Fatalf("shared durable allocation = %+v, want unclaimed attempt-7", record.Lease)
	}
	resources.mu.Lock()
	defer resources.mu.Unlock()
	if len(resources.reconcileRequests) != 2 {
		t.Fatalf("reconcile requests = %+v, want two observations", resources.reconcileRequests)
	}
	for _, request := range resources.reconcileRequests {
		if request.AttemptID != testAttemptID {
			t.Fatalf("reconcile request = %+v, want persisted attempt-7", request)
		}
	}
	if len(resources.releases) != 0 {
		t.Fatalf("overlapping retry released shared allocation: %+v", resources.releases)
	}
}

func TestDispatchOwnerRetainsTheWinnerWhenAnAdopterFinalizesFirst(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := newAdopterWinsResources()
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	type result struct {
		allocation handoff.Allocation
		err        error
	}
	ownerResult := make(chan result, 1)
	go func() {
		allocation, allocateErr := coordinator.Allocate(
			context.Background(),
			validRequest(),
		)
		ownerResult <- result{allocation: allocation, err: allocateErr}
	}()
	<-resources.provisionStarted

	adopterRequest := validRequest()
	adopterRequest.AttemptID = "attempt-8"
	adopter, err := coordinator.Allocate(context.Background(), adopterRequest)
	if err != nil {
		t.Fatalf("adopter Allocate returned an error: %v", err)
	}
	if !adopter.RetainOnFailure {
		t.Fatalf("adopter allocation = %+v, want retained durable winner", adopter)
	}
	close(resources.allowProvision)
	owner := <-ownerResult
	if owner.err != nil {
		t.Fatalf("dispatch owner Allocate returned an error: %v", owner.err)
	}
	if !owner.allocation.RetainOnFailure {
		t.Fatalf(
			"dispatch owner allocation = %+v, want replayed winner retained",
			owner.allocation,
		)
	}
}

func TestCanceledDispatchOwnerRetainsTheAdopterWinner(t *testing.T) {
	storage := newMemoryStorage()
	storage.respectContext = true
	store := newLeaseStore(t, storage)
	resources := newAdopterWinsResources()
	resources.provisionErr = context.Canceled
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	type result struct {
		allocation handoff.Allocation
		err        error
	}
	ownerCtx, cancelOwner := context.WithCancel(context.Background())
	ownerResult := make(chan result, 1)
	go func() {
		allocation, allocateErr := coordinator.Allocate(ownerCtx, validRequest())
		ownerResult <- result{allocation: allocation, err: allocateErr}
	}()
	<-resources.provisionStarted

	adopterRequest := validRequest()
	adopterRequest.AttemptID = "attempt-8"
	adopter, err := coordinator.Allocate(context.Background(), adopterRequest)
	if err != nil || !adopter.RetainOnFailure {
		t.Fatalf("adopter allocation = %+v/%v, want retained winner", adopter, err)
	}
	cancelOwner()
	close(resources.allowProvision)
	owner := <-ownerResult
	if owner.err != nil {
		t.Fatalf("canceled dispatch owner did not resolve adopter winner: %v", owner.err)
	}
	if !owner.allocation.RetainOnFailure {
		t.Fatalf("canceled dispatch owner allocation = %+v, want retained winner", owner.allocation)
	}
}

func TestAllocateNeverDispatchesWhenBarrierWriteFails(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeErrAt = 2
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

	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); !errors.Is(err, nakamalease.ErrStorage) {
		t.Fatalf("barrier write failure = %v, want ErrStorage", err)
	}
	if len(resources.events) != 0 {
		t.Fatalf("failed dispatch barrier touched external resources: %v", resources.events)
	}
}

func TestAllocateReconcilesDispatchedAttemptAfterRestartWithoutRedispatch(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
	}
	first, err := NewCoordinator(
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
	if _, err := first.Allocate(
		context.Background(),
		validRequest(),
	); status.Code(err) != codes.Unavailable {
		t.Fatalf("first ambiguous dispatch status = %s, want Unavailable", status.Code(err))
	}

	resources.provisionErr = nil
	restarted, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("restart NewCoordinator returned an error: %v", err)
	}
	got, err := restarted.Allocate(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("restart reconciliation returned an error: %v", err)
	}
	if !reflect.DeepEqual(got, retainedAllocation(validAllocation())) {
		t.Fatalf("restart reconciliation = %+v, want retained %+v", got, validAllocation())
	}
	if len(resources.provisions) != 1 {
		t.Fatalf("resource dispatches = %d, want exactly one", len(resources.provisions))
	}
	if len(resources.reconciliations) != 1 ||
		resources.reconciliations[0] != validRequest() {
		t.Fatalf(
			"resource reconciliations = %+v, want one exact attempt",
			resources.reconciliations,
		)
	}
	if !reflect.DeepEqual(
		resources.events,
		[]string{"provision:attempt-7", "reconcile:attempt-7"},
	) {
		t.Fatalf("restart resource events = %v, want dispatch then reconcile", resources.events)
	}
}

func TestAllocateConcurrentCoordinatorsDispatchOnce(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := newConcurrentResources()
	first, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("first NewCoordinator returned an error: %v", err)
	}
	second, err := NewCoordinator(
		resources,
		store,
		Config{
			LeaseTTL: time.Minute,
			Now:      func() time.Time { return testNow },
		},
	)
	if err != nil {
		t.Fatalf("second NewCoordinator returned an error: %v", err)
	}

	type result struct {
		allocation handoff.Allocation
		err        error
	}
	results := make(chan result, 2)
	go func() {
		allocation, allocateErr := first.Allocate(context.Background(), validRequest())
		results <- result{allocation: allocation, err: allocateErr}
	}()
	<-resources.provisionStarted
	go func() {
		allocation, allocateErr := second.Allocate(context.Background(), validRequest())
		results <- result{allocation: allocation, err: allocateErr}
	}()
	<-resources.reconcileStarted
	close(resources.allowProvision)

	retained := 0
	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatalf("concurrent Allocate returned an error: %v", got.err)
		}
		if got.allocation.RetainOnFailure {
			retained++
			got.allocation.RetainOnFailure = false
		}
		if !reflect.DeepEqual(got.allocation, validAllocation()) {
			t.Fatalf("concurrent allocation = %+v, want %+v", got.allocation, validAllocation())
		}
	}
	if retained != 2 {
		t.Fatalf("retained concurrent results = %d, want both published responses retained", retained)
	}
	provisions, reconciliations := resources.calls()
	if provisions != 1 || reconciliations != 1 {
		t.Fatalf(
			"concurrent resource calls = %d dispatch/%d reconcile, want 1/1",
			provisions,
			reconciliations,
		)
	}
}

func TestAllocateAdoptsQuarantinedDispatchWithoutRedispatch(t *testing.T) {
	ambiguous := status.Error(codes.Unavailable, "ambiguous allocation result")
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: ambiguous,
		reconcileErr: ambiguous,
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
		t.Fatalf("first ambiguous dispatch status = %s, want Unavailable", status.Code(err))
	}

	newer := validRequest()
	newer.AttemptID = "attempt-8"
	if _, err := coordinator.Allocate(context.Background(), newer); err == nil {
		t.Fatal("transport retry reconciled an unavailable dispatch, want refusal")
	}
	if len(resources.provisions) != 1 {
		t.Fatalf("resource dispatches = %+v, want exactly one dispatch", resources.provisions)
	}
	if len(resources.reconciliations) != 1 ||
		resources.reconciliations[0].AttemptID != testAttemptID {
		t.Fatalf(
			"resource reconciliations = %+v, want persisted attempt-7 observation",
			resources.reconciliations,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("transport retry released ambiguous resources: %+v", resources.releases)
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load quarantined attempt: %v", err)
	}
	if record.Lease.AttemptID != testAttemptID {
		t.Fatalf("durable attempt = %q, want %q", record.Lease.AttemptID, testAttemptID)
	}
}

func TestAllocateRetryCannotAdoptAQuarantineWhoseReleaseHasBegun(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	resources := &recordingResources{
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(
		context.Background(),
		validRequest(),
	); status.Code(err) != codes.Unavailable {
		t.Fatalf("first ambiguous dispatch status = %s, want Unavailable", status.Code(err))
	}
	current, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load quarantined dispatch: %v", err)
	}
	if _, err := store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	); err != nil {
		t.Fatalf("BeginRelease returned an error: %v", err)
	}
	resources.events = nil
	resources.reconciliations = nil
	resources.releases = nil

	retry := validRequest()
	retry.AttemptID = "attempt-8"
	got, err := coordinator.Allocate(context.Background(), retry)
	if !errors.Is(err, nakamalease.ErrReleasing) {
		t.Fatalf("retry during release error = %v, want ErrReleasing", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("retry during release returned %+v, want zero allocation", got)
	}
	if len(resources.events) != 0 {
		t.Fatalf("retry during release touched resources: %v", resources.events)
	}
}

func TestReconcileExpiredRetainsAmbiguousDispatchUntilFence(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow
	resources := &recordingResources{
		provisionErr: status.Error(codes.Unavailable, "ambiguous allocation result"),
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
	); status.Code(err) != codes.Unavailable {
		t.Fatalf("first ambiguous dispatch status = %s, want Unavailable", status.Code(err))
	}

	now = testNow.Add(2 * time.Minute)
	if err := coordinator.ReconcileExpired(context.Background()); err != nil {
		t.Fatalf("ReconcileExpired returned an error: %v", err)
	}
	record, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load expired quarantine: %v", err)
	}
	if record.Lease.AttemptID != testAttemptID || !record.Lease.Staging {
		t.Fatalf("expired quarantine = %+v, want original staging attempt", record.Lease)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("expiry sweep released ambiguous resources: %+v", resources.releases)
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
	if !reflect.DeepEqual(got, retainedAllocation(validAllocation())) {
		t.Fatalf("recovered allocation = %+v, want retained %+v", got, validAllocation())
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

func TestAllocateExpiredAttemptReleasesAndReplacesTheLease(t *testing.T) {
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
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	previous, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	now = testNow.Add(2 * time.Minute)

	nextAllocation := validAllocation()
	nextAllocation.ID = "gameserver-18"
	nextAllocation.ServerName = "zone-18.edge.example"
	nextAllocation.Observer = sim.EntityID(84)
	nextAllocation.AdmissionSecret = bytes.Repeat([]byte{0x84}, 32)
	nextAllocation.LeaseExpiresAt = now.Add(time.Minute)
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
		case durable.State(now) != nakamalease.StateReleasing:
			return fmt.Errorf(
				"replacement barrier state = %q, want %q",
				durable.State(now),
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
	if !reflect.DeepEqual(got, retainedAllocation(nextAllocation)) {
		t.Fatalf("replacement allocation = %+v, want retained %+v", got, nextAllocation)
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

func TestAllocateDetachesExpiredResourceCleanupFromCallerCancellation(t *testing.T) {
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
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	now = testNow.Add(2 * time.Minute)
	ctx, cancel := context.WithCancel(context.Background())
	resources.releaseContextCheck = func(cleanupCtx context.Context) error {
		cancel()
		return cleanupCtx.Err()
	}
	next := validRequest()
	next.AttemptID = "attempt-8"
	resources.provisioned.Allocation.ID = "gameserver-18"
	resources.provisioned.Allocation.LeaseExpiresAt = now.Add(time.Minute)
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

func TestAllocateExpiredReplacementKeepsTheReleasingLeaseWhenResourceReleaseFails(t *testing.T) {
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
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("first Allocate returned an error: %v", err)
	}
	before, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("load first allocation lease: %v", err)
	}
	now = testNow.Add(2 * time.Minute)
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
	if len(resources.releases) != 0 {
		t.Fatalf("ambiguous provision released resources: %+v", resources.releases)
	}
	record, loadErr := store.Load(context.Background(), testUserID, testReservationID)
	if loadErr != nil {
		t.Fatalf("load ambiguous provision quarantine: %v", loadErr)
	}
	if !record.Lease.Staging || !record.Lease.Dispatched {
		t.Fatalf("ambiguous provision lease = %+v, want dispatched staging", record.Lease)
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("provision failure leaked %q: %v", leaked, err)
		}
	}
}

func TestAllocateProvisionFailureQuarantinesTheReportedStagedResource(t *testing.T) {
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
		[]string{"provision:attempt-7"},
	) {
		t.Fatalf(
			"staged provision failure resource order = %v, want quarantine",
			resources.events,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("staged provision failure released %+v, want none", resources.releases)
	}
	record, loadErr := store.Load(context.Background(), testUserID, testReservationID)
	if loadErr != nil {
		t.Fatalf("load staged provision quarantine: %v", loadErr)
	}
	if !record.Lease.Staging ||
		!record.Lease.Dispatched ||
		record.Lease.AllocationID != "" ||
		record.Lease.SecretRef != "" {
		t.Fatalf("staged provision quarantine = %+v, want opaque dispatch", record.Lease)
	}
}

func TestAllocateProvisionFailureKeepsTheDurableQuarantineExpiry(t *testing.T) {
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
	record, loadErr := store.Load(context.Background(), testUserID, testReservationID)
	if loadErr != nil {
		t.Fatalf("load staged provision quarantine: %v", loadErr)
	}
	if !record.Lease.ExpiresAt.Equal(testNow.Add(time.Minute)) {
		t.Fatalf(
			"quarantine expiry = %s, want durable pre-dispatch expiry %s",
			record.Lease.ExpiresAt,
			testNow.Add(time.Minute),
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf("reported ambiguous resource was released: %+v", resources.releases)
	}
}

func TestAllocateProvisionFailureAdoptsAProgressedSameAttemptWinner(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	staging := nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		ExpiresAt:     testNow.Add(time.Minute),
		Staging:       true,
	}
	if _, err := store.Create(context.Background(), staging); err != nil {
		t.Fatalf("create concurrent staging intent: %v", err)
	}
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionErr: status.Error(codes.Unavailable, "ambiguous sibling result"),
	}
	resources.provisionCheck = func(
		request handoff.AllocationRequest,
		_ time.Time,
	) error {
		current, err := store.Load(
			context.Background(),
			request.UserID,
			request.ReservationID,
		)
		if err != nil {
			return fmt.Errorf("load staging winner: %w", err)
		}
		_, err = store.Finalize(
			context.Background(),
			current,
			leaseFromProvisioned(
				request,
				resources.provisioned,
				resources.provisioned.Allocation.LeaseExpiresAt,
			),
		)
		return err
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
		t.Fatalf("Allocate did not adopt the progressed winner: %v", err)
	}
	if !reflect.DeepEqual(got, retainedAllocation(validAllocation())) {
		t.Fatalf("adopted allocation = %+v, want retained %+v", got, validAllocation())
	}
	if !reflect.DeepEqual(
		resources.events,
		[]string{"provision:attempt-7", "resolve:attempt-7"},
	) {
		t.Fatalf(
			"progressed-winner events = %v, want provision then resolve",
			resources.events,
		)
	}
	if len(resources.releases) != 0 {
		t.Fatalf(
			"provision loser released the progressed winner: %+v",
			resources.releases,
		)
	}
}

func TestAllocateRechecksExpiryAfterSlowProvisioning(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionCheck: func(
			_ handoff.AllocationRequest,
			expiresAt time.Time,
		) error {
			now = expiresAt
			return nil
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

	got, err := coordinator.Allocate(context.Background(), validRequest())
	if !errors.Is(err, ErrInvalidResource) {
		t.Fatalf("slow provisioning error = %v, want ErrInvalidResource", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("slow provisioning returned %+v, want zero allocation", got)
	}
	if len(resources.releases) != 1 ||
		resources.releases[0].AttemptID != testAttemptID {
		t.Fatalf(
			"expired staged resource releases = %+v, want exact attempt",
			resources.releases,
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

func TestAllocateFailsClosedWhenFinalizationCleanupCannotBeReconciled(t *testing.T) {
	storage := newMemoryStorage()
	storage.writeErrAt = 3
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
		t.Fatalf("finalization cleanup error = %v, want ErrReconciliation", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("finalization cleanup returned %+v, want zero allocation", got)
	}
	for _, leaked := range []string{testReservationID, testAttemptID} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("finalization cleanup leaked %q: %v", leaked, err)
		}
	}
}

func TestAllocateDetachesKnownResourceCleanupFromCallerCancellation(t *testing.T) {
	storage := newMemoryStorage()
	storage.respectContext = true
	store := newLeaseStore(t, storage)
	ctx, cancel := context.WithCancel(context.Background())
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		provisionCheck: func(handoff.AllocationRequest, time.Time) error {
			cancel()
			return nil
		},
		releaseContextCheck: func(releaseCtx context.Context) error {
			return releaseCtx.Err()
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return testNow }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}

	got, err := coordinator.Allocate(ctx, validRequest())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Allocate after caller cancellation error = %v, want context.Canceled", err)
	}
	if !reflect.DeepEqual(got, handoff.Allocation{}) {
		t.Fatalf("canceled allocation returned %+v, want zero allocation", got)
	}
	if len(resources.releases) != 1 {
		t.Fatalf("known resource releases = %d, want 1", len(resources.releases))
	}
	if _, err := store.Load(
		context.Background(),
		testUserID,
		testReservationID,
	); !errors.Is(err, nakamalease.ErrNotFound) {
		t.Fatalf("known resource lease survived detached cleanup: %v", err)
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

func TestRunExpiryReconcilerRetriesTransientCleanupFailure(t *testing.T) {
	storage := newMemoryStorage()
	store := newLeaseStore(t, storage)
	now := testNow
	releaseCalls := make(chan int, 2)
	releaseAttempt := 0
	resources := &recordingResources{
		provisioned: Provisioned{
			Allocation: validAllocation(),
			SecretRef:  "zone-admission-gameserver-17",
		},
		releaseCheck: func(nakamalease.Lease) error {
			releaseAttempt++
			releaseCalls <- releaseAttempt
			if releaseAttempt == 1 {
				return errors.New("transient resource cleanup failure")
			}
			return nil
		},
	}
	coordinator, err := NewCoordinator(
		resources,
		store,
		Config{LeaseTTL: time.Minute, Now: func() time.Time { return now }},
	)
	if err != nil {
		t.Fatalf("NewCoordinator returned an error: %v", err)
	}
	if _, err := coordinator.Allocate(context.Background(), validRequest()); err != nil {
		t.Fatalf("Allocate returned an error: %v", err)
	}
	now = testNow.Add(time.Minute)
	coordinator.sweepInterval = time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		result <- coordinator.RunExpiryReconciler(ctx)
	}()
	select {
	case attempt := <-releaseCalls:
		if attempt != 1 {
			t.Fatalf("first cleanup attempt = %d, want 1", attempt)
		}
	case <-time.After(time.Second):
		t.Fatal("reconciler did not start no-show cleanup")
	}
	select {
	case err := <-result:
		t.Fatalf("reconciler stopped after a transient cleanup failure: %v", err)
	case attempt := <-releaseCalls:
		if attempt != 2 {
			t.Fatalf("retried cleanup attempt = %d, want 2", attempt)
		}
	case <-time.After(time.Second):
		t.Fatal("reconciler did not retry transient cleanup failure")
	}

	deadline := time.Now().Add(time.Second)
	for {
		_, loadErr := store.Load(
			context.Background(),
			testUserID,
			testReservationID,
		)
		if errors.Is(loadErr, nakamalease.ErrNotFound) {
			break
		}
		if loadErr != nil {
			t.Fatalf("load lease after cleanup retry: %v", loadErr)
		}
		if time.Now().After(deadline) {
			t.Fatal("successful cleanup retry did not remove the durable lease")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("reconciler stop error = %v, want context.Canceled", err)
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
