// Package allocatordiscovery reads allocator identities without granting dispatch
// authority or proving that a process has stopped.
package allocatordiscovery

import (
	"context"
	"errors"
	"net/netip"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/validation"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	discoveryclient "k8s.io/client-go/kubernetes/typed/discovery/v1"
)

var (
	// ErrInvalidArgument refuses ambiguous or unbounded discovery configuration.
	ErrInvalidArgument = errors.New("allocator discovery: invalid argument")
	// ErrObservation returns no partial evidence. Backend error text is suppressed.
	ErrObservation = errors.New("allocator discovery: incomplete or invalid observation")
)

// Config pins one namespace, Pod selector, Service identity and named TCP port.
// MaxPages must be 1..100; each list requests at most 100 objects per page.
type Config struct {
	Namespace, PodSelector, ServiceName, ServiceUID, PortName string
	MaxPages                                                  int
}

// Identity is an exact Kubernetes object identity; the name alone is not enough.
type Identity struct{ Namespace, Name, UID string }

// Endpoint preserves observed conditions. An IP address does not authenticate a process.
type Endpoint struct {
	Address                     netip.Addr
	Port                        uint16
	Ready, Serving, Terminating corev1.ConditionStatus
	Deleting                    bool
}

// Member includes selected Pods even when no endpoint is currently eligible.
type Member struct {
	Identity        Identity
	ResourceVersion string
	Phase           corev1.PodPhase
	Ready           corev1.ConditionStatus
	Deleting        bool
	Endpoints       []Endpoint
}

// Snapshot contains complete per-kind lists. The two resource versions do not
// describe an atomic cross-kind snapshot, and neither establishes a fence.
type Snapshot struct {
	PodResourceVersion, EndpointSliceResourceVersion string
	Members                                          []Member
}

// Presence describes API object identity only, never process termination.
type Presence string

const (
	Present  Presence = "present"
	Absent   Presence = "absent"
	Replaced Presence = "replaced"
)

// Observation has no Pod for Absent; Replaced reports the currently observed UID.
type Observation struct {
	Presence Presence
	Pod      Member
}

type podReader interface {
	List(context.Context, metav1.ListOptions) (*corev1.PodList, error)
	Get(context.Context, string, metav1.GetOptions) (*corev1.Pod, error)
}
type sliceReader interface {
	List(context.Context, metav1.ListOptions) (*discoveryv1.EndpointSliceList, error)
}

// Reader retains only namespaced read capabilities, with no mutation API.
type Reader struct {
	pods     podReader
	slices   sliceReader
	config   Config
	selector labels.Selector
}

// newReader binds typed read capabilities after the public constructor has
// installed the response budget. Tests can supply narrow in-memory clients.
func newReader(core coreclient.CoreV1Interface, discovery discoveryclient.DiscoveryV1Interface, config Config) (*Reader, error) {
	if len(config.PodSelector) > 4096 {
		return nil, ErrInvalidArgument
	}
	selector, err := labels.Parse(config.PodSelector)
	if core == nil || discovery == nil || len(validation.IsDNS1123Label(config.Namespace)) != 0 ||
		len(validation.IsDNS1035Label(config.ServiceName)) != 0 || !token(config.ServiceUID, 128) ||
		len(validation.IsDNS1123Label(config.PortName)) != 0 || config.MaxPages < 1 || config.MaxPages > 100 ||
		err != nil || selector.Empty() {
		return nil, ErrInvalidArgument
	}
	return &Reader{pods: core.Pods(config.Namespace), slices: discovery.EndpointSlices(config.Namespace), config: config, selector: selector}, nil
}

// Discover publishes only after every page and identity join succeeds.
func (r *Reader) Discover(ctx context.Context) (Snapshot, error) {
	ctx = withResponseBudget(ctx)
	pods, podVersion, err := collect(ctx, r.config.MaxPages, r.selector.String(), func(ctx context.Context, options metav1.ListOptions) ([]corev1.Pod, metav1.ListMeta, error) {
		list, err := r.pods.List(ctx, options)
		if err != nil {
			return nil, metav1.ListMeta{}, err
		}
		if list == nil {
			return nil, metav1.ListMeta{}, ErrObservation
		}
		return list.Items, list.ListMeta, nil
	})
	if err != nil {
		return Snapshot{}, err
	}
	addresses := 0
	slicesList, sliceVersion, err := collect(ctx, r.config.MaxPages, labels.Set{discoveryv1.LabelServiceName: r.config.ServiceName}.String(), func(ctx context.Context, options metav1.ListOptions) ([]discoveryv1.EndpointSlice, metav1.ListMeta, error) {
		list, err := r.slices.List(ctx, options)
		if err != nil {
			return nil, metav1.ListMeta{}, err
		}
		if list == nil {
			return nil, metav1.ListMeta{}, ErrObservation
		}
		if err := countAddresses(list.Items, &addresses); err != nil {
			return nil, metav1.ListMeta{}, err
		}
		return list.Items, list.ListMeta, nil
	})
	if err != nil {
		return Snapshot{}, err
	}
	members, err := r.join(pods, slicesList)
	if err != nil {
		return Snapshot{}, err
	}
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return Snapshot{PodResourceVersion: podVersion, EndpointSliceResourceVersion: sliceVersion, Members: members}, nil
}

