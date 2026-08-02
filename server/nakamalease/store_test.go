package nakamalease

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	testUserID        = "11111111-1111-4111-8111-111111111111"
	testCanonicalID   = "abcdefab-cdef-4abc-8def-abcdefabcdef"
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
	testAllocationID  = "gameserver-17"
	testSecretRef     = "zone-admission-gameserver-17"
	testSystemUserID  = "00000000-0000-0000-0000-000000000000"
)

type memoryStorage struct {
	mu                     sync.Mutex
	objects                map[string]*api.StorageObject
	reads                  []*runtime.StorageRead
	writes                 []*runtime.StorageWrite
	deletes                []*runtime.StorageDelete
	version                int
	readErr                error
	listErr                error
	writeErr               error
	writeAfterCommitErr    error
	writeAfterCommitErrAt  int
	deleteErr              error
	createConflictMutation func(map[string]*api.StorageObject, string)
	deleteFault            func(map[string]*api.StorageObject, []*runtime.StorageDelete) error
}

type createRaceStorage struct {
	*memoryStorage
	initialReads sync.WaitGroup
	barrierMu    sync.Mutex
	barrierReads int
}

func newCreateRaceStorage() *createRaceStorage {
	storage := &createRaceStorage{memoryStorage: newMemoryStorage()}
	storage.initialReads.Add(2)
	return storage
}

func (s *createRaceStorage) StorageRead(
	ctx context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	objects, err := s.memoryStorage.StorageRead(ctx, reads)
	s.barrierMu.Lock()
	waitForPeer := s.barrierReads < 2
	if waitForPeer {
		s.barrierReads++
	}
	s.barrierMu.Unlock()
	if waitForPeer {
		s.initialReads.Done()
		s.initialReads.Wait()
	}
	return objects, err
}

func newMemoryStorage() *memoryStorage {
	return &memoryStorage{
		objects: make(map[string]*api.StorageObject),
	}
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
	if s.listErr != nil {
		return nil, "", s.listErr
	}
	objects := make([]*api.StorageObject, 0, len(s.objects))
	for _, object := range s.objects {
		if object.GetUserId() == userID &&
			object.GetCollection() == collection {
			objects = append(objects, cloneStorageObject(object))
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
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readErr != nil {
		return nil, s.readErr
	}
	objects := make([]*api.StorageObject, 0, len(reads))
	for _, read := range reads {
		copy := *read
		s.reads = append(s.reads, &copy)
		if object := s.objects[storageID(storageOwner(read.UserID), read.Collection, read.Key)]; object != nil {
			objects = append(objects, cloneStorageObject(object))
		}
	}
	return objects, nil
}

func (s *memoryStorage) StorageWrite(
	_ context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.writeErr != nil {
		return nil, s.writeErr
	}
	acks := make([]*api.StorageObjectAck, 0, len(writes))
	for _, write := range writes {
		if write.PermissionRead != 0 || write.PermissionWrite != 0 {
			return nil, errors.New("test storage: expected server-only permissions")
		}
		s.writes = append(s.writes, cloneStorageWrite(write))
		ownerID := storageOwner(write.UserID)
		id := storageID(ownerID, write.Collection, write.Key)
		current := s.objects[id]
		switch {
		case write.Version == "*" && current != nil:
			if s.createConflictMutation != nil {
				s.createConflictMutation(s.objects, id)
			}
			return nil, runtime.ErrStorageRejectedVersion
		case write.Version == "*":
		case current == nil || current.GetVersion() != write.Version:
			return nil, runtime.ErrStorageRejectedVersion
		}
		s.version++
		version := fmt.Sprintf("v%d", s.version)
		s.objects[id] = &api.StorageObject{
			Collection:      write.Collection,
			Key:             write.Key,
			UserId:          ownerID,
			Value:           write.Value,
			Version:         version,
			PermissionRead:  0,
			PermissionWrite: 0,
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     ownerID,
			Version:    version,
		})
		if s.writeAfterCommitErr != nil &&
			(s.writeAfterCommitErrAt == 0 || s.version == s.writeAfterCommitErrAt) {
			err := s.writeAfterCommitErr
			s.writeAfterCommitErr = nil
			return nil, err
		}
	}
	return acks, nil
}

func (s *memoryStorage) StorageDelete(
	_ context.Context,
	deletes []*runtime.StorageDelete,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.deleteErr != nil {
		return s.deleteErr
	}
	if s.deleteFault != nil {
		return s.deleteFault(s.objects, deletes)
	}
	for _, deletion := range deletes {
		copy := *deletion
		s.deletes = append(s.deletes, &copy)
		id := storageID(storageOwner(deletion.UserID), deletion.Collection, deletion.Key)
		current := s.objects[id]
		if current == nil || current.GetVersion() != deletion.Version {
			return runtime.ErrStorageRejectedVersion
		}
		delete(s.objects, id)
	}
	return nil
}

func storageOwner(userID string) string {
	if userID == "" {
		return testSystemUserID
	}
	return userID
}

func storageID(userID, collection, key string) string {
	return userID + "\x00" + collection + "\x00" + key
}

func cloneStorageObject(object *api.StorageObject) *api.StorageObject {
	return &api.StorageObject{
		Collection:      object.GetCollection(),
		Key:             object.GetKey(),
		UserId:          object.GetUserId(),
		Value:           object.GetValue(),
		Version:         object.GetVersion(),
		PermissionRead:  object.GetPermissionRead(),
		PermissionWrite: object.GetPermissionWrite(),
	}
}

func cloneStorageWrite(write *runtime.StorageWrite) *runtime.StorageWrite {
	copy := *write
	return &copy
}

func validLease() Lease {
	return Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		AllocationID:  testAllocationID,
		Observer:      sim.EntityID(42),
		SecretRef:     testSecretRef,
		ExpiresAt:     time.Unix(2_000_000_000, 123_456_789).UTC(),
	}
}

func TestNewStoreRequiresStorage(t *testing.T) {
	if _, err := NewStore(nil); err == nil {
		t.Fatal("NewStore(nil) returned nil, want an error")
	}
}

func TestCreatePersistsPrivateVersionedLeaseByHashedKey(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()

	got, err := store.Create(context.Background(), lease)
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	if got.Lease != lease || got.Version != "v1" {
		t.Fatalf("created record = %+v, want lease %+v at version v1", got, lease)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes = %d, want 1", len(storage.writes))
	}
	write := storage.writes[0]
	if write.Collection != Collection ||
		write.Key != "ff9dd796a2c444815c6712b11b454a52ebe370f5bed18ee266445ce61da7a9e6" ||
		write.UserID != "" {
		t.Fatalf(
			"storage identity = %q/%q/%q, want server-owned hashed user/reservation",
			write.UserID,
			write.Collection,
			write.Key,
		)
	}
	if write.Version != "*" {
		t.Fatalf("create version = %q, want Nakama uniqueness guard '*'", write.Version)
	}
	if write.PermissionRead != 0 || write.PermissionWrite != 0 {
		t.Fatalf(
			"storage permissions = read %d/write %d, want server-only 0/0",
			write.PermissionRead,
			write.PermissionWrite,
		)
	}
	if write.Value == "" || !json.Valid([]byte(write.Value)) {
		t.Fatalf("stored lease is not valid JSON: %q", write.Value)
	}
	if got := write.Value; got == "" ||
		strings.Contains(got, testReservationID) ||
		strings.Contains(got, testUserID) {
		t.Fatalf("stored lease exposes raw storage identity: %q", got)
	}

	var document map[string]any
	if err := json.Unmarshal([]byte(write.Value), &document); err != nil {
		t.Fatalf("decode stored lease: %v", err)
	}
	want := map[string]any{
		"schema":           float64(3),
		"attempt_id":       testAttemptID,
		"allocation_id":    testAllocationID,
		"observer":         float64(42),
		"secret_ref":       testSecretRef,
		"expires_at_nanos": float64(2_000_000_000_123_456_789),
		"claimed_at_nanos": nil,
	}
	if !reflect.DeepEqual(document, want) {
		t.Fatalf("stored document = %#v, want %#v", document, want)
	}
}

