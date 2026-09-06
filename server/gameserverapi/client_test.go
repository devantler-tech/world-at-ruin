package gameserverapi

import (
	"context"
	"errors"
	"strings"
	"testing"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"
)

const (
	testNamespace   = "world-at-ruin"
	testFleet       = "zone"
	testTLSPortName = "tls"
	testAttemptID   = "attempt-7"
	testAttemptHash = "tacnzegdot6y5a6jxfnhkyi7tpwg4ddozxf62uyz2zereccbouqq"
)

func validConfig() Config {
	return Config{
		Namespace:   testNamespace,
		Fleet:       testFleet,
		TLSPortName: testTLSPortName,
	}
}

func validGameServer(name string, uid types.UID) *agonesv1.GameServer {
	return &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: testNamespace,
			Name:      name,
			UID:       uid,
			Labels: map[string]string{
				agones.FleetLabel:   testFleet,
				agones.AttemptLabel: testAttemptHash,
			},
			Annotations: map[string]string{
				"world-at-ruin.dev/test": "value",
			},
		},
		Spec: agonesv1.GameServerSpec{
			Ports: []agonesv1.GameServerPort{
				{
					Name:          testTLSPortName,
					ContainerPort: 8443,
					HostPort:      8443,
					Protocol:      corev1.ProtocolTCP,
				},
			},
		},
		Status: agonesv1.GameServerStatus{
			State: agonesv1.GameServerStateAllocated,
			Ports: []agonesv1.GameServerStatusPort{
				{Name: testTLSPortName, Port: 8443},
			},
		},
	}
}

func clientAgainst(
	t *testing.T,
	clientset *agonesfake.Clientset,
	cfg Config,
) *Client {
	t.Helper()
	client, err := NewClient(
		clientset.AgonesV1().GameServers(cfg.Namespace),
		cfg,
	)
	if err != nil {
		t.Fatalf("NewClient returned an error: %v", err)
	}
	return client
}

func TestNewClientRejectsInvalidConfiguration(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Config)
	}{
		{
			name: "namespace",
			mutate: func(cfg *Config) {
				cfg.Namespace = "World-At-Ruin"
			},
		},
		{
			name: "fleet",
			mutate: func(cfg *Config) {
				cfg.Fleet = "zone/fleet"
			},
		},
		{
			name: "fleet label length",
			mutate: func(cfg *Config) {
				cfg.Fleet = strings.Repeat("f", 64)
			},
		},
		{
			name: "TLS port name",
			mutate: func(cfg *Config) {
				cfg.TLSPortName = "zone.tls"
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validConfig()
			test.mutate(&cfg)
			api := agonesfake.NewSimpleClientset().
				AgonesV1().
				GameServers(testNamespace)

			client, err := NewClient(api, cfg)
			if err == nil || client != nil {
				t.Fatalf("NewClient(%+v) = %+v, %v; want refusal", cfg, client, err)
			}
		})
	}

	client, err := NewClient(nil, validConfig())
	if err == nil || client != nil {
		t.Fatalf("NewClient(nil) = %+v, %v; want refusal", client, err)
	}
}

