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

func TestListAllocatedUsesExactAttemptAndFleetSelector(t *testing.T) {
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

			got, err := client.ListAllocated(context.Background(), testAttemptID)
			if err != nil {
				t.Fatalf("ListAllocated returned an error: %v", err)
			}
			if len(got) != len(test.want) {
				t.Fatalf("ListAllocated count = %d, want %d: %+v", len(got), len(test.want), got)
			}
			wantIdentities := make(map[Identity]bool, len(test.want))
			for _, identity := range test.want {
				wantIdentities[identity] = true
			}
			for i := range got {
				if !wantIdentities[got[i].Identity] {
					t.Errorf("ListAllocated[%d] identity = %+v, want one of %+v", i, got[i].Identity, test.want)
				}
				if got[i].State != agonesv1.GameServerStateAllocated || got[i].TLSPort != 8443 {
					t.Errorf("ListAllocated[%d] = %+v, want Allocated on TLS port 8443", i, got[i])
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

func TestListAllocatedRejectsInvalidAttemptBeforeAPI(t *testing.T) {
	clientset := agonesfake.NewSimpleClientset()
	client := clientAgainst(t, clientset, validConfig())

	for _, attemptID := range []string{"", "attempt/7", strings.Repeat("a", 129)} {
		if got, err := client.ListAllocated(context.Background(), attemptID); err == nil || got != nil {
			t.Errorf("ListAllocated(%q) = %+v, %v; want refusal", attemptID, got, err)
		}
	}
	if actions := clientset.Actions(); len(actions) != 0 {
		t.Fatalf("invalid attempts caused API actions: %#v", actions)
	}
}

func TestListAllocatedRefusesAnOutOfContractReturnedObject(t *testing.T) {
	changed := validGameServer("zone-1", "uid-1")
	changed.Status.State = agonesv1.GameServerStateReady
	clientset := agonesfake.NewSimpleClientset()
	clientset.PrependReactor(
		"list",
		"gameservers",
		func(clienttesting.Action) (bool, runtime.Object, error) {
			return true, &agonesv1.GameServerList{
				Items: []agonesv1.GameServer{*changed.DeepCopy()},
			}, nil
		},
	)
	client := clientAgainst(t, clientset, validConfig())

	if got, err := client.ListAllocated(
		context.Background(),
		testAttemptID,
	); err == nil || got != nil {
		t.Fatalf("ListAllocated accepted Ready object: %+v, %v", got, err)
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
