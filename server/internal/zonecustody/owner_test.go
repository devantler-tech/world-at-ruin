package zonecustody

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

func fixture() (*nakamastoragetest.Fake, Config, zoneclaim.Receipt) {
	s := nakamastoragetest.New()
	b := agones.ClaimBinding{Namespace: "world", LeaseObjectID: strings.Repeat("a", 64), AttemptDigest: strings.Repeat("a", 52), AllocationID: "zone-a", GameServerUID: "uid-a"}
	r := zoneclaim.Receipt{Namespace: "world", Observer: 7, Fence: nakamalease.SessionFence{LeaseObjectID: b.LeaseObjectID, AttemptDigest: b.AttemptDigest, AllocationID: b.AllocationID, GameServerUID: b.GameServerUID, LeaseVersion: "original-version", Generation: time.Unix(123, 456).UTC()}}
	return s, Config{Enabled: true, Storage: s, Binding: b, OwnerID: "supervisor-a", ChildIncarnation: "child-a"}, r
}

func reserve(t *testing.T, cfg Config) Enrollment {
	t.Helper()
	o, err := NewOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	e, err := o.Reserve(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	return e
}

// Removing create-only exclusion would let a competing owner replace this
// allocation's frozen enrollment and originating receipt.
func TestOriginalCustodyIsPrivateImmutableAndOwnerIndependent(t *testing.T) {
	s, cfg, receipt := fixture()
	e := reserve(t, cfg)
	if _, ok := e.Pins(); ok {
		t.Fatal("enrollment alone exported receipt custody")
	}
	if err := e.RetainOriginal(t.Context(), receipt); err != nil {
		t.Fatal(err)
	}
	pins, ok := e.Pins()
	if !ok || pins.EnrollmentVersion != "v1" || pins.CustodyVersion != "v2" || pins.Enrollment.OwnerID != cfg.OwnerID || pins.Enrollment.ChildIncarnation != cfg.ChildIncarnation || !pins.Receipt.Equal(receipt) {
		t.Fatal("originating ACK or full original receipt lost")
	}
	for _, collection := range []string{EnrollmentCollection, CustodyCollection} {
		row, exists := s.Get(collection, LifetimeKey(cfg.Binding), "")
		if !exists || row.PermissionRead != 0 || row.PermissionWrite != 0 || row.UserID != "00000000-0000-0000-0000-000000000000" {
			t.Fatal("missing or public custody")
		}
	}
	copy := e
	if copy.RetainOriginal(t.Context(), receipt) == nil {
		t.Fatal("copied enrollment refreshed custody")
	}
	for _, change := range []string{"same owner", "new owner", "new child"} {
		next := cfg
		if change == "new owner" {
			next.OwnerID = "supervisor-b"
		}
		if change == "new child" {
			next.ChildIncarnation = "child-b"
		}
		o, err := NewOwner(next)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = o.Reserve(t.Context()); err == nil {
			t.Fatal("replacement adopted original enrollment")
		}
	}
	if len(s.Objects()) != 2 || len(s.WrittenValues()) != 5 || s.ReadCalls != 0 {
		t.Fatal("custody replaced rows or reconstructed an ACK")
	}
	if (Enrollment{}).RetainOriginal(t.Context(), receipt) == nil {
		t.Fatal("zero handle reconstructed custody")
	}
}

type faultStorage struct {
	*nakamastoragetest.Fake
	fault      string
	collection string
	cancel     context.CancelFunc
	entered    chan struct{}
	release    chan struct{}
}

func (s *faultStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	acks, err := s.Fake.StorageWrite(ctx, writes)
	if writes[0].Collection != s.collection || err != nil {
		return acks, err
	}
	if s.entered != nil {
		close(s.entered)
		<-s.release
	}
	if s.cancel != nil {
		s.cancel()
	}
	switch s.fault {
	case "lost":
		return nil, errors.New("committed response lost")
	case "partial":
		return acks, errors.New("partial response")
	case "missing":
		return nil, nil
	case "nil":
		return []*api.StorageObjectAck{nil}, nil
	case "extra":
		return append(acks, acks[0]), nil
	case "key":
		acks[0].Key = "foreign"
	case "collection":
		acks[0].Collection = "foreign"
	case "owner":
		acks[0].UserId = "foreign"
	case "version":
		acks[0].Version = "*"
	case "whitespace":
		acks[0].Version = "bad version"
	}
	return acks, nil
}

// Accepting a partial/malformed reply or retrying uncertainty can create a
// usable custodian without its actual originating enrollment or custody ACK.
func TestUnknownAcknowledgementsCannotRetryOrRestore(t *testing.T) {
	for _, phase := range []string{EnrollmentCollection, CustodyCollection} {
		for _, fault := range []string{"lost", "partial", "missing", "nil", "extra", "key", "collection", "owner", "version", "whitespace", "cancel"} {
			t.Run(phase+"/"+fault, func(t *testing.T) {
				base, cfg, receipt := fixture()
				ctx, cancel := context.WithCancel(t.Context())
				defer cancel()
				s := &faultStorage{Fake: base, fault: fault, collection: phase}
				if fault == "cancel" {
					s.cancel = cancel
				}
				cfg.Storage = s
				o, err := NewOwner(cfg)
				if err != nil {
					t.Fatal(err)
				}
				copy := *o
				e, err := o.Reserve(ctx)
				if phase == EnrollmentCollection {
					if err == nil || e.RetainOriginal(t.Context(), receipt) == nil {
						t.Fatal("unknown enrollment permitted custody")
					}
				} else {
					if err != nil {
						t.Fatal(err)
					}
					if e.RetainOriginal(ctx, receipt) == nil {
						t.Fatal("unknown custody acknowledged")
					}
					if e.RetainOriginal(t.Context(), receipt) == nil {
						t.Fatal("unknown custody retried")
					}
				}
				if pins, ok := e.Pins(); ok || pins != (Pins{}) {
					t.Fatal("unknown ACK exported pins")
				}
				if _, err = copy.Reserve(t.Context()); err == nil {
					t.Fatal("copied owner retried")
				}
				fresh, err := NewOwner(cfg)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = fresh.Reserve(t.Context()); err == nil {
					t.Fatal("restart adopted diagnostic enrollment")
				}
				want := 2
				if phase == CustodyCollection {
					want = 3
				}
				if len(base.WrittenValues()) != want || base.ReadCalls != 0 {
					t.Fatal("uncertainty read-adopted or retried")
				}
			})
		}
	}
}

func TestPendingCustodyWithholdsPinsAcrossCopies(t *testing.T) {
	s, cfg, receipt := fixture()
	f := &faultStorage{Fake: s, collection: CustodyCollection, entered: make(chan struct{}), release: make(chan struct{})}
	cfg.Storage = f
	e := reserve(t, cfg)
	result := make(chan error, 1)
	go func() { result <- e.RetainOriginal(t.Context(), receipt) }()
	<-f.entered
	copy := e
	if _, ok := copy.Pins(); ok {
		t.Fatal("pending custody exported")
	}
	if copy.RetainOriginal(t.Context(), receipt) == nil {
		t.Fatal("pending custody dispatched twice")
	}
	close(f.release)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if _, ok := copy.Pins(); !ok {
		t.Fatal("acknowledged custody missing")
	}
}

func TestCompetingOwnersHaveOneCreateOnlyWinner(t *testing.T) {
	s, cfg, _ := fixture()
	var wg sync.WaitGroup
	winners := make(chan Enrollment, 12)
	for range 12 {
		wg.Go(func() {
			o, err := NewOwner(cfg)
			if err != nil {
				t.Error(err)
				return
			}
			if e, err := o.Reserve(t.Context()); err == nil {
				winners <- e
			}
		})
	}
	wg.Wait()
	close(winners)
	if len(winners) != 1 || len(s.Objects()) != 1 {
		t.Fatal("competing enrollment had multiple winners")
	}
}
