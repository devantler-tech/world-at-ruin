package nakamageneration

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// faultStorage changes only responses around the shared fake's real mutations.
type faultStorage struct {
	*nakamastoragetest.Fake
	read  func(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error)
	write func(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error)
}

func (f *faultStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	if f.read != nil {
		return f.read(ctx, reads)
	}
	return f.Fake.StorageRead(ctx, reads)
}

func (f *faultStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	if f.write != nil {
		return f.write(ctx, writes)
	}
	return f.Fake.StorageWrite(ctx, writes)
}

func TestCreateOpenReconcilesEveryMalformedAcknowledgement(t *testing.T) {
	t.Parallel()
	cases := map[string]func([]*api.StorageObjectAck) []*api.StorageObjectAck{
		"absent":     func([]*api.StorageObjectAck) []*api.StorageObjectAck { return nil },
		"nil":        func([]*api.StorageObjectAck) []*api.StorageObjectAck { return []*api.StorageObjectAck{nil} },
		"multiple":   func(a []*api.StorageObjectAck) []*api.StorageObjectAck { return append(a, a[0]) },
		"collection": func(a []*api.StorageObjectAck) []*api.StorageObjectAck { a[0].Collection = "foreign"; return a },
		"key":        func(a []*api.StorageObjectAck) []*api.StorageObjectAck { a[0].Key = "another-generation"; return a },
		"owner": func(a []*api.StorageObjectAck) []*api.StorageObjectAck {
			a[0].UserId = "11111111-1111-4111-8111-111111111111"
			return a
		},
		"empty-version":    func(a []*api.StorageObjectAck) []*api.StorageObjectAck { a[0].Version = ""; return a },
		"wildcard-version": func(a []*api.StorageObjectAck) []*api.StorageObjectAck { a[0].Version = "*"; return a },
		"long-version": func(a []*api.StorageObjectAck) []*api.StorageObjectAck {
			a[0].Version = strings.Repeat("v", 1025)
			return a
		},
		"whitespace-version": func(a []*api.StorageObjectAck) []*api.StorageObjectAck { a[0].Version = "v 1"; return a },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			storage.write = func(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
				acks, err := storage.Fake.StorageWrite(ctx, writes)
				if err != nil {
					return nil, err
				}
				return mutate(acks), nil
			}
			got, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
			if err != nil || got.Version != "v1" || storage.ReadCalls != 2 || len(storage.WriteCalls) != 1 {
				t.Fatalf("did not recover committed record after %s ack: %+v, %v", name, got, err)
			}
		})
	}
}

func TestCreateOpenKeepsUnresolvedWritesIndeterminate(t *testing.T) {
	t.Parallel()
	for _, outcome := range []string{"absent", "read-error", "corrupt", "conflict", "lost-ack", "ack-and-error"} {
		t.Run(outcome, func(t *testing.T) {
			t.Parallel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			store := newTestStore(t, storage)
			storage.write = func(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
				if outcome == "absent" {
					return nil, errors.New("secret backend detail")
				}
				if outcome == "conflict" {
					other := newTestStore(t, storage.Fake)
					if _, err := other.CreateOpen(ctx, "generation-1", []string{"pod-b"}); err != nil {
						t.Fatal(err)
					}
					return nil, runtime.ErrStorageRejectedVersion
				}
				acks, err := storage.Fake.StorageWrite(ctx, writes)
				if err != nil {
					t.Fatal(err)
				}
				if outcome == "read-error" {
					storage.ReadErr = errors.New("secret backend detail")
				}
				if outcome == "corrupt" {
					object, _ := storage.Get(Collection, "generation-1", "")
					object.Value = "unreadable"
					storage.Seed(object)
				}
				if outcome == "ack-and-error" {
					return acks, errors.New("secret backend detail")
				}
				return nil, errors.New("secret backend detail")
			}
			got, err := store.CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
			switch outcome {
			case "lost-ack", "ack-and-error":
				if err != nil || got.Version != "v1" {
					t.Fatalf("durable match lost: %+v, %v", got, err)
				}
			case "conflict":
				if !errors.Is(err, ErrConflict) {
					t.Fatalf("conflict misclassified: %v", err)
				}
			default:
				if !errors.Is(err, ErrIndeterminate) || errors.Is(err, ErrNotFound) || !reflect.DeepEqual(got, Record{}) {
					t.Fatalf("uncertainty became a definite outcome: %+v, %v", got, err)
				}
			}
			// A new instance can recover a later-visible commit using the same ID.
			if outcome == "read-error" {
				storage.ReadErr = nil
				recovered, recoveryErr := newTestStore(t, storage.Fake).CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
				if recoveryErr != nil || recovered.Version != "v1" || len(storage.WriteCalls) != 1 {
					t.Fatalf("restart did not adopt the unresolved commit: %+v, %v", recovered, recoveryErr)
				}
			}
		})
	}
}