func TestListAttemptUsesExactAttemptAndFleetSelector(t *testing.T) {
	otherAttempt := validGameServer("zone-other-attempt", "uid-other-attempt")
	otherAttempt.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
	otherFleet := validGameServer("zone-other-fleet", "uid-other-fleet")
	otherFleet.Labels[agones.FleetLabel] = "other-zone"
	first := validGameServer("zone-1", "uid-1")
	second := validGameServer("zone-2", "uid-2")

	tests := []struct {
		name string
		seed []*agonesv1.GameServer
		want []Identity
	}{
		{name: "zero"},
		{
			name: "one",
			seed: []*agonesv1.GameServer{otherAttempt, otherFleet, first},
			want: []Identity{
				{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"},
			},
		},
		{
			name: "duplicates remain explicit",
			seed: []*agonesv1.GameServer{first, second},
			want: []Identity{
				{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"},
				{Namespace: testNamespace, Name: "zone-2", UID: "uid-2"},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			objects := make([]runtime.Object, len(test.seed))
			for i, gameServer := range test.seed {
				objects[i] = gameServer.DeepCopy()
			}
			clientset := agonesfake.NewSimpleClientset(objects...)
			client := clientAgainst(t, clientset, validConfig())

			got, err := client.ListAttempt(context.Background(), testAttemptID)
			if err != nil {
				t.Fatalf("ListAttempt returned an error: %v", err)
			}
			if len(got) != len(test.want) {
				t.Fatalf("ListAttempt count = %d, want %d: %+v", len(got), len(test.want), got)
			}
			wantIdentities := make(map[Identity]bool, len(test.want))
			for _, identity := range test.want {
				wantIdentities[identity] = true
			}
			for i := range got {
				if !wantIdentities[got[i].Identity] {
					t.Errorf("ListAttempt[%d] identity = %+v, want one of %+v", i, got[i].Identity, test.want)
				}
				if got[i].State != agonesv1.GameServerStateAllocated || got[i].TLSPort != 8443 {
					t.Errorf("ListAttempt[%d] = %+v, want Allocated on TLS port 8443", i, got[i])
				}
			}

			actions := clientset.Actions()
			if len(actions) != 1 {
				t.Fatalf("client actions = %d, want one list: %#v", len(actions), actions)
			}
			listAction, ok := actions[0].(clienttesting.ListAction)
			if !ok {
				t.Fatalf("action = %T, want ListAction", actions[0])
			}
			selector := listAction.GetListRestrictions().Labels
			if !selector.Matches(mapLabels{
				agones.FleetLabel:   testFleet,
				agones.AttemptLabel: testAttemptHash,
			}) {
				t.Fatalf("selector %q does not require the exact Fleet and attempt digest", selector)
			}
			if selector.Matches(mapLabels{
				agones.FleetLabel:   testFleet,
				agones.AttemptLabel: strings.Repeat("a", 52),
			}) {
				t.Fatalf("selector %q accepted a different attempt digest", selector)
			}
		})
	}
}

type mapLabels map[string]string

func (m mapLabels) Has(label string) bool {
	_, ok := m[label]
	return ok
}

func (m mapLabels) Get(label string) string {
	return m[label]
}

func (m mapLabels) Lookup(label string) (string, bool) {
	value, ok := m[label]
	return value, ok
}

func TestListAttemptRejectsInvalidAttemptBeforeAPI(t *testing.T) {
	clientset := agonesfake.NewSimpleClientset()
	client := clientAgainst(t, clientset, validConfig())

	for _, attemptID := range []string{"", "attempt/7", strings.Repeat("a", 129)} {
		if got, err := client.ListAttempt(context.Background(), attemptID); err == nil || got != nil {
			t.Errorf("ListAttempt(%q) = %+v, %v; want refusal", attemptID, got, err)
		}
	}
	if actions := clientset.Actions(); len(actions) != 0 {
		t.Fatalf("invalid attempts caused API actions: %#v", actions)
	}
}

// TestListAttemptReportsObjectsAgonesHasMovedOn checks that the listing keeps
// an attempt-labelled object whose state has left Allocated, because cleanup
// must be able to see and delete it. Ownership is not exercised here and
// cannot be: the label selector already restricts the query to this Fleet and
// attempt, so a foreign object never reaches the snapshot through this path —
// the name-keyed reads are where ErrNotOwned is reachable and tested.
func TestListAttemptReportsObjectsAgonesHasMovedOn(t *testing.T) {
	moved := validGameServer("zone-1", "uid-1")
	moved.Status.State = agonesv1.GameServerStateShutdown
	moved.Status.Ports = nil
	allocated := validGameServer("zone-2", "uid-2")
	client := clientAgainst(t, agonesfake.NewSimpleClientset(moved, allocated), validConfig())

	got, err := client.ListAttempt(context.Background(), testAttemptID)
	if err != nil {
		t.Fatalf("ListAttempt refused a Shutdown object cleanup still owns: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListAttempt count = %d, want both objects: %+v", len(got), got)
	}
	states := map[types.UID]agonesv1.GameServerState{}
	ports := map[types.UID]uint16{}
	for _, gameServer := range got {
		states[gameServer.Identity.UID] = gameServer.State
		ports[gameServer.Identity.UID] = gameServer.TLSPort
	}
	if states["uid-1"] != agonesv1.GameServerStateShutdown ||
		states["uid-2"] != agonesv1.GameServerStateAllocated {
		t.Fatalf("ListAttempt reported states %+v, want the observed ones", states)
	}
	if ports["uid-1"] != 0 || ports["uid-2"] != 8443 {
		t.Fatalf("ListAttempt reported ports %+v, want the port-less object tolerated", ports)
	}
}

func TestGetAllocatedRejectsInvalidInputBeforeAPI(t *testing.T) {
	validIdentity := Identity{
		Namespace: testNamespace,
		Name:      "zone-1",
		UID:       "uid-1",
	}
	tests := []struct {
		name      string
		identity  Identity
		attemptID string
	}{
		{
			name: "missing UID",
			identity: Identity{
				Namespace: testNamespace,
				Name:      "zone-1",
			},
			attemptID: testAttemptID,
		},
		{
			name: "wrong namespace",
			identity: Identity{
				Namespace: "other-namespace",
				Name:      "zone-1",
				UID:       "uid-1",
			},
			attemptID: testAttemptID,
		},
		{
			name:      "malformed name",
			identity:  Identity{Namespace: testNamespace, Name: "Zone_1", UID: "uid-1"},
			attemptID: testAttemptID,
		},
		{
			name:      "malformed attempt",
			identity:  validIdentity,
			attemptID: "attempt/7",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			clientset := agonesfake.NewSimpleClientset()
			client := clientAgainst(t, clientset, validConfig())

			got, err := client.GetAllocated(
				context.Background(),
				test.identity,
				test.attemptID,
			)
			if err == nil || !isZeroGameServer(got) {
				t.Fatalf(
					"GetAllocated(%+v, %q) = %+v, %v; want refusal",
					test.identity,
					test.attemptID,
					got,
					err,
				)
			}
			if actions := clientset.Actions(); len(actions) != 0 {
				t.Fatalf("invalid input caused API actions: %#v", actions)
			}
		})
	}
}

func TestGetAllocatedValidatesExactObservedIdentity(t *testing.T) {
	wantIdentity := Identity{
		Namespace: testNamespace,
		Name:      "zone-1",
		UID:       "uid-1",
	}
	tests := []struct {
		name   string
		mutate func(*agonesv1.GameServer)
	}{
		{
			name: "namespace changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Namespace = "other-namespace"
			},
		},
		{
			name: "name changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Name = "zone-2"
			},
		},
		{
			name: "UID changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.UID = "uid-2"
			},
		},
		{
			name: "Fleet changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Labels[agones.FleetLabel] = "other-zone"
			},
		},
		{
			name: "attempt changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
			},
		},
		{
			name: "state changed",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Status.State = agonesv1.GameServerStateReady
			},
		},
		{
			name: "UID missing",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.UID = ""
			},
		},
		{
			name: "TLS port missing",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Status.Ports = nil
			},
		},
		{
			name: "TLS port duplicated",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Status.Ports = append(
					gameServer.Status.Ports,
					agonesv1.GameServerStatusPort{Name: testTLSPortName, Port: 9443},
				)
			},
		},
		{
			name: "TLS port invalid",
			mutate: func(gameServer *agonesv1.GameServer) {
				gameServer.Status.Ports[0].Port = 0
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			observed := validGameServer(wantIdentity.Name, wantIdentity.UID)
			test.mutate(observed)
			clientset := agonesfake.NewSimpleClientset()
			clientset.PrependReactor(
				"get",
				"gameservers",
				func(clienttesting.Action) (bool, runtime.Object, error) {
					return true, observed.DeepCopy(), nil
				},
			)
			client := clientAgainst(t, clientset, validConfig())

			if got, err := client.GetAllocated(
				context.Background(),
				wantIdentity,
				testAttemptID,
			); err == nil || !isZeroGameServer(got) {
				t.Fatalf("GetAllocated accepted changed object: %+v, %v", got, err)
			}
		})
	}
}

