package nakamaruntime

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamaauth"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
)

type blockingAllocator struct{ started chan struct{} }

func (a blockingAllocator) Allocate(ctx context.Context, _ handoff.AllocationRequest) (handoff.Allocation, error) {
	close(a.started)
	<-ctx.Done()
	return handoff.Allocation{}, handoff.RetainAllocationOutcome(ctx.Err())
}
func (blockingAllocator) Release(context.Context, handoff.AllocationRequest) error { return nil }

func TestRPCBoundsCallsAndCancelsOnShutdown(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(map[bool]string{false: "deadline", true: "shutdown"}[shutdown], func(t *testing.T) {
			allocator := blockingAllocator{started: make(chan struct{})}
			storage := &moduleStorage{Fake: nakamastoragetest.New()}
			service, err := handoff.NewService(nakamaauth.NewRuntimeVerifier(storage), allocator, handoff.Config{ZoneDomain: "zones.example"})
			if err != nil {
				t.Fatal(err)
			}
			life, cancel := context.WithCancel(context.Background())
			defer cancel()
			timeout := 50 * time.Millisecond
			if shutdown {
				timeout = time.Minute
			}
			handler := rpcHandler(life, service, timeout)
			result := make(chan error, 1)
			go func() {
				_, err := handler(signedContext(), nil, nil, storage, `{"reservation_id":"deadline"}`)
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

func TestRPCCannotAllocateWithoutAuthenticatedSession(t *testing.T) {
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	allocator := blockingAllocator{started: make(chan struct{})}
	service, err := handoff.NewService(nakamaauth.NewRuntimeVerifier(storage), allocator, handoff.Config{ZoneDomain: "zones.example"})
	if err != nil {
		t.Fatal(err)
	}
	handler := rpcHandler(context.Background(), service, time.Second)
	for _, ctx := range []context.Context{context.Background(), context.WithValue(signedContext(), runtime.RUNTIME_CTX_USER_SESSION_EXP, time.Now().Add(-time.Minute).Unix())} {
		result, err := handler(ctx, nil, nil, storage, `{"reservation_id":"unauthenticated"}`)
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