func TestCreateIgnoresAClientOwnedObjectAtTheDerivedKey(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()
	value, err := json.Marshal(documentFrom(lease))
	if err != nil {
		t.Fatalf("marshal client object: %v", err)
	}
	key := reservationKey(testUserID, testReservationID)
	storage.objects[storageID(testUserID, Collection, key)] = &api.StorageObject{
		Collection:      Collection,
		Key:             key,
		UserId:          testUserID,
		Value:           string(value),
		Version:         "client-version",
		PermissionRead:  0,
		PermissionWrite: 0,
	}

	got, err := store.Create(context.Background(), lease)
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	if got.Lease != lease || got.Version != "v1" {
		t.Fatalf("created record = %+v, want lease %+v at version v1", got, lease)
	}
	if len(storage.reads) != 1 || storage.reads[0].UserID != "" {
		t.Fatalf("storage reads = %+v, want one server-owned read", storage.reads)
	}
	if len(storage.writes) != 1 || storage.writes[0].UserID != "" {
		t.Fatalf("storage writes = %+v, want one server-owned write", storage.writes)
	}
	if storage.objects[storageID(testUserID, Collection, key)].GetVersion() != "client-version" {
		t.Fatal("Create mutated the client-owned decoy object")
	}
}

func TestLeaseIdentityCanonicalizesEquivalentUserIDSpellings(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	upper := validLease()
	upper.UserID = strings.ToUpper(testCanonicalID)

	created, err := store.Create(context.Background(), upper)
	if err != nil {
		t.Fatalf("Create with uppercase user ID returned an error: %v", err)
	}
	want := validLease()
	want.UserID = testCanonicalID
	if created.Lease != want {
		t.Fatalf("created lease = %+v, want canonical lease %+v", created.Lease, want)
	}
	replayed, err := store.Create(context.Background(), want)
	if err != nil {
		t.Fatalf("Create with lowercase user ID returned an error: %v", err)
	}
	if replayed != created {
		t.Fatalf("equivalent user ID replay = %+v, want original %+v", replayed, created)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("writes for equivalent user ID spellings = %d, want 1", len(storage.writes))
	}

	if err := store.Release(
		context.Background(),
		strings.ToUpper(testCanonicalID),
		testReservationID,
		testAttemptID,
	); err != nil {
		t.Fatalf("Release with uppercase user ID returned an error: %v", err)
	}
	if _, err := store.Load(
		context.Background(),
		testCanonicalID,
		testReservationID,
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load after canonical release error = %v, want ErrNotFound", err)
	}
}

func TestCreateRejectsAnotherAttemptAtTheSameReservation(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	if _, err := store.Create(context.Background(), validLease()); err != nil {
		t.Fatalf("first Create returned an error: %v", err)
	}
	other := validLease()
	other.AttemptID = "attempt-8"
	other.AllocationID = "gameserver-18"
	other.SecretRef = "zone-admission-gameserver-18"

	if _, err := store.Create(context.Background(), other); !errors.Is(err, ErrConflict) {
		t.Fatalf("colliding Create error = %v, want ErrConflict", err)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes after colliding create = %d, want 1", len(storage.writes))
	}
}

func TestCreateReplaysTheSameAttemptWithoutAnotherWrite(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()
	first, err := store.Create(context.Background(), lease)
	if err != nil {
		t.Fatalf("first Create returned an error: %v", err)
	}

	replayed, err := store.Create(context.Background(), lease)
	if err != nil {
		t.Fatalf("replayed Create returned an error: %v", err)
	}
	if replayed != first {
		t.Fatalf("replayed record = %+v, want original %+v", replayed, first)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes after replay = %d, want 1", len(storage.writes))
	}
}

func TestConcurrentIdenticalCreateReconcilesTheDurableWinner(t *testing.T) {
	storage := newCreateRaceStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()
	var records [2]Record
	var errs [2]error
	var creates sync.WaitGroup
	creates.Add(len(records))
	for i := range records {
		go func() {
			defer creates.Done()
			records[i], errs[i] = store.Create(context.Background(), lease)
		}()
	}
	creates.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent Create %d returned an error: %v", i, err)
		}
	}
	if records[0] != records[1] || records[0].Lease != lease {
		t.Fatalf(
			"concurrent records = %+v and %+v, want one durable lease %+v",
			records[0],
			records[1],
			lease,
		)
	}
	if len(storage.writes) != 2 {
		t.Fatalf(
			"concurrent create writes = %d, want one winner and one conflict",
			len(storage.writes),
		)
	}
}

func TestConcurrentStagingCreateReusesTheDurableWinnerExpiry(t *testing.T) {
	storage := newCreateRaceStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	candidates := []Lease{staging, staging}
	candidates[1].ExpiresAt = candidates[1].ExpiresAt.Add(time.Nanosecond)
	records := make([]Record, len(candidates))
	errs := make([]error, len(candidates))
	var creates sync.WaitGroup
	creates.Add(len(candidates))
	for i := range candidates {
		go func() {
			defer creates.Done()
			records[i], errs[i] = store.Create(
				context.Background(),
				candidates[i],
			)
		}()
	}
	creates.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent staging Create %d returned an error: %v", i, err)
		}
	}
	if records[0] != records[1] ||
		!records[0].Lease.Staging ||
		records[0].Lease.AttemptID != testAttemptID {
		t.Fatalf(
			"concurrent staging records = %+v and %+v, want one durable intent",
			records[0],
			records[1],
		)
	}
}

func TestConcurrentStagingCreateAcceptsAProgressedWinner(t *testing.T) {
	storage := newCreateRaceStorage()
	progressed := validLease()
	progressed.ClaimedAt = progressed.ExpiresAt.Add(-time.Second)
	storage.createConflictMutation = func(
		objects map[string]*api.StorageObject,
		id string,
	) {
		value, err := json.Marshal(documentFrom(progressed))
		if err != nil {
			t.Fatalf("marshal progressed winner: %v", err)
		}
		objects[id].Value = string(value)
		objects[id].Version = "claimed-v2"
	}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	var records [2]Record
	var errs [2]error
	var creates sync.WaitGroup
	creates.Add(len(records))
	for i := range records {
		go func() {
			defer creates.Done()
			records[i], errs[i] = store.Create(context.Background(), staging)
		}()
	}
	creates.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent staging Create %d returned an error: %v", i, err)
		}
	}
	progressedWinners := 0
	for _, record := range records {
		if !record.Lease.Staging {
			progressedWinners++
			if record.Lease != progressed {
				t.Fatalf(
					"progressed staging winner = %+v, want %+v",
					record.Lease,
					progressed,
				)
			}
		}
	}
	if progressedWinners != 1 {
		t.Fatalf(
			"progressed staging records = %d, want the reloaded winner once",
			progressedWinners,
		)
	}
}