func TestGetAllocatedReturnsDetachedMetadataSnapshot(t *testing.T) {
	seed := validGameServer("zone-1", "uid-1")
	clientset := agonesfake.NewSimpleClientset(seed)
	client := clientAgainst(t, clientset, validConfig())
	identity := Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"}

	got, err := client.GetAllocated(context.Background(), identity, testAttemptID)
	if err != nil {
		t.Fatalf("GetAllocated returned an error: %v", err)
	}
	if got.Identity != identity ||
		got.State != agonesv1.GameServerStateAllocated ||
		got.TLSPort != 8443 ||
		got.Labels[agones.FleetLabel] != testFleet ||
		got.Annotations["world-at-ruin.dev/test"] != "value" {
		t.Fatalf("GetAllocated = %+v, want validated detached snapshot", got)
	}
	got.Labels[agones.FleetLabel] = "mutated"
	got.Annotations["world-at-ruin.dev/test"] = "mutated"

	again, err := client.GetAllocated(context.Background(), identity, testAttemptID)
	if err != nil {
		t.Fatalf("second GetAllocated returned an error: %v", err)
	}
	if again.Labels[agones.FleetLabel] != testFleet ||
		again.Annotations["world-at-ruin.dev/test"] != "value" {
		t.Fatalf("returned maps alias API state: %+v", again)
	}
}

