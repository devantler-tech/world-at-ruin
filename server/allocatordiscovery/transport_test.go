package allocatordiscovery

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	discoveryclient "k8s.io/client-go/kubernetes/typed/discovery/v1"
	"k8s.io/client-go/rest"
)

// This exercises generated clients, URL/query construction and API decoding;
// fake reactors alone cannot establish what would actually go over the wire.
func TestGeneratedClientsUseOnlyNamespacedReadEndpoints(t *testing.T) {
	t.Parallel()
	p := pod("allocator-a", "uid-a", "10.0.0.1")
	s := endpointSlice("slice", p)
	// ObjectReference permits an omitted API version; retain exact Pod identity.
	s.Endpoints[0].TargetRef.APIVersion = ""
	var mu sync.Mutex
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		paths = append(paths, r.URL.Path)
		if r.Method != http.MethodGet {
			t.Error("non-read request")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var result any
		switch r.URL.Path {
		case "/api/v1/namespaces/allocation/pods":
			if r.URL.Query().Get("labelSelector") != "app=allocator" || r.URL.Query().Get("limit") != "100" || r.URL.Query().Get("resourceVersion") != "" {
				t.Errorf("unexpected Pod query: %s", r.URL.RawQuery)
			}
			result = &corev1.PodList{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "PodList"}, ListMeta: metav1.ListMeta{ResourceVersion: "pods-rv"}, Items: []corev1.Pod{p}}
		case "/apis/discovery.k8s.io/v1/namespaces/allocation/endpointslices":
			if r.URL.Query().Get("labelSelector") != "kubernetes.io/service-name=allocator" || r.URL.Query().Get("limit") != "100" {
				t.Errorf("unexpected slice query: %s", r.URL.RawQuery)
			}
			result = &discoveryv1.EndpointSliceList{TypeMeta: metav1.TypeMeta{APIVersion: "discovery.k8s.io/v1", Kind: "EndpointSliceList"}, ListMeta: metav1.ListMeta{ResourceVersion: "slices-rv"}, Items: []discoveryv1.EndpointSlice{s}}
		case "/api/v1/namespaces/allocation/pods/allocator-a":
			current := p.DeepCopy()
			current.TypeMeta = metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"}
			current.UID = "replacement-uid"
			result = current
		default:
			t.Errorf("unexpected API resource: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(result); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(server.Close)
	transport := &rest.Config{Host: server.URL, Timeout: time.Second}
	core, err := coreclient.NewForConfig(transport)
	if err != nil {
		t.Fatal(err)
	}
	discovery, err := discoveryclient.NewForConfig(transport)
	if err != nil {
		t.Fatal(err)
	}
	r, err := New(core, discovery, config())
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := r.Discover(t.Context())
	if err != nil || len(snapshot.Members) != 1 || len(snapshot.Members[0].EligibleEndpoints()) != 1 {
		t.Fatalf("real client discovery: %+v, %v", snapshot, err)
	}
	observed, err := r.ObservePod(t.Context(), snapshot.Members[0].Identity)
	if err != nil || observed.Presence != Replaced || observed.Pod.Identity.UID != "replacement-uid" {
		t.Fatalf("real client UID reuse: %+v, %v", observed, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(paths) != 3 {
		t.Fatalf("extra API operations: %v", paths)
	}
}
