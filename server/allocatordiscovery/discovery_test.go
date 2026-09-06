package allocatordiscovery

import (
	"context"
	"errors"
	"net/netip"
	"reflect"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	corefake "k8s.io/client-go/kubernetes/typed/core/v1/fake"
	discoveryfake "k8s.io/client-go/kubernetes/typed/discovery/v1/fake"
	ktesting "k8s.io/client-go/testing"
)

func ptr[T any](value T) *T { return &value }

func config() Config {
	return Config{Namespace: "allocation", PodSelector: "app=allocator", ServiceName: "allocator", ServiceUID: "service-uid", PortName: "grpc", MaxPages: 3}
}

func pod(name, uid, ip string) corev1.Pod {
	return corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "allocation", UID: types.UID(uid), ResourceVersion: "pod-rv", Labels: map[string]string{"app": "allocator"}},
		Status:     corev1.PodStatus{Phase: corev1.PodRunning, PodIP: ip, PodIPs: []corev1.PodIP{{IP: ip}}, Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}},
	}
}

func endpointSlice(name string, p corev1.Pod) discoveryv1.EndpointSlice {
	return discoveryv1.EndpointSlice{
		ObjectMeta:  metav1.ObjectMeta{Name: name, Namespace: "allocation", UID: types.UID(name + "-uid"), ResourceVersion: "slice-rv", Labels: map[string]string{discoveryv1.LabelServiceName: "allocator"}, OwnerReferences: []metav1.OwnerReference{{APIVersion: "v1", Kind: "Service", Name: "allocator", UID: "service-uid", Controller: ptr(true)}}},
		AddressType: discoveryv1.AddressTypeIPv4,
		Ports:       []discoveryv1.EndpointPort{{Name: ptr("grpc"), Port: ptr(int32(443)), Protocol: ptr(corev1.ProtocolTCP)}},
		Endpoints:   []discoveryv1.Endpoint{{Addresses: []string{p.Status.PodIP}, TargetRef: &corev1.ObjectReference{APIVersion: "v1", Kind: "Pod", Namespace: p.Namespace, Name: p.Name, UID: p.UID}, Conditions: discoveryv1.EndpointConditions{Ready: ptr(true), Serving: ptr(true), Terminating: ptr(false)}}},
	}
}

func fixture(t *testing.T, pods []corev1.Pod, slices []discoveryv1.EndpointSlice) (*Reader, *ktesting.Fake) {
	t.Helper()
	client := &ktesting.Fake{}
	client.PrependReactor("list", "pods", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, &corev1.PodList{ListMeta: metav1.ListMeta{ResourceVersion: "pods-rv"}, Items: pods}, nil
	})
	client.PrependReactor("list", "endpointslices", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, &discoveryv1.EndpointSliceList{ListMeta: metav1.ListMeta{ResourceVersion: "slices-rv"}, Items: slices}, nil
	})
	reader, err := New(&corefake.FakeCoreV1{Fake: client}, &discoveryfake.FakeDiscoveryV1{Fake: client}, config())
	if err != nil {
		t.Fatal(err)
	}
	return reader, client
}

