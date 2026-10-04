package nakamaruntime

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamaauth"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
)

type blockingAllocator struct{ started chan struct{} }

// Allocate waits for cancellation so the RPC's timeout and shutdown behavior are observable.
func (a blockingAllocator) Allocate(ctx context.Context, _ handoff.AllocationRequest) (handoff.Allocation, error) {
	close(a.started)
	<-ctx.Done()
	return handoff.Allocation{}, handoff.RetainAllocationOutcome(ctx.Err())
}

// Release is inert because this fixture retains an uncertain allocation outcome on cancellation.
func (blockingAllocator) Release(context.Context, handoff.AllocationRequest) error { return nil }

// rpcServiceFixture preserves the real session verifier and handoff service.
func rpcServiceFixture(t *testing.T, allocator handoff.Allocator) (*moduleStorage, *handoff.Service) {
	t.Helper()
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	service, err := handoff.NewService(nakamaauth.NewRuntimeVerifier(storage), allocator, handoff.Config{ZoneDomain: "zones.example"})
	if err != nil {
		t.Fatal(err)
	}
	return storage, service
}

// TestRPCBoundsCallsAndCancelsOnShutdown requires allocator calls to preserve deadline and lifecycle cancellation status codes.
func TestRPCBoundsCallsAndCancelsOnShutdown(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(map[bool]string{false: "deadline", true: "shutdown"}[shutdown], func(t *testing.T) {
			allocator := blockingAllocator{started: make(chan struct{})}
			storage, service := rpcServiceFixture(t, allocator)
			life, cancel := context.WithCancel(context.Background())
			defer cancel()
			timeout := 50 * time.Millisecond
			if shutdown {
				timeout = time.Minute
			}
			handler := rpcHandler(life, &handlerGate{}, service, timeout)
			result := make(chan error, 1)
			go func() {
				_, err := handler(signedContext(), nil, nil, storage, `{}`)
				result <- err
			}()
			select {
			case <-allocator.started:
			case <-time.After(time.Second):
				t.Fatal("RPC never reached allocation")
			}
			want := codes.DeadlineExceeded
			if shutdown {
				cancel()
				want = codes.Canceled
			}
			select {
			case err := <-result:
				var failure *runtime.Error
				if !errors.As(err, &failure) || failure.Code != int(want) {
					t.Fatalf("RPC did not preserve cancellation: %#v", err)
				}
			case <-time.After(time.Second):
				t.Fatal("RPC ignored its deadline or shutdown")
			}
		})
	}
}

// TestRPCCannotAllocateWithoutAuthenticatedSession rejects anonymous and expired sessions before any allocator work begins.
func TestRPCCannotAllocateWithoutAuthenticatedSession(t *testing.T) {
	allocator := blockingAllocator{started: make(chan struct{})}
	storage, service := rpcServiceFixture(t, allocator)
	handler := rpcHandler(context.Background(), &handlerGate{}, service, time.Second)
	for _, ctx := range []context.Context{context.Background(), context.WithValue(signedContext(), runtime.RUNTIME_CTX_USER_SESSION_EXP, time.Now().Add(-time.Minute).Unix())} {
		result, err := handler(ctx, nil, nil, storage, `{}`)
		var failure *runtime.Error
		if result != "" || !errors.As(err, &failure) || failure.Code != int(codes.Unauthenticated) {
			t.Fatalf("anonymous/expired RPC: %#v", err)
		}
	}
	select {
	case <-allocator.started:
		t.Fatal("unauthenticated RPC allocated a GameServer")
	default:
	}
}

// cleanupAllocator models a coordinator that keeps fencing and cleaning up
// under a detached context for a while after its caller is cancelled.
type cleanupAllocator struct {
	started  chan struct{}
	finished atomic.Bool
}

func (a *cleanupAllocator) Allocate(ctx context.Context, _ handoff.AllocationRequest) (handoff.Allocation, error) {
	close(a.started)
	<-ctx.Done()
	time.Sleep(100 * time.Millisecond)
	a.finished.Store(true)
	return handoff.Allocation{}, handoff.RetainAllocationOutcome(ctx.Err())
}
func (*cleanupAllocator) Release(context.Context, handoff.AllocationRequest) error { return nil }

// TestShutdownWaitsForInFlightHandlersAndRefusesNewOnes waits for cancelled handlers' cleanup before refusing subsequent requests.
func TestShutdownWaitsForInFlightHandlersAndRefusesNewOnes(t *testing.T) {
	allocator := &cleanupAllocator{started: make(chan struct{})}
	storage, service := rpcServiceFixture(t, allocator)
	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	handlers := &handlerGate{}
	handler := rpcHandler(life, handlers, service, time.Minute)
	go func() { _, _ = handler(signedContext(), nil, nil, storage, `{}`) }()
	select {
	case <-allocator.started:
	case <-time.After(time.Second):
		t.Fatal("RPC never reached allocation")
	}
	reconciler := make(chan struct{})
	close(reconciler)
	drain(context.Background(), cancel, handlers, reconciler)
	if !allocator.finished.Load() {
		t.Fatal("shutdown returned before the in-flight handler finished its cleanup")
	}
	_, err := handler(signedContext(), nil, nil, storage, `{}`)
	var failure *runtime.Error
	if !errors.As(err, &failure) || failure.Code != int(codes.Unavailable) {
		t.Fatalf("handler admitted after shutdown: %#v", err)
	}
}

func TestShutdownWaitIsBoundedByItsContext(t *testing.T) {
	handlers := &handlerGate{}
	if !handlers.enter() {
		t.Fatal("open gate refused a handler")
	}
	shutdownCtx, stop := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer stop()
	returned := make(chan struct{})
	reconciler := make(chan struct{})
	var finished <-chan struct{}
	go func() {
		finished = drain(shutdownCtx, func() {}, handlers, reconciler)
		close(returned)
	}()
	select {
	case <-returned:
	case <-time.After(time.Second):
		t.Fatal("shutdown ignored its deadline while a handler was stuck")
	}
	select {
	case <-finished:
		t.Fatal("hook timeout was mistaken for actual drain completion")
	default:
	}
	handlers.leave()
	close(reconciler)
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("returned worker and handler never completed the drain")
	}
}
