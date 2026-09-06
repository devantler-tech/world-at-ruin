package allocatordiscovery

import (
	"errors"
	"reflect"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestIneligibleEndpointsRetainMembershipAndConditions(t *testing.T) {
	t.Parallel()
	for name, mutate := range map[string]func(*corev1.Pod, *discoveryv1.EndpointSlice){
		"pod-not-ready": func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) {
			p.Status.Conditions[0].Status = corev1.ConditionFalse
		},
		"pod-ready-unknown":      func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) { p.Status.Conditions = nil },
		"pod-deleting":           func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) { p.DeletionTimestamp = ptr(metav1.Now()) },
		"pod-terminal":           func(p *corev1.Pod, _ *discoveryv1.EndpointSlice) { p.Status.Phase = corev1.PodFailed },
		"endpoint-not-ready":     func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].Conditions.Ready = ptr(false) },
		"endpoint-ready-unknown": func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].Conditions.Ready = nil },
		"endpoint-not-serving":   func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].Conditions.Serving = ptr(false) },
		"endpoint-terminating":   func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.Endpoints[0].Conditions.Terminating = ptr(true) },
		"slice-deleting":         func(_ *corev1.Pod, s *discoveryv1.EndpointSlice) { s.DeletionTimestamp = ptr(metav1.Now()) },
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			p := pod("allocator-a", "uid-a", "10.0.0.1")
			s := endpointSlice("slice", p)
			mutate(&p, &s)
			r, _ := fixture(t, []corev1.Pod{p}, []discoveryv1.EndpointSlice{s})
			got, err := r.Discover(t.Context())
			if err != nil || len(got.Members) != 1 || len(got.Members[0].Endpoints) != 1 || len(got.Members[0].EligibleEndpoints()) != 0 {
				t.Fatalf("ineligible observation lost or became eligible: %+v, %v", got, err)
			}
		})
	}
}

func TestDiscoveryRejectsConflictingDuplicates(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"duplicate-pod", "pod-name-reused", "duplicate-slice", "duplicate-condition", "socket-two-uids", "socket-two-conditions"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			p := pod("allocator-a", "uid-a", "10.0.0.1")
			s := endpointSlice("slice", p)
			pods := []corev1.Pod{p}
			slices := []discoveryv1.EndpointSlice{s}
			switch scenario {
			case "duplicate-pod":
				pods = append(pods, p)
			case "pod-name-reused":
				p.UID = "other-uid"
				pods = append(pods, p)
			case "duplicate-slice":
				slices = append(slices, s)
			case "duplicate-condition":
				pods[0].Status.Conditions = append(pods[0].Status.Conditions, p.Status.Conditions[0])
			case "socket-two-uids":
				other := pod("allocator-b", "uid-b", p.Status.PodIP)
				pods = append(pods, other)
				slices = append(slices, endpointSlice("other", other))
			case "socket-two-conditions":
				other := *s.DeepCopy()
				other.Name = "other"
				other.UID = "other-uid"
				other.Endpoints[0].Conditions.Ready = ptr(false)
				slices = append(slices, other)
			}
			r, _ := fixture(t, pods, slices)
			got, err := r.Discover(t.Context())
			if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) {
				t.Fatalf("conflicting discovery accepted: %+v, %v", got, err)
			}
		})
	}
}
