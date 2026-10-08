package gameservercommit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
)

// generationRecord supplies an open two-member observation with a fixed
// canonical digest so tests can detect changed or caller-mutated membership.
func generationRecord() nakamageneration.Record {
	return nakamageneration.Record{GenerationID: "generation-1", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", State: "open", Version: "source-version-1"}
}

// generationFixture creates an explicitly enabled owner with a test-owned HTTP
// endpoint and enough transport budget to exercise the lifetime grant bound.
func generationFixture(t *testing.T, handler http.HandlerFunc) (*Generation, GenerationConfig) {
	t.Helper()
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	// The 256-capability control measures the lifetime bound, not client-go's
	// default rate limiter. Keep the fake transport's budget explicit and local.
	cfg := GenerationConfig{Enabled: true, Commit: Config{REST: &rest.Config{Host: s.URL, QPS: 512, Burst: 512}, Namespace: "trial", Fleet: "fleet"}, Record: generationRecord()}
	g, err := NewGeneration(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return g, cfg
}

// generationAPI supplies exact API bodies, while the owner and capability under test
// perform their real HTTP reads/writes and private admission/receipt checks.
func generationAPI(t *testing.T, failName string) http.HandlerFunc {
	t.Helper()
	var mu sync.Mutex
	objects := make(map[string]*agonesv1.GameServer)
	return func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		name := path.Base(r.URL.Path)
		obj := objects[name]
		if obj == nil {
			obj = ready()
			obj.Name, obj.UID = name, types.UID("uid-"+name)
			objects[name] = obj
		}
		if r.Method == http.MethodPut {
			var next agonesv1.GameServer
			if err := json.NewDecoder(r.Body).Decode(&next); err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			if name == failName {
				w.WriteHeader(503)
				return
			}
			if next.ResourceVersion != obj.ResourceVersion || next.UID != obj.UID {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(409)
				_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Conflict","code":409}`))
				return
			}
			next.ResourceVersion = obj.ResourceVersion + "-next"
			obj = next.DeepCopy()
			objects[name] = obj
		}
		reply(w, obj)
	}
}

// generationPrepare issues a registered capability attributed to the supplied
// actor, with an attempt identifier unique to the named test GameServer.
func generationPrepare(t *testing.T, g *Generation, actor, name string) GenerationGrant {
	t.Helper()
	grant, err := g.Prepare(context.Background(), actor, name, "attempt-"+name)
	if err != nil {
		t.Fatal(err)
	}
	return grant
}

// TestGenerationCompleteReceiptBindsAllIssuedGrants checks complete identity
// and outcome accounting, detached receipt data and irreversible admission.
func TestGenerationCompleteReceiptBindsAllIssuedGrants(t *testing.T) {
	g, cfg := generationFixture(t, generationAPI(t, ""))
	a := generationPrepare(t, g, "pod-a", "zone-a")
	b := generationPrepare(t, g, "pod-b", "zone-b")
	if err := b.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Caller-owned membership must not replace the generation's frozen identity.
	cfg.Record.MemberPodUIDs[0] = "foreign"
	r, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got, err := g.Accept(r)
	if err != nil || got.GenerationID != "generation-1" || got.SourceVersion != "source-version-1" || got.MemberSetDigest != generationRecord().MemberSetDigest || !slices.Equal(got.MemberPodUIDs, []string{"pod-a", "pod-b"}) || len(got.Grants) != 2 {
		t.Fatalf("incomplete or changed receipt: %#v %v", got, err)
	}
	for i, want := range []struct {
		actor, name string
		outcome     Outcome
	}{{"pod-a", "zone-a", Uncommitted}, {"pod-b", "zone-b", Allocated}} {
		v := got.Grants[i]
		if v.ActorUID != want.actor || v.AttemptID != "attempt-"+want.name || v.Namespace != "trial" || v.Name != want.name || v.UID != "uid-"+want.name || v.SourceVersion != "opaque-a" || v.BarrierVersion == v.SourceVersion || v.Outcome != want.outcome {
			t.Fatalf("grant identity/outcome: %#v", v)
		}
	}
	got.MemberPodUIDs[0], got.Grants[0].UID = "changed", "changed"
	again, err := g.Accept(r)
	if err != nil || again.MemberPodUIDs[0] != "pod-a" || again.Grants[0].UID != "uid-zone-a" {
		t.Fatal("acceptance exposed mutable receipt data")
	}
	if _, err = g.Prepare(context.Background(), "pod-a", "zone-c", "attempt-c"); !errors.Is(err, ErrClosed) {
		t.Fatalf("prepare after drain: %v", err)
	}
	if err = a.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("unsubmitted grant reopened: %v", err)
	}
	if _, err = g.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("fence replay: %v", err)
	}
}

