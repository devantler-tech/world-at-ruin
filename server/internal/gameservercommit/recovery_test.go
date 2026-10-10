package gameservercommit

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatoradmission"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type recoveryTransportFunc func(*http.Request) (*http.Response, error)

// RoundTrip injects a fault at the actual HTTP request boundary of a fixture.
func (f recoveryTransportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Refusing uncertain history and changed ACK/readback bytes is what separates
// an observed metadata nonce from an acknowledged complete recovery proof.
func TestFreshRecoveryRefusesUnknownTargetsAndAcknowledgments(t *testing.T) {
	for _, fault := range []string{"changed-ready", "replacement", "missing", "foreign-attempt", "existing-barrier", "deleting", "lost-ack", "partial-ack", "ack-spec", "ack-status", "ack-attempt", "ack-original-version", "ack-observed-version", "readback-version", "readback-nonce", "readback-status", "cancel-ack", "cancel-readback", "second-target"} {
		t.Run(fault, func(t *testing.T) {
			var active atomic.Bool
			var gets, puts atomic.Int32
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			api := generationAPI(t, "")
			r, reservation, cfg := recoveryPair(t, func(w http.ResponseWriter, req *http.Request) {
				if !active.Load() {
					api(w, req)
					return
				}
				if fault == "second-target" && path.Base(req.URL.Path) == "zone-b" {
					w.WriteHeader(404)
					return
				}
				if req.Method == http.MethodGet {
					gets.Add(1)
				} else {
					puts.Add(1)
				}
				recorder := httptest.NewRecorder()
				api(recorder, req)
				var obj agonesv1.GameServer
				if json.Unmarshal(recorder.Body.Bytes(), &obj) != nil {
					t.Error("invalid API fixture")
					w.WriteHeader(500)
					return
				}
				first := req.Method == http.MethodGet && gets.Load() == 1
				ack := req.Method == http.MethodPut
				readback := req.Method == http.MethodGet && gets.Load() == 2
				if first {
					switch fault {
					case "changed-ready":
						obj.ResourceVersion = "changed"
					case "replacement":
						obj.UID = "replacement"
					case "missing":
						w.WriteHeader(404)
						return
					case "foreign-attempt":
						obj.Status.State = agonesv1.GameServerStateAllocated
						obj.ResourceVersion = "allocated"
						obj.Labels[agones.AttemptLabel] = "foreign"
					case "existing-barrier":
						obj.Annotations = map[string]string{BarrierAnnotation: "visible-old-nonce"}
					case "deleting":
						now := metav1.Now()
						obj.DeletionTimestamp = &now
					}
				}
				if ack {
					switch fault {
					case "lost-ack":
						w.WriteHeader(503)
						return
					case "partial-ack":
						_, _ = w.Write([]byte(`{"metadata":`))
						return
					case "ack-spec":
						obj.Spec.Container = "different"
					case "ack-status":
						obj.Status.Address = "different"
					case "ack-attempt":
						obj.Labels[agones.AttemptLabel] = "different"
					case "ack-original-version", "ack-observed-version":
						obj.ResourceVersion = "opaque-a"
					case "cancel-ack":
						cancel()
					}
				}
				if readback {
					switch fault {
					case "readback-version":
						obj.ResourceVersion = "later"
					case "readback-nonce":
						obj.Annotations[BarrierAnnotation] = "later"
					case "readback-status":
						obj.Status.Address = "different"
					case "cancel-readback":
						cancel()
					}
				}
				reply(w, &obj)
			}, false)
			active.Store(true)
			result, err := r.Fence(ctx)
			if !errors.Is(err, ErrUnknown) || result.state != nil {
				t.Fatalf("unknown target exported complete result: %v", err)
			}
			if _, err = r.Accept(result); !errors.Is(err, ErrClosed) {
				t.Fatal("partial result accepted")
			}
			beforeGets, beforePuts := gets.Load(), puts.Load()
			other, _ := NewRecovery(cfg, reservation)
			if _, err = other.Fence(context.Background()); !errors.Is(err, ErrClosed) || gets.Load() != beforeGets || puts.Load() != beforePuts {
				t.Fatal("visible barrier restored consumed attempt")
			}
		})
	}
}

func TestFreshRecoveryPreservesOneDeadlineAndMetadataOnlyWrites(t *testing.T) {
	var active atomic.Bool
	api := generationAPI(t, "")
	r, reservation, cfg := recoveryPair(t, func(w http.ResponseWriter, req *http.Request) {
		if active.Load() && req.Method == http.MethodPut {
			var obj agonesv1.GameServer
			if json.NewDecoder(req.Body).Decode(&obj) != nil {
				t.Error("invalid barrier")
				w.WriteHeader(400)
				return
			}
			if obj.Status.State != agonesv1.GameServerStateReady || obj.Labels[agones.AttemptLabel] != "" || obj.ResourceVersion != "opaque-a" || obj.Annotations[BarrierAnnotation] == "" {
				t.Error("recovery replayed allocation or refreshed original")
			}
			raw, _ := json.Marshal(obj)
			req.Body = io.NopCloser(bytes.NewReader(raw))
		}
		api(w, req)
	}, false)
	var mu sync.Mutex
	var deadline time.Time
	cfg.REST.WrapTransport = func(base http.RoundTripper) http.RoundTripper {
		return recoveryTransportFunc(func(req *http.Request) (*http.Response, error) {
			got, ok := req.Context().Deadline()
			mu.Lock()
			defer mu.Unlock()
			if !ok || time.Until(got) > 30*time.Second || (!deadline.IsZero() && !got.Equal(deadline)) {
				t.Error("recovery refreshed shared deadline")
			}
			deadline = got
			return base.RoundTrip(req)
		})
	}
	checked, err := NewRecovery(cfg, reservation)
	if err != nil {
		t.Fatal(err)
	}
	_ = r
	active.Store(true)
	if _, err = checked.Fence(context.Background()); err != nil {
		t.Fatal(err)
	}
}

// Real preparation, admission, handoff, ownership and HTTP paths remain intact;
// only the external Nakama/Kubernetes services are replaced by owned fixtures.
func recoveryPair(t *testing.T, handler http.HandlerFunc, allocated bool) (*Recovery, allocatoradmission.RecoveryReservation, Config) {
	t.Helper()
	s := nakamastoragetest.New()
	_, cfg := generationFixture(t, handler)
	g, err := NewDurableGeneration(context.Background(), DurableGenerationConfig{Enabled: true, Storage: s, IncarnationID: "original-incarnation", Record: cfg.Record, Commit: cfg.Commit})
	if err != nil {
		t.Fatal(err)
	}
	generationPrepare(t, g, "pod-a", "zone-a")
	b := generationPrepare(t, g, "pod-b", "zone-b")
	if allocated {
		if err = b.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	binding, version, err := g.CloseForRecovery(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	owner, err := allocatoradmission.NewRecoveryOwner(allocatoradmission.RecoveryOwnerConfig{Enabled: true, Storage: s, Binding: binding, HandoffVersion: version, OwnerID: "recoverer-1"})
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := owner.Reserve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	commit := cfg.Commit
	commit.Enabled = true
	r, err := NewRecovery(commit, reservation)
	if err != nil {
		t.Fatal(err)
	}
	return r, reservation, commit
}

// Omitting a target, losing provenance, or accepting caller-mutated diagnostics
// breaks complete process-local proof; recovery emits metadata barriers only.
func TestFreshRecoveryCompleteMixedInventory(t *testing.T) {
	var puts atomic.Int32
	api := generationAPI(t, "")
	r, reservation, cfg := recoveryPair(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodPut {
			puts.Add(1)
		}
		api(w, req)
	}, true)
	result, err := r.Fence(context.Background())
	if err != nil {
		t.Fatalf("fresh recovery did not fence acknowledged inventory: %v", err)
	}
	got, err := r.Accept(result)
	if err != nil || got.Owner.OwnerID != "recoverer-1" || got.Owner.Version != "v6" || got.Owner.HandoffVersion != "v5" || got.Owner.Handoff.Journal.Binding.Version != "v4" || got.Owner.Handoff.Journal.Binding.IncarnationID != "original-incarnation" || len(got.Grants) != 2 || puts.Load() != 3 {
		t.Fatalf("incomplete binding/result: %+v %v puts=%d", got, err, puts.Load())
	}
	for i, outcome := range []Outcome{Uncommitted, Allocated} {
		g := got.Grants[i]
		name, actor := "zone-a", "pod-a"
		if i == 1 {
			name, actor = "zone-b", "pod-b"
		}
		if g.Name != name || g.ActorUID != actor || g.AttemptID != "attempt-"+name || g.UID != "uid-"+name || g.Namespace != "trial" || g.SourceVersion != "opaque-a" || g.BarrierVersion == "" || g.BarrierVersion == g.SourceVersion || g.Outcome != outcome {
			t.Fatalf("changed original or outcome: %+v", g)
		}
	}
	got.Owner.Handoff.Journal.Binding.MemberPodUIDs[0] = "mutated"
	got.Owner.Handoff.Journal.Grants[0].Name = "mutated"
	got.Grants[0].UID = "mutated"
	again, err := r.Accept(result)
	if err != nil || again.Owner.Handoff.Journal.Binding.MemberPodUIDs[0] != "pod-a" || again.Owner.Handoff.Journal.Grants[0].Name != "zone-a" || again.Grants[0].UID != "uid-zone-a" {
		t.Fatal("result exposed mutable authority")
	}
	if _, err = r.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("recovery replayed")
	}
	other, err := NewRecovery(cfg, reservation)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = other.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("new wrapper restored consumed recovery")
	}
	if _, err = other.Accept(result); !errors.Is(err, ErrClosed) {
		t.Fatal("foreign wrapper accepted complete proof")
	}
	if _, err = r.Accept(RecoveryResult{}); !errors.Is(err, ErrClosed) {
		t.Fatal("zero result reconstructed proof")
	}
}