func TestConcurrentIdenticalCreateReconcilesAClaimedWinner(t *testing.T) {
	storage := newCreateRaceStorage()
	claimTime := validLease().ExpiresAt.Add(-time.Second).UnixNano()
	storage.createConflictMutation = func(
		objects map[string]*api.StorageObject,
		id string,
	) {
		object := objects[id]
		object.Value = strings.Replace(
			object.GetValue(),
			`"claimed_at_nanos":null`,
			fmt.Sprintf(`"claimed_at_nanos":%d`, claimTime),
			1,
		)
		object.Version = "claimed-v2"
	}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()
	var records [2]Record
	var errs [2]error
	var creates sync.WaitGroup
	creates.Add(len(records))
	for i := range records {
		go func() {
			defer creates.Done()
			records[i], errs[i] = store.Create(context.Background(), lease)
		}()
	}
	creates.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent Create %d returned an error: %v", i, err)
		}
	}
	claimed := 0
	for _, record := range records {
		if !record.Lease.ClaimedAt.IsZero() {
			claimed++
		}
		if record.Lease.AttemptID != lease.AttemptID ||
			record.Lease.AllocationID != lease.AllocationID ||
			record.Lease.SecretRef != lease.SecretRef {
			t.Fatalf("concurrent Create returned a different owner: %+v", record)
		}
	}
	if claimed != 1 {
		t.Fatalf("claimed concurrent records = %d, want the reloaded winner once", claimed)
	}
}

func TestConcurrentIdenticalCreateRefusesAReleasingWinner(t *testing.T) {
	storage := newCreateRaceStorage()
	storage.createConflictMutation = func(
		objects map[string]*api.StorageObject,
		id string,
	) {
		object := objects[id]
		object.Value = strings.Replace(
			object.GetValue(),
			"{",
			`{"releasing":true,`,
			1,
		)
		object.Version = "releasing-v2"
	}
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	lease := validLease()
	var errs [2]error
	var creates sync.WaitGroup
	creates.Add(len(errs))
	for i := range errs {
		go func() {
			defer creates.Done()
			_, errs[i] = store.Create(context.Background(), lease)
		}()
	}
	creates.Wait()

	succeeded := 0
	releasing := 0
	for _, err := range errs {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, ErrReleasing):
			releasing++
		default:
			t.Fatalf("concurrent Create returned an unexpected error: %v", err)
		}
	}
	if succeeded != 1 || releasing != 1 {
		t.Fatalf(
			"concurrent outcomes = %d success/%d releasing, want one of each",
			succeeded,
			releasing,
		)
	}
}

func TestCreateAndReplaceRequireAnUnclaimedLease(t *testing.T) {
	t.Run("create", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		lease := validLease()
		lease.ClaimedAt = lease.ExpiresAt.Add(-time.Second)

		if _, err := store.Create(context.Background(), lease); !errors.Is(err, ErrClaimed) {
			t.Fatalf("Create preclaimed lease error = %v, want ErrClaimed", err)
		}
		if len(storage.writes) != 0 {
			t.Fatalf("storage writes after preclaimed create = %d, want 0", len(storage.writes))
		}
	})

	t.Run("replace", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		current, err := store.Create(context.Background(), validLease())
		if err != nil {
			t.Fatalf("Create returned an error: %v", err)
		}
		next := validLease()
		next.AttemptID = "attempt-8"
		next.AllocationID = "gameserver-18"
		next.SecretRef = "zone-admission-gameserver-18"
		next.ClaimedAt = next.ExpiresAt.Add(-time.Second)

		if _, err := store.Replace(context.Background(), current, next); !errors.Is(err, ErrClaimed) {
			t.Fatalf("Replace with a preclaimed lease error = %v, want ErrClaimed", err)
		}
		if len(storage.writes) != 1 {
			t.Fatalf("storage writes after preclaimed replacement = %d, want 1", len(storage.writes))
		}
	})

	t.Run("create releasing", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		lease := validLease()
		lease.Releasing = true

		if _, err := store.Create(context.Background(), lease); !errors.Is(err, ErrReleasing) {
			t.Fatalf("Create releasing lease error = %v, want ErrReleasing", err)
		}
		if len(storage.writes) != 0 {
			t.Fatalf("storage writes after releasing create = %d, want 0", len(storage.writes))
		}
	})

	t.Run("replace with releasing target", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		current, err := store.Create(context.Background(), validLease())
		if err != nil {
			t.Fatalf("Create returned an error: %v", err)
		}
		next := validLease()
		next.AttemptID = "attempt-8"
		next.AllocationID = "gameserver-18"
		next.SecretRef = "zone-admission-gameserver-18"
		next.Releasing = true

		if _, err := store.Replace(
			context.Background(),
			current,
			next,
		); !errors.Is(err, ErrReleasing) {
			t.Fatalf("Replace with releasing lease error = %v, want ErrReleasing", err)
		}
		if len(storage.writes) != 1 {
			t.Fatalf(
				"storage writes after releasing replacement = %d, want 1",
				len(storage.writes),
			)
		}
	})
}

func TestCreateRejectsMalformedSecretReferencesWithoutStorage(t *testing.T) {
	for _, secretRef := range []string{
		".zone-admission",
		"zone-admission.",
		"zone..admission",
		"zone.-admission",
		strings.Repeat("a", 64),
	} {
		t.Run(secretRef, func(t *testing.T) {
			storage := newMemoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore returned an error: %v", err)
			}
			lease := validLease()
			lease.SecretRef = secretRef

			if _, err := store.Create(context.Background(), lease); err == nil {
				t.Fatal("Create with a malformed secret reference returned nil, want an error")
			}
			if len(storage.writes) != 0 {
				t.Fatalf("storage writes after malformed secret reference = %d, want 0", len(storage.writes))
			}
		})
	}
}

func TestReplaceUsesObservedVersionAndStaleRecordCannotOverwrite(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	first, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	nextLease := validLease()
	nextLease.AttemptID = "attempt-8"
	nextLease.AllocationID = "gameserver-18"
	nextLease.Observer = sim.EntityID(43)
	nextLease.SecretRef = "zone-admission-gameserver-18"
	nextLease.ExpiresAt = nextLease.ExpiresAt.Add(time.Minute)

	current, err := store.Replace(context.Background(), first, nextLease)
	if err != nil {
		t.Fatalf("Replace returned an error: %v", err)
	}
	if current.Lease != nextLease || current.Version != "v2" {
		t.Fatalf("replacement = %+v, want lease %+v at v2", current, nextLease)
	}

	staleLease := nextLease
	staleLease.AttemptID = "attempt-9"
	staleLease.AllocationID = "gameserver-19"
	staleLease.SecretRef = "zone-admission-gameserver-19"
	if _, err := store.Replace(context.Background(), first, staleLease); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale Replace error = %v, want ErrConflict", err)
	}
	loaded, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load returned an error: %v", err)
	}
	if loaded != current {
		t.Fatalf("record after stale replace = %+v, want current %+v", loaded, current)
	}
	if len(storage.writes) != 3 ||
		storage.writes[1].Version != "v1" ||
		storage.writes[2].Version != "v1" {
		t.Fatalf("replacement write versions = %+v, want both guarded by v1", storage.writes)
	}
}

