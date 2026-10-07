//go:build war_native_trial

package nakamatrial

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"debug/buildinfo"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"maps"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	sdkproto "agones.dev/agones/pkg/sdk"
	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

var zoneArtifact = flag.String("war-zone", "", "built sealed zone command for the disposable trial")

type trialZone struct {
	f                *fixture
	name             string
	port             int
	sidecar          *agonestest.Sidecar
	process          *nativeProcess
	roots            *x509.CertPool
	claimConnections atomic.Int32
}

// closedFixture selects the real zone pool; it never manufactures admission keys.
func closedFixture(t *testing.T) *fixture {
	t.Helper()
	f := newFixture(t)
	f.zonePool = make(map[string]*trialZone)
	f.env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
	return f
}

// zoneFile writes private material only to this scenario's owned temporary directory.
func (f *fixture) zoneFile(name string, data []byte) string {
	f.t.Helper()
	path := filepath.Join(f.dir, name)
	if err := os.WriteFile(path, data, 0600); err != nil {
		f.t.Fatal(err)
	}
	return path
}

// startZone runs the exact built command against a generated SDK service.
func (f *fixture) startZone(name string, wrapping *rsa.PrivateKey, peer string, held bool, options ...string) *trialZone {
	f.t.Helper()
	if *zoneArtifact == "" {
		f.t.Fatal("closed-loop trial requires a packaged zone artifact")
	}
	if _, err := os.Stat(*zoneArtifact); err != nil {
		f.t.Fatal("closed-loop zone artifact is unavailable")
	}
	sdk, err := agonestest.Start(nil)
	if err != nil {
		f.t.Fatal(err)
	}
	sdk.SetGameServer("world-at-ruin", name, name+"-uid", "Starting")
	if held {
		sdk.HoldWatchEvents()
	}
	if peer == "publication-failed" {
		sdk.FailSetAnnotation(status.Error(codes.Unavailable, "fixture publication failure"))
	}
	f.mu.Lock()
	port := 8443 + len(f.zonePool)
	z := &trialZone{f: f, name: name, port: port, sidecar: sdk}
	f.zonePool[name] = z
	f.mu.Unlock()
	// Separate transport roots certify the handoff's actual DNS name.
	ca, caKey, caPEM := newCA(f.t)
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		f.t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: bigSerial(f.t), DNSNames: []string{"node-" + name + ".zones.example"}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, caKey)
	if err != nil {
		f.t.Fatal(err)
	}
	certPath := f.zoneFile(name+"-tls.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	keyPath := f.zoneFile(name+"-tls-key.pem", pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	z.roots = x509.NewCertPool()
	z.roots.AppendCertsFromPEM(caPEM)
	peerCA, peerKey := f.claimsCA, f.claimsKey
	identity := name + "-uid"
	if peer == "wrong" {
		identity = "wrong-uid"
	}
	if peer == "untrusted" {
		peerCA, peerKey, _ = newCA(f.t)
	}
	_, peerCert, peerPrivate := newCertificate(f.t, peerCA, peerKey, "spiffe://fixture.example/zone/world-at-ruin/"+identity, false)
	public, err := x509.MarshalPKIXPublicKey(&wrapping.PublicKey)
	if err != nil {
		f.t.Fatal(err)
	}
	claimAddress := z.claimProbe()
	// Cover the 40m demo square's diagonal so moving neighbours remain visible
	// through multi-restart scenarios; admission tests require populated frames.
	args := []string{"-listen", "127.0.0.1:" + strconv.Itoa(port), "-interest", "60000", "-tls-cert", certPath, "-tls-key", keyPath, "-agones", "-agones-health-interval", "50ms", "-agones-admission-public-key", f.zoneFile(name+"-wrap.pem", pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: public})), "-private-claims", "-claim-url", "https://localhost:" + claimAddress + "/v1/claim", "-claim-ca", f.env["WAR_HANDOFF_CLAIMS_CA_FILE"], "-claim-cert", f.zoneFile(name+"-peer.pem", peerCert), "-claim-key", f.zoneFile(name+"-peer-key.pem", peerPrivate)}
	args = append(args, options...)
	p := &nativeProcess{cmd: exec.Command(*zoneArtifact, args...), done: make(chan struct{}), log: &lockedLog{}}
	p.cmd.Env = append(os.Environ(), "AGONES_SDK_GRPC_HOST=127.0.0.1", "AGONES_SDK_GRPC_PORT="+sdk.PortString(), "WAR_ZONE_ADMISSION_SECRET=")
	p.cmd.Stdout, p.cmd.Stderr = p.log, p.log
	if err := p.cmd.Start(); err != nil {
		sdk.Stop()
		f.t.Fatal(err)
	}
	z.process = p
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	f.t.Cleanup(func() { p.stop(f.t); sdk.Stop() })
	if !held {
		z.ready()
	}
	return z
}