// Even a failed first GET must exclude a later independently constructed client.
func TestFreshRecoveryPartialFailureConsumesBeforeRead(t *testing.T) {
	var gets atomic.Int32
	var failing atomic.Bool
	api := generationAPI(t, "zone-b")
	r, reservation, cfg := recoveryPair(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodGet {
			gets.Add(1)
			if failing.Load() {
				w.WriteHeader(503)
				return
			}
		}
		api(w, req)
	}, false)
	failing.Store(true)
	before := gets.Load()
	result, err := r.Fence(context.Background())
	if !errors.Is(err, ErrUnknown) || result.state != nil || gets.Load() != before+1 {
		t.Fatalf("first read uncertainty escaped: %v", err)
	}
	other, err := NewRecovery(cfg, reservation)
	if err != nil {
		t.Fatal(err)
	}
	failing.Store(false)
	if _, err = other.Fence(context.Background()); !errors.Is(err, ErrClosed) || gets.Load() != before+1 {
		t.Fatal("independent client retried after first read failure")
	}
}

// Copied handles and separate wrappers race the same originating reservation,
// rather than each owning an independent per-client consumption bit.
func TestFreshRecoveryIndependentClientsRaceOneReservation(t *testing.T) {
	r, reservation, cfg := recoveryPair(t, generationAPI(t, ""), false)
	other, err := NewRecovery(cfg, reservation)
	if err != nil {
		t.Fatal(err)
	}
	copy := *r
	var wg sync.WaitGroup
	var wins atomic.Int32
	for _, owner := range []*Recovery{r, &copy, other} {
		wg.Go(func() {
			result, e := owner.Fence(context.Background())
			if e == nil {
				if _, e = owner.Accept(result); e != nil {
					t.Error(e)
				}
				wins.Add(1)
			} else if !errors.Is(e, ErrClosed) {
				t.Error(e)
			}
		})
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("complete recovery owners=%d", wins.Load())
	}
}

// Default-off construction avoids dependencies; cancellation spends a live
// reservation without exporting or restoring the complete result.
func TestFreshRecoveryDisabledAndCanceled(t *testing.T) {
	if r, err := NewRecovery(Config{}, allocatoradmission.RecoveryReservation{}); r != nil || !errors.Is(err, ErrDisabled) {
		t.Fatal("disabled recovery inspected dependencies")
	}
	r, reservation, cfg := recoveryPair(t, generationAPI(t, ""), false)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := r.Fence(ctx)
	if !errors.Is(err, ErrUnknown) || !reflect.DeepEqual(result, RecoveryResult{}) {
		t.Fatal("canceled recovery exported proof")
	}
	other, _ := NewRecovery(cfg, reservation)
	if _, err = other.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("canceled attempt reopened")
	}
}
