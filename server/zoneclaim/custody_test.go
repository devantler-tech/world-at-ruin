package zoneclaim

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

type custodianFunc func(context.Context, Receipt) error

func (f custodianFunc) RetainOriginal(ctx context.Context, r Receipt) error { return f(ctx, r) }

func custodyFixture() (*receiptSource, Receipt) {
	b := agones.ClaimBinding{Namespace: "world", LeaseObjectID: strings.Repeat("0", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-1", GameServerUID: "uid-1"}
	r := Receipt{Namespace: b.Namespace, Observer: 1, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "original-v2", Generation: time.Unix(0, 2000000000000000001)}}
	return &receiptSource{binding: b, current: true}, r
}

// An initial uncertain remote claim must not become a replay-derived receipt.
func TestCustodyGateQuarantinesUncertainInitialClaim(t *testing.T) {
	for _, mode := range []string{"error", "malformed receipt", "canceled acknowledgement"} {
		t.Run(mode, func(t *testing.T) {
			source, original := custodyFixture()
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			calls, custodyCalls := 0, 0
			gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
				calls++
				if calls > 1 {
					return original, nil
				}
				switch mode {
				case "error":
					return Receipt{}, errors.New("claim acknowledgement lost")
				case "malformed receipt":
					bad := original
					bad.Fence.LeaseVersion = "*"
					return bad, nil
				default:
					cancel()
					return original, nil
				}
			}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(context.Context, Receipt) error { custodyCalls++; return nil })})
			if err != nil {
				t.Fatal(err)
			}
			if gate.Claim(ctx, "token", 1) == nil {
				t.Fatal("uncertain initial claim admitted")
			}
			for range 3 {
				if gate.Claim(t.Context(), "token", 1) == nil {
					t.Fatal("uncertain original claim replayed into admission")
				}
			}
			if r, ok := gate.Receipt(); ok || r != (Receipt{}) || calls != 1 || custodyCalls != 0 {
				t.Fatal("quarantined claim exported or replayed receipt material")
			}
		})
	}
}

func TestCustodyGateRefusesDisabledAndMissingDependencies(t *testing.T) {
	source, r := custodyFixture()
	backend := receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) { return r, nil })
	custodian := custodianFunc(func(context.Context, Receipt) error { return nil })
	for _, cfg := range []CustodyConfig{{}, {Custodian: custodian}, {Enabled: true}} {
		if gate, err := NewCustodiedReceiptGate(source, backend, cfg); err == nil || gate != nil {
			t.Fatal("disabled or missing custody constructed an admission gate")
		}
	}
	for _, mode := range []string{"source", "backend"} {
		var bindingSource BindingSource = source
		var claimer ReceiptClaimer = backend
		if mode == "source" {
			bindingSource = nil
		} else {
			claimer = nil
		}
		if gate, err := NewCustodiedReceiptGate(bindingSource, claimer, CustodyConfig{Enabled: true, Custodian: custodian}); err == nil || gate != nil {
			t.Fatal("missing claim dependency constructed custody gate")
		}
	}
}

func TestCustodyGateWithholdsAdmissionAndReceiptUntilAcknowledgement(t *testing.T) {
	source, original := custodyFixture()
	entered, release := make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	var claimCalls, custodyCalls atomic.Int32
	gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
		claimCalls.Add(1)
		return original, nil
	}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(ctx context.Context, r Receipt) error {
		custodyCalls.Add(1)
		if r != original {
			return errors.New("substituted original receipt")
		}
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- gate.Claim(ctx, "token", 1) }()
	select {
	case <-entered:
	case err := <-done:
		t.Fatalf("admission escaped without custody: %v", err)
	case <-ctx.Done():
		t.Fatal("custody was not reached within bound")
	}
	if r, ok := gate.Receipt(); ok || r != (Receipt{}) {
		t.Error("pending custody exported original receipt")
	}
	canceled, stop := context.WithCancel(t.Context())
	stop()
	if gate.Claim(canceled, "token", 1) == nil {
		t.Error("canceled waiter admitted")
	}
	select {
	case <-done:
		t.Error("pending custody released admission")
	default:
	}
	close(release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("acknowledged custody did not finish")
	}
	if r, ok := gate.Receipt(); !ok || r != original {
		t.Fatal("acknowledged original receipt was not retained")
	}
	if err := gate.Claim(t.Context(), "token", 1); err != nil || claimCalls.Load() != 2 || custodyCalls.Load() != 1 {
		t.Fatal("reconnect refreshed custody or bypassed claim authentication")
	}
}

