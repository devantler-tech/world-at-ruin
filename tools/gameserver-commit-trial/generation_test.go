package trial

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	typed "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

// resourcePair creates two independent GameServers in the native storage
// fixture so a generation fence must account for distinct object identities.
func resourcePair(t *testing.T) (typed.GameServerInterface, []*agonesv1.GameServer) {
	t.Helper()
	api, first := resource(t)
	second := first.DeepCopy()
	second.Name, second.UID, second.ResourceVersion = "zone-two", "", ""
	second.CreationTimestamp = metav1.Time{}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	second, err := api.Create(ctx, second, metav1.CreateOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return api, []*agonesv1.GameServer{first, second}
}

// nativeGeneration binds an explicitly enabled two-member owner to the supplied
// native API transport without adding it to any production allocator path.
func nativeGeneration(t *testing.T, cfg *rest.Config, ns string) *gameservercommit.Generation {
	t.Helper()
	g, err := gameservercommit.NewGeneration(gameservercommit.GenerationConfig{Enabled: true,
		Commit: gameservercommit.Config{REST: cfg, Namespace: ns, Fleet: "fleet"},
		Record: nakamageneration.Record{GenerationID: "generation-1", MemberPodUIDs: []string{"pod-a", "pod-b"}, MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d", State: "open", Version: "source-version-1"}})
	if err != nil {
		t.Fatal(err)
	}
	return g
}

// pairGrants registers one exact-object capability per member before tests
// submit or close either capability against the native Kubernetes API.
func pairGrants(t *testing.T, g *gameservercommit.Generation, objects []*agonesv1.GameServer) []gameservercommit.GenerationGrant {
	t.Helper()
	grants := make([]gameservercommit.GenerationGrant, len(objects))
	for i, object := range objects {
		actor := []string{"pod-a", "pod-b"}[i]
		var err error
		grants[i], err = g.Prepare(context.Background(), actor, object.Name, "attempt-"+object.Name)
		if err != nil {
			t.Fatal(err)
		}
	}
	return grants
}

// readNamed observes persisted native state independently of the generation's
// private receipts, with a bounded deadline for storage verification.
func readNamed(t *testing.T, api typed.GameServerInterface, name string) *agonesv1.GameServer {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := api.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// TestGenerationStorageFencesEveryOutstandingMutation checks that omitting even
// one issued grant from Fence makes its held storage write succeed;
// the unfenced arms prove this is actual optimistic concurrency, not proxy refusal.
func TestGenerationStorageFencesEveryOutstandingMutation(t *testing.T) {
	for _, fenced := range []bool{false, true} {
		for _, canceled := range []bool{false, true} {
			t.Run(fmt.Sprintf("fenced-%t-canceled-%t", fenced, canceled), func(t *testing.T) {
				api, objects := resourcePair(t)
				cfg, held := proxyMany(t, "zone", "zone-two")
				g := nativeGeneration(t, cfg, objects[0].Namespace)
				grants := pairGrants(t, g, objects)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				done := make([]chan error, len(grants))
				for i, grant := range grants {
					done[i] = make(chan error, 1)
					go func() { done[i] <- grant.Commit(ctx) }()
					reached(t, held[objects[i].Name])
				}
				if canceled {
					cancel()
					for _, result := range done {
						if err := <-result; !errors.Is(err, context.Canceled) || !errors.Is(err, gameservercommit.ErrUnknown) {
							t.Fatalf("cancellation mistaken for absence: %v", err)
						}
					}
				}
				versions := make([]string, len(objects))
				if fenced {
					r, err := g.Fence(context.Background())
					if err != nil {
						t.Fatal(err)
					}
					got, err := g.Accept(r)
					if err != nil || len(got.Grants) != 2 || got.GenerationID != "generation-1" {
						t.Fatalf("complete receipt: %#v %v", got, err)
					}
					for i, object := range objects {
						v := got.Grants[i]
						if v.UID != string(object.UID) || v.SourceVersion != object.ResourceVersion || v.Outcome != gameservercommit.Uncommitted || v.Name != object.Name {
							t.Fatalf("wrong native identity: %#v", v)
						}
						stored := readNamed(t, api, object.Name)
						versions[i] = stored.ResourceVersion
						if v.BarrierVersion != stored.ResourceVersion || stored.Annotations[gameservercommit.BarrierAnnotation] == "" {
							t.Fatal("receipt not backed by storage barrier")
						}
					}
					for _, grant := range grants {
						if err := grant.Commit(context.Background()); !errors.Is(err, gameservercommit.ErrClosed) {
							t.Fatalf("post-drain commit: %v", err)
						}
					}
				}
				for i, object := range objects {
					h := held[object.Name]
					h.unblock()
					want := 200
					if fenced {
						want = 409
					}
					storedStatus(t, h, want)
					if !canceled {
						err := <-done[i]
						if (fenced && !errors.Is(err, gameservercommit.ErrConflict)) || (!fenced && err != nil) {
							t.Fatalf("held write result: %v", err)
						}
					}
					stored := readNamed(t, api, object.Name)
					if fenced {
						if stored.ResourceVersion != versions[i] || stored.Status.State != agonesv1.GameServerStateReady {
							t.Fatal("late mutation bypassed complete fence")
						}
					} else if stored.Status.State != agonesv1.GameServerStateAllocated {
						t.Fatal("unfenced positive control did not allocate")
					}
				}
			})
		}
	}
}

// TestGenerationStorageRetainsAllocatedOutcome checks mixed native outcomes
// and proves that a barrier preserves an already persisted allocation.
func TestGenerationStorageRetainsAllocatedOutcome(t *testing.T) {
	api, objects := resourcePair(t)
	g := nativeGeneration(t, control, objects[0].Namespace)
	grants := pairGrants(t, g, objects)
	if err := grants[0].Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	r, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got, err := g.Accept(r)
	if err != nil || len(got.Grants) != 2 || got.Grants[0].Outcome != gameservercommit.Allocated || got.Grants[1].Outcome != gameservercommit.Uncommitted {
		t.Fatalf("allocation reclassified: %#v %v", got, err)
	}
	if readNamed(t, api, objects[0].Name).Status.State != agonesv1.GameServerStateAllocated {
		t.Fatal("fence erased allocation")
	}
}

type lostBarrierReply struct{ base http.RoundTripper }

// RoundTrip lets native storage persist the second barrier before dropping its
// acknowledgement, proving that storage success alone cannot authorize a receipt.
func (l lostBarrierReply) RoundTrip(r *http.Request) (*http.Response, error) {
	response, err := l.base.RoundTrip(r)
	if err == nil && r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/zone-two") {
		_ = response.Body.Close()
		return nil, errors.New("trial lost barrier acknowledgement")
	}
	return response, err
}

// TestGenerationStorageIncompleteProofCannotAccept injects second-target faults
// and proves that the first target's partial native fence supplies no authority.
func TestGenerationStorageIncompleteProofCannotAccept(t *testing.T) {
	for _, fault := range []string{"replacement", "changed-history", "lost-ack", "missing"} {
		t.Run(fault, func(t *testing.T) {
			api, objects := resourcePair(t)
			cfg := rest.CopyConfig(control)
			if fault == "lost-ack" {
				cfg.WrapTransport = func(base http.RoundTripper) http.RoundTripper { return lostBarrierReply{base: base} }
			}
			g := nativeGeneration(t, cfg, objects[0].Namespace)
			grants := pairGrants(t, g, objects)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			second := objects[1].DeepCopy()
			switch fault {
			case "replacement", "missing":
				if err := api.Delete(ctx, second.Name, metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &second.UID}}); err != nil {
					t.Fatal(err)
				}
				if fault == "replacement" {
					second.UID, second.ResourceVersion, second.CreationTimestamp = "", "", metav1.Time{}
					var err error
					second, err = api.Create(ctx, second, metav1.CreateOptions{})
					if err != nil {
						t.Fatal(err)
					}
				}
			case "changed-history":
				second.Annotations = map[string]string{"trial.example/change": "other"}
				var err error
				second, err = api.Update(ctx, second, metav1.UpdateOptions{})
				if err != nil {
					t.Fatal(err)
				}
			}
			r, err := g.Fence(ctx)
			if !errors.Is(err, gameservercommit.ErrUnknown) {
				t.Fatalf("incomplete fence accepted: %v", err)
			}
			if _, err = g.Accept(r); err == nil {
				t.Fatal("partial set supplied authority")
			}
			first := readNamed(t, api, "zone")
			if first.Annotations[gameservercommit.BarrierAnnotation] == "" {
				t.Fatal("test did not reach partial barrier")
			}
			if _, err = g.Fence(ctx); !errors.Is(err, gameservercommit.ErrClosed) {
				t.Fatalf("partial barrier replayed: %v", err)
			}
			for _, grant := range grants {
				if err = grant.Commit(ctx); !errors.Is(err, gameservercommit.ErrClosed) {
					t.Fatalf("partial drain reopened: %v", err)
				}
			}
			if readNamed(t, api, "zone").ResourceVersion != first.ResourceVersion {
				t.Fatal("fence retry rewrote accepted member")
			}
			if fault != "missing" {
				stored := readNamed(t, api, "zone-two")
				if fault == "lost-ack" {
					if stored.Annotations[gameservercommit.BarrierAnnotation] == "" {
						t.Fatal("lost-ack control never persisted barrier")
					}
				} else if stored.UID != second.UID || stored.ResourceVersion != second.ResourceVersion || stored.Annotations[gameservercommit.BarrierAnnotation] != "" {
					t.Fatal("unknown target mutated")
				}
			}
		})
	}
}