// ObservePod performs a fresh exact-name read, comparing the result with the
// expected UID. Even Absent and a terminal Pod phase cannot clear quarantine.
func (r *Reader) ObservePod(ctx context.Context, expected Identity) (Observation, error) {
	ctx = withResponseBudget(ctx)
	if expected.Namespace != r.config.Namespace || !validIdentity(expected) {
		return Observation{}, ErrInvalidArgument
	}
	if err := ctx.Err(); err != nil {
		return Observation{}, err
	}
	pod, err := r.pods.Get(ctx, expected.Name, metav1.GetOptions{})
	if cancel := ctx.Err(); cancel != nil {
		return Observation{}, cancel
	}
	if apierrors.IsNotFound(err) {
		return Observation{Presence: Absent}, nil
	}
	if err != nil {
		return Observation{}, observationError(err)
	}
	if pod == nil || pod.Namespace != expected.Namespace || pod.Name != expected.Name {
		return Observation{}, ErrObservation
	}
	member, err := observe(*pod)
	if err != nil {
		return Observation{}, err
	}
	presence := Present
	if member.Identity.UID != expected.UID {
		presence = Replaced
	}
	return Observation{Presence: presence, Pod: member}, nil
}

// EligibleEndpoints returns a detached list of observed candidates, not dispatch
// authority. Unknown readiness is excluded; Pod readiness defeats Services that
// publish not-ready addresses. Serving/terminating unknowns retain API defaults.
func (m Member) EligibleEndpoints() []Endpoint {
	var endpoints []Endpoint
	if m.Deleting || m.Phase != corev1.PodRunning || m.Ready != corev1.ConditionTrue {
		return endpoints
	}
	for _, endpoint := range m.Endpoints {
		if !endpoint.Deleting && endpoint.Ready == corev1.ConditionTrue && endpoint.Serving != corev1.ConditionFalse && endpoint.Terminating != corev1.ConditionTrue {
			endpoints = append(endpoints, endpoint)
		}
	}
	return endpoints
}

// observe preserves unknown readiness and rejects contradictory Pod conditions.
func observe(pod corev1.Pod) (Member, error) {
	identity := Identity{pod.Namespace, pod.Name, string(pod.UID)}
	if !validIdentity(identity) || !token(pod.ResourceVersion, 1024) {
		return Member{}, ErrObservation
	}
	ready := corev1.ConditionUnknown
	found := false
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady {
			if found || (condition.Status != corev1.ConditionTrue && condition.Status != corev1.ConditionFalse && condition.Status != corev1.ConditionUnknown) {
				return Member{}, ErrObservation
			}
			ready = condition.Status
			found = true
		}
	}
	return Member{Identity: identity, ResourceVersion: pod.ResourceVersion, Phase: pod.Status.Phase, Ready: ready, Deleting: pod.DeletionTimestamp != nil}, nil
}

// validIdentity requires a namespaced object name plus a bounded opaque UID.
func validIdentity(identity Identity) bool {
	return len(validation.IsDNS1123Label(identity.Namespace)) == 0 && len(validation.IsDNS1123Subdomain(identity.Name)) == 0 && token(identity.UID, 128)
}

// token bounds opaque API identifiers without assuming a numeric encoding.
func token(value string, maximum int) bool {
	return value != "" && len(value) <= maximum && utf8.ValidString(value) && !strings.ContainsFunc(value, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) })
}

// observationError preserves cancellation while withholding private backend text.
func observationError(err error) error {
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return ErrObservation
}

// sortMembers makes output stable across API page order and address families.
func sortMembers(members []Member) {
	slices.SortFunc(members, func(a, b Member) int { return strings.Compare(a.Identity.UID, b.Identity.UID) })
	for i := range members {
		slices.SortFunc(members[i].Endpoints, func(a, b Endpoint) int {
			if order := a.Address.Compare(b.Address); order != 0 {
				return order
			}
			return int(a.Port) - int(b.Port)
		})
	}
}