func TestReplaceRejectsAClaimedLeaseWithoutWriting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	claimed, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		current.Lease.ExpiresAt.Add(-time.Second),
	)
	if err != nil {
		t.Fatalf("Claim returned an error: %v", err)
	}
	next := validLease()
	next.AttemptID = "attempt-8"
	next.AllocationID = "gameserver-18"
	next.SecretRef = "zone-admission-gameserver-18"

	if _, err := store.Replace(context.Background(), claimed, next); !errors.Is(err, ErrClaimed) {
		t.Fatalf("Replace claimed lease error = %v, want ErrClaimed", err)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("storage writes after claimed replacement = %d, want 2", len(storage.writes))
	}
}

func TestReplaceCannotReplayAStaleUnchangedRecord(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	stale, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	if _, err := store.Claim(
		context.Background(),
		stale,
		testAttemptID,
		stale.Lease.ExpiresAt.Add(-time.Second),
	); err != nil {
		t.Fatalf("Claim returned an error: %v", err)
	}

	if _, err := store.Replace(context.Background(), stale, stale.Lease); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale unchanged Replace error = %v, want ErrConflict", err)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("storage writes after stale unchanged replacement = %d, want 2", len(storage.writes))
	}
}

func TestReplaceReconcilesAReplacementCommittedFromTheSameObservedRecord(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	observed, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	next := validLease()
	next.AttemptID = "attempt-8"
	next.AllocationID = "gameserver-18"
	next.SecretRef = "zone-admission-gameserver-18"
	replaced, err := store.Replace(context.Background(), observed, next)
	if err != nil {
		t.Fatalf("first Replace returned an error: %v", err)
	}

	reconciled, err := store.Replace(context.Background(), observed, next)
	if err != nil {
		t.Fatalf("overlapping Replace returned an error: %v", err)
	}
	if reconciled != replaced {
		t.Fatalf("reconciled replacement = %+v, want committed replacement %+v", reconciled, replaced)
	}
}

func TestConcurrentReplaceLeavesExactlyOneCurrentAttempt(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	candidates := []Lease{validLease(), validLease()}
	candidates[0].AttemptID = "attempt-8"
	candidates[0].AllocationID = "gameserver-18"
	candidates[0].SecretRef = "zone-admission-gameserver-18"
	candidates[1].AttemptID = "attempt-9"
	candidates[1].AllocationID = "gameserver-19"
	candidates[1].SecretRef = "zone-admission-gameserver-19"
	type result struct {
		record Record
		err    error
	}
	start := make(chan struct{})
	results := make(chan result, len(candidates))
	for _, candidate := range candidates {
		go func(lease Lease) {
			<-start
			record, err := store.Replace(context.Background(), current, lease)
			results <- result{record: record, err: err}
		}(candidate)
	}
	close(start)

	var winner Record
	successes, conflicts := 0, 0
	for range candidates {
		got := <-results
		switch {
		case got.err == nil:
			successes++
			winner = got.record
		case errors.Is(got.err, ErrConflict):
			conflicts++
		default:
			t.Fatalf("concurrent Replace returned unexpected error: %v", got.err)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("concurrent Replace results = %d success/%d conflict, want 1/1", successes, conflicts)
	}
	loaded, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load returned an error: %v", err)
	}
	if loaded != winner {
		t.Fatalf("stored concurrent winner = %+v, want successful record %+v", loaded, winner)
	}
}

func TestConcurrentStagingReplaceReusesTheDurableWinnerExpiry(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	current, err = store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("BeginRelease returned an error: %v", err)
	}
	staging := validLease()
	staging.AttemptID = "attempt-8"
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	candidates := []Lease{staging, staging}
	candidates[1].ExpiresAt = candidates[1].ExpiresAt.Add(time.Nanosecond)
	records := make([]Record, len(candidates))
	errs := make([]error, len(candidates))
	var replacements sync.WaitGroup
	replacements.Add(len(candidates))
	for i := range candidates {
		go func() {
			defer replacements.Done()
			records[i], errs[i] = store.Replace(
				context.Background(),
				current,
				candidates[i],
			)
		}()
	}
	replacements.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf(
				"concurrent staging Replace %d returned an error: %v",
				i,
				err,
			)
		}
	}
	if records[0] != records[1] ||
		!records[0].Lease.Staging ||
		records[0].Lease.AttemptID != "attempt-8" {
		t.Fatalf(
			"concurrent staging records = %+v and %+v, want one durable replacement",
			records[0],
			records[1],
		)
	}
}

func TestBeginDispatchUsesObservedVersionAndReplaysTheWinner(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	current, err := store.Create(context.Background(), staging)
	if err != nil {
		t.Fatalf("Create staging lease returned an error: %v", err)
	}

	dispatched, mayDispatch, err := store.BeginDispatch(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("BeginDispatch returned an error: %v", err)
	}
	if !mayDispatch ||
		!dispatched.Lease.Dispatched ||
		dispatched.Lease.DispatchID == "" ||
		dispatched.Version != "v2" {
		t.Fatalf(
			"dispatch barrier = %+v/%t, want dispatched v2 winner",
			dispatched,
			mayDispatch,
		)
	}
	if len(storage.writes) != 2 || storage.writes[1].Version != current.Version {
		t.Fatalf(
			"begin-dispatch writes = %+v, want exact observed version %q",
			storage.writes,
			current.Version,
		)
	}

	replayed, mayRedispatch, err := store.BeginDispatch(
		context.Background(),
		dispatched,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("replayed BeginDispatch returned an error: %v", err)
	}
	if replayed != dispatched || mayRedispatch {
		t.Fatalf(
			"replayed dispatch barrier = %+v/%t, want existing non-dispatching winner",
			replayed,
			mayRedispatch,
		)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("replayed BeginDispatch writes = %d, want 2", len(storage.writes))
	}
}

func TestBeginDispatchReconcilesACommittedBarrierWhoseAcknowledgementWasLost(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	current, err := store.Create(context.Background(), staging)
	if err != nil {
		t.Fatalf("Create staging lease returned an error: %v", err)
	}
	storage.writeAfterCommitErrAt = 2
	storage.writeAfterCommitErr = errors.New("lost dispatch acknowledgement")

	dispatched, mayDispatch, err := store.BeginDispatch(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("BeginDispatch after lost acknowledgement returned an error: %v", err)
	}
	if !mayDispatch ||
		!dispatched.Lease.Dispatched ||
		dispatched.Lease.DispatchID == "" ||
		dispatched.Version != "v2" {
		t.Fatalf(
			"reconciled dispatch barrier = %+v/%t, want identified v2 dispatcher",
			dispatched,
			mayDispatch,
		)
	}
}

func TestFinalizeRefusesAStagingAttemptThatWasNeverDispatched(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	current, err := store.Create(context.Background(), staging)
	if err != nil {
		t.Fatalf("Create staging lease returned an error: %v", err)
	}

	if _, err := store.Finalize(
		context.Background(),
		current,
		validLease(),
	); err == nil {
		t.Fatal("Finalize before BeginDispatch returned nil, want refusal")
	}
	if len(storage.writes) != 1 {
		t.Fatalf("pre-dispatch Finalize writes = %d, want 1", len(storage.writes))
	}
}

