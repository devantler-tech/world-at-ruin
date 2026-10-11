package zonecustody

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Invalid constructor dependencies and receipt identity must refuse before
// storage; removing these checks would persist ambiguous lifetime ownership.
func TestConfigurationAndChangedReceiptsCannotDispatch(t *testing.T) {
	s, cfg, r := fixture()
	for _, change := range []string{"disabled", "nil storage", "typed nil", "namespace", "lease", "attempt", "allocation", "uid", "owner", "child"} {
		bad := cfg
		switch change {
		case "disabled":
			bad.Enabled = false
		case "nil storage":
			bad.Storage = nil
		case "typed nil":
			var missing *nakamastoragetest.Fake
			bad.Storage = missing
		case "namespace":
			bad.Binding.Namespace = "bad namespace"
		case "lease":
			bad.Binding.LeaseObjectID = "bad"
		case "attempt":
			bad.Binding.AttemptDigest = "bad"
		case "allocation":
			bad.Binding.AllocationID = "bad/name"
		case "uid":
			bad.Binding.GameServerUID = "bad/uid"
		case "owner":
			bad.OwnerID = ""
		case "child":
			bad.ChildIncarnation = ""
		}
		if _, err := NewOwner(bad); err == nil {
			t.Fatal("invalid constructor", change)
		}
	}
	if len(s.WrittenValues()) != 0 {
		t.Fatal("constructor performed I/O")
	}
	for _, change := range []string{"namespace", "lease", "attempt", "allocation", "uid", "observer", "version", "generation"} {
		storage := nakamastoragetest.New()
		next := cfg
		next.Storage = storage
		e := reserve(t, next)
		bad := r
		switch change {
		case "namespace":
			bad.Namespace = "other"
		case "lease":
			bad.Fence.LeaseObjectID = strings.Repeat("b", 64)
		case "attempt":
			bad.Fence.AttemptDigest = strings.Repeat("b", 51) + "a"
		case "allocation":
			bad.Fence.AllocationID = "other"
		case "uid":
			bad.Fence.GameServerUID = "other"
		case "observer":
			bad.Observer = 0
		case "version":
			bad.Fence.LeaseVersion = "*"
		case "generation":
			bad.Fence.Generation = time.Time{}
		}
		if e.RetainOriginal(t.Context(), bad) == nil || e.RetainOriginal(t.Context(), r) == nil || len(storage.Objects()) != 1 {
			t.Fatal("invalid receipt dispatched or retry restored custody", change)
		}
	}
	key := LifetimeKey(cfg.Binding)
	if len(key) != 64 {
		t.Fatal("unbounded lifetime key")
	}
	for _, change := range []string{"namespace", "lease", "attempt", "allocation", "uid"} {
		b := cfg.Binding
		switch change {
		case "namespace":
			b.Namespace = "other"
		case "lease":
			b.LeaseObjectID = strings.Repeat("b", 64)
		case "attempt":
			b.AttemptDigest = strings.Repeat("b", 51) + "a"
		case "allocation":
			b.AllocationID = "other"
		case "uid":
			b.GameServerUID = "other"
		}
		if LifetimeKey(b) == key {
			t.Fatal("lifetime identity omitted", change)
		}
	}
}

// A fresh allocation locator can differ by watch revision without changing
// the original lifetime. Expired/canceled callers cannot leave a retry path.
func TestCanceledAttemptNeverWritesOrReopens(t *testing.T) {
	s, cfg, r := fixture()
	o, err := NewOwner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err = o.Reserve(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation identity lost", err)
	}
	if _, err = o.Reserve(t.Context()); err == nil || len(s.Objects()) != 0 {
		t.Fatal("canceled owner retried")
	}
	copy := cfg
	copy.Storage = nakamastoragetest.New()
	e := reserve(t, copy)
	if err = e.RetainOriginal(ctx, r); !errors.Is(err, context.Canceled) {
		t.Fatal("custody cancellation lost", err)
	}
	if e.RetainOriginal(t.Context(), r) == nil {
		t.Fatal("canceled custody retried")
	}
}

type deadlineStorage struct {
	*nakamastoragetest.Fake
	t              *testing.T
	parentDeadline time.Time
	writes, reads  int
}

func (s *deadlineStorage) observe(ctx context.Context) {
	s.t.Helper()
	d, ok := ctx.Deadline()
	remaining := time.Until(d)
	if !ok || remaining <= 0 || remaining > 30*time.Second {
		s.t.Fatal("storage received an unbounded or expired context", remaining, ok)
	}
	if !s.parentDeadline.IsZero() && !d.Equal(s.parentDeadline) {
		s.t.Fatal("storage extended the shorter parent deadline")
	}
}

func (s *deadlineStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	s.observe(ctx)
	s.writes++
	return s.Fake.StorageWrite(ctx, writes)
}

func (s *deadlineStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.observe(ctx)
	s.reads++
	return s.Fake.StorageRead(ctx, reads)
}

// Removing any operation's timeout would expose an unbounded Background
// context here; extending a short caller deadline also fails at storage.
func TestEveryStorageOperationBoundsItsCallerContext(t *testing.T) {
	for _, short := range []bool{false, true} {
		s, cfg, r := fixture()
		ctx := context.Background()
		observed := &deadlineStorage{Fake: s, t: t}
		if short {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			observed.parentDeadline, _ = ctx.Deadline()
		}
		// A value client is supported without weakening typed-nil refusal.
		cfg.Storage = struct{ *deadlineStorage }{observed}
		o, err := NewOwner(cfg)
		if err != nil {
			t.Fatal(err)
		}
		e, err := o.Reserve(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err = e.RetainOriginal(ctx, r); err != nil {
			t.Fatal(err)
		}
		pins, ok := e.Pins()
		if !ok {
			t.Fatal("originating custody missing")
		}
		if _, err = Read(ctx, ReadConfig{Enabled: true, Storage: observed, Pins: pins}); err != nil {
			t.Fatal(err)
		}
		if observed.writes != 2 || observed.reads != 1 {
			t.Fatal("deadline observation omitted an operation")
		}
		var missing *nakamastoragetest.Fake
		if _, err = Read(ctx, ReadConfig{Enabled: true, Storage: missing, Pins: pins}); err == nil {
			t.Fatal("typed nil reader accepted")
		}
	}
}

// Normal commands and serving plugin cannot activate the experimental writer.
func TestNormalArtifactsDoNotComposeZoneCustody(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-tags=", "-deps", "./cmd/zone", "./cmd/nakama")
	cmd.Dir = "../.."
	raw, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("normal import observation incomplete: %v %s", err, raw)
	}
	if strings.Contains(string(raw), "/internal/zonecustody") {
		t.Fatal("normal artifact composed experimental custody")
	}
}
