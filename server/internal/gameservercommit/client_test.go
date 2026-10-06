package gameservercommit

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

func ready() *agonesv1.GameServer {
	return &agonesv1.GameServer{TypeMeta: metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServer"}, ObjectMeta: metav1.ObjectMeta{Namespace: "trial", Name: "zone", UID: "uid-1", ResourceVersion: "opaque-a", Labels: map[string]string{agones.FleetLabel: "fleet"}}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateReady}}
}

func fixture(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	c, err := New(Config{Enabled: true, REST: &rest.Config{Host: s.URL}, Namespace: "trial", Fleet: "fleet"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func reply(w http.ResponseWriter, obj *agonesv1.GameServer) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(obj)
}

func TestDefaultOff(t *testing.T) {
	if _, err := New(Config{}); !errors.Is(err, ErrDisabled) {
		t.Fatalf("default enabled: %v", err)
	}
}

func TestFrozenSingleConditionalWrite(t *testing.T) {
	source := ready()
	var puts int
	c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/agones.dev/v1/namespaces/trial/gameservers/zone" {
			t.Errorf("wrong path: %s", r.URL.Path)
		}
		if r.Method == http.MethodGet {
			reply(w, source)
			return
		}
		puts++
		var got agonesv1.GameServer
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Error(err)
		}
		digest, _ := agones.CorrelationLabel("attempt-1")
		if got.ResourceVersion != "opaque-a" || got.UID != "uid-1" || got.Status.State != agonesv1.GameServerStateAllocated || got.Labels[agones.AttemptLabel] != digest {
			t.Errorf("write not exact: %#v", got)
		}
		got.ResourceVersion = "opaque-b"
		reply(w, &got)
	})
	g, err := c.Prepare(context.Background(), "zone", "attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	source.ResourceVersion = "opaque-new"
	source.Labels[agones.FleetLabel] = "changed"
	if err = g.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err = g.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("replay accepted: %v", err)
	}
	if puts != 1 {
		t.Fatalf("puts=%d", puts)
	}
}

func TestRefuseInvalidPreparation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*agonesv1.GameServer)
	}{
		{"missing uid", func(g *agonesv1.GameServer) { g.UID = "" }},
		{"missing version", func(g *agonesv1.GameServer) { g.ResourceVersion = "" }},
		{"wrong name", func(g *agonesv1.GameServer) { g.Name = "other" }},
		{"wrong namespace", func(g *agonesv1.GameServer) { g.Namespace = "other" }},
		{"wrong fleet", func(g *agonesv1.GameServer) { g.Labels[agones.FleetLabel] = "other" }},
		{"not ready", func(g *agonesv1.GameServer) { g.Status.State = agonesv1.GameServerStateAllocated }},
		{"prior attempt", func(g *agonesv1.GameServer) { g.Labels[agones.AttemptLabel] = "prior" }},
		{"prior barrier", func(g *agonesv1.GameServer) { g.Annotations = map[string]string{BarrierAnnotation: "prior"} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			obj := ready()
			tc.mutate(obj)
			writes := 0
			c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					writes++
				}
				reply(w, obj)
			})
			if _, err := c.Prepare(context.Background(), "zone", "attempt-1"); err == nil {
				t.Fatal("invalid preparation accepted")
			}
			if writes != 0 {
				t.Fatal("preparation wrote a resource")
			}
		})
	}
}