func TestDiscoverJoinsAllMembersAndDeduplicatesDualStack(t *testing.T) {
	t.Parallel()
	a, b := pod("allocator-a", "uid-a", "10.0.0.1"), pod("allocator-b", "uid-b", "10.0.0.2")
	a.Status.PodIPs = append(a.Status.PodIPs, corev1.PodIP{IP: "fd00::1"})
	v4 := endpointSlice("v4", a)
	v6 := endpointSlice("v6", a)
	v6.AddressType = discoveryv1.AddressTypeIPv6
	v6.Endpoints[0].Addresses = []string{"fd00::1"}
	duplicate := *v4.DeepCopy()
	duplicate.Name = "duplicate"
	duplicate.UID = "duplicate-uid"
	reader, client := fixture(t, []corev1.Pod{b, a}, []discoveryv1.EndpointSlice{v6, duplicate, v4})
	got, err := reader.Discover(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if got.PodResourceVersion != "pods-rv" || got.EndpointSliceResourceVersion != "slices-rv" || len(got.Members) != 2 {
		t.Fatalf("incomplete observation: %+v", got)
	}
	want := Member{Identity: Identity{"allocation", "allocator-a", "uid-a"}, ResourceVersion: "pod-rv", Phase: corev1.PodRunning, Ready: corev1.ConditionTrue, Endpoints: []Endpoint{
		{Address: netip.MustParseAddr("10.0.0.1"), Port: 443, Ready: corev1.ConditionTrue, Serving: corev1.ConditionTrue, Terminating: corev1.ConditionFalse},
		{Address: netip.MustParseAddr("fd00::1"), Port: 443, Ready: corev1.ConditionTrue, Serving: corev1.ConditionTrue, Terminating: corev1.ConditionFalse},
	}}
	if !reflect.DeepEqual(got.Members[0], want) || got.Members[1].Identity.UID != "uid-b" || len(got.Members[1].Endpoints) != 0 {
		t.Fatalf("join differs: %+v", got)
	}
	eligible := got.Members[0].EligibleEndpoints()
	if !reflect.DeepEqual(eligible, want.Endpoints) {
		t.Fatalf("eligible endpoints: %+v", eligible)
	}
	eligible[0].Port = 1
	if got.Members[0].Endpoints[0].Port != 443 {
		t.Fatal("eligible endpoints alias the observation")
	}
	got.Members[0].Endpoints[0].Port = 2
	again, err := reader.Discover(t.Context())
	if err != nil || !reflect.DeepEqual(again.Members[0], want) {
		t.Fatalf("observation aliases client storage: %+v, %v", again, err)
	}
	for _, action := range client.Actions() {
		if action.GetNamespace() != "allocation" || action.GetVerb() != "list" || (action.GetResource().Resource != "pods" && action.GetResource().Resource != "endpointslices") {
			t.Fatalf("authority widened: %+v", action)
		}
	}
}

func TestDiscoverAcceptsDNSLabelServicePortNames(t *testing.T) {
	t.Parallel()
	p := pod("allocator-a", "uid-a", "10.0.0.1")
	s := endpointSlice("slice", p)
	portName := "allocator-grpc-secure"
	s.Ports[0].Name = &portName
	_, client := fixture(t, []corev1.Pod{p}, []discoveryv1.EndpointSlice{s})
	c := config()
	c.PortName = portName
	r, err := New(&corefake.FakeCoreV1{Fake: client}, &discoveryfake.FakeDiscoveryV1{Fake: client}, c)
	if err != nil {
		t.Fatal(err)
	}
	got, err := r.Discover(t.Context())
	if err != nil || len(got.Members) != 1 || len(got.Members[0].EligibleEndpoints()) != 1 {
		t.Fatalf("valid Service port unavailable: %+v, %v", got, err)
	}
}

func TestDiscoveryRefusesUnsafeEndpointJoins(t *testing.T) {
	t.Parallel()
	cases := map[string]func(*corev1.Pod, *discoveryv1.EndpointSlice){
		"service-uid":          func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.OwnerReferences[0].UID = "old-service" },
		"owner-kind":           func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.OwnerReferences[0].Kind = "Pod" },
		"owner-controller":     func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.OwnerReferences[0].Controller = nil },
		"foreign-slice":        func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Namespace = "foreign" },
		"missing-ref":          func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].TargetRef = nil },
		"foreign-ref":          func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].TargetRef.Namespace = "foreign" },
		"reused-pod-name":      func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].TargetRef.UID = "old-pod" },
		"wrong-pod-name":       func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].TargetRef.Name = "another" },
		"unobserved-address":   func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].Addresses = []string{"10.0.0.99"} },
		"wrong-address-family": func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.AddressType = discoveryv1.AddressTypeIPv6 },
		"dns-address":          func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.AddressType = discoveryv1.AddressTypeFQDN },
		"missing-port":         func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Ports = nil },
		"wrong-port-name":      func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Ports[0].Name = ptr("http") },
		"udp-port":             func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Ports[0].Protocol = ptr(corev1.ProtocolUDP) },
		"port-overflow":        func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Ports[0].Port = ptr(int32(65536)) },
		"duplicate-port":       func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Ports = append(s.Ports, s.Ports[0]) },
		"missing-pod-version":  func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) { p.ResourceVersion = "" },
		"missing-pod-uid":      func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) { p.UID = "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			p := pod("allocator-a", "uid-a", "10.0.0.1")
			s := endpointSlice("slice", p)
			mutate(&p, &s)
			r, _ := fixture(t, []corev1.Pod{p}, []discoveryv1.EndpointSlice{s})
			got, err := r.Discover(t.Context())
			if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) {
				t.Fatalf("unsafe partial result: %+v, %v", got, err)
			}
		})
	}
}

func TestObservePodReportsIdentityWithoutInferringProcessDeath(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"present", "deleting", "failed", "replaced", "absent", "unavailable", "canceled"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			p := pod("allocator-a", "uid-a", "10.0.0.1")
			r, client := fixture(t, nil, nil)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			client.PrependReactor("get", "pods", func(action ktesting.Action) (bool, runtime.Object, error) {
				get, ok := action.(ktesting.GetAction)
				if !ok || action.GetNamespace() != "allocation" || get.GetName() != p.Name {
					t.Fatal("lookup identity changed")
				}
				switch scenario {
				case "deleting":
					p.DeletionTimestamp = ptr(metav1.Now())
				case "failed":
					p.Status.Phase = corev1.PodFailed
				case "replaced":
					p.UID = "uid-new"
				case "absent":
					return true, nil, apierrors.NewNotFound(schema.GroupResource{Resource: "pods"}, p.Name)
				case "unavailable":
					return true, nil, apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, p.Name, errors.New("private detail"))
				case "canceled":
					cancel()
				}
				return true, &p, nil
			})
			got, err := r.ObservePod(ctx, Identity{"allocation", "allocator-a", "uid-a"})
			if scenario == "unavailable" || scenario == "canceled" {
				if err == nil || !reflect.DeepEqual(got, Observation{}) {
					t.Fatalf("failure became evidence: %+v, %v", got, err)
				}
				if scenario == "canceled" && !errors.Is(err, context.Canceled) {
					t.Fatal(err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			want := Present
			if scenario == "replaced" {
				want = Replaced
			}
			if scenario == "absent" {
				want = Absent
			}
			if got.Presence != want {
				t.Fatalf("presence=%s, want=%s", got.Presence, want)
			}
			if scenario == "deleting" && !got.Pod.Deleting || scenario == "failed" && got.Pod.Phase != corev1.PodFailed {
				t.Fatalf("raw state lost: %+v", got)
			}
			if len(client.Actions()) != 1 {
				t.Fatalf("unexpected API authority: %+v", client.Actions())
			}
		})
	}
}