func isZeroGameServer(gameServer GameServer) bool {
	return gameServer.Identity == (Identity{}) &&
		gameServer.State == "" &&
		gameServer.TLSPort == 0 &&
		gameServer.Labels == nil &&
		gameServer.Annotations == nil
}

func TestDeleteUsesExactUIDPrecondition(t *testing.T) {
	seed := validGameServer("zone-1", "uid-1")
	clientset := agonesfake.NewSimpleClientset(seed)
	client := clientAgainst(t, clientset, validConfig())
	identity := Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"}

	if err := client.Delete(context.Background(), identity); err != nil {
		t.Fatalf("Delete returned an error: %v", err)
	}
	actions := clientset.Actions()
	if len(actions) != 1 {
		t.Fatalf("client actions = %d, want one delete: %#v", len(actions), actions)
	}
	deleteAction, ok := actions[0].(clienttesting.DeleteAction)
	if !ok {
		t.Fatalf("action = %T, want DeleteAction", actions[0])
	}
	options := deleteAction.GetDeleteOptions()
	if options.Preconditions == nil ||
		options.Preconditions.UID == nil ||
		*options.Preconditions.UID != identity.UID {
		t.Fatalf("delete preconditions = %+v, want exact UID %q", options.Preconditions, identity.UID)
	}
}

func TestDeleteCannotRemoveARecreatedGameServer(t *testing.T) {
	recreated := validGameServer("zone-1", "uid-new")
	clientset := agonesfake.NewSimpleClientset(recreated)
	clientset.PrependReactor(
		"delete",
		"gameservers",
		func(action clienttesting.Action) (bool, runtime.Object, error) {
			deleteAction, ok := action.(clienttesting.DeleteAction)
			if !ok {
				t.Fatalf("action = %T, want DeleteAction", action)
			}
			preconditions := deleteAction.GetDeleteOptions().Preconditions
			if preconditions == nil ||
				preconditions.UID == nil ||
				*preconditions.UID != recreated.UID {
				return true, nil, apierrors.NewConflict(
					schema.GroupResource{Group: "agones.dev", Resource: "gameservers"},
					recreated.Name,
					errors.New("UID precondition failed"),
				)
			}
			return false, nil, nil
		},
	)
	client := clientAgainst(t, clientset, validConfig())
	stale := Identity{Namespace: testNamespace, Name: recreated.Name, UID: "uid-old"}

	if err := client.Delete(context.Background(), stale); !apierrors.IsConflict(err) {
		t.Fatalf("Delete with stale UID error = %v, want Conflict", err)
	}
	stillPresent, err := clientset.
		AgonesV1().
		GameServers(testNamespace).
		Get(context.Background(), recreated.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("recreated GameServer was deleted: %v", err)
	}
	if stillPresent.UID != recreated.UID {
		t.Fatalf("remaining GameServer UID = %q, want %q", stillPresent.UID, recreated.UID)
	}
}

