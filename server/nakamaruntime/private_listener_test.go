package nakamaruntime

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"maps"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestPrivateListenerRejectsIncompleteOptIn catches an enabled listener silently
// falling back to a runtime which cannot serve durable claims.
func TestPrivateListenerRejectsIncompleteOptIn(t *testing.T) {
	for _, value := range []string{"true", "TRUE", "1"} {
		env := validEnvironment()
		env["WAR_HANDOFF_CLAIMS_ENABLED"] = value
		called := false
		err := initialize(environmentContext(env), &moduleStorage{}, &registration{}, func(config) (dependencies, error) {
			called = true
			return dependencies{}, errors.New("private transport should not be reached")
		})
		if err == nil || called || !strings.Contains(err.Error(), "invalid WAR_HANDOFF_CLAIMS_") {
			t.Fatalf("invalid listener configuration reached dependencies: %v; called=%v", err, called)
		}
	}
}

// TestPrivateListenerConfigurationAndStartupRollback catches partial activation,
// leaked bound sockets and enabled registrations surviving a startup error.
func TestPrivateListenerConfigurationAndStartupRollback(t *testing.T) {
	f := newListenerFixture(t)
	for field, values := range map[string][]string{
		"WAR_HANDOFF_CLAIMS_ADDRESS":      {"", ":443", "localhost:443", "127.0.0.1:0", "127.0.0.1:65536"},
		"WAR_HANDOFF_CLAIMS_CA_FILE":      {"", "relative.pem"},
		"WAR_HANDOFF_CLAIMS_CERT_FILE":    {"", " /private.pem"},
		"WAR_HANDOFF_CLAIMS_KEY_FILE":     {"", "relative.pem"},
		"WAR_HANDOFF_CLAIMS_TRUST_DOMAIN": {"", "bad/domain"},
	} {
		for _, value := range values {
			env := maps.Clone(f.env)
			env[field] = value
			if _, err := readConfig(env); err == nil {
				t.Fatalf("accepted invalid %s", field)
			}
		}
	}
	for _, stage := range []string{"material", "oversized", "occupied", "rpc", "shutdown", "disabled"} {
		t.Run(stage, func(t *testing.T) {
			env := maps.Clone(f.env)
			r := &registration{}
			var closed atomic.Int32
			deps := f.deps
			deps.close = func() { closed.Add(1) }
			switch stage {
			case "material":
				env["WAR_HANDOFF_CLAIMS_KEY_FILE"] = "/private-missing-credential"
			case "oversized":
				env["WAR_HANDOFF_CLAIMS_CA_FILE"] = writeMaterial(t, t.TempDir(), "private-material", bytes.Repeat([]byte{'x'}, 1024*1024+1))
			case "rpc":
				r.rpcErr = errors.New("private registration error")
			case "shutdown":
				r.shutdownErr = errors.New("private registration error")
			case "occupied", "disabled":
				occupied, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = occupied.Close() }()
				if stage == "disabled" {
					env["WAR_HANDOFF_CLAIMS_ENABLED"] = "false"
					env["WAR_HANDOFF_CLAIMS_KEY_FILE"] = "/private-missing-credential"
				}
			}
			err := initialize(environmentContext(env), f.storage, r, func(config) (dependencies, error) { return deps, nil })
			if stage == "disabled" {
				if err != nil {
					t.Fatalf("disabled private path touched dependencies: %v", err)
				}
				r.shutdown(context.Background(), nil, nil, f.storage)
			} else {
				if err == nil || strings.Contains(err.Error(), "private-missing-credential") || strings.Contains(err.Error(), "private registration error") {
					t.Fatalf("startup error absent or leaked: %v", err)
				}
				if r.rpc != nil {
					if _, err := r.rpc(signedContext(), nil, nil, f.storage, `{}`); err == nil {
						t.Fatal("failed startup left a serving RPC")
					}
				}
			}
			if closed.Load() != 1 {
				t.Fatal("startup/shutdown did not release dependencies once")
			}
			if stage != "occupied" && stage != "disabled" {
				probe, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if err != nil {
					t.Fatal("startup rollback leaked the listener")
				}
				_ = probe.Close()
			}
		})
	}
	// The enclosing runtime switch dominates even malformed private settings.
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_ENABLED"] = "false"
	env["WAR_HANDOFF_CLAIMS_ADDRESS"] = "invalid"
	if err := Initialize(environmentContext(env), nil, nil); err != nil {
		t.Fatal("disabled runtime inspected private configuration")
	}
}

