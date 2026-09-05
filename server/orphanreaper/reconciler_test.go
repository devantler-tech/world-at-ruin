package orphanreaper

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"
)

type leaseReader struct {
	protected map[string]struct{}
	err       error
	calls     int
	hook      func()
}

func (l *leaseReader) ProtectedAttempts(ctx context.Context, _ int) (map[string]struct{}, error) {
	l.calls++
	if l.hook != nil {
		l.hook()
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return l.protected, l.err
}

type fixture struct {
	t       *testing.T
	reaper  *Reconciler
	api     *agonesfake.Clientset
	leases  *leaseReader
	now     time.Time
	deleted []metav1.DeleteOptions
}

func gameServer(name, attempt string) *agonesv1.GameServer {
	digest, _ := agones.CorrelationLabel(attempt)
	return &agonesv1.GameServer{ObjectMeta: metav1.ObjectMeta{
		Namespace: "world", Name: name, UID: types.UID(name + "-uid"), ResourceVersion: "7",
		Labels: map[string]string{agones.FleetLabel: "zone", agones.AttemptLabel: digest},
	}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated}}
}

func newFixture(t *testing.T, objects ...*agonesv1.GameServer) *fixture {
	t.Helper()
	seed := make([]runtime.Object, len(objects))
	for i, object := range objects {
		seed[i] = object
	}
	f := &fixture{t: t, api: agonesfake.NewSimpleClientset(seed...), leases: &leaseReader{protected: map[string]struct{}{}}, now: time.Unix(1000, 0)}
	// The generated client is exercised; the fake must supply the API server's
	// consistent list revision and enforce real delete preconditions.
	f.api.PrependReactor("list", "gameservers", func(action clienttesting.Action) (bool, runtime.Object, error) {
		list, err := f.api.Tracker().List(agonesv1.SchemeGroupVersion.WithResource("gameservers"), agonesv1.SchemeGroupVersion.WithKind("GameServer"), "world")
		if err != nil {
			return true, nil, err
		}
		servers, ok := list.(*agonesv1.GameServerList)
		if !ok {
			t.Fatal("unexpected list type")
		}
		servers.ResourceVersion = "10"
		return true, servers, nil
	})
	f.api.PrependReactor("delete", "gameservers", func(action clienttesting.Action) (bool, runtime.Object, error) {
		deletion, ok := action.(clienttesting.DeleteAction)
		if !ok {
			t.Fatal("unexpected delete type")
		}
		options := deletion.GetDeleteOptions()
		f.deleted = append(f.deleted, options)
		object, err := f.api.Tracker().Get(agonesv1.SchemeGroupVersion.WithResource("gameservers"), "world", deletion.GetName())
		if err != nil {
			return true, nil, err
		}
		server, ok := object.(*agonesv1.GameServer)
		if !ok {
			t.Fatal("unexpected object type")
		}
		if options.Preconditions == nil || options.Preconditions.UID == nil || *options.Preconditions.UID != server.UID || options.Preconditions.ResourceVersion == nil || *options.Preconditions.ResourceVersion != server.ResourceVersion {
			return true, nil, apierrors.NewConflict(schema.GroupResource{Group: "agones.dev", Resource: "gameservers"}, deletion.GetName(), errors.New("precondition mismatch"))
		}
		return true, nil, f.api.Tracker().Delete(agonesv1.SchemeGroupVersion.WithResource("gameservers"), "world", deletion.GetName())
	})
	var err error
	f.reaper, err = New(f.api.AgonesV1().GameServers("world"), f.leases, Config{Namespace: "world", Fleet: "zone", Grace: time.Minute, Interval: time.Second, SweepTimeout: time.Second, MaxPages: 10})
	if err != nil {
		t.Fatal(err)
	}
	f.reaper.now = func() time.Time { return f.now }
	return f
}

func (f *fixture) sweep(advance time.Duration) (Report, error) {
	f.t.Helper()
	f.now = f.now.Add(advance)
	return f.reaper.Sweep(context.Background())
}

func (f *fixture) mustSweep(advance time.Duration) Report {
	f.t.Helper()
	report, err := f.sweep(advance)
	if err != nil {
		f.t.Fatal(err)
	}
	return report
}