func TestBeginReleaseMarksTheCurrentAttemptBeforeExternalCleanup(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	releasing, err := store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("BeginRelease returned an error: %v", err)
	}
	want := validLease()
	want.Releasing = true
	if releasing.Lease != want || releasing.Version != "v2" {
		t.Fatalf("releasing record = %+v, want lease %+v at v2", releasing, want)
	}
	if releasing.State(time.Now()) != StateReleasing {
		t.Fatalf(
			"releasing record state = %q, want %q",
			releasing.State(time.Now()),
			StateReleasing,
		)
	}
	loaded, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load returned an error: %v", err)
	}
	if loaded != releasing {
		t.Fatalf("stored releasing record = %+v, want %+v", loaded, releasing)
	}
	if len(storage.writes) != 2 || storage.writes[1].Version != current.Version {
		t.Fatalf(
			"begin-release writes = %+v, want exact observed version %q",
			storage.writes,
			current.Version,
		)
	}
}

func TestClaimCannotWinAfterReleaseBegins(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	releasing, err := store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("BeginRelease returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		releasing,
		testAttemptID,
		releasing.Lease.ExpiresAt.Add(-time.Second),
	); !errors.Is(err, ErrReleasing) {
		t.Fatalf("Claim after BeginRelease error = %v, want ErrReleasing", err)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("claim after BeginRelease writes = %d, want 2", len(storage.writes))
	}
}

func TestBeginReleaseReplayKeepsTheExistingBarrier(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	releasing, err := store.BeginRelease(
		context.Background(),
		current,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("first BeginRelease returned an error: %v", err)
	}

	replayed, err := store.BeginRelease(
		context.Background(),
		releasing,
		testAttemptID,
	)
	if err != nil {
		t.Fatalf("replayed BeginRelease returned an error: %v", err)
	}
	if replayed != releasing {
		t.Fatalf("replayed release barrier = %+v, want %+v", replayed, releasing)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("replayed BeginRelease writes = %d, want 2", len(storage.writes))
	}
}

func TestClaimAndBeginReleaseLeaveExactlyOneOwner(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	claimedAt := current.Lease.ExpiresAt.Add(-time.Second)
	type result struct {
		operation string
		record    Record
		err       error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	go func() {
		<-start
		record, beginErr := store.BeginRelease(
			context.Background(),
			current,
			testAttemptID,
		)
		results <- result{operation: "release", record: record, err: beginErr}
	}()
	go func() {
		<-start
		record, claimErr := store.Claim(
			context.Background(),
			current,
			testAttemptID,
			claimedAt,
		)
		results <- result{operation: "claim", record: record, err: claimErr}
	}()
	close(start)

	first, second := <-results, <-results
	successes := 0
	for _, got := range []result{first, second} {
		if got.err == nil {
			successes++
			continue
		}
		switch got.operation {
		case "release":
			if !errors.Is(got.err, ErrClaimed) {
				t.Fatalf("losing BeginRelease error = %v, want ErrClaimed", got.err)
			}
		case "claim":
			if !errors.Is(got.err, ErrReleasing) {
				t.Fatalf("losing Claim error = %v, want ErrReleasing", got.err)
			}
		}
	}
	if successes != 1 {
		t.Fatalf(
			"Claim/BeginRelease results = %+v and %+v, want exactly one success",
			first,
			second,
		)
	}
	current, err = store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load returned an error: %v", err)
	}
	if current.Lease.Releasing == !current.Lease.ClaimedAt.IsZero() {
		t.Fatalf(
			"final lease = %+v, want exactly one of releasing or claimed",
			current.Lease,
		)
	}
}

func TestClaimPersistsClaimTimeForTheCurrentAttempt(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	claimedAt := time.Unix(1_999_999_999, 987_654_321).UTC()

	claimed, err := store.Claim(context.Background(), current, testAttemptID, claimedAt)
	if err != nil {
		t.Fatalf("Claim returned an error: %v", err)
	}
	want := validLease()
	want.ClaimedAt = claimedAt
	if claimed.Lease != want || claimed.Version != "v2" {
		t.Fatalf("claimed record = %+v, want lease %+v at v2", claimed, want)
	}
	if len(storage.writes) != 2 || storage.writes[1].Version != "v1" {
		t.Fatalf("claim writes = %+v, want claim guarded by v1", storage.writes)
	}
}

func TestClaimRejectsAStaleAttemptWithoutWriting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		current,
		"attempt-older",
		time.Now(),
	); !errors.Is(err, ErrStaleAttempt) {
		t.Fatalf("stale Claim error = %v, want ErrStaleAttempt", err)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes after stale claim = %d, want 1", len(storage.writes))
	}
}

func TestClaimRejectsAStagingIntentWithoutWriting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	staging := validLease()
	staging.AllocationID = ""
	staging.Observer = 0
	staging.SecretRef = ""
	staging.Staging = true
	current, err := store.Create(context.Background(), staging)
	if err != nil {
		t.Fatalf("Create staging intent returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		staging.ExpiresAt.Add(-time.Second),
	); !errors.Is(err, ErrStaging) {
		t.Fatalf("Claim staging intent error = %v, want ErrStaging", err)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("claim staging writes = %d, want only the create", len(storage.writes))
	}
}

func TestClaimRejectsAnExpiredUnclaimedLease(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		current.Lease.ExpiresAt,
	); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired Claim error = %v, want ErrExpired", err)
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes after expired claim = %d, want 1", len(storage.writes))
	}
}

func TestClaimRejectsAnUnsetClaimTimeWithoutWriting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		time.Time{},
	); err == nil {
		t.Fatal("Claim with an unset timestamp returned nil, want an error")
	}
	if len(storage.writes) != 1 {
		t.Fatalf("storage writes after invalid claim = %d, want 1", len(storage.writes))
	}
}

func TestClaimReplayKeepsTheOriginalClaimWithoutWriting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	claimedAt := current.Lease.ExpiresAt.Add(-time.Second)
	claimed, err := store.Claim(context.Background(), current, testAttemptID, claimedAt)
	if err != nil {
		t.Fatalf("first Claim returned an error: %v", err)
	}

	replayed, err := store.Claim(
		context.Background(),
		claimed,
		testAttemptID,
		claimedAt.Add(500*time.Millisecond),
	)
	if err != nil {
		t.Fatalf("replayed Claim returned an error: %v", err)
	}
	if replayed != claimed {
		t.Fatalf("replayed claim = %+v, want original %+v", replayed, claimed)
	}
	if len(storage.writes) != 2 {
		t.Fatalf("storage writes after claim replay = %d, want 2", len(storage.writes))
	}
}

func TestClaimReconcilesAClaimCommittedFromTheSameObservedRecord(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	observed, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	firstClaimedAt := observed.Lease.ExpiresAt.Add(-time.Second)
	claimed, err := store.Claim(
		context.Background(),
		observed,
		testAttemptID,
		firstClaimedAt,
	)
	if err != nil {
		t.Fatalf("first Claim returned an error: %v", err)
	}

	reconciled, err := store.Claim(
		context.Background(),
		observed,
		testAttemptID,
		firstClaimedAt.Add(500*time.Millisecond),
	)
	if err != nil {
		t.Fatalf("overlapping Claim returned an error: %v", err)
	}
	if reconciled != claimed {
		t.Fatalf("reconciled claim = %+v, want committed claim %+v", reconciled, claimed)
	}
}