func TestDeleteRejectsEmptyOrMismatchedIdentityBeforeAPI(t *testing.T) {
	tests := []Identity{
		{Namespace: testNamespace, Name: "zone-1"},
		{Namespace: "other-namespace", Name: "zone-1", UID: "uid-1"},
		{Namespace: testNamespace, Name: "", UID: "uid-1"},
		{Namespace: testNamespace, Name: "Zone_1", UID: "uid-1"},
	}
	for _, identity := range tests {
		t.Run(identity.Namespace+"/"+identity.Name+"/"+string(identity.UID), func(t *testing.T) {
			clientset := agonesfake.NewSimpleClientset()
			client := clientAgainst(t, clientset, validConfig())

			if err := client.Delete(context.Background(), identity); err == nil {
				t.Fatalf("Delete(%+v) succeeded; want refusal", identity)
			}
			if actions := clientset.Actions(); len(actions) != 0 {
				t.Fatalf("Delete(%+v) caused API actions: %#v", identity, actions)
			}
		})
	}
}

// TestGetAllocatedByNameReportsTheObservedUIDAndNode checks that one exact-name
// read returns the observed identity, node and validated TLS port.
func TestGetAllocatedByNameReportsTheObservedUIDAndNode(t *testing.T) {
	observed := validGameServer("zone-1", "uid-1")
	observed.Status.NodeName = "node-a"
	clientset := agonesfake.NewSimpleClientset(observed)
	client := clientAgainst(t, clientset, validConfig())

	got, err := client.GetAllocatedByName(context.Background(), "zone-1", testAttemptID)
	if err != nil {
		t.Fatalf("GetAllocatedByName returned an error: %v", err)
	}
	want := Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"}
	if got.Identity != want || got.NodeName != "node-a" || got.TLSPort != 8443 {
		t.Fatalf("GetAllocatedByName = %+v, want identity %+v on node-a:8443", got, want)
	}
	if actions := clientset.Actions(); len(actions) != 1 || actions[0].GetVerb() != "get" {
		t.Fatalf("client actions = %#v, want one get", actions)
	}
}

// TestGetAllocatedByNameRefusesAbsentOrOutOfContractObjects distinguishes absence
// from invalid state or attempt ownership and returns no resource on failure.
func TestGetAllocatedByNameRefusesAbsentOrOutOfContractObjects(t *testing.T) {
	tests := []struct {
		name         string
		seed         *agonesv1.GameServer
		wantNotFound bool
	}{
		{name: "absent", wantNotFound: true},
		{
			name: "other attempt",
			seed: func() *agonesv1.GameServer {
				gameServer := validGameServer("zone-1", "uid-1")
				gameServer.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
				return gameServer
			}(),
		},
		{
			name: "not Allocated",
			seed: func() *agonesv1.GameServer {
				gameServer := validGameServer("zone-1", "uid-1")
				gameServer.Status.State = agonesv1.GameServerStateShutdown
				return gameServer
			}(),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var objects []runtime.Object
			if test.seed != nil {
				objects = append(objects, test.seed)
			}
			client := clientAgainst(t, agonesfake.NewSimpleClientset(objects...), validConfig())

			got, err := client.GetAllocatedByName(context.Background(), "zone-1", testAttemptID)
			if err == nil || !isZeroGameServer(got) {
				t.Fatalf("GetAllocatedByName = %+v, %v; want refusal", got, err)
			}
			if errors.Is(err, ErrNotFound) != test.wantNotFound {
				t.Fatalf("GetAllocatedByName error = %v, want ErrNotFound=%t", err, test.wantNotFound)
			}
		})
	}
}

// TestGetAllocatedTranslatesAbsenceToErrNotFound checks that a missing object
// retains both the package sentinel and Kubernetes NotFound classification.
func TestGetAllocatedTranslatesAbsenceToErrNotFound(t *testing.T) {
	client := clientAgainst(t, agonesfake.NewSimpleClientset(), validConfig())

	_, err := client.GetAllocated(
		context.Background(),
		Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"},
		testAttemptID,
	)
	if !errors.Is(err, ErrNotFound) || !apierrors.IsNotFound(err) {
		t.Fatalf("GetAllocated error = %v, want ErrNotFound wrapping the API NotFound", err)
	}
}

