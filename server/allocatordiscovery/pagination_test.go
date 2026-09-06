package allocatordiscovery

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	corefake "k8s.io/client-go/kubernetes/typed/core/v1/fake"
	discoveryfake "k8s.io/client-go/kubernetes/typed/discovery/v1/fake"
	ktesting "k8s.io/client-go/testing"
)

func TestDiscoverCompletesEveryCollectionBeforePublishing(t *testing.T) {
	t.Parallel()
	p := pod("allocator-a", "uid-a", "10.0.0.1")
	s := endpointSlice("slice", p)
	r, client := fixture(t, nil, nil)
	for _, resource := range []string{"pods", "endpointslices"} {
		calls := 0
		client.PrependReactor("list", resource, func(action ktesting.Action) (bool, runtime.Object, error) {
			calls++
			list, ok := action.(interface{ GetListOptions() metav1.ListOptions })
			if !ok {
				t.Fatal("not list")
			}
			options := list.GetListOptions()
			wantSelector := "app=allocator"
			if resource == "endpointslices" {
				wantSelector = "kubernetes.io/service-name=allocator"
			}
			wantContinue := ""
			if calls == 2 {
				wantContinue = "next-" + resource
			}
			if action.GetNamespace() != "allocation" || options.Limit != 100 || options.LabelSelector != wantSelector || options.Continue != wantContinue || options.ResourceVersion != "" || options.Watch || calls > 2 {
				t.Fatalf("unbounded or widened list: %+v", options)
			}
			meta := metav1.ListMeta{ResourceVersion: resource + "-rv"}
			if calls == 1 {
				meta.Continue = "next-" + resource
			}
			if resource == "pods" {
				items := []corev1.Pod(nil)
				if calls == 2 {
					items = []corev1.Pod{p}
				}
				return true, &corev1.PodList{ListMeta: meta, Items: items}, nil
			}
			items := []discoveryv1.EndpointSlice(nil)
			if calls == 2 {
				items = []discoveryv1.EndpointSlice{s}
			}
			return true, &discoveryv1.EndpointSliceList{ListMeta: meta, Items: items}, nil
		})
	}
	got, err := r.Discover(t.Context())
	if err != nil || len(got.Members) != 1 || len(got.Members[0].Endpoints) != 1 || len(client.Actions()) != 4 {
		t.Fatalf("incomplete pagination: %+v, %v", got, err)
	}
}