func TestNoRetryAfterAndNoSecondSubmission(t *testing.T) {
	calls := 0
	c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			reply(w, ready())
			return
		}
		calls++
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"TooManyRequests","code":429}`))
	})
	g, err := c.Prepare(context.Background(), "zone", "attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	if err = g.Commit(context.Background()); !errors.Is(err, ErrUnknown) {
		t.Fatalf("want Unknown: %v", err)
	}
	if err = g.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("second dispatch: %v", err)
	}
	if calls != 1 {
		t.Fatalf("hidden retry: %d", calls)
	}
}

func TestFenceReceiptBindsOriginAndAcknowledgedReadback(t *testing.T) {
	obj := ready()
	var mu sync.Mutex
	puts := 0
	c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method == http.MethodPut {
			var got agonesv1.GameServer
			_ = json.NewDecoder(r.Body).Decode(&got)
			puts++
			got.ResourceVersion = "opaque-b"
			obj = &got
		}
		reply(w, obj)
	})
	g, err := c.Prepare(context.Background(), "zone", "attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	copied := g
	receipt, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	observed, err := copied.Accept(receipt)
	if err != nil || observed.Outcome != Uncommitted {
		t.Fatalf("receipt: %#v %v", observed, err)
	}
	if err = copied.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("copy not drained: %v", err)
	}
	if _, err = g.Accept(Receipt{}); err == nil {
		t.Fatal("zero receipt accepted")
	}
	var other Grant
	if _, err = other.Accept(receipt); err == nil {
		t.Fatal("receipt crossed incarnation")
	}
	if puts != 1 || obj.Annotations[BarrierAnnotation] == "" || obj.ResourceVersion == "opaque-a" {
		t.Fatal("barrier was not a new mutation")
	}
}

func TestFenceUnknownCannotGrantReceiptOrReopen(t *testing.T) {
	for _, mode := range []string{"recreated", "foreign allocation", "lost write", "invalid ack", "invalid readback", "conflict"} {
		t.Run(mode, func(t *testing.T) {
			obj := ready()
			reads := 0
			writes := 0
			c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					reads++
					out := obj.DeepCopy()
					if reads > 1 && mode == "recreated" {
						out.UID = "replacement"
					}
					if reads > 1 && mode == "foreign allocation" {
						out.Status.State = agonesv1.GameServerStateAllocated
						out.Labels[agones.AttemptLabel] = "foreign"
					}
					if reads > 2 && mode == "invalid readback" {
						out.Annotations = nil
					}
					reply(w, out)
					return
				}
				writes++
				var got agonesv1.GameServer
				_ = json.NewDecoder(r.Body).Decode(&got)
				got.ResourceVersion = "opaque-b"
				obj = &got
				switch mode {
				case "lost write":
					w.WriteHeader(503)
				case "conflict":
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(409)
					_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","reason":"Conflict","code":409}`))
				case "invalid ack":
					obj.ResourceVersion = "opaque-a"
					reply(w, obj)
				default:
					reply(w, obj)
				}
			})
			g, err := c.Prepare(context.Background(), "zone", "attempt-1")
			if err != nil {
				t.Fatal(err)
			}
			receipt, err := g.Fence(context.Background())
			if !errors.Is(err, ErrUnknown) {
				t.Fatalf("want unknown: %v", err)
			}
			if _, err = g.Accept(receipt); err == nil {
				t.Fatal("ambiguous receipt accepted")
			}
			if err = g.Commit(context.Background()); !errors.Is(err, ErrClosed) {
				t.Fatalf("unknown reopened: %v", err)
			}
			if (mode == "recreated" || mode == "foreign allocation") && writes != 0 {
				t.Fatal("foreign object mutated")
			}
		})
	}
}

func TestConcurrentCopiesSubmitOnlyOnce(t *testing.T) {
	var mu sync.Mutex
	puts := 0
	c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			reply(w, ready())
			return
		}
		mu.Lock()
		puts++
		mu.Unlock()
		var obj agonesv1.GameServer
		_ = json.NewDecoder(r.Body).Decode(&obj)
		obj.ResourceVersion = "opaque-b"
		reply(w, &obj)
	})
	g, err := c.Prepare(context.Background(), "zone", "attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 16 {
		wg.Go(func() { _ = g.Commit(context.Background()) })
	}
	wg.Wait()
	if puts != 1 {
		t.Fatalf("duplicate submission: %d", puts)
	}
}

func TestChangedHistoryNeverBecomesAbsence(t *testing.T) {
	for _, mode := range []string{"unrelated version", "commit then erased correlation"} {
		t.Run(mode, func(t *testing.T) {
			reads, writes := 0, 0
			c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					writes++
				}
				reads++
				obj := ready()
				if reads > 1 {
					obj.ResourceVersion = "opaque-later"
				}
				reply(w, obj)
			})
			g, err := c.Prepare(context.Background(), "zone", "attempt-1")
			if err != nil {
				t.Fatal(err)
			}
			// Both histories have the same observation. Neither contains an absence proof.
			receipt, err := g.Fence(context.Background())
			if !errors.Is(err, ErrUnknown) {
				t.Fatalf("changed history claimed absence: %v", err)
			}
			if _, err = g.Accept(receipt); err == nil || writes != 0 {
				t.Fatal("ambiguous history granted authority")
			}
		})
	}
}

func TestInvalidCommitAcknowledgementStaysUnknown(t *testing.T) {
	for _, mode := range []string{"uid", "version", "attempt", "state"} {
		t.Run(mode, func(t *testing.T) {
			c := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					reply(w, ready())
					return
				}
				var obj agonesv1.GameServer
				_ = json.NewDecoder(r.Body).Decode(&obj)
				obj.ResourceVersion = "opaque-b"
				switch mode {
				case "uid":
					obj.UID = "replacement"
				case "version":
					obj.ResourceVersion = "opaque-a"
				case "attempt":
					obj.Labels[agones.AttemptLabel] = "other"
				case "state":
					obj.Status.State = agonesv1.GameServerStateReady
				}
				reply(w, &obj)
			})
			g, err := c.Prepare(context.Background(), "zone", "attempt-1")
			if err != nil {
				t.Fatal(err)
			}
			if err = g.Commit(context.Background()); !errors.Is(err, ErrUnknown) {
				t.Fatalf("invalid ack accepted: %v", err)
			}
		})
	}
}
