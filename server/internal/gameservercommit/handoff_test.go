package gameservercommit

import (
	"context"
	"errors"
	"fmt"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

type recoveryCloser interface {
	CloseForRecovery(context.Context) (allocatorjournal.JournalBinding, string, error)
}

func TestRecoveryUnknownDrainOrPublicationCannotRestoreOwner(t *testing.T) {
	for _, cut := range []int{3, 4} {
		t.Run(fmt.Sprintf("write-%d", cut), func(t *testing.T) {
			s := nakamastoragetest.New()
			s.AfterWrite = func(version int) error {
				if version == cut {
					return errors.New("committed reply lost")
				}
				return nil
			}
			g := durableFixture(t, s, generationAPI(t, ""))
			grant := generationPrepare(t, g, "pod-a", "zone-a")
			b, v, e := g.CloseForRecovery(context.Background())
			if !errors.Is(e, ErrUnknown) || v != "" || b.Version != "" {
				t.Fatal("unknown closure exported pins")
			}
			expected := 0
			if cut == 4 {
				expected = 1
			}
			rows := 0
			for _, row := range s.Objects() {
				if row.Collection == allocatoradmission.HandoffCollection {
					rows++
				}
			}
			if rows != expected {
				t.Fatal("unknown drain published a handoff or committed publication disappeared")
			}
			before := len(s.WrittenValues())
			if _, v, e = g.CloseForRecovery(context.Background()); v != "" || !errors.Is(e, ErrClosed) || len(s.WrittenValues()) != before {
				t.Fatal("unknown handoff retried")
			}
			if e = grant.Commit(context.Background()); !errors.Is(e, ErrClosed) {
				t.Fatal("unknown owner reopened commit admission")
			}
			if _, e = g.Fence(context.Background()); !errors.Is(e, ErrClosed) {
				t.Fatal("unknown owner restored barrier authority")
			}
			if _, e = g.Accept(GenerationReceipt{}); e == nil {
				t.Fatal("unknown owner accepted reconstructed receipt")
			}
		})
	}
}
func TestRecoveryHandoffRejectsProcessLocalGeneration(t *testing.T) {
	g, _ := generationFixture(t, generationAPI(t, ""))
	if _, v, e := g.CloseForRecovery(context.Background()); v != "" || !errors.Is(e, ErrInvalid) {
		t.Fatal("process-local owner published durable handoff")
	}
}

func TestRecoveryClosureAccountsForLateRegistrationWithoutBarriers(t *testing.T) {
	s := &durableStorage{Fake: nakamastoragetest.New(), holdVersion: "v3", entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() {
		select {
		case <-s.release:
		default:
			close(s.release)
		}
	})
	var puts atomic.Int32
	handler := generationAPI(t, "")
	g := durableFixture(t, s, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			puts.Add(1)
		}
		handler(w, r)
	})
	closer, ok := any(g).(recoveryCloser)
	if !ok {
		t.Fatal("durable generation cannot close into a handoff")
	}
	exported := generationPrepare(t, g, "pod-a", "zone-a")
	prepared := make(chan error, 1)
	go func() {
		grant, e := g.Prepare(context.Background(), "pod-b", "zone-b", "original-b")
		if grant.state != nil {
			prepared <- errors.New("late capability escaped")
			return
		}
		prepared <- e
	}()
	select {
	case <-s.entered:
	case <-time.After(time.Second):
		t.Fatal("registration not committed")
	}
	type result struct {
		binding allocatorjournal.JournalBinding
		version string
		err     error
	}
	done := make(chan result, 1)
	go func() { b, v, e := closer.CloseForRecovery(context.Background()); done <- result{b, v, e} }()
	deadline := time.Now().Add(time.Second)
	for {
		g.state.mu.Lock()
		closed := g.state.closed
		g.state.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("handoff closure waited for registration")
		}
		time.Sleep(time.Millisecond)
	}
	if e := exported.Commit(context.Background()); !errors.Is(e, ErrClosed) {
		t.Fatal("commit admission left open")
	}
	select {
	case <-done:
		t.Fatal("handoff skipped pending acknowledgment")
	default:
	}
	close(s.release)
	if e := <-prepared; !errors.Is(e, ErrClosed) {
		t.Fatal("late capability exported")
	}
	got := <-done
	if got.err != nil || got.binding.IssuedCount != 2 || got.binding.Version != "v4" || got.version != "v5" || puts.Load() != 0 {
		t.Fatalf("incomplete handoff: %+v puts=%d", got, puts.Load())
	}
	observed, e := allocatoradmission.ReadHandoff(context.Background(), allocatoradmission.HandoffReadConfig{Enabled: true, Storage: s.Fake, Binding: got.binding, Version: got.version})
	if e != nil || len(observed.Journal.Grants) != 2 || observed.Journal.Grants[1].AttemptID != "original-b" {
		t.Fatalf("fresh handoff lost pending original: %+v %v", observed, e)
	}
	if _, e = g.Fence(context.Background()); !errors.Is(e, ErrClosed) {
		t.Fatal("handoff admitted barrier path")
	}
	if _, v, e := closer.CloseForRecovery(context.Background()); v != "" || !errors.Is(e, ErrClosed) {
		t.Fatal("handoff replayed")
	}
	if _, e = g.Accept(GenerationReceipt{}); e == nil {
		t.Fatal("handoff restored receipt")
	}
}
