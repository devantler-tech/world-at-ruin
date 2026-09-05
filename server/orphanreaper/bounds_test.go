package orphanreaper

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	clienttesting "k8s.io/client-go/testing"
)

func TestSweepExhaustsConsistentPagesBeforeLeaseScan(t *testing.T) {
	f := newFixture(t, gameServer("one", "attempt-1"), gameServer("two", "attempt-2"))
	calls := 0
	f.api.PrependReactor("list", "gameservers", func(action clienttesting.Action) (bool, runtime.Object, error) {
		list, ok := action.(interface{ GetListOptions() metav1.ListOptions })
		if !ok {
			t.Fatal("unexpected list action")
		}
		options := list.GetListOptions()
		if options.Limit != 100 || options.ResourceVersion != "" {
			t.Fatal("list must use bounded, current consistent reads")
		}
		selector, err := labels.Parse(options.LabelSelector)
		if err != nil {
			t.Fatal(err)
		}
		if selector.Matches(labels.Set{agones.FleetLabel: "zone"}) || selector.Matches(labels.Set{agones.FleetLabel: "foreign", agones.AttemptLabel: "digest"}) {
			t.Fatal("selector admits Ready or foreign Fleet capacity")
		}
		calls++
		result := &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "20"}}
		switch options.Continue {
		case "":
			result.Items = []agonesv1.GameServer{*gameServer("one", "attempt-1")}
			result.Continue = "page-two"
		case "page-two":
			result.Items = []agonesv1.GameServer{*gameServer("two", "attempt-2")}
		default:
			t.Fatal("unexpected cursor")
		}
		return true, result, nil
	})
	f.leases.hook = func() {
		if calls%2 != 0 {
			t.Fatal("lease read before resource enumeration completed")
		}
	}
	f.mustSweep(0)
	if report := f.mustSweep(time.Minute); report.Deleted != 2 || calls != 4 {
		t.Fatalf("pagination = %+v, %d calls", report, calls)
	}
}

func TestSweepRejectsBrokenPaginationWithoutPreservingEvidence(t *testing.T) {
	for _, scenario := range []string{"late failure", "revision change", "empty revision", "cycle", "budget", "oversized", "duplicate name", "invalid digest", "noncanonical digest", "missing uid", "foreign namespace", "wildcard revision"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t, gameServer("one", "attempt-1"))
			f.mustSweep(0)
			f.api.PrependReactor("list", "gameservers", func(action clienttesting.Action) (bool, runtime.Object, error) {
				list, ok := action.(interface{ GetListOptions() metav1.ListOptions })
				if !ok {
					t.Fatal("unexpected list action")
				}
				page := &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "20", Continue: "next"}, Items: []agonesv1.GameServer{*gameServer("one", "attempt-1")}}
				if list.GetListOptions().Continue != "" {
					page.Items = nil
					page.Continue = ""
					switch scenario {
					case "late failure":
						return true, nil, errors.New("secret-page")
					case "revision change":
						page.ResourceVersion = "21"
					case "empty revision":
						page.ResourceVersion = ""
					case "cycle", "budget":
						page.Continue = "next"
					case "duplicate name":
						page.Items = []agonesv1.GameServer{*gameServer("one", "attempt-1")}
					}
				} else {
					switch scenario {
					case "oversized":
						for range 100 {
							page.Items = append(page.Items, *gameServer("extra", "attempt-x"))
						}
					case "invalid digest":
						page.Items[0].Labels[agones.AttemptLabel] = "short"
					case "noncanonical digest":
						page.Items[0].Labels[agones.AttemptLabel] = strings.Repeat("a", 51) + "b"
					case "missing uid":
						page.Items[0].UID = ""
					case "foreign namespace":
						page.Items[0].Namespace = "foreign"
					case "wildcard revision":
						page.ResourceVersion = "0"
						page.Continue = ""
					}
				}
				return true, page, nil
			})
			if scenario == "budget" {
				f.reaper.cfg.MaxPages = 1
			}
			_, err := f.sweep(time.Minute)
			if !errors.Is(err, ErrScan) || strings.Contains(err.Error(), "secret") || len(f.deleted) != 0 {
				t.Fatalf("invalid evidence accepted: %v", err)
			}
			f.api.ReactionChain = f.api.ReactionChain[1:]
			f.mustSweep(time.Minute)
			if len(f.deleted) != 0 {
				t.Fatal("failed scan counted as consecutive absence")
			}
		})
	}
}

