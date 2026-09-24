package nakamalease

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

// claimFixture gives each test a private unclaimed lease and its opaque locator
// while retaining the raw identity solely for independent owner-side assertions.
func claimFixture(t *testing.T) (*Store, *nakamastoragetest.Fake, Record, string) {
	t.Helper()
	fake := nakamastoragetest.New()
	store, err := NewStore(fake)
	if err != nil {
		t.Fatal(err)
	}
	record, err := store.Create(context.Background(), Lease{UserID: "11111111-1111-1111-1111-111111111111", ReservationID: "reserve-1", AttemptID: "attempt-1", AllocationID: "zone-1", Observer: 1, SecretRef: "reference-1", ExpiresAt: time.Now().Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	return store, fake, record, ReservationKey(record.Lease.UserID, record.Lease.ReservationID)
}

// TestClaimByKeyPersistsAndWinsAgainstCleanup proves admission ownership is
// durable, replay writes nothing, and no-show cleanup loses after the claim.
func TestClaimByKeyPersistsAndWinsAgainstCleanup(t *testing.T) {
	store, fake, original, key := claimFixture(t)
	ctx := context.Background()
	located, err := store.LoadForClaim(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	if located.Lease.UserID != "" || located.Lease.ReservationID != "" {
		t.Fatal("opaque lookup exposed raw identity")
	}
	claimed, err := store.ClaimByKey(ctx, key, located, time.Now())
	if err != nil || claimed.Lease.ClaimedAt.IsZero() {
		t.Fatalf("claim was not durable: %v", err)
	}
	loaded, err := store.Load(ctx, original.Lease.UserID, original.Lease.ReservationID)
	if err != nil || loaded.Lease.ClaimedAt.IsZero() {
		t.Fatalf("normal owner cannot read claimed lease: %v", err)
	}
	if _, err := store.BeginRelease(ctx, original, original.Lease.AttemptID); !errors.Is(err, ErrClaimed) {
		t.Fatalf("cleanup did not lose: %v", err)
	}
	replay, err := store.ClaimByKey(ctx, key, located, time.Now())
	if err != nil || replay != claimed {
		t.Fatalf("identical claim replay changed ownership: %v", err)
	}
	for _, value := range fake.WrittenValues() {
		if strings.Contains(value, original.Lease.UserID) || strings.Contains(value, original.Lease.ReservationID) {
			t.Fatal("claim persisted raw identity")
		}
	}
}

// TestClaimByKeyRefusesReleaseAndStaleIdentity rejects callers whose observed
// version or allocation no longer owns the private lease.
func TestClaimByKeyRefusesReleaseAndStaleIdentity(t *testing.T) {
	for _, name := range []string{"release wins", "changed allocation", "changed attempt", "changed version", "expired", "canceled"} {
		t.Run(name, func(t *testing.T) {
			store, fake, original, key := claimFixture(t)
			ctx := context.Background()
			located, err := store.LoadForClaim(ctx, key)
			if err != nil {
				t.Fatal(err)
			}
			at := time.Now()
			switch name {
			case "release wins":
				_, err = store.BeginRelease(ctx, original, original.Lease.AttemptID)
			case "changed allocation":
				located.Lease.AllocationID = "zone-2"
			case "changed attempt":
				located.Lease.AttemptID = "attempt-2"
			case "changed version":
				located.Version = "missing-version"
			case "expired":
				at = located.Lease.ExpiresAt
			case "canceled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if err != nil {
				t.Fatal(err)
			}
			before := len(fake.WrittenValues())
			if _, err := store.ClaimByKey(ctx, key, located, at); err == nil {
				t.Fatal("invalid claim was accepted")
			}
			if len(fake.WrittenValues()) != before {
				t.Fatal("refused claim wrote storage")
			}
		})
	}
}

// TestClaimByKeyRecoversLostAcknowledgementWithoutRewriting distinguishes a
// committed claim from its missing response by one readback, never another write.
func TestClaimByKeyRecoversLostAcknowledgementWithoutRewriting(t *testing.T) {
	store, fake, _, key := claimFixture(t)
	located, err := store.LoadForClaim(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	fake.AfterWrite = func(int) error { return errors.New("private storage failure") }
	claimed, err := store.ClaimByKey(context.Background(), key, located, time.Now())
	if err != nil || claimed.Lease.ClaimedAt.IsZero() {
		t.Fatalf("committed claim acknowledgement not recovered: %v", err)
	}
	if len(fake.WrittenValues()) != 2 {
		t.Fatal("claim retried a possibly committed write")
	}
}

// TestLoadForClaimRefusesMalformedOrPublicStorage prevents malformed routing,
// ambiguous data and public permissions from becoming trusted lease evidence.
func TestLoadForClaimRefusesMalformedOrPublicStorage(t *testing.T) {
	for _, name := range []string{"uppercase key", "short key", "public", "wildcard version", "duplicate field", "missing"} {
		t.Run(name, func(t *testing.T) {
			store, fake, _, key := claimFixture(t)
			object, _ := fake.Get(Collection, key, "")
			switch name {
			case "uppercase key":
				key = strings.ToUpper(key)
			case "short key":
				key = "a"
			case "public":
				object.PermissionRead = 2
			case "wildcard version":
				object.Version = "*"
			case "duplicate field":
				object.Value = strings.Replace(object.Value, "{", "{\"observer\":99,", 1)
			case "missing":
				key = strings.Repeat("0", 64)
			}
			fake.Seed(object)
			if _, err := store.LoadForClaim(context.Background(), key); err == nil {
				t.Fatal("untrustworthy claim lookup accepted")
			}
		})
	}
}

// TestClaimByKeyAndCleanupHaveOneConcurrentWinner exercises the shared storage
// version race rather than substituting a mocked success for either transition.
func TestClaimByKeyAndCleanupHaveOneConcurrentWinner(t *testing.T) {
	for range 32 {
		store, _, original, key := claimFixture(t)
		ctx := context.Background()
		located, err := store.LoadForClaim(ctx, key)
		if err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		claimed, released := make(chan error, 1), make(chan error, 1)
		go func() {
			<-start
			_, err := store.ClaimByKey(ctx, key, located, time.Now())
			claimed <- err
		}()
		go func() {
			<-start
			_, err := store.BeginRelease(ctx, original, original.Lease.AttemptID)
			released <- err
		}()
		close(start)
		claimErr, releaseErr := <-claimed, <-released
		if (claimErr == nil) == (releaseErr == nil) {
			t.Fatalf("expected one winner: claim=%v release=%v", claimErr, releaseErr)
		}
		stored, err := store.Load(ctx, original.Lease.UserID, original.Lease.ReservationID)
		if err != nil {
			t.Fatal(err)
		}
		if stored.Lease.Releasing != (releaseErr == nil) || stored.Lease.ClaimedAt.IsZero() != (claimErr != nil) {
			t.Fatal("winner did not match durable state")
		}
	}
}

// TestClaimByKeyRetainsUncertainCommittedClaim ensures cancellation cannot undo
// ownership that must remain reserved until fenced session cleanup is authorized.
func TestClaimByKeyRetainsUncertainCommittedClaim(t *testing.T) {
	for _, scenario := range []string{"canceled after write", "lost write and read acknowledgements"} {
		t.Run(scenario, func(t *testing.T) {
			store, fake, original, key := claimFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			located, err := store.LoadForClaim(ctx, key)
			if err != nil {
				t.Fatal(err)
			}
			fake.AfterWrite = func(int) error {
				if scenario == "canceled after write" {
					cancel()
				} else {
					fake.ReadErr = errors.New("private read failure")
				}
				return errors.New("private write acknowledgement failure")
			}
			if _, err := store.ClaimByKey(ctx, key, located, time.Now()); err == nil {
				t.Fatal("uncertain outcome authorized admission")
			}
			fake.ReadErr = nil
			stored, err := store.Load(context.Background(), original.Lease.UserID, original.Lease.ReservationID)
			if err != nil || stored.Lease.ClaimedAt.IsZero() || len(fake.WrittenValues()) != 2 {
				t.Fatal("uncertain committed claim was released or rewritten")
			}
		})
	}
}
