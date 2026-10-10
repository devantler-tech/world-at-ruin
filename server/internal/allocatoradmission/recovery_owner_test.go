package allocatoradmission

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/protobuf/proto"
)

// Bypassing pinned handoff validation or accepting an incomplete ACK would
// manufacture a reservation; replacing create-only with CAS would elect twice.
func TestRecoveryOwnerRequiresPinnedHandoffAndExactAcknowledgment(t *testing.T) {
	s, cfg := recoveryFixture(t)
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal("recovery owner cannot be constructed:", err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal("acknowledged generation-wide reservation unavailable:", err)
	}
	got, err := owner.Accept(reservation)
	if err != nil || got.OwnerID != "recoverer-a" || got.Version != "owner-ack-1" || got.HandoffVersion != cfg.HandoffVersion || got.Handoff.Journal.Binding.Version != "v4" || len(got.Handoff.Journal.Grants) != 2 || got.Handoff.Journal.Grants[0] != grantA || got.Handoff.Journal.Grants[1] != grantB || s.writes != 1 || s.read.reads != 2 {
		t.Fatalf("original complete owner binding lost: %+v %v", got, err)
	}
	if s.deadline.IsZero() || time.Until(s.deadline) <= 0 || time.Until(s.deadline) > 30*time.Second {
		t.Fatal("unbounded reservation")
	}
	if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrClosed) || s.writes != 1 {
		t.Fatal("reservation retried")
	}
	got.Handoff.Journal.Grants[0].UID = "mutated"
	got.Handoff.Journal.Binding.MemberPodUIDs[0] = "mutated"
	again, err := owner.Accept(reservation)
	if err != nil || again.Handoff.Journal.Grants[0] != grantA || again.Handoff.Journal.Binding.MemberPodUIDs[0] != "pod-a" {
		t.Fatal("reservation aliases diagnostic data")
	}
	other, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = other.Accept(reservation); !errors.Is(err, ErrClosed) {
		t.Fatal("foreign process restored reservation")
	}
	if _, err = owner.Accept(RecoveryReservation{}); !errors.Is(err, ErrClosed) {
		t.Fatal("public fields restored reservation")
	}
}

type recoveryStorage struct {
	mu       sync.Mutex
	read     *handoffReadStorage
	row      *api.StorageObject
	writes   int
	fault    string
	cancel   context.CancelFunc
	deadline time.Time
}

func (s *recoveryStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(reads) == 1 && reads[0].Collection == "world_at_ruin_allocator_recovery_owners" {
		if s.row == nil {
			return nil, nil
		}
		row, ok := proto.Clone(s.row).(*api.StorageObject)
		if !ok {
			return nil, errors.New("owner fixture clone unavailable")
		}
		return []*api.StorageObject{row}, nil
	}
	return s.read.StorageRead(ctx, reads)
}
func (s *recoveryStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.writes++
	s.deadline, _ = ctx.Deadline()
	if len(writes) != 1 {
		return nil, errors.New("unexpected owner batch")
	}
	w := writes[0]
	if ctx.Err() != nil || s.row != nil || w.Collection != "world_at_ruin_allocator_recovery_owners" || w.Key == "" || w.Version != "*" || w.UserID != "" || w.PermissionRead != 0 || w.PermissionWrite != 0 {
		return nil, errors.New("private create-only owner refused")
	}
	s.row = &api.StorageObject{Collection: w.Collection, Key: w.Key, UserId: "00000000-0000-0000-0000-000000000000", Version: "owner-ack-1", Value: w.Value}
	ack := &api.StorageObjectAck{Collection: w.Collection, Key: w.Key, UserId: s.row.GetUserId(), Version: s.row.GetVersion()}
	if s.cancel != nil {
		s.cancel()
	}
	switch s.fault {
	case "lost":
		return nil, errors.New("committed reply lost")
	case "partial":
		return []*api.StorageObjectAck{ack}, errors.New("partial failure")
	case "key":
		ack.Key = "foreign"
	case "collection":
		ack.Collection = "foreign"
	case "owner":
		ack.UserId = "foreign"
	case "version":
		ack.Version = "*"
	case "missing":
		return nil, nil
	case "nil":
		return []*api.StorageObjectAck{nil}, nil
	case "extra":
		return []*api.StorageObjectAck{ack, ack}, nil
	}
	return []*api.StorageObjectAck{ack}, nil
}
func recoveryFixture(t *testing.T) (*recoveryStorage, RecoveryOwnerConfig) {
	t.Helper()
	read, pins := handoffFixture(t)
	s := &recoveryStorage{read: read}
	return s, RecoveryOwnerConfig{Enabled: true, Storage: s, Binding: pins.Binding, HandoffVersion: pins.Version, OwnerID: "recoverer-a"}
}