// TestGenerationPartialProofNeverAcceptsOrReopens checks that one failed barrier
// denies a complete receipt and permanently closes every issued capability.
func TestGenerationPartialProofNeverAcceptsOrReopens(t *testing.T) {
	g, _ := generationFixture(t, generationAPI(t, "zone-b"))
	a := generationPrepare(t, g, "pod-a", "zone-a")
	generationPrepare(t, g, "pod-b", "zone-b")
	r, err := g.Fence(context.Background())
	if !errors.Is(err, ErrUnknown) {
		t.Fatalf("partial barrier accepted: %v", err)
	}
	if _, err = g.Accept(r); err == nil {
		t.Fatal("partial receipt authorized complete set")
	}
	if err = a.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("partial drain reopened: %v", err)
	}
	if _, err = g.Fence(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("partial fence retried: %v", err)
	}
}

// TestGenerationPreparationRacingDrainCannotExportGrant holds a preparation GET
// across closure and checks that its late result exports no writable capability.
func TestGenerationPreparationRacingDrainCannotExportGrant(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var puts atomic.Int32
	g, _ := generationFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			close(started)
			<-release
		} else {
			puts.Add(1)
		}
		reply(w, ready())
	})
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	done := make(chan error, 1)
	go func() { _, err := g.Prepare(context.Background(), "pod-a", "zone", "attempt-1"); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("prepare did not read")
	}
	r, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got, err := g.Accept(r)
	if err != nil || len(got.Grants) != 0 {
		t.Fatalf("empty issued set: %#v %v", got, err)
	}
	close(release)
	if err = <-done; !errors.Is(err, ErrClosed) {
		t.Fatalf("late prepare exported a capability: %v", err)
	}
	if puts.Load() != 0 {
		t.Fatal("unissued capability wrote storage")
	}
}

// TestGenerationReceiptOriginAndCopiedGrantState races copied grants to prove
// single submission and rejects receipts from zero values or another owner.
func TestGenerationReceiptOriginAndCopiedGrantState(t *testing.T) {
	g, cfg := generationFixture(t, generationAPI(t, ""))
	grant := generationPrepare(t, g, "pod-a", "zone")
	var wg sync.WaitGroup
	results := make(chan error, 16)
	for range 16 {
		copied := grant
		wg.Go(func() { results <- copied.Commit(context.Background()) })
	}
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		} else if !errors.Is(err, ErrClosed) {
			t.Fatal(err)
		}
	}
	if success != 1 {
		t.Fatalf("copied submission successes=%d", success)
	}
	r, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	other, err := NewGeneration(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, pair := range []struct {
		owner   *Generation
		receipt GenerationReceipt
	}{{g, GenerationReceipt{}}, {other, r}} {
		if _, err = pair.owner.Accept(pair.receipt); err == nil {
			t.Fatal("foreign/zero receipt accepted")
		}
	}
	var zero GenerationGrant
	if err = zero.Commit(context.Background()); !errors.Is(err, ErrInvalid) {
		t.Fatalf("zero grant: %v", err)
	}
}