func TestClaimReportsConflictWhenTheObservedLeaseWasReleased(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	observed, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	if err := store.Release(
		context.Background(),
		testUserID,
		testReservationID,
		testAttemptID,
	); err != nil {
		t.Fatalf("Release returned an error: %v", err)
	}

	if _, err := store.Claim(
		context.Background(),
		observed,
		testAttemptID,
		observed.Lease.ExpiresAt.Add(-time.Second),
	); !errors.Is(err, ErrConflict) {
		t.Fatalf("Claim after release error = %v, want ErrConflict", err)
	}
}

func TestReleaseDeletesTheCurrentAttemptAndReplaysIdempotently(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	if err := store.Release(
		context.Background(),
		testUserID,
		testReservationID,
		testAttemptID,
	); err != nil {
		t.Fatalf("Release returned an error: %v", err)
	}
	if len(storage.deletes) != 1 {
		t.Fatalf("storage deletes = %d, want 1", len(storage.deletes))
	}
	deletion := storage.deletes[0]
	if deletion.Collection != Collection ||
		deletion.Key != "ff9dd796a2c444815c6712b11b454a52ebe370f5bed18ee266445ce61da7a9e6" ||
		deletion.UserID != "" ||
		deletion.Version != current.Version {
		t.Fatalf("storage deletion = %+v, want exact current lease version", deletion)
	}

	if err := store.Release(
		context.Background(),
		testUserID,
		testReservationID,
		testAttemptID,
	); err != nil {
		t.Fatalf("replayed Release returned an error: %v", err)
	}
	if len(storage.deletes) != 1 {
		t.Fatalf("storage deletes after replay = %d, want 1", len(storage.deletes))
	}
}

func TestReleaseReconcilesNakamaConditionalDeleteRejections(t *testing.T) {
	t.Run("already deleted", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		if _, err := store.Create(context.Background(), validLease()); err != nil {
			t.Fatalf("Create returned an error: %v", err)
		}
		storage.deleteFault = func(
			objects map[string]*api.StorageObject,
			deletes []*runtime.StorageDelete,
		) error {
			deletion := deletes[0]
			delete(
				objects,
				storageID(storageOwner(deletion.UserID), deletion.Collection, deletion.Key),
			)
			return errors.New("Storage delete rejected - not found, version check failed, or permission denied.")
		}

		if err := store.Release(
			context.Background(),
			testUserID,
			testReservationID,
			testAttemptID,
		); err != nil {
			t.Fatalf("Release after a concurrent delete returned an error: %v", err)
		}
	})

	t.Run("concurrently replaced", func(t *testing.T) {
		storage := newMemoryStorage()
		store, err := NewStore(storage)
		if err != nil {
			t.Fatalf("NewStore returned an error: %v", err)
		}
		if _, err := store.Create(context.Background(), validLease()); err != nil {
			t.Fatalf("Create returned an error: %v", err)
		}
		replacement := validLease()
		replacement.AttemptID = "attempt-8"
		replacement.AllocationID = "gameserver-18"
		replacement.SecretRef = "zone-admission-gameserver-18"
		replacementValue, err := json.Marshal(documentFrom(replacement))
		if err != nil {
			t.Fatalf("marshal replacement: %v", err)
		}
		storage.deleteFault = func(
			objects map[string]*api.StorageObject,
			deletes []*runtime.StorageDelete,
		) error {
			deletion := deletes[0]
			id := storageID(storageOwner(deletion.UserID), deletion.Collection, deletion.Key)
			objects[id].Value = string(replacementValue)
			objects[id].Version = "concurrent-version"
			return errors.New("Storage delete rejected - not found, version check failed, or permission denied.")
		}

		if err := store.Release(
			context.Background(),
			testUserID,
			testReservationID,
			testAttemptID,
		); !errors.Is(err, ErrConflict) {
			t.Fatalf("Release after a concurrent replacement error = %v, want ErrConflict", err)
		}
	})
}

func TestReleaseRejectsAStaleAttemptWithoutDeleting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	if _, err := store.Create(context.Background(), validLease()); err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}

	if err := store.Release(
		context.Background(),
		testUserID,
		testReservationID,
		"attempt-older",
	); !errors.Is(err, ErrStaleAttempt) {
		t.Fatalf("stale Release error = %v, want ErrStaleAttempt", err)
	}
	if len(storage.deletes) != 0 {
		t.Fatalf("storage deletes after stale release = %d, want 0", len(storage.deletes))
	}
}

func TestReleaseRejectsAClaimedLeaseWithoutDeleting(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	current, err := store.Create(context.Background(), validLease())
	if err != nil {
		t.Fatalf("Create returned an error: %v", err)
	}
	if _, err := store.Claim(
		context.Background(),
		current,
		testAttemptID,
		current.Lease.ExpiresAt.Add(-time.Second),
	); err != nil {
		t.Fatalf("Claim returned an error: %v", err)
	}

	if err := store.Release(
		context.Background(),
		testUserID,
		testReservationID,
		testAttemptID,
	); !errors.Is(err, ErrClaimed) {
		t.Fatalf("claimed Release error = %v, want ErrClaimed", err)
	}
	if len(storage.deletes) != 0 {
		t.Fatalf("storage deletes after claimed release = %d, want 0", len(storage.deletes))
	}
}

func TestRecordStateDistinguishesNoShowExpiryFromClaimedOwnership(t *testing.T) {
	lease := validLease()
	unclaimed := Record{Lease: lease, Version: "v1"}
	if got := unclaimed.State(lease.ExpiresAt.Add(-time.Nanosecond)); got != StateUnclaimed {
		t.Fatalf("state before expiry = %q, want %q", got, StateUnclaimed)
	}
	if got := unclaimed.State(lease.ExpiresAt); got != StateExpired {
		t.Fatalf("state at expiry = %q, want %q", got, StateExpired)
	}

	lease.ClaimedAt = lease.ExpiresAt.Add(-time.Second)
	claimed := Record{Lease: lease, Version: "v2"}
	if got := claimed.State(lease.ExpiresAt.Add(time.Hour)); got != StateClaimed {
		t.Fatalf("claimed state after no-show deadline = %q, want %q", got, StateClaimed)
	}
}

func TestReclaimExpiredContinuesAfterOneResourceTimesOut(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	first := validLease()
	second := validLease()
	second.UserID = "22222222-2222-4222-8222-222222222222"
	second.ReservationID = "handoff-43"
	second.AttemptID = "attempt-8"
	second.AllocationID = "gameserver-18"
	second.SecretRef = "zone-admission-gameserver-18"
	for _, lease := range []Lease{first, second} {
		if _, err := store.Create(context.Background(), lease); err != nil {
			t.Fatalf("Create lease %q returned an error: %v", lease.AttemptID, err)
		}
	}
	resourceErr := context.DeadlineExceeded
	var attempts []string
	err = store.ReclaimExpired(
		context.Background(),
		first.ExpiresAt,
		func(_ context.Context, lease Lease) error {
			attempts = append(attempts, lease.AttemptID)
			if len(attempts) == 1 {
				return resourceErr
			}
			return nil
		},
	)
	if !errors.Is(err, resourceErr) {
		t.Fatalf("ReclaimExpired error = %v, want resource timeout", err)
	}
	if len(attempts) != 2 {
		t.Fatalf(
			"expiry cleanup attempts = %v, want both records despite first failure",
			attempts,
		)
	}
	for _, lease := range []Lease{first, second} {
		record, loadErr := store.Load(
			context.Background(),
			lease.UserID,
			lease.ReservationID,
		)
		if lease.AttemptID == attempts[0] {
			if loadErr != nil {
				t.Fatalf("load failed cleanup record: %v", loadErr)
			}
			if !record.Lease.Releasing {
				t.Fatalf(
					"failed cleanup record = %+v, want durable releasing barrier",
					record,
				)
			}
			continue
		}
		if !errors.Is(loadErr, ErrNotFound) {
			t.Fatalf(
				"successful cleanup record error = %v, want ErrNotFound",
				loadErr,
			)
		}
	}
}