func TestRecoveryOwnerUnknownCannotResumeOrRetry(t *testing.T) {
	for _, fault := range []string{"lost", "partial", "key", "collection", "owner", "version", "missing", "nil", "extra", "cancel"} {
		t.Run(fault, func(t *testing.T) {
			s, cfg := recoveryFixture(t)
			s.fault = fault
			owner, err := NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if fault == "cancel" {
				s.cancel = cancel
			}
			reservation, err := owner.Reserve(ctx)
			if !errors.Is(err, ErrUnknown) || reservation.owner != nil || s.row == nil {
				t.Fatal("ambiguous owner exported reservation")
			}
			if fault == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal("cancellation lost")
			}
			if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrClosed) || s.writes != 1 {
				t.Fatal("ambiguous write retried")
			}
			s.cancel = nil
			s.fault = ""
			fresh, err := NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			r, err := fresh.Reserve(context.Background())
			if !errors.Is(err, ErrUnknown) || r.owner != nil || s.writes != 2 {
				t.Fatal("same owner ID resumed from visible row")
			}
		})
	}
}
func TestRecoveryOwnerCompetesAcrossIDsButSharesLocalAttempt(t *testing.T) {
	s, cfg := recoveryFixture(t)
	a, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfg.OwnerID = "recoverer-b"
	b, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var success atomic.Int32
	for i := range 20 {
		wg.Go(func() {
			owner := a
			if i%2 == 1 {
				owner = b
			}
			if r, e := owner.Reserve(context.Background()); e == nil {
				if _, e = owner.Accept(r); e == nil {
					success.Add(1)
				}
			}
		})
	}
	wg.Wait()
	if success.Load() != 1 || s.writes != 2 {
		t.Fatal("generation admitted multiple owners or repeated attempts")
	}
}
func TestRecoveryOwnerRefusesUnknownHandoffBeforeWrite(t *testing.T) {
	for _, fault := range []string{"partial", "owner", "permission", "key", "version", "missing", "canceled"} {
		t.Run(fault, func(t *testing.T) {
			s, cfg := recoveryFixture(t)
			s.read.fault = fault
			if fault == "missing" {
				s.read.handoff = nil
			}
			owner, err := NewRecoveryOwner(cfg)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if fault == "canceled" {
				cancel()
			}
			r, err := owner.Reserve(ctx)
			if !errors.Is(err, ErrUnknown) || r.owner != nil || s.writes != 0 {
				t.Fatal("unknown handoff elected owner")
			}
			s.read.fault = ""
			if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrClosed) || s.writes != 0 {
				t.Fatal("failed read refreshed and retried")
			}
		})
	}
	s, cfg := recoveryFixture(t)
	cfg.Enabled = false
	if _, err := NewRecoveryOwner(cfg); !errors.Is(err, ErrDisabled) || s.read.reads != 0 || s.writes != 0 {
		t.Fatal("disabled owner inspected dependencies")
	}
}

