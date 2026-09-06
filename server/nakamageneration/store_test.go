package nakamageneration

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

func newTestStore(t *testing.T, storage nakamastorage.Client) *Store {
	t.Helper()
	store, err := NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestCreateOpenPersistsPrivateCanonicalMembershipAndSurvivesRestart(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	store := newTestStore(t, storage)
	members := []string{"pod-b", "pod-a"}
	got, err := store.CreateOpen(t.Context(), "generation-1", members)
	if err != nil {
		t.Fatal(err)
	}
	if got.GenerationID != "generation-1" || got.State != "open" || got.Version != "v1" ||
		len(got.MemberSetDigest) != 64 || !reflect.DeepEqual(got.MemberPodUIDs, []string{"pod-a", "pod-b"}) {
		t.Fatalf("incomplete durable generation: %+v", got)
	}
	if !reflect.DeepEqual(members, []string{"pod-b", "pod-a"}) {
		t.Fatal("sorted the caller's slice")
	}
	object, exists := storage.Get(Collection, "generation-1", "")
	if !exists || object.UserID != nakamastorage.SystemOwnerID || object.PermissionRead != 0 || object.PermissionWrite != 0 {
		t.Fatalf("generation is not private/system-owned: %+v", object)
	}
	if len(storage.WriteCalls) != 1 || len(storage.WriteCalls[0]) != 1 || storage.WriteCalls[0][0].Version != "*" {
		t.Fatalf("create is not one conditional mutation: %+v", storage.WriteCalls)
	}
	members[0] = "caller-changed"
	restarted := newTestStore(t, storage)
	replayed, err := restarted.CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-b"})
	if err != nil || !reflect.DeepEqual(replayed, got) || len(storage.WriteCalls) != 1 {
		t.Fatalf("restart rewrote or lost the generation: %+v, %v", replayed, err)
	}
	got.MemberPodUIDs[0] = "result-changed"
	loaded, err := restarted.Load(t.Context(), "generation-1")
	if err != nil || !reflect.DeepEqual(loaded, replayed) {
		t.Fatalf("result alias leaked: %+v, %v", loaded, err)
	}
	if _, err := restarted.CreateOpen(t.Context(), "generation-1", []string{"pod-c"}); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflicting membership was accepted: %v", err)
	}
	after, _ := storage.Get(Collection, "generation-1", "")
	if after != object || len(storage.WriteCalls) != 1 {
		t.Fatal("conflict changed durable state")
	}
}

func TestCreateOpenResolvesCommittedWriteAfterCancellation(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	storage.AfterWrite = func(int) error { cancel(); return errors.New("private transport failure") }
	got, err := newTestStore(t, storage).CreateOpen(ctx, "generation-1", []string{"pod-a"})
	if err != nil || got.Version != "v1" || got.GenerationID != "generation-1" {
		t.Fatalf("committed generation was lost after cancellation: %+v, %v", got, err)
	}
	if storage.ReadCalls != 2 || len(storage.WriteCalls) != 1 {
		t.Fatal("did not reconcile the single uncertain create")
	}
}

func TestCreateOpenRefusesDuplicateMembersBeforeStorage(t *testing.T) {
	t.Parallel()
	storage := nakamastoragetest.New()
	_, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a", "pod-a"})
	if !errors.Is(err, ErrInvalidArgument) || storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
		t.Fatalf("duplicate membership reached storage: %v", err)
	}
}
