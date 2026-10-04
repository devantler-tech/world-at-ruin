package zoneclaim

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

type receiptSource struct {
	binding agones.ClaimBinding
	current bool
}

func (s *receiptSource) ClaimBinding() (agones.ClaimBinding, error) { return s.binding, nil }
func (s *receiptSource) ClaimBindingCurrent(b agones.ClaimBinding) bool {
	return s.current && s.binding == b
}

type receiptFunc func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error)

func (f receiptFunc) ClaimWithReceipt(ctx context.Context, b agones.ClaimBinding, token string, id sim.EntityID) (Receipt, error) {
	return f(ctx, b, token, id)
}

func TestReceiptGateRetainsOriginalFenceAfterUpgradeRefusal(t *testing.T) {
	for _, mode := range []string{"canceled", "binding invalidated"} {
		t.Run(mode, func(t *testing.T) {
			b := agones.ClaimBinding{Namespace: "world", LeaseObjectID: strings.Repeat("0", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-1", GameServerUID: "uid-1"}
			r := Receipt{Namespace: "world", Observer: 1, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "v2", Generation: time.Unix(0, 2000000000000000001)}}
			source := &receiptSource{binding: b, current: true}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			calls := 0
			gate, err := NewReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
				calls++
				if calls == 1 {
					if mode == "canceled" {
						cancel()
					} else {
						source.current = false
					}
				}
				return r, nil
			}))
			if err != nil {
				t.Fatal(err)
			}
			if gate.Claim(ctx, "token", 1) == nil {
				t.Fatal("late admission accepted")
			}
			if retained, ok := gate.Receipt(); !ok || retained != r {
				t.Fatal("failed upgrade discarded committed receipt")
			}
			source.current = true
			if err := gate.Claim(t.Context(), "token", 1); err != nil {
				t.Fatal("identical reconnect refused")
			}
			r.Fence.LeaseVersion = "v3"
			if gate.Claim(t.Context(), "token", 1) == nil {
				t.Fatal("reconnect adopted a different generation")
			}
			source.binding.GameServerUID = "uid-2"
			before := calls
			if gate.Claim(t.Context(), "token", 1) == nil || calls != before {
				t.Fatal("changed lifetime reached claim backend")
			}
			if retained, _ := gate.Receipt(); retained.Fence.LeaseVersion != "v2" {
				t.Fatal("original receipt overwritten")
			}
		})
	}
}

func TestReceiptGateConcurrentAdmissionKeepsOneFence(t *testing.T) {
	b := agones.ClaimBinding{Namespace: "world", LeaseObjectID: strings.Repeat("0", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-1", GameServerUID: "uid-1"}
	r := Receipt{Namespace: "world", Observer: 1, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "v2", Generation: time.Unix(0, 2000000000000000001)}}
	var calls atomic.Int32
	gate, err := NewReceiptGate(&receiptSource{binding: b, current: true}, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
		if calls.Add(1) == 2 {
			r.Fence.LeaseVersion = "v3"
		}
		return r, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var success atomic.Int32
	for range 2 {
		wg.Go(func() {
			if gate.Claim(t.Context(), "token", 1) == nil {
				success.Add(1)
			}
		})
	}
	wg.Wait()
	retained, ok := gate.Receipt()
	if !ok || retained.Fence.LeaseVersion != "v2" || success.Load() != 1 {
		t.Fatal("concurrent capture replaced allocation lifetime")
	}
}

func TestReceiptGateCanceledWaiterDoesNotWaitForAnotherRPC(t *testing.T) {
	b := agones.ClaimBinding{Namespace: "world", LeaseObjectID: strings.Repeat("0", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-1", GameServerUID: "uid-1"}
	entered, release := make(chan struct{}), make(chan struct{})
	gate, err := NewReceiptGate(&receiptSource{binding: b, current: true}, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
		close(entered)
		<-release
		return Receipt{}, ErrRefused
	}))
	if err != nil {
		t.Fatal(err)
	}
	first := make(chan error, 1)
	go func() { first <- gate.Claim(t.Context(), "token", 1) }()
	<-entered
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	second := make(chan error, 1)
	go func() { second <- gate.Claim(ctx, "token", 1) }()
	select {
	case err := <-second:
		if err == nil {
			t.Error("canceled waiter admitted")
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("canceled waiter blocked behind unrelated RPC")
	}
	close(release)
	<-first
}