func TestRecoveryOwnerCopiesFreezeInputsAndCannotRefreshPins(t *testing.T) {
	s, cfg := recoveryFixture(t)
	owner, err := NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	copied := *owner
	cfg.Binding.MemberPodUIDs[0] = "changed"
	cfg.HandoffVersion = "changed"
	r, err := copied.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = owner.Accept(r); err != nil {
		t.Fatal("local copy lost ACK origin")
	}
	if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrClosed) || s.writes != 1 {
		t.Fatal("copy reopened attempt")
	}
	s, cfg = recoveryFixture(t)
	cfg.OwnerID = "new-incarnation"
	cfg.HandoffVersion = "changed"
	owner, err = NewRecoveryOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = owner.Reserve(context.Background()); !errors.Is(err, ErrUnknown) || s.writes != 0 {
		t.Fatal("stale handoff refreshed before reservation")
	}
	var empty RecoveryOwner
	if _, err = empty.Reserve(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("zero owner opened")
	}
	if _, err = (*RecoveryOwner)(nil).Accept(r); !errors.Is(err, ErrClosed) {
		t.Fatal("nil owner accepted")
	}
}

func TestRecoveryOwnerKeepsEveryShippedSchemaReadable(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_allocator_recovery_owner_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeRecoveryOwner(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	expected, err := os.ReadFile("testdata/golden_allocator_recovery_handoff_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	handoff, err := decodeHandoff(string(expected))
	if err != nil {
		t.Fatal(err)
	}
	if got.OwnerID != "recoverer-1" || got.HandoffVersion != "handoff-version-1" || got.Version != "" || !reflect.DeepEqual(got.Handoff, handoff) || len(got.Handoff.Journal.Grants) != 2 || got.Handoff.Journal.Grants[0] != grantA || got.Handoff.Journal.Grants[1] != grantB {
		t.Fatalf("historical owner lost original complete binding: %+v", got)
	}
}

func TestRecoveryOwnerRejectsAmbiguousHistoricalDocuments(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_allocator_recovery_owner_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	base := string(raw)
	for _, value := range []string{
		strings.Replace(base, "\"schema\": 1", "\"schema\": 2", 1),
		strings.Replace(base, "\"schema\": 1", "\"schema\": 1, \"schema\": 1", 1),
		strings.Replace(base, "\"schema\": 1", "\"schema\": 1, \"unknown\": true", 1),
		strings.Replace(base, "\"owner_id\": \"recoverer-1\"", "\"owner_id\": null", 1),
		strings.Replace(base, "\"owner_id\": \"recoverer-1\"", "\"owner_id\": \"\"", 1),
		strings.Replace(base, "\"handoff_version\": \"handoff-version-1\"", "\"handoff_version\": \"*\"", 1),
		strings.Replace(base, "\"handoff\": {", "\"handoff\": null, \"ignored\": {", 1),
		strings.Replace(base, "\"phase\": \"draining\"", "\"phase\": \"open\"", 1),
		strings.Replace(base, "\"grant_count\": 2", "\"grant_count\": 1", 1),
		strings.Replace(base, "\"uid\": \"uid-a\"", "\"uid\": \"uid-b\"", 1),
		strings.Replace(base, "\"root-version-4\"", "null", 1),
		base + "{}", string([]byte{0xff}), strings.Repeat(" ", 267265),
	} {
		got, err := DecodeRecoveryOwner(value)
		if !errors.Is(err, ErrUnknown) || got.OwnerID != "" || got.Version != "" {
			t.Fatal("ambiguous document produced owner observation")
		}
	}
}

func TestRecoveryOwnerRejectsInvalidConstructionWithoutStorage(t *testing.T) {
	for _, fault := range []string{"nil-storage", "typed-nil-storage", "owner", "root-version", "handoff-version"} {
		t.Run(fault, func(t *testing.T) {
			s, cfg := recoveryFixture(t)
			switch fault {
			case "nil-storage":
				cfg.Storage = nil
			case "typed-nil-storage":
				cfg.Storage = (*recoveryStorage)(nil)
			case "owner":
				cfg.OwnerID = ""
			case "root-version":
				cfg.Binding.Version = "*"
			case "handoff-version":
				cfg.HandoffVersion = "*"
			}
			if owner, err := NewRecoveryOwner(cfg); !errors.Is(err, ErrClosed) || owner != nil || s.read.reads != 0 || s.writes != 0 {
				t.Fatal("invalid construction touched storage")
			}
		})
	}
	if owner, err := NewRecoveryOwner(RecoveryOwnerConfig{}); !errors.Is(err, ErrDisabled) || owner != nil {
		t.Fatal("default-off construction inspected dependencies")
	}
}