// TestPrivateListenerFailureStopsPublicAdmission proves a broken private server
// cancels the same lifecycle used by the public handoff gate.
func TestPrivateListenerFailureStopsPublicAdmission(t *testing.T) {
	f := newListenerFixture(t)
	cfg, err := readConfig(f.env)
	if err != nil {
		t.Fatal(err)
	}
	life, cancel := context.WithCancel(t.Context())
	defer cancel()
	gate := &handlerGate{}
	private, err := preparePrivateListener(cfg.claims, life, gate, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	private.start(cancel)
	defer private.stop(t.Context())
	if err := private.listener.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-life.Done():
	case <-time.After(time.Second):
		t.Fatal("private server failure did not stop module admission")
	}
	public := rpcHandler(life, gate, nil, time.Second)
	if _, err := public(signedContext(), nil, nil, f.storage, `{}`); err == nil {
		t.Fatal("failed private server left public handoff open")
	}
}

// TestPrivateListenerRejectsUnusableOrSharedTrust catches a listener starting
// with a trust root that cannot verify any workload, or with trust or a key it
// shares with the allocator PKI.
func TestPrivateListenerRejectsUnusableOrSharedTrust(t *testing.T) {
	f := newListenerFixture(t)
	serverCfg, _, _ := certificateFixture(t, t.TempDir())
	for name, mutate := range map[string]func(map[string]string){
		"valid": func(map[string]string) {},
		"expired root": func(env map[string]string) {
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = rootFixture(t, time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour), true)
		},
		"future root": func(env map[string]string) {
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = rootFixture(t, time.Now().Add(time.Hour), time.Now().Add(2*time.Hour), true)
		},
		"non-CA root": func(env map[string]string) {
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = rootFixture(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour), false)
		},
		"expired root in bundle": func(env map[string]string) {
			valid, err := os.ReadFile(env["WAR_HANDOFF_CLAIMS_CA_FILE"])
			if err != nil {
				t.Fatal(err)
			}
			expired, err := os.ReadFile(rootFixture(t, time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour), true))
			if err != nil {
				t.Fatal(err)
			}
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = writeMaterial(t, t.TempDir(), "bundle.pem", append(valid, expired...))
		},
		"allocator root": func(env map[string]string) {
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = env["WAR_HANDOFF_ALLOCATOR_CA_FILE"]
		},
		"allocator root in bundle": func(env map[string]string) {
			workload, err := os.ReadFile(env["WAR_HANDOFF_CLAIMS_CA_FILE"])
			if err != nil {
				t.Fatal(err)
			}
			allocator, err := os.ReadFile(env["WAR_HANDOFF_ALLOCATOR_CA_FILE"])
			if err != nil {
				t.Fatal(err)
			}
			env["WAR_HANDOFF_CLAIMS_CA_FILE"] = writeMaterial(t, t.TempDir(), "bundle.pem", append(workload, allocator...))
		},
		"allocator key": func(env map[string]string) {
			env["WAR_HANDOFF_ALLOCATOR_CERT_FILE"] = env["WAR_HANDOFF_CLAIMS_CERT_FILE"]
			env["WAR_HANDOFF_ALLOCATOR_KEY_FILE"] = env["WAR_HANDOFF_CLAIMS_KEY_FILE"]
			env["WAR_HANDOFF_ALLOCATOR_CA_FILE"] = serverCfg.allocatorCA
		},
		"unreadable allocator root": func(env map[string]string) {
			env["WAR_HANDOFF_ALLOCATOR_CA_FILE"] = "/private-missing-allocator-root"
		},
	} {
		t.Run(name, func(t *testing.T) {
			env := maps.Clone(f.env)
			mutate(env)
			cfg, err := readConfig(env)
			if err != nil {
				t.Fatal(err)
			}
			private, err := preparePrivateListener(cfg.claims, t.Context(), &handlerGate{}, http.NotFoundHandler())
			if name == "valid" {
				if err != nil {
					t.Fatalf("valid separate trust rejected: %v", err)
				}
				_ = private.listener.Close()
				return
			}
			if !errors.Is(err, errMaterial) {
				if private != nil {
					_ = private.listener.Close()
				}
				t.Fatalf("listener accepted %s: %v", name, err)
			}
		})
	}
}