func TestLoadKeepsSchemaOneLeaseReadableAsNotReleasing(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	key := reservationKey(testUserID, testReservationID)
	storage.objects[storageID(testSystemUserID, Collection, key)] = &api.StorageObject{
		Collection: Collection,
		Key:        key,
		UserId:     testSystemUserID,
		Value: `{"schema":1,"attempt_id":"attempt-7","allocation_id":"gameserver-17",` +
			`"observer":42,"secret_ref":"zone-admission-gameserver-17",` +
			`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null}`,
		Version:         "schema-one",
		PermissionRead:  0,
		PermissionWrite: 0,
	}

	got, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load schema-one lease returned an error: %v", err)
	}
	if got.Lease != validLease() || got.Version != "schema-one" {
		t.Fatalf(
			"loaded schema-one record = %+v, want lease %+v at schema-one",
			got,
			validLease(),
		)
	}
	if got.Lease.Releasing {
		t.Fatalf("schema-one lease loaded as releasing: %+v", got.Lease)
	}
}

func TestEveryShippedLeaseSchemaShapeStaysReadable(t *testing.T) {
	t.Parallel()

	ledgerBytes, err := os.ReadFile(filepath.Join(
		"testdata",
		"shipped_lease_versions.txt",
	))
	if err != nil {
		t.Fatalf("read lease schema ledger: %v", err)
	}
	versions := strings.Fields(string(ledgerBytes))
	if len(versions) == 0 {
		t.Fatal("lease schema ledger is empty")
	}
	for index, rawVersion := range versions {
		version, err := strconv.Atoi(rawVersion)
		if err != nil {
			t.Fatalf("lease schema ledger entry %q: %v", rawVersion, err)
		}
		if version != index+1 {
			t.Fatalf(
				"lease schema ledger[%d] = %d, want %d",
				index,
				version,
				index+1,
			)
		}
		goldenBytes, err := os.ReadFile(filepath.Join(
			"testdata",
			fmt.Sprintf("golden_lease_v%d.json", version),
		))
		if err != nil {
			t.Fatalf("read lease schema %d goldens: %v", version, err)
		}
		var goldens []json.RawMessage
		if err := json.Unmarshal(goldenBytes, &goldens); err != nil {
			t.Fatalf("decode lease schema %d golden set: %v", version, err)
		}
		if len(goldens) == 0 {
			t.Fatalf("lease schema %d has no golden shapes", version)
		}
		for shapeIndex, golden := range goldens {
			var stored document
			if err := json.Unmarshal(golden, &stored); err != nil {
				t.Fatalf(
					"decode lease schema %d shape %d: %v",
					version,
					shapeIndex+1,
					err,
				)
			}
			if stored.Schema != version {
				t.Fatalf(
					"lease schema %d shape %d declares %d",
					version,
					shapeIndex+1,
					stored.Schema,
				)
			}
			if _, err := leaseFrom(
				string(golden),
				testUserID,
				testReservationID,
			); err != nil {
				t.Fatalf(
					"read lease schema %d shape %d: %v",
					version,
					shapeIndex+1,
					err,
				)
			}
		}
	}
	lastVersion, err := strconv.Atoi(versions[len(versions)-1])
	if err != nil || lastVersion != schemaVersion {
		t.Fatalf(
			"lease schema ledger head = %q, writer = %d",
			versions[len(versions)-1],
			schemaVersion,
		)
	}
}

// The legacy refusal keys on whether the document carries the newer keys at
// all, so a value that decodes to the zero flag still counts as carried. A
// duplicate key is the case a decoded field cannot see: encoding/json keeps the
// last occurrence, so a trailing null would otherwise hide the flag in front of
// it.
func TestLoadRefusesLegacySchemaCarryingPostLegacyKeys(t *testing.T) {
	for _, test := range []struct {
		name   string
		prefix string
	}{
		{name: "staging null", prefix: `"staging":null,`},
		{name: "releasing null", prefix: `"releasing":null,`},
		{name: "staging shadowed by a later null", prefix: `"staging":true,"staging":null,`},
		{name: "releasing shadowed by a later null", prefix: `"releasing":true,"releasing":null,`},
		{name: "staging false shadowed by a later null", prefix: `"staging":false,"staging":null,`},
		// encoding/json matches a field name case-insensitively, so these reach
		// the same fields the lowercase spellings do.
		{name: "capitalised releasing", prefix: `"Releasing":true,`},
		{name: "capitalised staging", prefix: `"Staging":true,`},
		{name: "upper-case releasing", prefix: `"RELEASING":true,`},
		{name: "capitalised releasing at its zero value", prefix: `"Releasing":false,`},
		{name: "capitalised releasing as null", prefix: `"Releasing":null,`},
		// The decoder routes U+017F to Staging, but the rune is already lower
		// case, so a lowercasing presence check would miss it. The value is
		// false deliberately: a true flag is refused by a later check anyway,
		// which would leave the case-folding untested.
		{name: "long-s staging at its zero value", prefix: `"ſtaging":false,`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := leaseFrom(
				`{`+test.prefix+`"schema":1,"attempt_id":"attempt-7",`+
					`"allocation_id":"gameserver-17","observer":42,`+
					`"secret_ref":"zone-admission-gameserver-17",`+
					`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null}`,
				testUserID,
				testReservationID,
			); err == nil {
				t.Fatalf("legacy document carrying %s loaded, want an error", test.name)
			}
		})
	}
}

func TestLoadKeepsSchemaTwoLeaseCarryingExplicitFalseFlags(t *testing.T) {
	storage := newMemoryStorage()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatalf("NewStore returned an error: %v", err)
	}
	key := reservationKey(testUserID, testReservationID)
	storage.objects[storageID(testSystemUserID, Collection, key)] = &api.StorageObject{
		Collection: Collection,
		Key:        key,
		UserId:     testSystemUserID,
		Value: `{"schema":2,"attempt_id":"attempt-7","allocation_id":"gameserver-17",` +
			`"observer":42,"secret_ref":"zone-admission-gameserver-17",` +
			`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null,` +
			`"staging":false,"releasing":false}`,
		Version:         "explicit-false",
		PermissionRead:  0,
		PermissionWrite: 0,
	}

	got, err := store.Load(context.Background(), testUserID, testReservationID)
	if err != nil {
		t.Fatalf("Load of explicit-false lease returned an error: %v", err)
	}
	if got.Lease != validLease() || got.Version != "explicit-false" {
		t.Fatalf(
			"loaded explicit-false record = %+v, want lease %+v at explicit-false",
			got,
			validLease(),
		)
	}
	if got.Lease.Staging || got.Lease.Releasing {
		t.Fatalf("explicit-false lease loaded as staging or releasing: %+v", got.Lease)
	}
}

