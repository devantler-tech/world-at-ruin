package claimrpc

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// TestPrivateClaimPreservesCanonicalTokens keeps socket legacy compatibility
// and signed formatting aliases outside the private claim protocol.
func TestPrivateClaimPreservesCanonicalTokens(t *testing.T) {
	for _, name := range []string{"legacy", "observer alias", "expiry alias", "signature alias"} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			expiry := time.Now().Add(handoff.DefaultTokenTTL)
			token, err := zonesock.MintToken(f.allocation.AdmissionSecret, "zone-1", 1, expiry)
			if err != nil {
				t.Fatal(err)
			}
			parts := strings.Split(token, ".")
			switch name {
			case "legacy":
				parts[0], parts[3] = "v2", strconv.FormatInt(expiry.Unix(), 10)
			case "observer alias":
				parts[2] = "01"
			case "expiry alias":
				parts[3] = "+" + parts[3]
			}
			payload := strings.Join(parts[:4], ".")
			mac := hmac.New(sha256.New, f.allocation.AdmissionSecret)
			mac.Write([]byte(payload))
			signature := hex.EncodeToString(mac.Sum(nil))
			if name == "signature alias" {
				signature = strings.ToUpper(signature)
			}
			f.token = payload + "." + signature
			verifier, err := zonesock.NewHMACVerifier(f.allocation.AdmissionSecret, "zone-1")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := verifier.Verify(f.token); err != nil {
				t.Fatalf("control token has an invalid signature: %v", err)
			}
			client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
			if err := client.Claim(context.Background(), f.binding, f.token, 1); !errors.Is(err, ErrRefused) {
				t.Fatalf("noncanonical private token admitted: %v", err)
			}
			if len(f.storage.WrittenValues()) != 1 {
				t.Fatal("noncanonical token changed private ownership")
			}
		})
	}
}

// expiryStorage observes the actual claim-write context and delays its
// acknowledgement until expiry, optionally retaining a committed claim.
type expiryStorage struct {
	*nakamastoragetest.Fake
	deadline chan time.Time
	commit   bool
}

// StorageWrite models both cancellation before mutation and lost acknowledgement
// after mutation; the fake retains the production storage ownership semantics.
func (s *expiryStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	deadline, _ := ctx.Deadline()
	s.deadline <- deadline
	if s.commit {
		if _, err := s.Fake.StorageWrite(ctx, writes); err != nil {
			return nil, err
		}
	}
	<-ctx.Done()
	return nil, ctx.Err()
}

// TestPrivateClaimTokenExpiryBoundsWrite checks the token deadline at the storage
// boundary and ensures expiry never acknowledges or releases a committed claim.
func TestPrivateClaimTokenExpiryBoundsWrite(t *testing.T) {
	for _, commit := range []bool{false, true} {
		t.Run(strconv.FormatBool(commit), func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			storage := &expiryStorage{Fake: f.storage, deadline: make(chan time.Time, 1), commit: commit}
			var err error
			f.store, err = nakamalease.NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
			expiry := time.Now().Add(500 * time.Millisecond)
			f.token, err = zonesock.MintToken(f.allocation.AdmissionSecret, "zone-1", 1, expiry)
			if err != nil {
				t.Fatal(err)
			}
			if err := client.Claim(context.Background(), f.binding, f.token, 1); !errors.Is(err, ErrRefused) {
				t.Fatalf("expired claim acknowledged: %v", err)
			}
			select {
			case deadline := <-storage.deadline:
				if !deadline.Equal(expiry) {
					t.Fatalf("claim write deadline = %s, want token expiry %s", deadline, expiry)
				}
			default:
				t.Fatal("positive control never reached the claim write")
			}
			stored, err := f.store.Load(context.Background(), f.record.Lease.UserID, f.record.Lease.ReservationID)
			if err != nil || !stored.Lease.ExpiresAt.Equal(f.record.Lease.ExpiresAt) || !stored.Lease.ClaimedAt.IsZero() != commit {
				t.Fatalf("expiry lost or altered durable ownership: %v", err)
			}
		})
	}
}