// rootFixture writes a self-signed root with the given validity window.
func rootFixture(t *testing.T, notBefore, notAfter time.Time, isCA bool) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: notBefore, NotAfter: notAfter, IsCA: isCA, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, root, root, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return writeMaterial(t, t.TempDir(), "root.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

// TestPrivateListenerBoundsConnections catches unbounded TLS admission; releasing
// one admitted connection must permit the next verified workload to connect.
func TestPrivateListenerBoundsConnections(t *testing.T) {
	f := newListenerFixture(t)
	r := &registration{}
	if err := initialize(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return f.deps, nil }); err != nil {
		t.Fatal(err)
	}
	defer r.shutdown(context.Background(), nil, nil, f.storage)
	dialer := &tls.Dialer{Config: f.tls}
	var connections []net.Conn
	defer func() {
		for _, conn := range connections {
			_ = conn.Close()
		}
	}()
	for range 64 {
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		conn, err := dialer.DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
		cancel()
		if err != nil {
			t.Fatalf("allowed workload could not connect: %v", err)
		}
		connections = append(connections, conn)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	extra, err := dialer.DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
	cancel()
	if err == nil {
		_ = extra.Close()
		t.Fatal("private listener exceeded its connection budget")
	}
	_ = connections[0].Close()
	ctx, cancel = context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	replacement, err := dialer.DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
	if err != nil {
		t.Fatalf("released connection did not restore capacity: %v", err)
	}
	_ = replacement.Close()
}

type listenerFixture struct {
	env     map[string]string
	deps    dependencies
	storage *moduleStorage
	store   *nakamalease.Store
	binding agones.ClaimBinding
	token   string
	tls     *tls.Config
}

// newListenerFixture retains real lease storage, envelope resolution and claim
// logic; only the Nakama transport and Kubernetes API are hermetic fixtures.
func newListenerFixture(t *testing.T) listenerFixture {
	t.Helper()
	serverCfg, _, serverRoots := certificateFixture(t, t.TempDir())
	workloadCfg, certificate, _ := certificateFixture(t, t.TempDir(), "spiffe://claims.example/zone/world-at-ruin/uid-one")
	reserved, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	if err := reserved.Close(); err != nil {
		t.Fatal(err)
	}
	env := validEnvironment()
	env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
	env["WAR_HANDOFF_CLAIMS_ADDRESS"] = address
	env["WAR_HANDOFF_CLAIMS_CERT_FILE"] = serverCfg.allocatorCert
	env["WAR_HANDOFF_CLAIMS_KEY_FILE"] = serverCfg.allocatorKey
	env["WAR_HANDOFF_CLAIMS_CA_FILE"] = workloadCfg.allocatorCA
	env["WAR_HANDOFF_CLAIMS_TRUST_DOMAIN"] = "claims.example"
	// The listener checks separation from real allocator credentials.
	allocatorCfg, _, _ := certificateFixture(t, t.TempDir())
	env["WAR_HANDOFF_ALLOCATOR_CA_FILE"] = allocatorCfg.allocatorCA
	env["WAR_HANDOFF_ALLOCATOR_CERT_FILE"] = allocatorCfg.allocatorCert
	env["WAR_HANDOFF_ALLOCATOR_KEY_FILE"] = allocatorCfg.allocatorKey
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint, err := admissionref.Fingerprint(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	secret := bytes.Repeat([]byte{0xab}, 32)
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", "world-at-ruin", "zone-one", "uid-one", fingerprint}, "\x00"))
	sealed, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.PublicKey, secret, label)
	if err != nil {
		t.Fatal(err)
	}
	envelope := "v1." + base64.RawURLEncoding.EncodeToString(sealed)
	attempt, err := agones.CorrelationLabel("attempt-one")
	if err != nil {
		t.Fatal(err)
	}
	gs := &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{Namespace: "world-at-ruin", Name: "zone-one", UID: "uid-one", ResourceVersion: "1", Labels: map[string]string{agones.FleetLabel: "cave", agones.AttemptLabel: attempt, agones.AdmissionReadyLabel: agones.AdmissionReadyValue(fingerprint)}, Annotations: map[string]string{agones.AdmissionKeyAnnotation: fingerprint, agones.AdmissionEnvelopeAnnotation: envelope}},
		Status:     agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated, NodeName: "node-a", Ports: []agonesv1.GameServerStatusPort{{Name: "tls", Port: 8443}}},
	}
	keyring, err := admissionref.NewKeyring(key)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := keyring.Open(admissionref.Material{Namespace: gs.Namespace, GameServerName: gs.Name, GameServerUID: string(gs.UID), WrappingKeyFingerprint: fingerprint, AdmissionEnvelope: envelope, TLSPort: 8443})
	if err != nil {
		t.Fatal(err)
	}
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	store, err := nakamalease.NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	lease := nakamalease.Lease{UserID: moduleUser, ReservationID: playerReservation, AttemptID: "attempt-one", AllocationID: gs.Name, Observer: 1, SecretRef: opened.SecretRef(), ExpiresAt: time.Now().Add(time.Minute)}
	if _, err := store.Create(t.Context(), lease); err != nil {
		t.Fatal(err)
	}
	token, err := zonesock.MintToken(secret, gs.Name, 1, lease.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	return listenerFixture{env: env, deps: dependencies{allocator: allocatorFunction{}, resources: agonesfake.NewSimpleClientset(gs).AgonesV1().GameServers(gs.Namespace), keys: []*rsa.PrivateKey{key}}, storage: storage, store: store,
		binding: agones.ClaimBinding{Namespace: gs.Namespace, AllocationID: gs.Name, GameServerUID: string(gs.UID), LeaseObjectID: nakamalease.ReservationKey(moduleUser, playerReservation), AttemptDigest: attempt}, token: token,
		tls: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: serverRoots, ServerName: "localhost", Certificates: []tls.Certificate{certificate}}}
}