// bigSerial gives each ephemeral zone leaf a distinct positive serial.
func bigSerial(t *testing.T) *big.Int {
	t.Helper()
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// claimProbe observes actual private connections without terminating or replacing mutual TLS.
func (z *trialZone) claimProbe() string {
	z.f.t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		z.f.t.Fatal(err)
	}
	var mu sync.Mutex
	connections := make(map[net.Conn]struct{})
	var workers sync.WaitGroup
	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		for {
			client, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			connections[client] = struct{}{}
			mu.Unlock()
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer func() { _ = client.Close(); mu.Lock(); delete(connections, client); mu.Unlock() }()
				backend, err := net.DialTimeout("tcp", "127.0.0.1:7443", time.Second)
				if err != nil {
					return
				}
				mu.Lock()
				connections[backend] = struct{}{}
				mu.Unlock()
				defer func() { _ = backend.Close(); mu.Lock(); delete(connections, backend); mu.Unlock() }()
				z.claimConnections.Add(1)
				done := make(chan struct{})
				go func() { _, _ = io.Copy(backend, client); _ = backend.Close(); _ = client.Close(); close(done) }()
				_, _ = io.Copy(client, backend)
				_ = backend.Close()
				_ = client.Close()
				<-done
			}()
		}
	}()
	z.f.t.Cleanup(func() {
		_ = listener.Close()
		<-acceptDone
		mu.Lock()
		for connection := range connections {
			_ = connection.Close()
		}
		mu.Unlock()
		joined := make(chan struct{})
		go func() { workers.Wait(); close(joined) }()
		select {
		case <-joined:
		case <-time.After(3 * time.Second):
			z.f.t.Error("private connection probe failed to join")
		}
	})
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	return port
}

func (z *trialZone) ready() {
	z.f.t.Helper()
	waitFor(z.f.t, 8*time.Second, "built sealed zone readiness", func() bool {
		select {
		case <-z.process.done:
			z.f.t.Fatalf("zone startup failed: %s", z.process.log.String())
		default:
		}
		return z.sidecar.ReadyCalls() == 1
	})
	gs, err := z.sidecar.GetGameServer(z.f.t.Context(), &sdkproto.Empty{})
	if err != nil || gs.GetObjectMeta().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] == "" || gs.GetObjectMeta().GetLabels()[agones.AdmissionReadyLabel] == "" {
		z.f.t.Fatal("zone readiness preceded observed sealed material")
	}
	gs.Status.State = "Ready"
	z.sidecar.PublishGameServer(gs)
}

