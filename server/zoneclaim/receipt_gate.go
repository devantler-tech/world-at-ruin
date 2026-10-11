package zoneclaim

import (
	"context"
	"sync"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// ReceiptClaimer authenticates admission and returns its original durable fence.
// Implementations must honor context and never manufacture a new generation on replay.
type ReceiptClaimer interface {
	ClaimWithReceipt(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error)
}

// ReceiptGate explicitly opts into receipt capture. Its first successful claim
// fixes one allocation lifetime, independently of socket upgrade or disconnect.
type ReceiptGate struct {
	mu        sync.Mutex
	admission chan struct{}
	source    BindingSource
	backend   ReceiptClaimer
	receipt   Receipt
	captured  bool
	custodian ReceiptCustodian
	uncertain bool
}

// NewReceiptGate requires explicit receipt-capable admission dependencies and
// constructs one immutable allocation lifetime; it starts no background work.
func NewReceiptGate(source BindingSource, backend ReceiptClaimer) (*ReceiptGate, error) {
	if source == nil || backend == nil {
		return nil, ErrRefused
	}
	gate := &ReceiptGate{source: source, backend: backend, admission: make(chan struct{}, 1)}
	gate.admission <- struct{}{}
	return gate, nil
}

// Claim serializes capture so overlapping admissions cannot adopt two lifetimes.
// Retain a validated receipt even when the subsequent upgrade is refused.
func (g *ReceiptGate) Claim(ctx context.Context, token string, observer sim.EntityID) error {
	if g.custodian != nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
	}
	select {
	case <-ctx.Done():
		return ErrRefused
	case <-g.admission:
	}
	defer func() { g.admission <- struct{}{} }()
	if ctx.Err() != nil {
		return ErrRefused
	}
	g.mu.Lock()
	uncertain := g.uncertain
	g.mu.Unlock()
	if uncertain {
		return ErrRefused
	}
	original, captured := g.Receipt()
	binding, err := g.source.ClaimBinding()
	if err != nil || !g.source.ClaimBindingCurrent(binding) || (captured && !original.Matches(binding, observer)) {
		return ErrRefused
	}
	// Latch before dispatch: a failed claim reply can follow a remote commit.
	// Only the originating custody acknowledgement may clear this latch.
	if g.custodian != nil && !captured {
		g.mu.Lock()
		g.uncertain = true
		g.mu.Unlock()
	}
	receipt, err := g.backend.ClaimWithReceipt(ctx, binding, token, observer)
	if err != nil || !receipt.Matches(binding, observer) || (captured && !original.Equal(receipt)) {
		return ErrRefused
	}
	if !captured {
		g.mu.Lock()
		g.receipt = receipt
		g.captured = true
		g.mu.Unlock()
		if g.custodian != nil {
			if ctx.Err() != nil || g.custodian.RetainOriginal(ctx, receipt) != nil || ctx.Err() != nil {
				return ErrRefused
			}
			g.mu.Lock()
			g.uncertain = false
			g.mu.Unlock()
		}
	}
	if ctx.Err() != nil || !g.source.ClaimBindingCurrent(binding) {
		return ErrRefused
	}
	return nil
}

// Receipt returns a copy of the immutable original fence, never a fresh lookup.
// Custody-aware gates withhold it until the originating custody acknowledgement.
// The caller must establish independent session-end authority before using it.
func (g *ReceiptGate) Receipt() (Receipt, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.uncertain {
		return Receipt{}, false
	}
	return g.receipt, g.captured
}