func (f *fixture) update(server *agonesv1.GameServer) {
	f.t.Helper()
	if err := f.api.Tracker().Update(agonesv1.SchemeGroupVersion.WithResource("gameservers"), server, "world"); err != nil {
		f.t.Fatal(err)
	}
}

func TestSweepRequiresConsecutiveObservationsAndGrace(t *testing.T) {
	f := newFixture(t, gameServer("one", "attempt-1"))
	if report := f.mustSweep(0); report.Waiting != 1 || len(f.deleted) != 0 {
		t.Fatalf("first observation = %+v", report)
	}
	f.mustSweep(59 * time.Second)
	if len(f.deleted) != 0 {
		t.Fatal("grace bypassed")
	}
	if report := f.mustSweep(time.Second); report.Deleted != 1 || len(f.deleted) != 1 {
		t.Fatalf("mature orphan = %+v", report)
	}
	if report := f.mustSweep(time.Minute); report.Deleted != 0 {
		t.Fatal("absent object was counted twice")
	}
	for _, action := range f.api.Actions() {
		if action.GetResource().Resource != "gameservers" || (action.GetVerb() != "get" && action.GetVerb() != "list" && action.GetVerb() != "delete") {
			t.Fatal("unexpected Kubernetes authority")
		}
	}
}

func TestSweepProtectsLeaseOwnersAndReadyCapacity(t *testing.T) {
	ready := gameServer("ready", "")
	ready.Status.State = agonesv1.GameServerStateReady
	delete(ready.Labels, agones.AttemptLabel)
	labelledReady := gameServer("labelled-ready", "attempt-3")
	labelledReady.Status.State = agonesv1.GameServerStateReady
	owned := gameServer("owned", "attempt-1")
	duplicate := gameServer("duplicate", "attempt-1")
	f := newFixture(t, ready, labelledReady, owned, duplicate, gameServer("orphan", "attempt-2"))
	f.leases.protected[owned.Labels[agones.AttemptLabel]] = struct{}{}
	f.mustSweep(0)
	report := f.mustSweep(time.Minute)
	if report.Protected != 2 || report.Deleted != 1 || len(f.deleted) != 1 {
		t.Fatalf("protection = %+v", report)
	}
}

func TestSweepDeletesDuplicateOrphansByEachOwnUID(t *testing.T) {
	f := newFixture(t, gameServer("one", "attempt-1"), gameServer("two", "attempt-1"))
	f.mustSweep(0)
	if report := f.mustSweep(time.Minute); report.Deleted != 2 {
		t.Fatalf("duplicates = %+v", report)
	}
	seen := map[types.UID]bool{}
	for _, options := range f.deleted {
		seen[*options.Preconditions.UID] = true
	}
	if !seen["one-uid"] || !seen["two-uid"] {
		t.Fatal("duplicate cleanup reused an identity")
	}
}

func TestSweepResetsEvidenceOnLeaseOrIncompleteScan(t *testing.T) {
	for _, scenario := range []string{"lease", "lease failure", "resource failure", "missing", "restart", "clock reversal"} {
		t.Run(scenario, func(t *testing.T) {
			server := gameServer("one", "attempt-1")
			f := newFixture(t, server)
			f.mustSweep(0)
			switch scenario {
			case "lease":
				f.leases.protected[server.Labels[agones.AttemptLabel]] = struct{}{}
				f.mustSweep(time.Minute)
				clear(f.leases.protected)
			case "lease failure":
				f.leases.err = errors.New("private-lease-token")
				if _, err := f.sweep(time.Minute); err == nil {
					t.Fatal("failed scan accepted")
				}
				f.leases.err = nil
			case "resource failure":
				f.api.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
					return true, nil, errors.New("private-envelope")
				})
				if _, err := f.sweep(time.Minute); err == nil {
					t.Fatal("failed list accepted")
				}
				f.api.ReactionChain = f.api.ReactionChain[1:]
			case "missing":
				if err := f.api.Tracker().Delete(agonesv1.SchemeGroupVersion.WithResource("gameservers"), "world", "one"); err != nil {
					t.Fatal(err)
				}
				f.mustSweep(time.Minute)
				if err := f.api.Tracker().Add(server); err != nil {
					t.Fatal(err)
				}
			case "restart":
				restarted, err := New(f.api.AgonesV1().GameServers("world"), f.leases, f.reaper.cfg)
				if err != nil {
					t.Fatal(err)
				}
				f.reaper = restarted
				f.reaper.now = func() time.Time { return f.now }
			case "clock reversal":
				if _, err := f.sweep(-time.Second); err == nil {
					t.Fatal("backward clock accepted")
				}
			}
			f.mustSweep(time.Minute)
			if len(f.deleted) != 0 {
				t.Fatal("nonconsecutive observation deleted a server")
			}
			f.mustSweep(time.Minute)
			if len(f.deleted) != 1 {
				t.Fatal("fresh grace did not eventually reclaim")
			}
		})
	}
}

