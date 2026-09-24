package claimrpc

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/agonesresources"
	"github.com/devantler-tech/world-at-ruin/server/gameserverapi"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"google.golang.org/grpc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type observedBinding struct{ binding agones.ClaimBinding }

// ClaimBinding supplies only server-owned metadata to the socket admission gate.
func (b observedBinding) ClaimBinding() (agones.ClaimBinding, error) { return b.binding, nil }

// ClaimBindingCurrent makes a changed observation invalidate an in-flight claim.
func (b observedBinding) ClaimBindingCurrent(value agones.ClaimBinding) bool {
	return value == b.binding
}

type forbiddenAllocator struct{}

// Allocate refuses any accidental resource creation during claim verification.
func (forbiddenAllocator) Allocate(context.Context, *allocationpb.AllocationRequest, ...grpc.CallOption) (*allocationpb.AllocationResponse, error) {
	return nil, errors.New("claim must never allocate")
}

// This fixture replaces only the Kubernetes transport. Claim resolution uses
// the real resource checks, sealed envelope decryption and pinned reference.
func (f *fixture) resourceResolver(t *testing.T) (*agonesresources.Adapter, *agonesfake.Clientset, *agonesv1.GameServer) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint, err := admissionref.Fingerprint(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", "world", "zone-1", "uid-1", fingerprint}, "\x00"))
	sealed, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.PublicKey, f.allocation.AdmissionSecret, label)
	if err != nil {
		t.Fatal(err)
	}
	envelope := "v1." + base64.RawURLEncoding.EncodeToString(sealed)
	ref, err := admissionref.Reference(admissionref.Material{Namespace: "world", GameServerName: "zone-1", GameServerUID: "uid-1", WrappingKeyFingerprint: fingerprint, AdmissionEnvelope: envelope, TLSPort: 443})
	if err != nil {
		t.Fatal(err)
	}
	object, _ := f.storage.Get(nakamalease.Collection, f.binding.LeaseObjectID, "")
	object.Value = strings.Replace(object.Value, f.record.Lease.SecretRef, ref, 1)
	f.storage.Seed(object)
	f.record.Lease.SecretRef = ref
	gs := &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{Namespace: "world", Name: "zone-1", UID: "uid-1", ResourceVersion: "1", Labels: map[string]string{agones.FleetLabel: "cave", agones.AttemptLabel: f.binding.AttemptDigest, agones.AdmissionReadyLabel: agones.AdmissionReadyValue(fingerprint)}, Annotations: map[string]string{agones.AdmissionKeyAnnotation: fingerprint, agones.AdmissionEnvelopeAnnotation: envelope}},
		Status:     agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated, NodeName: "node-a", Ports: []agonesv1.GameServerStatusPort{{Name: "tls", Port: 443}}},
	}
	kube := agonesfake.NewSimpleClientset(gs)
	resources, err := gameserverapi.NewClient(kube.AgonesV1().GameServers("world"), gameserverapi.Config{Namespace: "world", Fleet: "cave", TLSPortName: "tls"})
	if err != nil {
		t.Fatal(err)
	}
	allocator, err := agonesalloc.NewClient(forbiddenAllocator{}, agonesalloc.Config{Namespace: "world", Fleet: "cave", TLSPortName: "tls", WrappingKeyFingerprint: fingerprint})
	if err != nil {
		t.Fatal(err)
	}
	keyring, err := admissionref.NewKeyring(key)
	if err != nil {
		t.Fatal(err)
	}
	adapter, err := agonesresources.NewAdapter(allocator, resources, keyring, agonesresources.Config{ZoneDomain: "zones.example", Observer: func(handoff.AllocationRequest) (sim.EntityID, error) { return 1, nil }})
	if err != nil {
		t.Fatal(err)
	}
	return adapter, kube, gs
}

// TestPrivateClaimControlsRealSocketWithPinnedResource requires the real resource
// checks and durable claim to succeed before a TLS socket receives its snapshot.
func TestPrivateClaimControlsRealSocketWithPinnedResource(t *testing.T) {
	for _, scenario := range []string{"valid", "replacement UID", "changed envelope", "changed attempt", "cleanup won"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			resolver, kube, gs := f.resourceResolver(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch scenario {
			case "replacement UID":
				gs.UID = "uid-replacement"
			case "changed envelope":
				gs.Annotations[agones.AdmissionEnvelopeAnnotation] += "A"
			case "changed attempt":
				gs.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
			case "cleanup won":
				if _, err := f.store.BeginRelease(ctx, f.record, "attempt-1"); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := kube.AgonesV1().GameServers("world").Update(ctx, gs, metav1.UpdateOptions{}); err != nil {
				t.Fatal(err)
			}
			client, _ := f.serve(t, resolver.Resolve)
			gate, err := zoneclaim.New(observedBinding{f.binding}, client)
			if err != nil {
				t.Fatal(err)
			}
			verifier, err := zonesock.NewHMACVerifier(f.allocation.AdmissionSecret, "zone-1")
			if err != nil {
				t.Fatal(err)
			}
			hub, err := zonesock.NewClaimedHub(zonesock.Config{Verifier: verifier}, gate, time.Second)
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				world := sim.NewDemoWorld()
				ticker := time.NewTicker(time.Millisecond)
				defer ticker.Stop()
				for {
					select {
					case <-ctx.Done():
						return
					case <-ticker.C:
						hub.Tick(world)
					}
				}
			}()
			defer func() { cancel(); <-done }()
			server := httptest.NewTLSServer(hub.Handler())
			defer server.Close()
			dialCtx, stop := context.WithTimeout(ctx, 5*time.Second)
			defer stop()
			conn, response, err := websocket.Dial(dialCtx, server.URL, &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: http.Header{"Authorization": {"Bearer " + f.token}}})
			if response != nil && response.Body != nil {
				_ = response.Body.Close()
			}
			if conn != nil {
				defer func() { _ = conn.CloseNow() }()
			}
			stored, loadErr := f.store.Load(ctx, f.record.Lease.UserID, f.record.Lease.ReservationID)
			if loadErr != nil {
				t.Fatal(loadErr)
			}
			if scenario != "valid" {
				if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized || !stored.Lease.ClaimedAt.IsZero() || hub.Connected() != 0 {
					t.Fatal("unverified durable claim admitted a socket")
				}
				return
			}
			if err != nil || stored.Lease.ClaimedAt.IsZero() {
				t.Fatalf("socket opened without a durable claim: %v", err)
			}
			_, data, err := conn.Read(dialCtx)
			if err != nil {
				t.Fatal(err)
			}
			message, err := wire.Decode(data)
			if err != nil || message.Snapshot.Observer != 1 {
				t.Fatal("admitted socket did not receive the real join snapshot")
			}
			if _, err := f.store.BeginRelease(ctx, f.record, "attempt-1"); !errors.Is(err, nakamalease.ErrClaimed) {
				t.Fatalf("cleanup stole an admitted session: %v", err)
			}
		})
	}
}
