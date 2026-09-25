package nakamalease

import (
	"context"
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/runtime"
)

// sessionFixture claims a real private lease and records its original receipt,
// including a reference that independently pins the test GameServer UID.
func sessionFixture(t *testing.T) (*Store, *nakamastoragetest.Fake, Record, SessionFence) {
	t.Helper()
	store, fake, original, key := claimFixture(t)
	uidDigest := sha256.Sum256([]byte("uid-1"))
	uid := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(uidDigest[:]))
	ref := "v1.k" + strings.Repeat("a", 52) + ".u" + uid + ".e" + strings.Repeat("a", 52) + ".p443"
	object, _ := fake.Get(Collection, key, "")
	object.Value = strings.Replace(object.Value, original.Lease.SecretRef, ref, 1)
	fake.Seed(object)
	observed, err := store.LoadForClaim(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimByKey(context.Background(), key, observed, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	digest, err := agones.CorrelationLabel("attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	fence := SessionFence{LeaseObjectID: key, LeaseVersion: claimed.Version, AttemptDigest: digest, AllocationID: "zone-1", GameServerUID: "uid-1", Generation: claimed.Lease.ClaimedAt}
	return store, fake, claimed, fence
}

// TestEndSessionHandlesUncertainBarrierWithoutBlindRetry requires durable
// readback before cleanup and preserves uncertain outcomes without another CAS.
func TestEndSessionHandlesUncertainBarrierWithoutBlindRetry(t *testing.T) {
	for _, scenario := range []string{"write refused", "lost acknowledgement", "unreadable acknowledgement", "canceled after commit"} {
		t.Run(scenario, func(t *testing.T) {
			store, fake, _, fence := sessionFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			privateErr := errors.New("private database address")
			switch scenario {
			case "write refused":
				fake.WriteErr = privateErr
			case "lost acknowledgement":
				fake.AfterWrite = func(int) error { return privateErr }
			case "unreadable acknowledgement":
				fake.AfterWrite = func(int) error { fake.ReadErr = privateErr; return privateErr }
			case "canceled after commit":
				fake.AfterWrite = func(int) error { cancel(); return nil }
			}
			before := len(fake.WrittenValues())
			calls := 0
			err := store.EndSession(ctx, fence, func(callCtx context.Context, _ Lease) error {
				calls++
				deadline, ok := callCtx.Deadline()
				if !ok || time.Until(deadline) > 30*time.Second {
					t.Fatal("unbounded cleanup")
				}
				return nil
			})
			if scenario == "lost acknowledgement" {
				if err != nil || calls != 1 {
					t.Fatalf("durable barrier not recovered: %v calls=%d", err, calls)
				}
			} else if err == nil || calls != 0 || strings.Contains(err.Error(), "private") {
				t.Fatalf("uncertain barrier reached cleanup or leaked error: %v calls=%d", err, calls)
			}
			if len(fake.WrittenValues()) != before+1 {
				t.Fatal("barrier was blindly rewritten")
			}
		})
	}
}

type sessionDeleteStorage struct {
	*nakamastoragetest.Fake
	loseAcknowledgement bool
}

// StorageDelete injects response loss only after the real conditional fake
// commits, separating transport uncertainty from durable deletion.
func (s *sessionDeleteStorage) StorageDelete(ctx context.Context, deletes []*runtime.StorageDelete) error {
	if err := s.Fake.StorageDelete(ctx, deletes); err != nil {
		return err
	}
	if s.loseAcknowledgement {
		return errors.New("private delete response lost")
	}
	return nil
}

// TestEndSessionSettlesLostDeleteAcknowledgement recognizes completed deletion
// through readback rather than retrying a destructive operation.
func TestEndSessionSettlesLostDeleteAcknowledgement(t *testing.T) {
	_, fake, _, fence := sessionFixture(t)
	store, err := NewStore(&sessionDeleteStorage{Fake: fake, loseAcknowledgement: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.EndSession(context.Background(), fence, func(context.Context, Lease) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, exists := fake.Get(Collection, fence.LeaseObjectID, ""); exists {
		t.Fatal("settled deletion retained lease")
	}
}

// TestEndSessionRetainsBarrierWhenDeleteFailsOrCleanupCancels requires durable
// restart evidence whenever completion cannot be safely acknowledged.
func TestEndSessionRetainsBarrierWhenDeleteFailsOrCleanupCancels(t *testing.T) {
	for _, scenario := range []string{"delete refused", "cancel after cleanup"} {
		t.Run(scenario, func(t *testing.T) {
			store, fake, _, fence := sessionFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if scenario == "delete refused" {
				fake.DeleteErr = errors.New("private storage address")
			}
			err := store.EndSession(ctx, fence, func(context.Context, Lease) error {
				if scenario == "cancel after cleanup" {
					cancel()
				}
				return nil
			})
			if err == nil || strings.Contains(err.Error(), "private") {
				t.Fatalf("unsafe completion: %v", err)
			}
			current, loadErr := store.LoadForClaim(context.Background(), fence.LeaseObjectID)
			if loadErr != nil || !current.Lease.Releasing {
				t.Fatalf("lost recovery barrier: %v", loadErr)
			}
		})
	}
}

// TestEndSessionConcurrentReplayCannotUnlockReplacement overlaps a completion
// with replacement ownership and checks that its stale delete version loses.
func TestEndSessionConcurrentReplayCannotUnlockReplacement(t *testing.T) {
	store, fake, claimed, fence := sessionFixture(t)
	started, finish := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- store.EndSession(context.Background(), fence, func(context.Context, Lease) error {
			close(started)
			<-finish
			return nil
		})
	}()
	<-started
	// The first completion owns the release barrier. A second completion must
	// neither adopt it as a fresh claim nor unlock while deletion is in flight.
	err := store.EndSession(context.Background(), fence, func(context.Context, Lease) error { t.Error("concurrent replay reached cleanup"); return nil })
	if !errors.Is(err, ErrReleasing) {
		t.Errorf("concurrent completion: %v", err)
	}
	if _, err := store.ClaimByKey(context.Background(), fence.LeaseObjectID, claimed, time.Now()); err == nil {
		t.Error("admission passed release barrier")
	}
	// Model the reaper finishing, followed by a new allocation at the same key,
	// while the first worker is still returning from idempotent resource cleanup.
	replacement, _ := fake.Get(Collection, fence.LeaseObjectID, "")
	replacement.Version = "replacement-version"
	replacement.Value = strings.ReplaceAll(replacement.Value, "attempt-1", "attempt-2")
	fake.Seed(replacement)
	close(finish)
	if err := <-done; !errors.Is(err, ErrConflict) {
		t.Fatalf("stale completion did not conflict: %v", err)
	}
	actual, exists := fake.Get(Collection, fence.LeaseObjectID, "")
	if !exists || actual != replacement {
		t.Fatal("stale completion deleted replacement lease")
	}
}

// Missing the release barrier permits an admission or replacement while the
// old GameServer can still exist; deleting before cleanup loses recovery state.
func TestEndSessionFencesBeforeCleanupAndUnlocksAfterSuccess(t *testing.T) {
	store, fake, claimed, fence := sessionFixture(t)
	ctx := context.Background()
	calls := 0
	err := store.EndSession(ctx, fence, func(callCtx context.Context, lease Lease) error {
		calls++
		current, err := store.LoadForClaim(callCtx, fence.LeaseObjectID)
		if err != nil || !current.Lease.Releasing || !current.Lease.ClaimedAt.IsZero() {
			t.Fatal("external cleanup started without durable release barrier")
		}
		if lease != current.Lease || lease.UserID != "" || lease.ReservationID != "" {
			t.Fatal("cleanup received wrong ownership material")
		}
		if _, err := store.ClaimByKey(callCtx, fence.LeaseObjectID, claimed, time.Now()); err == nil {
			t.Fatal("ending session admitted another socket")
		}
		return nil
	})
	if err != nil || calls != 1 {
		t.Fatalf("session did not end: %v cleanup=%d", err, calls)
	}
	if _, exists := fake.Get(Collection, fence.LeaseObjectID, ""); exists {
		t.Fatal("completed session retained reservation")
	}
	if err := store.EndSession(ctx, fence, func(context.Context, Lease) error { t.Fatal("completed replay repeated cleanup"); return nil }); err != nil {
		t.Fatal(err)
	}
	next := claimed.Lease
	next.UserID = "11111111-1111-1111-1111-111111111111"
	next.ReservationID = "reserve-1"
	next.AttemptID = "attempt-2"
	next.ClaimedAt = time.Time{}
	if _, err := store.Create(ctx, next); err != nil {
		t.Fatalf("completed cleanup did not unlock reservation: %v", err)
	}
}

// TestEndSessionRejectsStaleOrUnprovenOwnership varies receipt and storage
// evidence independently; refused calls must neither write nor invoke cleanup.
func TestEndSessionRejectsStaleOrUnprovenOwnership(t *testing.T) {
	for _, scenario := range []string{"version", "generation", "attempt", "allocation", "UID", "key", "unclaimed", "staging", "canceled", "unavailable", "nil cleanup"} {
		t.Run(scenario, func(t *testing.T) {
			store, fake, _, fence := sessionFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			cleanup := func(context.Context, Lease) error { t.Fatal("refused session reached deletion"); return nil }
			switch scenario {
			case "version":
				fence.LeaseVersion = "old-version"
			case "generation":
				fence.Generation = fence.Generation.Add(time.Nanosecond)
			case "attempt":
				fence.AttemptDigest = strings.Repeat("a", 52)
			case "allocation":
				fence.AllocationID = "zone-2"
			case "UID":
				fence.GameServerUID = "uid-2"
			case "key":
				fence.LeaseObjectID = "*"
			case "unclaimed":
				object, _ := fake.Get(Collection, fence.LeaseObjectID, "")
				object.Value = strings.Replace(object.Value, `"claimed_at_nanos":`, `"ignored_claim_stamp":`, 1)
				fake.Seed(object)
			case "staging":
				object, _ := fake.Get(Collection, fence.LeaseObjectID, "")
				object.Value = `{"schema":3,"attempt_id":"attempt-1","allocation_id":"","observer":0,"secret_ref":"","expires_at_nanos":` + strconv.FormatInt(time.Now().Add(time.Minute).UnixNano(), 10) + `,"staging":true,"dispatched":false,"releasing":false}`
				fake.Seed(object)
			case "canceled":
				cancel()
			case "unavailable":
				fake.ReadErr = errors.New("private storage details")
			case "nil cleanup":
				cleanup = nil
			}
			before := len(fake.WrittenValues())
			if err := store.EndSession(ctx, fence, cleanup); err == nil {
				t.Fatal("invalid ownership accepted")
			}
			if len(fake.WrittenValues()) != before {
				t.Fatal("refused session changed durable ownership")
			}
		})
	}
}

// TestEndSessionRetainsBarrierAfterCleanupFailureForRestart constructs a fresh
// store to prove recovery uses durable state rather than a worker's memory.
func TestEndSessionRetainsBarrierAfterCleanupFailureForRestart(t *testing.T) {
	store, fake, _, fence := sessionFixture(t)
	ctx := context.Background()
	if err := store.EndSession(ctx, fence, func(context.Context, Lease) error { return errors.New("private endpoint failure") }); err == nil {
		t.Fatal("failed resource cleanup reported complete")
	}
	current, err := store.LoadForClaim(ctx, fence.LeaseObjectID)
	if err != nil || !current.Lease.Releasing {
		t.Fatalf("cleanup failure lost durable barrier: %v", err)
	}
	// The original claim stamp is deliberately not rewritten into a new
	// schema: a retry of its old receipt leaves recovery to the durable reaper.
	if err := store.EndSession(ctx, fence, func(context.Context, Lease) error { t.Fatal("old receipt resumed unverified generation"); return nil }); !errors.Is(err, ErrReleasing) {
		t.Fatalf("releasing replay: %v", err)
	}
	restarted, err := NewStore(fake)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	if err := restarted.ReclaimExpired(ctx, time.Now(), func(_ context.Context, lease Lease) error {
		calls++
		if !lease.Releasing || lease.AllocationID != "zone-1" {
			t.Fatal("restarted cleanup received wrong session")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatal("releasing session waited for its old expiry")
	}
	if _, exists := fake.Get(Collection, fence.LeaseObjectID, ""); exists {
		t.Fatal("restart did not settle ended reservation")
	}
}