func TestSweepRevalidatesIdentityStateAndMetadataBeforeDelete(t *testing.T) {
	for _, change := range []string{"uid", "attempt", "fleet", "state"} {
		t.Run(change, func(t *testing.T) {
			server := gameServer("one", "attempt-1")
			f := newFixture(t, server)
			f.mustSweep(0)
			f.leases.hook = func() {
				switch change {
				case "uid":
					server.UID = "replacement-uid"
				case "attempt":
					server.Labels[agones.AttemptLabel], _ = agones.CorrelationLabel("other")
				case "fleet":
					server.Labels[agones.FleetLabel] = "other"
				case "state":
					server.Status.State = agonesv1.GameServerStateReady
				}
				f.update(server)
			}
			f.mustSweep(time.Minute)
			if len(f.deleted) != 0 {
				t.Fatal("changed resource was deleted")
			}
		})
	}
}

func TestSweepReconcilesAmbiguousDeletionAndContinuesOtherOrphans(t *testing.T) {
	for _, outcome := range []string{"absent", "replacement", "same", "read failure"} {
		t.Run(outcome, func(t *testing.T) {
			f := newFixture(t, gameServer("one", "attempt-1"), gameServer("two", "attempt-2"))
			f.mustSweep(0)
			readFailure := false
			f.api.PrependReactor("get", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
				if readFailure {
					return true, nil, errors.New("secret-get-error")
				}
				return false, nil, nil
			})
			f.api.PrependReactor("delete", "gameservers", func(action clienttesting.Action) (bool, runtime.Object, error) {
				deletion, ok := action.(clienttesting.DeleteAction)
				if !ok {
					t.Fatal("unexpected delete")
				}
				if deletion.GetName() != "one" {
					return false, nil, nil
				}
				switch outcome {
				case "absent":
					if err := f.api.Tracker().Delete(agonesv1.SchemeGroupVersion.WithResource("gameservers"), "world", "one"); err != nil {
						t.Fatal(err)
					}
				case "replacement":
					replacement := gameServer("one", "replacement")
					replacement.UID = "new-uid"
					f.update(replacement)
				case "read failure":
					readFailure = true
				}
				return true, nil, errors.New("secret-delete-error")
			})
			report, err := f.sweep(time.Minute)
			if outcome == "same" || outcome == "read failure" {
				if err == nil || strings.Contains(err.Error(), "secret") {
					t.Fatalf("unsanitized/missing refusal: %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if outcome != "read failure" && report.Deleted < 1 {
				t.Fatal("one failure stalled unrelated cleanup")
			}
			if outcome == "same" {
				f.api.ReactionChain = f.api.ReactionChain[1:]
				if got := f.mustSweep(time.Minute); got.Deleted != 1 {
					t.Fatalf("retry = %+v", got)
				}
			}
		})
	}
}

func TestSweepCancelsBeforeMutation(t *testing.T) {
	f := newFixture(t, gameServer("one", "attempt-1"))
	f.mustSweep(0)
	ctx, cancel := context.WithCancel(context.Background())
	f.leases.hook = cancel
	f.now = f.now.Add(time.Minute)
	if _, err := f.reaper.Sweep(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation = %v", err)
	}
	if len(f.deleted) != 0 {
		t.Fatal("deleted after cancellation")
	}
}