// TestGenerationConcurrentFenceCopiesHaveOneCompleteReceipt races copied owners
// and checks that exactly one closure produces the complete original receipt.
func TestGenerationConcurrentFenceCopiesHaveOneCompleteReceipt(t *testing.T) {
	g, _ := generationFixture(t, generationAPI(t, ""))
	generationPrepare(t, g, "pod-a", "zone-a")
	generationPrepare(t, g, "pod-b", "zone-b")
	var wg sync.WaitGroup
	results := make(chan error, 16)
	for range 16 {
		copied := *g
		wg.Go(func() {
			r, err := copied.Fence(context.Background())
			if err == nil {
				got, acceptErr := g.Accept(r)
				if acceptErr != nil || len(got.Grants) != 2 {
					t.Errorf("copied owner lost complete origin: %#v %v", got, acceptErr)
				}
			}
			results <- err
		})
	}
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else if !errors.Is(err, ErrClosed) {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatalf("generation fence submissions=%d", successes)
	}
}

// TestGenerationCanceledFenceKeepsAdmissionClosed checks that cancellation
// returns unknown completion while every later commit remains inadmissible.
func TestGenerationCanceledFenceKeepsAdmissionClosed(t *testing.T) {
	g, _ := generationFixture(t, generationAPI(t, ""))
	grant := generationPrepare(t, g, "pod-a", "zone")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r, err := g.Fence(ctx)
	if !errors.Is(err, ErrUnknown) || !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled barrier claimed completion: %v", err)
	}
	if _, err = g.Accept(r); err == nil {
		t.Fatal("canceled fence supplied complete authority")
	}
	if err = grant.Commit(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("canceled drain reopened: %v", err)
	}
}

// TestGenerationRejectsMalformedOrReaderOnlyMembership checks opt-in, canonical
// identity and membership, and rejection of a future-schema reader observation.
func TestGenerationRejectsMalformedOrReaderOnlyMembership(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*GenerationConfig)
	}{
		{"off", func(c *GenerationConfig) { c.Enabled = false }},
		{"identity", func(c *GenerationConfig) { c.Record.GenerationID = "invalid identity" }},
		{"version", func(c *GenerationConfig) { c.Record.Version = "*" }},
		{"digest", func(c *GenerationConfig) { c.Record.MemberSetDigest = "wrong" }},
		{"order", func(c *GenerationConfig) { slices.Reverse(c.Record.MemberPodUIDs) }},
		{"duplicate", func(c *GenerationConfig) { c.Record.MemberPodUIDs[1] = "pod-a" }},
		{"empty", func(c *GenerationConfig) { c.Record.MemberPodUIDs = nil }},
		{"state", func(c *GenerationConfig) { c.Record.State = "draining" }},
		{"reader only", func(c *GenerationConfig) {
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: nakamageneration.Collection, Key: "generation-1", Value: `{"schema":2,"generation_id":"generation-1","member_pod_uids":["pod-a","pod-b"],"member_set_digest":"5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d","state":"open"}`, Version: "version-2"})
			store, err := nakamageneration.NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			c.Record, err = store.Load(context.Background(), "generation-1")
			if err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := GenerationConfig{Enabled: true, Commit: Config{REST: &rest.Config{Host: "http://127.0.0.1:1"}, Namespace: "trial", Fleet: "fleet"}, Record: generationRecord()}
			tc.mutate(&cfg)
			if _, err := NewGeneration(cfg); err == nil {
				t.Fatal("invalid generation accepted")
			}
		})
	}
}

// TestGenerationNonmembersAndLifetimeBudget denies unlisted actors and checks
// that the owner cannot export more than 256 capabilities over its lifetime.
func TestGenerationNonmembersAndLifetimeBudget(t *testing.T) {
	g, _ := generationFixture(t, generationAPI(t, ""))
	if _, err := g.Prepare(context.Background(), "foreign", "zone", "attempt-1"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("nonmember: %v", err)
	}
	for i := range 256 {
		generationPrepare(t, g, "pod-a", fmt.Sprintf("zone-%03d", i))
	}
	if _, err := g.Prepare(context.Background(), "pod-a", "overflow", "attempt-overflow"); !errors.Is(err, ErrClosed) {
		t.Fatalf("unbounded grant set: %v", err)
	}
}