func TestResourceVersionPreconditionFencesChangeAfterGet(t *testing.T) {
	f := newFixture(t, gameServer("one", "attempt-1"))
	f.mustSweep(0)
	f.api.PrependReactor("delete", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
		changed := gameServer("one", "new-attempt")
		changed.ResourceVersion = "8"
		f.update(changed)
		return false, nil, nil
	})
	if _, err := f.sweep(time.Minute); !errors.Is(err, ErrCleanup) {
		t.Fatalf("post-get mutation was not fenced: %v", err)
	}
	if len(f.deleted) != 1 || *f.deleted[0].Preconditions.ResourceVersion != "7" {
		t.Fatal("delete did not carry the validated resource revision")
	}
	if _, err := f.api.Tracker().Get(agonesv1.SchemeGroupVersion.WithResource("gameservers"), "world", "one"); err != nil {
		t.Fatal("mutated server was deleted")
	}
}

func TestSweepDeadlineAndOverlap(t *testing.T) {
	f := newFixture(t)
	f.reaper.cfg.SweepTimeout = 20 * time.Millisecond
	entered := make(chan struct{})
	f.api.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
		close(entered)
		time.Sleep(50 * time.Millisecond)
		return true, &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "1"}}, nil
	})
	done := make(chan error, 1)
	go func() { _, err := f.reaper.Sweep(context.Background()); done <- err }()
	<-entered
	if _, err := f.reaper.Sweep(context.Background()); !errors.Is(err, ErrBusy) {
		t.Fatalf("overlap = %v", err)
	}
	if err := <-done; !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline = %v", err)
	}
}

func TestRunIsExplicitStartupAndPeriodicSupervision(t *testing.T) {
	f := newFixture(t)
	if len(f.api.Actions()) != 0 {
		t.Fatal("constructor activated cleanup")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var observations atomic.Int32
	started := time.Now()
	err := f.reaper.Run(ctx, func(_ Report, _ error) {
		if observations.Add(1) == 1 && time.Since(started) > 500*time.Millisecond {
			t.Error("startup scan waited for the first interval")
		}
		if observations.Load() == 2 {
			cancel()
		}
	})
	if !errors.Is(err, context.Canceled) || observations.Load() != 2 {
		t.Fatalf("supervisor = %v, %d observations", err, observations.Load())
	}
}

func TestNewRejectsUnboundedConfiguration(t *testing.T) {
	f := newFixture(t)
	for _, mutate := range []func(*Config){
		func(c *Config) { c.Namespace = "*" }, func(c *Config) { c.Fleet = "*" },
		func(c *Config) { c.Grace = time.Nanosecond }, func(c *Config) { c.Grace = 2 * time.Hour },
		func(c *Config) { c.Interval = -time.Second }, func(c *Config) { c.SweepTimeout = 2 * time.Minute },
		func(c *Config) { c.MaxPages = -1 }, func(c *Config) { c.MaxPages = 1001 },
	} {
		cfg := f.reaper.cfg
		mutate(&cfg)
		if r, err := New(f.reaper.api, f.leases, cfg); err == nil || r != nil {
			t.Fatalf("invalid config accepted: %+v", cfg)
		}
	}
	if r, err := New(nil, f.leases, f.reaper.cfg); err == nil || r != nil {
		t.Fatal("nil resources accepted")
	}
	if r, err := New(f.reaper.api, nil, f.reaper.cfg); err == nil || r != nil {
		t.Fatal("nil leases accepted")
	}
}