func TestCustodyGateQuarantinesFailedCustody(t *testing.T) {
	for _, mode := range []string{"lost acknowledgement", "canceled acknowledgement"} {
		t.Run(mode, func(t *testing.T) {
			source, original := custodyFixture()
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			calls, custodyCalls := 0, 0
			gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
				calls++
				return original, nil
			}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(context.Context, Receipt) error {
				custodyCalls++
				if mode == "canceled acknowledgement" {
					cancel()
					return nil
				}
				return errors.New("custody acknowledgement lost")
			})})
			if err != nil {
				t.Fatal(err)
			}
			if gate.Claim(ctx, "token", 1) == nil {
				t.Fatal("uncertain custody admitted")
			}
			for range 3 {
				if gate.Claim(t.Context(), "token", 1) == nil {
					t.Fatal("custody retry restored admission")
				}
			}
			if r, ok := gate.Receipt(); ok || r != (Receipt{}) || calls != 1 || custodyCalls != 1 {
				t.Fatal("uncertain custody retried or exported a receipt")
			}
		})
	}
}

func TestCustodyGateReconnectNeverRefreshesOriginal(t *testing.T) {
	for _, mode := range []string{"unauthenticated token", "changed receipt", "invalidated binding", "invalidated during custody"} {
		t.Run(mode, func(t *testing.T) {
			source, original := custodyFixture()
			calls := 0
			gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(_ context.Context, _ agones.ClaimBinding, token string, _ sim.EntityID) (Receipt, error) {
				calls++
				if token != "token" {
					return Receipt{}, ErrRefused
				}
				returned := original
				if calls > 1 && mode == "changed receipt" {
					returned.Fence.Generation = returned.Fence.Generation.Add(time.Nanosecond)
				}
				return returned, nil
			}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(context.Context, Receipt) error {
				if mode == "invalidated during custody" {
					source.current = false
				}
				return nil
			})})
			if err != nil {
				t.Fatal(err)
			}
			firstErr := gate.Claim(t.Context(), "token", 1)
			if (firstErr != nil) != (mode == "invalidated during custody") {
				t.Fatal("first admission ignored source validity")
			}
			token := "token"
			switch mode {
			case "unauthenticated token":
				token = "other"
			case "invalidated binding":
				source.current = false
			}
			if gate.Claim(t.Context(), token, 1) == nil {
				t.Fatal("invalid reconnect admitted")
			}
			if retained, ok := gate.Receipt(); !ok || retained != original {
				t.Fatal("refused reconnect discarded or refreshed acknowledged custody")
			}
		})
	}
}

func TestCustodyGateConcurrentRetriesCannotRecoverUncertainCustody(t *testing.T) {
	source, original := custodyFixture()
	var calls, custodyCalls atomic.Int32
	gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
		calls.Add(1)
		return original, nil
	}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(context.Context, Receipt) error {
		custodyCalls.Add(1)
		return ErrRefused
	})})
	if err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for range 12 {
		group.Go(func() {
			if gate.Claim(t.Context(), "token", 1) == nil {
				t.Error("concurrent retry admitted uncertain custody")
			}
		})
	}
	group.Wait()
	if calls.Load() != 1 || custodyCalls.Load() != 1 {
		t.Fatal("concurrent retry replayed original claim or custody")
	}
}

func TestCustodyGatePreDispatchRefusalDoesNotConsumeLifetime(t *testing.T) {
	source, original := custodyFixture()
	gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) (Receipt, error) {
		return original, nil
	}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(context.Context, Receipt) error { return nil })})
	if err != nil {
		t.Fatal(err)
	}
	canceled, cancel := context.WithCancel(t.Context())
	cancel()
	if gate.Claim(canceled, "token", 1) == nil {
		t.Fatal("canceled initial request admitted")
	}
	source.current = false
	if gate.Claim(t.Context(), "token", 1) == nil {
		t.Fatal("invalid initial binding admitted")
	}
	source.current = true
	if err := gate.Claim(t.Context(), "token", 1); err != nil {
		t.Fatal("pre-dispatch refusal consumed an unissued lifetime")
	}
}

func TestCustodyGateBoundsDependenciesWithoutCallerDeadline(t *testing.T) {
	source, original := custodyFixture()
	started := time.Now()
	checkBound := func(ctx context.Context) bool {
		deadline, ok := ctx.Deadline()
		return ok && deadline.After(started) && deadline.Before(started.Add(31*time.Second))
	}
	gate, err := NewCustodiedReceiptGate(source, receiptFunc(func(ctx context.Context, _ agones.ClaimBinding, _ string, _ sim.EntityID) (Receipt, error) {
		if !checkBound(ctx) {
			return Receipt{}, errors.New("claim has no bounded context")
		}
		return original, nil
	}), CustodyConfig{Enabled: true, Custodian: custodianFunc(func(ctx context.Context, _ Receipt) error {
		if !checkBound(ctx) {
			return errors.New("custody has no bounded context")
		}
		return nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	if gate.Claim(context.Background(), "token", 1) != nil {
		t.Fatal("unbounded caller did not reach dependencies with a finite context")
	}
}