// client uses the real wire contract and verifies the private server's identity.
func (f listenerFixture) client(t *testing.T, config *tls.Config) *claimrpc.Client {
	t.Helper()
	client, err := claimrpc.NewClient("https://"+f.env["WAR_HANDOFF_CLAIMS_ADDRESS"]+"/v1/claim", config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

// TestPrivateListenerClaimsOnlyWithVerifiedWorkload catches omitted listener
// composition, permissive TLS and transport success without durable ownership.
func TestPrivateListenerClaimsOnlyWithVerifiedWorkload(t *testing.T) {
	f := newListenerFixture(t)
	r := &registration{}
	if err := initialize(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return f.deps, nil }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.shutdown(context.Background(), nil, nil, f.storage) })
	// An untrusted workload must fail at TLS before it can claim this valid lease.
	_, stranger, _ := certificateFixture(t, t.TempDir(), "spiffe://claims.example/zone/world-at-ruin/uid-one")
	bad := f.tls.Clone()
	bad.Certificates = []tls.Certificate{stranger}
	if err := f.client(t, bad).Claim(t.Context(), f.binding, f.token, 1); err == nil {
		t.Fatal("untrusted workload claimed a lease")
	}
	anonymous := f.tls.Clone()
	anonymous.Certificates = nil
	// TLS 1.2 exposes the missing-client-certificate alert during Dial itself;
	// TLS 1.3 may deliver that alert only on the first application read.
	anonymous.MaxVersion = tls.VersionTLS12
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	connection, err := (&tls.Dialer{Config: anonymous}).DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
	if connection != nil {
		_ = connection.Close()
	}
	if err == nil {
		t.Fatal("anonymous peer reached HTTP")
	}
	before, err := f.store.Load(t.Context(), moduleUser, playerReservation)
	if err != nil || !before.Lease.ClaimedAt.IsZero() {
		t.Fatal("unauthorized peer changed durable state")
	}
	client := f.client(t, f.tls)
	if err := client.Claim(t.Context(), f.binding, f.token, 1); err != nil {
		t.Fatalf("private listener did not serve the claim: %v", err)
	}
	after, err := f.store.Load(t.Context(), moduleUser, playerReservation)
	if err != nil || after.Lease.ClaimedAt.IsZero() {
		t.Fatal("listener returned before durable claim")
	}
	if _, err := f.store.BeginRelease(t.Context(), before, "attempt-one"); !errors.Is(err, nakamalease.ErrClaimed) {
		t.Fatalf("no-show cleanup stole admitted lease: %v", err)
	}
	r.shutdown(context.Background(), nil, nil, f.storage)
	if err := client.Claim(t.Context(), f.binding, f.token, 1); err == nil {
		t.Fatal("shutdown listener admitted another claim")
	}
}

type blockedClaimStorage struct {
	*moduleStorage
	started  chan struct{}
	once     sync.Once
	finished atomic.Bool
}

// StorageRead holds an admitted claim until cancellation, preserving the rest of
// the real store and reconciler and recording transport retirement order.
func (s *blockedClaimStorage) StorageRead(ctx context.Context, _ []*runtime.StorageRead) ([]*api.StorageObject, error) {
	s.once.Do(func() { close(s.started) })
	<-ctx.Done()
	s.finished.Store(true)
	return nil, ctx.Err()
}

// TestPrivateListenerShutdownCancelsClaimsBeforeClosingDependencies catches an
// unowned listener or active private request outliving the module transports.
func TestPrivateListenerShutdownCancelsClaimsBeforeClosingDependencies(t *testing.T) {
	f := newListenerFixture(t)
	storage := &blockedClaimStorage{moduleStorage: f.storage, started: make(chan struct{})}
	var closed atomic.Int32
	f.deps.close = func() {
		if !storage.finished.Load() {
			t.Error("dependencies closed before the claim returned")
		}
		closed.Add(1)
	}
	r := &registration{}
	if err := initialize(environmentContext(f.env), storage, r, func(config) (dependencies, error) { return f.deps, nil }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.shutdown(context.Background(), nil, nil, storage) })
	result := make(chan error, 1)
	client := f.client(t, f.tls)
	go func() { result <- client.Claim(t.Context(), f.binding, f.token, 1) }()
	select {
	case <-storage.started:
	case <-time.After(time.Second):
		t.Fatal("claim never reached storage")
	}
	r.shutdown(context.Background(), nil, nil, storage)
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("canceled claim succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("claim outlived shutdown")
	}
	if closed.Load() != 1 {
		t.Fatal("shutdown did not retire dependencies once")
	}
}