// allocateZone enforces the real client's complete Ready selector before any effect.
func (f *fixture) allocateZone(ctx context.Context, request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
	f.mu.Lock()
	f.allocationCalls++
	names := make([]string, 0, len(f.zonePool))
	for name := range f.zonePool {
		names = append(names, name)
	}
	sort.Strings(names)
	pool := make([]*trialZone, 0, len(names))
	for _, name := range names {
		pool = append(pool, f.zonePool[name])
	}
	ambiguous, hold, entered := f.ambiguous, f.hold, f.entered
	f.mu.Unlock()
	selectors := request.GetGameServerSelectors()
	if request.GetNamespace() != "world-at-ruin" || len(selectors) != 1 || selectors[0].GetGameServerState() != allocationpb.GameServerSelector_READY || len(selectors[0].GetMatchLabels()) != 2 || selectors[0].GetMatchLabels()[agones.FleetLabel] != "cave" || selectors[0].GetMatchLabels()[agones.AdmissionReadyLabel] == "" {
		return nil, status.Error(codes.InvalidArgument, "closed-loop allocator scope")
	}
	for _, z := range pool {
		gs, err := z.sidecar.GetGameServer(ctx, &sdkproto.Empty{})
		if err != nil || gs.GetStatus().GetState() != "Ready" || z.sidecar.ReadyCalls() != 1 || gs.GetObjectMeta().GetLabels()[agones.AdmissionReadyLabel] != selectors[0].GetMatchLabels()[agones.AdmissionReadyLabel] {
			continue
		}
		gs.Status.State = "Allocated"
		maps.Copy(gs.ObjectMeta.Labels, request.GetMetadata().GetLabels())
		maps.Copy(gs.ObjectMeta.Annotations, request.GetMetadata().GetAnnotations())
		resource := &agonesv1.GameServer{TypeMeta: metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServer"}, ObjectMeta: metav1.ObjectMeta{Namespace: "world-at-ruin", Name: z.name, UID: types.UID(gs.GetObjectMeta().GetUid()), ResourceVersion: "42", Labels: maps.Clone(gs.GetObjectMeta().GetLabels()), Annotations: maps.Clone(gs.GetObjectMeta().GetAnnotations())}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated, NodeName: "node-" + z.name, Ports: []agonesv1.GameServerStatusPort{{Name: "tls", Port: int32(z.port)}}}}
		resource.Labels[agones.FleetLabel] = "cave"
		f.mu.Lock()
		f.servers[z.name] = resource
		f.allocations++
		f.mu.Unlock()
		z.sidecar.PublishGameServer(gs)
		if entered != nil {
			select {
			case entered <- struct{}{}:
			default:
			}
		}
		if hold != nil {
			select {
			case <-hold:
			case <-ctx.Done():
				return nil, status.Error(codes.Canceled, "closed-loop acknowledgement lost")
			}
		}
		if ambiguous {
			return nil, status.Error(codes.Unavailable, "closed-loop acknowledgement lost")
		}
		return &allocationpb.AllocationResponse{GameServerName: z.name, NodeName: resource.Status.NodeName, Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{{Name: "tls", Port: int32(z.port)}}, Metadata: &allocationpb.AllocationResponse_GameServerMetadata{Labels: maps.Clone(resource.Labels), Annotations: maps.Clone(resource.Annotations)}}, nil
	}
	return nil, status.Error(codes.ResourceExhausted, "no observed Ready zone")
}

// dial uses the returned hostname for URL and TLS verification; only DNS routing is local.
func (z *trialZone) dial(ctx context.Context, got handoff.Handoff, versions ...uint16) (*websocket.Conn, error) {
	if got.ServerName != "node-"+z.name+".zones.example" || int(got.Port) != z.port {
		return nil, fmt.Errorf("handoff endpoint disagrees with allocated zone")
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: z.roots}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != net.JoinHostPort(got.ServerName, strconv.Itoa(int(got.Port))) {
			return nil, fmt.Errorf("unexpected zone endpoint")
		}
		return (&net.Dialer{}).DialContext(ctx, network, "127.0.0.1:"+strconv.Itoa(z.port))
	}}
	defer transport.CloseIdleConnections()
	headers := http.Header{"Authorization": {"Bearer " + got.Token}}
	if len(versions) > 0 {
		headers.Set("X-WAR-Wire-Version", strconv.FormatUint(uint64(versions[0]), 10))
	}
	conn, response, err := websocket.Dial(ctx, "wss://"+net.JoinHostPort(got.ServerName, strconv.Itoa(int(got.Port)))+"/zone", &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}, HTTPHeader: headers})
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil && response != nil {
		err = fmt.Errorf("zone HTTP %d: %w", response.StatusCode, err)
	}
	return conn, err
}