// TestLocateAcceptsAnyStateButNeverAnotherOwner allows cleanup of a Shutdown
// object without a port while refusing foreign Fleet or attempt ownership.
func TestLocateAcceptsAnyStateButNeverAnotherOwner(t *testing.T) {
	shutdown := validGameServer("zone-1", "uid-1")
	shutdown.Status.State = agonesv1.GameServerStateShutdown
	shutdown.Status.Ports = nil
	shutdown.Status.NodeName = "node-a"
	otherAttempt := validGameServer("zone-2", "uid-2")
	otherAttempt.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
	otherFleet := validGameServer("zone-3", "uid-3")
	otherFleet.Labels[agones.FleetLabel] = "other-zone"
	client := clientAgainst(
		t,
		agonesfake.NewSimpleClientset(shutdown, otherAttempt, otherFleet),
		validConfig(),
	)

	got, err := client.Locate(context.Background(), "zone-1", testAttemptID)
	if err != nil {
		t.Fatalf("Locate returned an error: %v", err)
	}
	if got.Identity.UID != "uid-1" ||
		got.State != agonesv1.GameServerStateShutdown ||
		got.TLSPort != 0 ||
		got.NodeName != "node-a" {
		t.Fatalf("Locate = %+v, want the Shutdown object with no TLS port", got)
	}
	for _, name := range []string{"zone-2", "zone-3"} {
		got, err := client.Locate(context.Background(), name, testAttemptID)
		if !errors.Is(err, ErrNotOwned) || !isZeroGameServer(got) {
			t.Fatalf("Locate(%q) = %+v, %v; want ErrNotOwned", name, got, err)
		}
	}
	got, err = client.Locate(context.Background(), "zone-9", testAttemptID)
	if !errors.Is(err, ErrNotFound) || !isZeroGameServer(got) {
		t.Fatalf("Locate(absent) = %+v, %v; want ErrNotFound", got, err)
	}
}

// TestLocateRejectsInvalidInputBeforeAPI checks both name-based read paths reject
// malformed names and attempts without issuing a Kubernetes request.
func TestLocateRejectsInvalidInputBeforeAPI(t *testing.T) {
	clientset := agonesfake.NewSimpleClientset()
	client := clientAgainst(t, clientset, validConfig())

	for _, input := range [][2]string{
		{"Zone_1", testAttemptID},
		{"", testAttemptID},
		{"zone-1", "attempt/7"},
	} {
		got, err := client.Locate(context.Background(), input[0], input[1])
		if err == nil || !isZeroGameServer(got) {
			t.Errorf("Locate(%q, %q) = %+v, %v; want refusal", input[0], input[1], got, err)
		}
		got, err = client.GetAllocatedByName(context.Background(), input[0], input[1])
		if err == nil || !isZeroGameServer(got) {
			t.Errorf("GetAllocatedByName(%q, %q) = %+v, %v; want refusal", input[0], input[1], got, err)
		}
	}
	if actions := clientset.Actions(); len(actions) != 0 {
		t.Fatalf("invalid input caused API actions: %#v", actions)
	}
}

// TestDeleteTranslatesAbsenceToErrNotFound checks that deleting an object that
// is already gone carries the package sentinel, so cleanup can treat absence
// as success without inspecting Kubernetes error reasons.
func TestDeleteTranslatesAbsenceToErrNotFound(t *testing.T) {
	client := clientAgainst(t, agonesfake.NewSimpleClientset(), validConfig())

	err := client.Delete(
		context.Background(),
		Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"},
	)
	if !errors.Is(err, ErrNotFound) || !apierrors.IsNotFound(err) {
		t.Fatalf("Delete error = %v, want ErrNotFound wrapping the API NotFound", err)
	}
}

// TestReadsRefuseAnotherOwnerWithErrNotOwned checks that every read path, not
// only Locate, reports a foreign Fleet or attempt through the one sentinel.
func TestReadsRefuseAnotherOwnerWithErrNotOwned(t *testing.T) {
	foreign := validGameServer("zone-1", "uid-1")
	foreign.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
	client := clientAgainst(t, agonesfake.NewSimpleClientset(foreign), validConfig())

	_, err := client.GetAllocated(
		context.Background(),
		Identity{Namespace: testNamespace, Name: "zone-1", UID: "uid-1"},
		testAttemptID,
	)
	if !errors.Is(err, ErrNotOwned) {
		t.Fatalf("GetAllocated error = %v, want ErrNotOwned", err)
	}
	if _, err := client.GetAllocatedByName(context.Background(), "zone-1", testAttemptID); !errors.Is(err, ErrNotOwned) {
		t.Fatalf("GetAllocatedByName error = %v, want ErrNotOwned", err)
	}
}
