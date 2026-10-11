package claimrpc

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

type custodyBinding struct{ binding agones.ClaimBinding }

func (s custodyBinding) ClaimBinding() (agones.ClaimBinding, error)     { return s.binding, nil }
func (s custodyBinding) ClaimBindingCurrent(b agones.ClaimBinding) bool { return s.binding == b }

type custodyRetention func(context.Context, zoneclaim.Receipt) error

func (f custodyRetention) RetainOriginal(ctx context.Context, r zoneclaim.Receipt) error {
	return f(ctx, r)
}

// Actual mutual TLS supplies the originating claim. Fixture storage readback
// demonstrates preservation, never native Nakama durability or custody authority.
func TestCustodyRefusalRetainsRemotelyAcknowledgedClaim(t *testing.T) {
	for _, mode := range []string{"refused", "canceled after custody return", "acknowledged"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			handler, err := NewHandler(f.store, resolverFunc(func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil }), Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
			if err != nil {
				t.Fatal(err)
			}
			var requests atomic.Int32
			client, _ := f.serveHandler(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				handler.ServeHTTP(w, r)
			}))
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			var original zoneclaim.Receipt
			custodyCalls := 0
			gate, err := zoneclaim.NewCustodiedReceiptGate(custodyBinding{f.binding}, client, zoneclaim.CustodyConfig{Enabled: true, Custodian: custodyRetention(func(_ context.Context, r zoneclaim.Receipt) error {
				custodyCalls++
				original = r
				if mode == "canceled after custody return" {
					cancel()
					return nil
				}
				if mode == "refused" {
					return errors.New("custody acknowledgement unavailable")
				}
				return nil
			})})
			if err != nil {
				t.Fatal(err)
			}
			claimErr := gate.Claim(ctx, f.token, 1)
			if (claimErr == nil) != (mode == "acknowledged") {
				t.Fatal("admission ignored originating custody acknowledgement")
			}
			stored, err := f.store.Load(t.Context(), f.record.Lease.UserID, f.record.Lease.ReservationID)
			if err != nil || stored.Lease.ClaimedAt.IsZero() || original.Fence.LeaseVersion != stored.Version || !original.Fence.Generation.Equal(stored.Lease.ClaimedAt) || !original.Matches(f.binding, 1) {
				t.Fatal("custody did not receive the actual acknowledged claim")
			}
			object, ok := f.storage.Get(nakamalease.Collection, original.Fence.LeaseObjectID, "")
			if !ok || object.PermissionRead != 0 || object.PermissionWrite != 0 {
				t.Fatal("original private claim missing or exposed")
			}
			for range 3 {
				retryErr := gate.Claim(t.Context(), f.token, 1)
				if (retryErr == nil) != (mode == "acknowledged") {
					t.Fatal("retry changed custody admission outcome")
				}
			}
			wantRequests := int32(1)
			if mode == "acknowledged" {
				wantRequests = 4
				if gate.Claim(t.Context(), "invalid-token", 1) == nil {
					t.Fatal("reconnect bypassed token authentication")
				}
				wantRequests++
			}
			retained, exported := gate.Receipt()
			if exported != (mode == "acknowledged") || (exported && !retained.Equal(original)) || (!exported && retained != (zoneclaim.Receipt{})) || requests.Load() != wantRequests || custodyCalls != 1 {
				t.Fatal("custody retried, refreshed, exported uncertainty or bypassed authentication")
			}
			latest, ok := f.storage.Get(nakamalease.Collection, original.Fence.LeaseObjectID, "")
			if !ok || latest.Value != object.Value || latest.Version != object.Version || len(f.storage.WrittenValues()) != 2 {
				t.Fatal("custody outcome changed or released original ownership")
			}
			if _, err := f.store.BeginRelease(t.Context(), stored, "attempt-1"); !errors.Is(err, nakamalease.ErrClaimed) {
				t.Fatal("custody uncertainty made claimed ownership reclaimable")
			}
		})
	}
}