func TestReadbackIsDetachedBoundedAndRetainsContextValues(t *testing.T) {
	t.Parallel()
	type contextKey struct{}
	ctx, cancel := context.WithCancel(context.WithValue(t.Context(), contextKey{}, "trace-id"))
	defer cancel()
	storage := &faultStorage{Fake: nakamastoragetest.New()}
	storage.AfterWrite = func(int) error { cancel(); return context.Canceled }
	readCalls := 0
	storage.read = func(readCtx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
		readCalls++
		if readCalls == 2 {
			deadline, bounded := readCtx.Deadline()
			if readCtx.Err() != nil || !bounded || time.Until(deadline) <= 0 || time.Until(deadline) > 5*time.Second ||
				readCtx.Value(contextKey{}) != "trace-id" {
				t.Fatal("readback lost its detached bounded context")
			}
		}
		return storage.Fake.StorageRead(readCtx, reads)
	}
	if _, err := newTestStore(t, storage).CreateOpen(ctx, "generation-1", []string{"pod-a"}); err != nil {
		t.Fatal(err)
	}
	if readCalls != 2 {
		t.Fatalf("readback calls = %d", readCalls)
	}
}

func TestCancellationBeforeCreateDoesNotWrite(t *testing.T) {
	t.Parallel()
	for _, cancelDuringRead := range []bool{false, true} {
		t.Run(map[bool]string{false: "before-read", true: "during-read"}[cancelDuringRead], func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			if cancelDuringRead {
				storage.read = func(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error) { cancel(); return nil, nil }
			} else {
				cancel()
			}
			_, err := newTestStore(t, storage).CreateOpen(ctx, "generation-1", []string{"pod-a"})
			if !errors.Is(err, context.Canceled) || len(storage.WriteCalls) != 0 {
				t.Fatalf("cancelled create dispatched: %v", err)
			}
		})
	}
}

func TestLoadPreservesCancellationDuringAnEmptyRead(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	storage := &faultStorage{Fake: nakamastoragetest.New()}
	storage.read = func(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error) { cancel(); return nil, nil }
	_, err := newTestStore(t, storage).Load(ctx, "generation-1")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled read reported absence: %v", err)
	}
}

func TestUnresolvedCreatePreservesCancellationWithoutBackendDetails(t *testing.T) {
	t.Parallel()
	for _, cause := range []error{context.Canceled, context.DeadlineExceeded} {
		t.Run(cause.Error(), func(t *testing.T) {
			t.Parallel()
			storage := &faultStorage{Fake: nakamastoragetest.New()}
			storage.write = func(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
				return nil, errors.Join(cause, errors.New("private backend detail"))
			}
			_, err := newTestStore(t, storage).CreateOpen(t.Context(), "generation-1", []string{"pod-a"})
			if !errors.Is(err, ErrIndeterminate) || !errors.Is(err, cause) || strings.Contains(err.Error(), "private backend detail") {
				t.Fatalf("uncertain cancellation lost or exposed backend detail: %v", err)
			}
		})
	}
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	storage := &faultStorage{Fake: nakamastoragetest.New()}
	storage.write = func(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
		cancel()
		return nil, errors.New("private backend detail")
	}
	_, err := newTestStore(t, storage).CreateOpen(ctx, "generation-1", []string{"pod-a"})
	if !errors.Is(err, ErrIndeterminate) || !errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "private backend detail") {
		t.Fatalf("caller cancellation lost or exposed backend detail: %v", err)
	}
}