func TestLoadRefusesSchemaTwoCarryingDispatched(t *testing.T) {
	for _, value := range []string{"true", "false", "null"} {
		t.Run(value, func(t *testing.T) {
			_, err := leaseFrom(
				`{"schema":2,"attempt_id":"attempt-7","allocation_id":"gameserver-17",`+
					`"observer":42,"secret_ref":"zone-admission-gameserver-17",`+
					`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null,`+
					`"dispatched":`+value+`}`,
				testUserID,
				testReservationID,
			)
			if err == nil {
				t.Fatalf("schema-two dispatched=%s loaded, want an error", value)
			}
		})
	}
	if _, err := leaseFrom(
		`{"schema":2,"attempt_id":"attempt-7","allocation_id":"gameserver-17",`+
			`"observer":42,"secret_ref":"zone-admission-gameserver-17",`+
			`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null,`+
			`"dispatch_id":"00112233445566778899aabbccddeeff"}`,
		testUserID,
		testReservationID,
	); err == nil {
		t.Fatal("schema-two dispatch identity loaded, want an error")
	}
}

func TestLoadRequiresDispatchIdentityToMatchTheDispatchFlag(t *testing.T) {
	for _, member := range []string{
		`"dispatched":true`,
		`"dispatch_id":"00112233445566778899aabbccddeeff"`,
	} {
		_, err := leaseFrom(
			`{"schema":3,"attempt_id":"attempt-7","allocation_id":"",`+
				`"observer":0,"secret_ref":"",`+
				`"expires_at_nanos":2000000000123456789,"claimed_at_nanos":null,`+
				`"staging":true,`+member+`}`,
			testUserID,
			testReservationID,
		)
		if err == nil {
			t.Fatalf("schema-three mismatched dispatch member %s loaded, want an error", member)
		}
	}
}

func TestLoadRejectsMalformedOrPublicStoredObjects(t *testing.T) {
	for _, test := range []struct {
		name   string
		tamper func(*api.StorageObject)
	}{
		{
			name: "unknown JSON field",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"unexpected":true,`,
					1,
				)
			},
		},
		{
			name: "unsupported schema",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"schema":3`,
					`"schema":4`,
					1,
				)
			},
		},
		{
			name: "schema one cannot encode releasing",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"schema":3`,
					`"schema":1`,
					1,
				)
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"releasing":true,`,
					1,
				)
			},
		},
		{
			name: "schema one cannot carry releasing at its zero value",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"schema":3`,
					`"schema":1`,
					1,
				)
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"releasing":false,`,
					1,
				)
			},
		},
		{
			name: "schema one cannot encode staging",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"schema":3`,
					`"schema":1`,
					1,
				)
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"staging":true,`,
					1,
				)
			},
		},
		{
			name: "schema one cannot carry staging at its zero value",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"schema":3`,
					`"schema":1`,
					1,
				)
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"staging":false,`,
					1,
				)
			},
		},
		{
			name: "player-readable permissions",
			tamper: func(object *api.StorageObject) {
				object.PermissionRead = 1
			},
		},
		{
			name: "player-writable permissions",
			tamper: func(object *api.StorageObject) {
				object.PermissionWrite = 1
			},
		},
		{
			name: "claim at expiry boundary",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"claimed_at_nanos":null`,
					`"claimed_at_nanos":2000000000123456789`,
					1,
				)
			},
		},
		{
			name: "claimed lease cannot also be releasing",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(
					object.GetValue(),
					`"claimed_at_nanos":null`,
					`"claimed_at_nanos":1999999999123456789`,
					1,
				)
				object.Value = strings.Replace(
					object.GetValue(),
					"{",
					`{"releasing":true,`,
					1,
				)
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := newMemoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore returned an error: %v", err)
			}
			if _, err := store.Create(context.Background(), validLease()); err != nil {
				t.Fatalf("Create returned an error: %v", err)
			}
			id := storageID(
				testSystemUserID,
				Collection,
				reservationKey(testUserID, testReservationID),
			)
			storage.mu.Lock()
			test.tamper(storage.objects[id])
			storage.mu.Unlock()

			if _, err := store.Load(
				context.Background(),
				testUserID,
				testReservationID,
			); err == nil {
				t.Fatal("Load of invalid stored object returned nil, want an error")
			}
		})
	}
}

func TestStorageContextCancellationIsPreserved(t *testing.T) {
	for _, test := range []struct {
		name string
		want error
		run  func(*Store, *memoryStorage) error
	}{
		{
			name: "read canceled",
			want: context.Canceled,
			run: func(store *Store, storage *memoryStorage) error {
				storage.readErr = fmt.Errorf("backend detail: %w", context.Canceled)
				_, err := store.Load(context.Background(), testUserID, testReservationID)
				return err
			},
		},
		{
			name: "write deadline",
			want: context.DeadlineExceeded,
			run: func(store *Store, storage *memoryStorage) error {
				storage.writeErr = fmt.Errorf("backend detail: %w", context.DeadlineExceeded)
				_, err := store.Create(context.Background(), validLease())
				return err
			},
		},
		{
			name: "delete canceled",
			want: context.Canceled,
			run: func(store *Store, storage *memoryStorage) error {
				if _, err := store.Create(context.Background(), validLease()); err != nil {
					t.Fatalf("Create returned an error: %v", err)
				}
				storage.deleteErr = fmt.Errorf("backend detail: %w", context.Canceled)
				return store.Release(
					context.Background(),
					testUserID,
					testReservationID,
					testAttemptID,
				)
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := newMemoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore returned an error: %v", err)
			}

			err = test.run(store, storage)
			if !errors.Is(err, test.want) {
				t.Fatalf("storage cancellation = %v, want %v", err, test.want)
			}
			if strings.Contains(err.Error(), "backend detail") {
				t.Fatalf("storage cancellation leaked backend detail: %v", err)
			}
		})
	}
}

func TestStorageFailuresAreSanitized(t *testing.T) {
	for _, test := range []struct {
		name string
		run  func(*Store, *memoryStorage) error
	}{
		{
			name: "read",
			run: func(store *Store, storage *memoryStorage) error {
				storage.readErr = fmt.Errorf(
					"backend exposed %s %s",
					testUserID,
					testReservationID,
				)
				_, err := store.Create(context.Background(), validLease())
				return err
			},
		},
		{
			name: "write",
			run: func(store *Store, storage *memoryStorage) error {
				storage.writeErr = fmt.Errorf(
					"backend exposed %s %s",
					testAttemptID,
					testSecretRef,
				)
				_, err := store.Create(context.Background(), validLease())
				return err
			},
		},
		{
			name: "delete",
			run: func(store *Store, storage *memoryStorage) error {
				if _, err := store.Create(context.Background(), validLease()); err != nil {
					t.Fatalf("Create returned an error: %v", err)
				}
				storage.deleteErr = fmt.Errorf(
					"backend exposed %s %s",
					testAttemptID,
					testSecretRef,
				)
				return store.Release(
					context.Background(),
					testUserID,
					testReservationID,
					testAttemptID,
				)
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := newMemoryStorage()
			store, err := NewStore(storage)
			if err != nil {
				t.Fatalf("NewStore returned an error: %v", err)
			}

			err = test.run(store, storage)
			if !errors.Is(err, ErrStorage) {
				t.Fatalf("storage failure = %v, want ErrStorage", err)
			}
			for _, secret := range []string{
				testUserID,
				testReservationID,
				testAttemptID,
				testSecretRef,
			} {
				if strings.Contains(err.Error(), secret) {
					t.Fatalf("storage failure leaked %q: %v", secret, err)
				}
			}
		})
	}
}