// snapshot requires an actual upgraded binary replication frame from the command.
func (z *trialZone) snapshot(got handoff.Handoff) *websocket.Conn {
	z.f.t.Helper()
	ctx, cancel := context.WithTimeout(z.f.t.Context(), 4*time.Second)
	defer cancel()
	var conn *websocket.Conn
	var err error
	for {
		conn, err = z.dial(ctx, got)
		if err == nil || ctx.Err() != nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		z.f.t.Fatalf("closed-loop TLS admission: %v", err)
	}
	z.f.t.Cleanup(func() { _ = conn.CloseNow() })
	kind, payload, err := conn.Read(ctx)
	if err != nil || kind != websocket.MessageBinary {
		z.f.t.Fatal("zone did not send binary replication")
	}
	message, err := wire.Decode(payload)
	if err != nil || message.Kind != wire.KindSnapshot || message.Snapshot.Observer != 1 || len(message.Snapshot.Entities) == 0 {
		z.f.t.Fatalf("zone snapshot: kind=%d observer=%d entities=%d decode=%v", message.Kind, message.Snapshot.Observer, len(message.Snapshot.Entities), err)
	}
	return conn
}

func (z *trialZone) refuse(got handoff.Handoff) {
	z.f.t.Helper()
	ctx, cancel := context.WithTimeout(z.f.t.Context(), 4*time.Second)
	defer cancel()
	conn, err := z.dial(ctx, got)
	if conn != nil {
		_ = conn.CloseNow()
	}
	if err == nil || !strings.Contains(err.Error(), "zone HTTP ") {
		z.f.t.Fatalf("invalid admission did not reach a refusing zone: %v", err)
	}
}

// claimBlock holds actual storage writes, with an independent PostgreSQL waiter observation.
func (f *fixture) claimBlock() (func(), func()) {
	f.t.Helper()
	tx, err := f.db.Begin()
	if err != nil {
		f.t.Fatal(err)
	}
	if _, err := tx.Exec("LOCK TABLE storage IN SHARE MODE"); err != nil {
		_ = tx.Rollback()
		f.t.Fatal(err)
	}
	var once sync.Once
	release := func() {
		once.Do(func() {
			if err := tx.Rollback(); err != nil {
				f.t.Error(err)
			}
		})
	}
	f.t.Cleanup(release)
	wait := func() {
		waitFor(f.t, 2*time.Second, "native PostgreSQL claim write blocked", func() bool {
			var count int
			err := f.db.QueryRow("SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND wait_event_type='Lock' AND query ILIKE '%storage%'", f.dbName).Scan(&count)
			return err == nil && count > 0
		})
	}
	return wait, release
}

func (f *fixture) blockedClaims() int {
	ctx, cancel := context.WithTimeout(f.t.Context(), time.Second)
	defer cancel()
	var count int
	if err := f.db.QueryRowContext(ctx, "SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND wait_event_type='Lock' AND query ILIKE '%storage%'", f.dbName).Scan(&count); err != nil {
		f.t.Fatal("observe native blocked claim writes")
	}
	return count
}

// pending starts real socket admission while its native database write is held.
func (z *trialZone) pending(got handoff.Handoff) <-chan error {
	done := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		conn, err := z.dial(ctx, got)
		if conn != nil {
			_ = conn.CloseNow()
		}
		done <- err
	}()
	return done
}

func (f *fixture) claimed(key string) (string, string) {
	f.t.Helper()
	value, version, read, write := f.row(key)
	var row struct {
		Claimed *int64 `json:"claimed_at_nanos"`
	}
	if json.Unmarshal([]byte(value), &row) != nil || row.Claimed == nil || *row.Claimed <= 0 || read != 0 || write != 0 {
		f.t.Fatal("socket admission lacks an exact private committed claim")
	}
	return value, version
}

// verifyZoneArtifact binds the exercised command to its separately packaged bytes.
func verifyZoneArtifact(t *testing.T) {
	t.Helper()
	data, err := os.ReadFile(*zoneArtifact)
	if err != nil {
		t.Fatal("packaged zone command unavailable")
	}
	digest, err := os.ReadFile(*zoneArtifact + ".sha256")
	if err != nil {
		t.Fatal("packaged zone digest unavailable")
	}
	sum := sha256.Sum256(data)
	fields := strings.Fields(string(digest))
	if len(fields) != 2 || fields[0] != hex.EncodeToString(sum[:]) {
		t.Fatal("packaged zone digest mismatch")
	}
	info, err := buildinfo.ReadFile(*zoneArtifact)
	if err != nil || info.GoVersion != "go1.27.1" || info.Main.Path != "github.com/devantler-tech/world-at-ruin/server" {
		t.Fatal("packaged zone provenance mismatch")
	}
}