func TestDiscoverDiscardsPartialCollections(t *testing.T) {
	t.Parallel()
	for _, resource := range []string{"pods", "endpointslices"} {
		t.Run(resource, func(t *testing.T) {
			t.Parallel()
			for _, fault := range []string{"late-error", "expired", "repeated-cursor", "changing-version", "missing-version", "oversized-page", "oversized-cursor", "page-budget", "canceled"} {
				t.Run(fault, func(t *testing.T) {
					t.Parallel()
					p := pod("allocator-a", "uid-a", "10.0.0.1")
					s := endpointSlice("slice", p)
					r, client := fixture(t, []corev1.Pod{p}, []discoveryv1.EndpointSlice{s})
					ctx, cancel := context.WithCancel(t.Context())
					defer cancel()
					calls := 0
					client.PrependReactor("list", resource, func(ktesting.Action) (bool, runtime.Object, error) {
						calls++
						meta := metav1.ListMeta{ResourceVersion: "collection-rv", Continue: "first"}
						count := 1
						if fault == "missing-version" {
							meta.ResourceVersion = ""
							meta.Continue = ""
						}
						if calls > 1 {
							count = 0
							meta.Continue = ""
							switch fault {
							case "late-error":
								return true, nil, errors.New("private API detail")
							case "expired":
								return true, nil, apierrors.NewResourceExpired("private expired cursor")
							case "repeated-cursor":
								meta.Continue = "first"
							case "changing-version":
								meta.ResourceVersion = "changed-rv"
							case "missing-version":
								meta.ResourceVersion = ""
							case "oversized-page":
								count = 101
							case "oversized-cursor":
								meta.Continue = strings.Repeat("x", 16385)
							case "page-budget":
								meta.Continue = strings.Repeat("x", calls)
							case "canceled":
								cancel()
							}
						}
						if resource == "pods" {
							items := make([]corev1.Pod, count)
							for i := range items {
								items[i] = p
								if calls > 1 {
									items[i].Name = fmt.Sprintf("extra-%d", i)
									items[i].UID = types.UID(items[i].Name)
								}
							}
							return true, &corev1.PodList{ListMeta: meta, Items: items}, nil
						}
						items := make([]discoveryv1.EndpointSlice, count)
						for i := range items {
							items[i] = s
							if calls > 1 {
								items[i].Name = fmt.Sprintf("extra-%d", i)
								items[i].UID = types.UID(items[i].Name)
							}
						}
						return true, &discoveryv1.EndpointSliceList{ListMeta: meta, Items: items}, nil
					})
					got, err := r.Discover(ctx)
					wantCalls := 2
					if fault == "missing-version" {
						wantCalls = 1
					}
					if fault == "page-budget" {
						wantCalls = config().MaxPages
					}
					if calls != wantCalls {
						t.Fatalf("failure stopped at page %d, want %d", calls, wantCalls)
					}
					if err == nil || strings.Contains(err.Error(), "private") || !reflect.DeepEqual(got, Snapshot{}) || calls > config().MaxPages {
						t.Fatalf("failure leaked partial evidence or API detail: %+v, %v; %d calls", got, err, calls)
					}
					if fault == "canceled" && !errors.Is(err, context.Canceled) {
						t.Fatal(err)
					}
					if resource == "pods" && len(client.Actions()) != calls {
						t.Fatal("continued with EndpointSlice reads after incomplete Pods")
					}
				})
			}
		})
	}
}

func TestNewRefusesUnscopedOrUnboundedDiscovery(t *testing.T) {
	t.Parallel()
	for name, mutate := range map[string]func(*Config){
		"namespace":        func(c *Config) { c.Namespace = "" },
		"namespace-path":   func(c *Config) { c.Namespace = "../secrets" },
		"service":          func(c *Config) { c.ServiceName = "" },
		"service-uid":      func(c *Config) { c.ServiceUID = "" },
		"port-name":        func(c *Config) { c.PortName = "" },
		"selector":         func(c *Config) { c.PodSelector = "" },
		"selector-parse":   func(c *Config) { c.PodSelector = "app in (" },
		"selector-size":    func(c *Config) { c.PodSelector = strings.Repeat("x", 4097) },
		"missing-budget":   func(c *Config) { c.MaxPages = 0 },
		"excessive-budget": func(c *Config) { c.MaxPages = 101 },
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := config()
			mutate(&c)
			if _, err := New(&corefake.FakeCoreV1{Fake: &ktesting.Fake{}}, &discoveryfake.FakeDiscoveryV1{Fake: &ktesting.Fake{}}, c); !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("invalid config accepted: %v", err)
			}
		})
	}
	if _, err := New(nil, nil, config()); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal("nil client accepted")
	}
}

func TestObservePodInvalidIdentityDoesNotCallAPI(t *testing.T) {
	t.Parallel()
	r, client := fixture(t, nil, nil)
	for _, identity := range []Identity{{"foreign", "allocator-a", "uid-a"}, {"allocation", "../secrets", "uid-a"}, {"allocation", "allocator-a", ""}} {
		if _, err := r.ObservePod(t.Context(), identity); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("invalid identity accepted: %v", err)
		}
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := r.Discover(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := r.ObservePod(ctx, Identity{"allocation", "allocator-a", "uid-a"}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if len(client.Actions()) != 0 {
		t.Fatalf("invalid input reached API: %+v", client.Actions())
	}
}
