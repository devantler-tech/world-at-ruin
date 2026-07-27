package nakamalease

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
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
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
	testAllocationID  = "gameserver-17"
	testSecretRef     = "zone-admission-gameserver-17"
)

type memoryStorage struct {
	mu        sync.Mutex
	objects   map[string]*api.StorageObject
	writes    []*runtime.StorageWrite
	deletes   []*runtime.StorageDelete
	version   int
	readErr   error
	writeErr  error
	deleteErr error
}

func newMemoryStorage() *memoryStorage {
	return &memoryStorage{
		objects: make(map[string]*api.StorageObject),
	}
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
		if object := s.objects[storageID(read.UserID, read.Collection, read.Key)]; object != nil {
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
		s.writes = append(s.writes, cloneStorageWrite(write))
		id := storageID(write.UserID, write.Collection, write.Key)
		current := s.objects[id]
		switch {
		case write.Version == "*" && current != nil:
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
			UserId:          write.UserID,
			Value:           write.Value,
			Version:         version,
			PermissionRead:  int32(write.PermissionRead),
			PermissionWrite: int32(write.PermissionWrite),
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     write.UserID,
			Version:    version,
		})
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
	for _, deletion := range deletes {
		copy := *deletion
		s.deletes = append(s.deletes, &copy)
		id := storageID(deletion.UserID, deletion.Collection, deletion.Key)
		current := s.objects[id]
		if current == nil || current.GetVersion() != deletion.Version {
			return runtime.ErrStorageRejectedVersion
		}
		delete(s.objects, id)
	}
	return nil
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
		write.Key != "e3559902024d49de0309dc1805bf73d40ddd2e30a414a35771e428ed2a4cdccb" ||
		write.UserID != testUserID {
		t.Fatalf(
			"storage identity = %q/%q/%q, want private user-scoped hashed reservation",
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
	if got := string(write.Value); got == "" ||
		strings.Contains(got, testReservationID) ||
		strings.Contains(got, testUserID) {
		t.Fatalf("stored lease exposes raw storage identity: %q", got)
	}

	var document map[string]any
	if err := json.Unmarshal([]byte(write.Value), &document); err != nil {
		t.Fatalf("decode stored lease: %v", err)
	}
	want := map[string]any{
		"schema":           float64(1),
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
		deletion.Key != "e3559902024d49de0309dc1805bf73d40ddd2e30a414a35771e428ed2a4cdccb" ||
		deletion.UserID != testUserID ||
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

func TestLoadRejectsMalformedOrPublicStoredObjects(t *testing.T) {
	for _, test := range []struct {
		name   string
		tamper func(*api.StorageObject)
	}{
		{
			name: "unknown JSON field",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(object.Value, "{", `{"unexpected":true,`, 1)
			},
		},
		{
			name: "unsupported schema",
			tamper: func(object *api.StorageObject) {
				object.Value = strings.Replace(object.Value, `"schema":1`, `"schema":2`, 1)
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
			id := storageID(testUserID, Collection, reservationKey(testReservationID))
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
