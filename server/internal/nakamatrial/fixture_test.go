//go:build war_native_trial

package nakamatrial

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
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
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	_ "github.com/jackc/pgx/v5/stdlib"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
)

var experimental = flag.Bool("war-experimental", false, "explicitly run disposable native acceptance")
var bundle = flag.String("war-bundle", "", "locked native bundle directory")
var postgres = flag.String("war-postgres", "", "disposable PostgreSQL host:port")

const collection = "world_at_ruin_handoff_leases"
const zeroOwner = "00000000-0000-0000-0000-000000000000"
const resourcePath = "/apis/agones.dev/v1/namespaces/world-at-ruin/gameservers"

// TestMain makes this separate, explicit acceptance binary fail on absent inputs.
func TestMain(m *testing.M) {
	flag.Parse()
	if !*experimental || runtime.GOOS != "linux" || *bundle == "" || *postgres == "" || os.Getenv("WAR_NATIVE_DB_PASSWORD") == "" {
		fmt.Fprintln(os.Stderr, "native trial requires Linux, explicit opt-in, a bundle and disposable PostgreSQL credentials")
		os.Exit(2)
	}
	os.Exit(m.Run())
}

type lockedLog struct {
	mu    sync.Mutex
	bytes bytes.Buffer
}

// Write serializes the subprocess stdout/stderr sink without losing output.
func (l *lockedLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.bytes.Write(p)
}

// String snapshots logs while the native process may still be writing.
func (l *lockedLog) String() string { l.mu.Lock(); defer l.mu.Unlock(); return l.bytes.String() }

type nativeProcess struct {
	cmd  *exec.Cmd
	done chan struct{}
	err  error
	log  *lockedLog
}

// stop signals the real native process and joins it before fixture retirement.
func (p *nativeProcess) stop(t *testing.T) {
	t.Helper()
	select {
	case <-p.done:
		return
	default:
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
	case <-time.After(15 * time.Second):
		_ = p.cmd.Process.Kill()
		<-p.done
		t.Error("native process exceeded shutdown bound")
	}
}

type fixture struct {
	allocationpb.UnimplementedAllocationServiceServer
	t                            *testing.T
	dir                          string
	admin, db                    *sql.DB
	dbName                       string
	key                          *rsa.PrivateKey
	fingerprint                  string
	caPEM                        []byte
	cert                         tls.Certificate
	roots                        *x509.CertPool
	claimsCA                     *x509.Certificate
	claimsKey                    *rsa.PrivateKey
	claimsPEM                    []byte
	claimsCertificate            tls.Certificate
	grpc                         *grpc.Server
	api                          *httptest.Server
	process                      *nativeProcess
	env                          map[string]string
	mu                           sync.Mutex
	servers                      map[string]*agonesv1.GameServer
	allocations, requests, lists int
	pages                        int
	deleted                      []string
	retryDelete                  bool
	ambiguous                    bool
	hold                         chan struct{}
	entered                      chan struct{}
	cancelled                    chan struct{}
	apiFault                     string
}

// newFixture owns a fresh database; it never migrates an existing caller database.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t, dir: t.TempDir(), servers: map[string]*agonesv1.GameServer{}}
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	f.dbName = "war_native_trial_" + hex.EncodeToString(nonce)
	host, port, err := net.SplitHostPort(*postgres)
	if err != nil || host == "" || port == "" {
		t.Fatal("invalid disposable PostgreSQL address")
	}
	connect := func(database string) *sql.DB {
		u := url.URL{Scheme: "postgres", User: url.UserPassword("war_native_trial", os.Getenv("WAR_NATIVE_DB_PASSWORD")), Host: *postgres, Path: "/" + database, RawQuery: "sslmode=disable&connect_timeout=5"}
		db, e := sql.Open("pgx", u.String())
		if e != nil {
			t.Fatal("open disposable database")
		}
		return db
	}
	f.admin = connect("postgres")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err = f.admin.ExecContext(ctx, "CREATE DATABASE "+f.dbName); err != nil {
		_ = f.admin.Close()
		t.Fatal("create fresh disposable database")
	}
	f.db = connect(f.dbName)
	t.Cleanup(func() {
		if f.process != nil {
			f.process.stop(t)
		}
		if f.grpc != nil {
			f.grpc.Stop()
		}
		if f.api != nil {
			f.api.Close()
		}
		_ = f.db.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, e := f.admin.ExecContext(ctx, "DROP DATABASE "+f.dbName); e != nil {
			t.Error("drop owned trial database")
		}
		_ = f.admin.Close()
	})
	f.key, err = rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	f.fingerprint, err = admissionref.Fingerprint(&f.key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	ca, key, caPEM := newCA(t)
	f.caPEM = caPEM
	f.roots = x509.NewCertPool()
	f.roots.AppendCertsFromPEM(caPEM)
	var certPEM, keyPEM []byte
	f.cert, certPEM, keyPEM = newCertificate(t, ca, key, "", true)
	f.claimsCA, f.claimsKey, f.claimsPEM = newCA(t)
	var claimsCertPEM, claimsKeyPEM []byte
	f.claimsCertificate, claimsCertPEM, claimsKeyPEM = newCertificate(t, f.claimsCA, f.claimsKey, "", true)
	material := func(name string, data []byte) string {
		path := filepath.Join(f.dir, name)
		if e := os.WriteFile(path, data, 0600); e != nil {
			t.Fatal(e)
		}
		return path
	}
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	f.grpc = grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{f.cert}, ClientCAs: f.roots, ClientAuth: tls.RequireAndVerifyClientCert})))
	allocationpb.RegisterAllocationServiceServer(f.grpc, f)
	go func() { _ = f.grpc.Serve(listener) }()
	f.api = httptest.NewUnstartedServer(http.HandlerFunc(f.serveAPI))
	f.api.TLS = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{f.cert}}
	f.api.StartTLS()
	apiURL, _ := url.Parse(f.api.URL)
	apiHost, apiPort, _ := net.SplitHostPort(apiURL.Host)
	// This binary only runs inside the disposable trial container, whose image
	// precreates the service-account directory for its unprivileged trial user.
	sa := "/var/run/secrets/kubernetes.io/serviceaccount"
	for name, data := range map[string][]byte{"ca.crt": caPEM, "token": []byte("native-fixture-service-account"), "namespace": []byte("world-at-ruin")} {
		if e := os.WriteFile(filepath.Join(sa, name), data, 0600); e != nil {
			t.Fatal("project trial-only service account material")
		}
	}
	unwrapJSON, _ := json.Marshal([]string{material("unwrap.pem", pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(f.key)}))})
	_, allocatorPort, _ := net.SplitHostPort(listener.Addr().String())
	f.env = map[string]string{
		"WAR_HANDOFF_ENABLED": "true", "WAR_HANDOFF_ALLOCATOR_ADDRESS": "localhost:" + allocatorPort,
		"WAR_HANDOFF_ALLOCATOR_CA_FILE": material("allocator-ca.pem", caPEM), "WAR_HANDOFF_ALLOCATOR_CERT_FILE": material("allocator.pem", certPEM), "WAR_HANDOFF_ALLOCATOR_KEY_FILE": material("allocator-key.pem", keyPEM),
		"WAR_HANDOFF_UNWRAP_KEYS": string(unwrapJSON), "WAR_HANDOFF_NAMESPACE": "world-at-ruin", "WAR_HANDOFF_FLEET": "cave", "WAR_HANDOFF_TLS_PORT_NAME": "tls", "WAR_HANDOFF_ZONE_DOMAIN": "zones.example", "WAR_HANDOFF_LEASE_TTL": "2m", "WAR_HANDOFF_RPC_TIMEOUT": "3s",
		"WAR_HANDOFF_CLAIMS_ADDRESS": "127.0.0.1:7443", "WAR_HANDOFF_CLAIMS_CERT_FILE": material("claims.pem", claimsCertPEM), "WAR_HANDOFF_CLAIMS_KEY_FILE": material("claims-key.pem", claimsKeyPEM), "WAR_HANDOFF_CLAIMS_CA_FILE": material("claims-ca.pem", f.claimsPEM), "WAR_HANDOFF_CLAIMS_TRUST_DOMAIN": "fixture.example",
	}
	if e := os.Setenv("KUBERNETES_SERVICE_HOST", apiHost); e != nil {
		t.Fatal(e)
	}
	if e := os.Setenv("KUBERNETES_SERVICE_PORT", apiPort); e != nil {
		t.Fatal(e)
	}
	f.writeConfig(f.env, filepath.Join(*bundle, "modules"), 10)
	cmd := exec.CommandContext(ctx, filepath.Join(*bundle, "nakama"), "migrate", "up", "--config", filepath.Join(f.dir, "config.json"))
	if bytes, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("native migration failed: %s", bytes)
	}
	return f
}

// newCA issues ephemeral trust unique to this fixture dependency.
func newCA(t *testing.T) (*x509.Certificate, *rsa.PrivateKey, []byte) {
	t.Helper()
	key, e := rsa.GenerateKey(rand.Reader, 3072)
	if e != nil {
		t.Fatal(e)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, e := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if e != nil {
		t.Fatal(e)
	}
	return ca, key, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

// newCertificate signs the exact TLS endpoint or workload URI used by a scenario.
func newCertificate(t *testing.T, ca *x509.Certificate, issuer *rsa.PrivateKey, identity string, server bool) (tls.Certificate, []byte, []byte) {
	t.Helper()
	key, e := rsa.GenerateKey(rand.Reader, 3072)
	if e != nil {
		t.Fatal(e)
	}
	serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if e != nil {
		t.Fatal(e)
	}
	leaf := &x509.Certificate{SerialNumber: serial, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	if server {
		leaf.ExtKeyUsage = append(leaf.ExtKeyUsage, x509.ExtKeyUsageServerAuth)
	}
	if identity != "" {
		uri, e := url.Parse(identity)
		if e != nil {
			t.Fatal(e)
		}
		leaf.URIs = []*url.URL{uri}
	}
	der, e := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, issuer)
	if e != nil {
		t.Fatal(e)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	cert, e := tls.X509KeyPair(certPEM, keyPEM)
	if e != nil {
		t.Fatal(e)
	}
	return cert, certPEM, keyPEM
}

// writeConfig confines every configurable endpoint/key to this owned fixture.
func (f *fixture) writeConfig(env map[string]string, modules string, grace int) {
	values := make([]string, 0, len(env))
	for key, value := range env {
		values = append(values, key+"="+value)
	}
	sort.Strings(values)
	config := map[string]any{"name": "war-native-trial", "data_dir": f.dir, "shutdown_grace_sec": grace,
		"database": map[string]any{"address": []string{"war_native_trial:" + os.Getenv("WAR_NATIVE_DB_PASSWORD") + "@" + *postgres + "/" + f.dbName + "?sslmode=disable"}},
		"socket":   map[string]any{"address": "127.0.0.1", "port": 7350, "server_key": "native-fixture-server-key"},
		"session":  map[string]any{"encryption_key": "native-fixture-session-key", "refresh_encryption_key": "native-fixture-refresh-key"},
		"runtime":  map[string]any{"path": modules, "http_key": "native-fixture-http-key", "env": values},
		"console":  map[string]any{"address": "127.0.0.1", "port": 7351, "username": "native-fixture", "password": "native-fixture-password", "signing_key": "native-fixture-console-key"},
		"logger":   map[string]any{"level": "info", "stdout": true}}
	data, e := json.Marshal(config)
	if e != nil {
		f.t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(f.dir, "config.json"), data, 0600); e != nil {
		f.t.Fatal(e)
	}
}

// launch starts the built binary; readiness requires its actual HTTP health API.
func (f *fixture) launch(env map[string]string, modules string, grace int, healthy bool) *nativeProcess {
	f.t.Helper()
	if f.process != nil {
		f.process.stop(f.t)
	}
	f.writeConfig(env, modules, grace)
	p := &nativeProcess{cmd: exec.Command(filepath.Join(*bundle, "nakama"), "--config", filepath.Join(f.dir, "config.json")), done: make(chan struct{}), log: &lockedLog{}}
	p.cmd.Env = append(os.Environ(), "NAKAMA_TELEMETRY=0")
	p.cmd.Stdout, p.cmd.Stderr = p.log, p.log
	if e := p.cmd.Start(); e != nil {
		f.t.Fatal(e)
	}
	f.process = p
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-p.done:
			if healthy {
				f.t.Fatalf("native startup failed: %s", p.log.String())
			}
			return p
		default:
		}
		response, e := (&http.Client{Timeout: 200 * time.Millisecond}).Get("http://127.0.0.1:7350/healthcheck")
		if e == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				if !healthy {
					p.stop(f.t)
					f.t.Fatal("invalid native startup became ready")
				}
				return p
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	p.stop(f.t)
	f.t.Fatal("native startup did not settle")
	return nil
}

// account obtains a real native session and reads its authenticated account ID.
func (f *fixture) account(id string) (string, string) {
	f.t.Helper()
	request, _ := http.NewRequest(http.MethodPost, "http://127.0.0.1:7350/v2/account/authenticate/custom?create=true", strings.NewReader(`{"id":"`+id+`"}`))
	request.SetBasicAuth("native-fixture-server-key", "")
	request.Header.Set("Content-Type", "application/json")
	response, e := (&http.Client{Timeout: 5 * time.Second}).Do(request)
	if e != nil {
		f.t.Fatal(e)
	}
	defer func() { _ = response.Body.Close() }()
	var session struct {
		Token string `json:"token"`
	}
	if response.StatusCode != 200 || json.NewDecoder(response.Body).Decode(&session) != nil {
		f.t.Fatal("native authentication failed")
	}
	parts := strings.Split(session.Token, ".")
	if len(parts) != 3 {
		f.t.Fatal("invalid native session")
	}
	data, e := base64.RawURLEncoding.DecodeString(parts[1])
	if e != nil {
		f.t.Fatal(e)
	}
	var claims struct {
		UID string `json:"uid"`
	}
	if json.Unmarshal(data, &claims) != nil || claims.UID == "" {
		f.t.Fatal("native session lacks account")
	}
	return session.Token, claims.UID
}

// request exercises only the owned native loopback HTTP API with a bounded response.
func (f *fixture) request(method, path, token, payload string) (int, []byte) {
	f.t.Helper()
	request, e := http.NewRequest(method, "http://127.0.0.1:7350"+path, strings.NewReader(payload))
	if e != nil {
		f.t.Fatal(e)
	}
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, e := (&http.Client{Timeout: 8 * time.Second}).Do(request)
	if e != nil {
		f.t.Fatal("native API request failed")
	}
	defer func() { _ = response.Body.Close() }()
	data, e := io.ReadAll(io.LimitReader(response.Body, 65536))
	if e != nil {
		f.t.Fatal(e)
	}
	return response.StatusCode, data
}

// handoff requires a complete native RPC success with a usable zone endpoint.
func (f *fixture) handoff(token string) handoff.Handoff {
	f.t.Helper()
	code, data := f.request("POST", "/v2/rpc/war_handoff?unwrap", token, "{}")
	if code != 200 {
		f.t.Fatalf("native handoff refused (%d): %s", code, data)
	}
	var got handoff.Handoff
	if json.Unmarshal(data, &got) != nil || got.ServerName == "" || got.Port != 8443 || got.Token == "" || !got.ExpiresAt.After(time.Now()) {
		f.t.Fatal("native handoff shape changed")
	}
	return got
}

// row inspects the exact system-owned PostgreSQL record independently of the RPC.
func (f *fixture) row(key string) (string, string, int, int) {
	f.t.Helper()
	var value, version string
	var read, write int
	if e := f.db.QueryRow("SELECT value::text,version,read,write FROM storage WHERE collection=$1 AND key=$2 AND user_id=$3::uuid", collection, key, zeroOwner).Scan(&value, &version, &read, &write); e != nil {
		f.t.Fatal("read exact private fixture row")
	}
	return value, version, read, write
}

// seed inserts retained JSON into a fresh, owned database with private permissions.
func (f *fixture) seed(key string, value []byte) {
	f.t.Helper()
	_, e := f.db.Exec("INSERT INTO storage(collection,key,user_id,value,version,read,write,create_time,update_time) VALUES($1,$2,$3::uuid,$4::text::jsonb,md5($4::text),0,0,now(),now())", collection, key, zeroOwner, string(value))
	if e != nil {
		f.t.Fatal("seed exact disposable private lease")
	}
}

// counts snapshots provider effects separately from native client acknowledgements.
func (f *fixture) counts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.allocations, f.requests
}

// resource reads a copy of the external fixture state after conditional cleanup.
func (f *fixture) resource(name string) *agonesv1.GameServer {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.servers[name] == nil {
		return nil
	}
	return f.servers[name].DeepCopy()
}

// makeServer seals admission material to an exact namespace/name/UID binding.
func (f *fixture) makeServer(name, attempt string) *agonesv1.GameServer {
	f.t.Helper()
	uid := name + "-uid"
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", "world-at-ruin", name, uid, f.fingerprint}, "\x00"))
	ciphertext, e := rsa.EncryptOAEP(sha256.New(), rand.Reader, &f.key.PublicKey, bytes.Repeat([]byte{7}, 32), label)
	if e != nil {
		f.t.Fatal(e)
	}
	gs := &agonesv1.GameServer{TypeMeta: metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServer"}, ObjectMeta: metav1.ObjectMeta{Namespace: "world-at-ruin", Name: name, UID: types.UID(uid), ResourceVersion: "42", Labels: map[string]string{agones.FleetLabel: "cave", agones.AdmissionReadyLabel: agones.AdmissionReadyValue(f.fingerprint)}, Annotations: map[string]string{agones.AdmissionKeyAnnotation: f.fingerprint, agones.AdmissionEnvelopeAnnotation: "v1." + base64.RawURLEncoding.EncodeToString(ciphertext)}}, Status: agonesv1.GameServerStatus{State: agonesv1.GameServerStateAllocated, NodeName: "node-a", Ports: []agonesv1.GameServerStatusPort{{Name: "tls", Port: 8443}}}}
	if attempt != "" {
		digest, e := agones.CorrelationLabel(attempt)
		if e != nil {
			f.t.Fatal(e)
		}
		gs.Labels[agones.AttemptLabel] = digest
	}
	return gs
}

// Allocate models the external effect after native storage has persisted dispatch.
func (f *fixture) Allocate(ctx context.Context, request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
	f.mu.Lock()
	f.allocations++
	number := f.allocations
	ambiguous, hold, entered, cancelled := f.ambiguous, f.hold, f.entered, f.cancelled
	f.mu.Unlock()
	if request.GetNamespace() != "world-at-ruin" {
		return nil, status.Error(codes.InvalidArgument, "fixture scope")
	}
	name := fmt.Sprintf("zone-%d", number)
	gs := f.makeServer(name, "")
	for k, v := range request.GetMetadata().GetLabels() {
		gs.Labels[k] = v
	}
	for k, v := range request.GetMetadata().GetAnnotations() {
		gs.Annotations[k] = v
	}
	f.mu.Lock()
	f.servers[name] = gs
	f.mu.Unlock()
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
			if cancelled != nil {
				select {
				case cancelled <- struct{}{}:
				default:
				}
			}
			return nil, status.Error(codes.Canceled, "fixture cancelled")
		}
	}
	if ambiguous {
		return nil, status.Error(codes.Unavailable, "provider-private-details")
	}
	return &allocationpb.AllocationResponse{GameServerName: name, NodeName: "node-a", Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{{Name: "tls", Port: 8443}}, Metadata: &allocationpb.AllocationResponse_GameServerMetadata{Labels: maps.Clone(gs.Labels), Annotations: maps.Clone(gs.Annotations)}}, nil
}

// serveAPI checks generated-client scope and exact conditional deletion.
func (f *fixture) serveAPI(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests++
	w.Header().Set("Content-Type", "application/json")
	write := func(value any) {
		if e := json.NewEncoder(w).Encode(value); e != nil {
			f.t.Error(e)
		}
	}
	fail := func(code int, reason metav1.StatusReason) {
		w.WriteHeader(code)
		write(metav1.Status{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"}, Status: metav1.StatusFailure, Reason: reason, Code: int32(code), Message: "provider-private-details"})
	}
	if r.Header.Get("Authorization") != "Bearer native-fixture-service-account" {
		f.t.Error("native Kubernetes client omitted fixture service account")
		fail(401, metav1.StatusReasonUnauthorized)
		return
	}
	if r.URL.Path == resourcePath && r.Method == http.MethodGet {
		f.lists++
		selector, e := labels.Parse(r.URL.Query().Get("labelSelector"))
		if e != nil || !strings.Contains(selector.String(), "agones.dev/fleet=cave") {
			f.t.Error("native resource list widened scope")
			fail(400, metav1.StatusReasonBadRequest)
			return
		}
		list := agonesv1.GameServerList{TypeMeta: metav1.TypeMeta{APIVersion: "agones.dev/v1", Kind: "GameServerList"}, ListMeta: metav1.ListMeta{ResourceVersion: "42"}, Items: []agonesv1.GameServer{}}
		names := make([]string, 0, len(f.servers))
		for name := range f.servers {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			if selector.Matches(labels.Set(f.servers[name].Labels)) {
				list.Items = append(list.Items, *f.servers[name].DeepCopy())
			}
		}
		if r.URL.Query().Get("limit") != "" && r.URL.Query().Get("limit") != "100" {
			f.t.Error("native orphan page size changed")
		}
		if f.apiFault == "partial" {
			list.Continue = "second"
			if r.URL.Query().Get("continue") != "" {
				fail(500, metav1.StatusReasonInternalError)
				return
			}
		}
		if f.apiFault == "" && r.URL.Query().Get("limit") == "100" && len(list.Items) > 1 {
			if r.URL.Query().Get("continue") == "" {
				list.Items, list.Continue = list.Items[:1], "fixture-page-2"
			} else if r.URL.Query().Get("continue") == "fixture-page-2" {
				f.pages++
				list.Items = list.Items[1:]
			} else {
				f.t.Error("native client changed the opaque resource cursor")
				fail(400, metav1.StatusReasonBadRequest)
				return
			}
		}
		write(list)
		return
	}
	if !strings.HasPrefix(r.URL.Path, resourcePath+"/") {
		f.t.Error("native client contacted unrelated API")
		fail(404, metav1.StatusReasonNotFound)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, resourcePath+"/")
	gs := f.servers[name]
	if gs == nil {
		fail(404, metav1.StatusReasonNotFound)
		return
	}
	switch r.Method {
	case http.MethodGet:
		write(gs)
	case http.MethodDelete:
		var options metav1.DeleteOptions
		if json.NewDecoder(r.Body).Decode(&options) != nil || options.Preconditions == nil || options.Preconditions.UID == nil || *options.Preconditions.UID != gs.UID || (options.Preconditions.ResourceVersion != nil && *options.Preconditions.ResourceVersion != gs.ResourceVersion) {
			f.t.Error("native deletion lacked exact resource preconditions")
			fail(409, metav1.StatusReasonConflict)
			return
		}
		f.deleted = append(f.deleted, name)
		if f.retryDelete {
			f.retryDelete = false
			fail(503, metav1.StatusReasonServiceUnavailable)
			return
		}
		delete(f.servers, name)
		write(metav1.Status{Status: metav1.StatusSuccess})
	default:
		f.t.Error("native client issued unsupported mutation")
		fail(405, metav1.StatusReasonMethodNotAllowed)
	}
}

// waitFor gives asynchronous native behavior one bounded observation window.
func waitFor(t *testing.T, timeout time.Duration, description string, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("native acceptance timed out: %s", description)
}

// leaseKey derives the source's stable player reservation; no client chooses it.
func leaseKey(uid string) string { return nakamalease.ReservationKey(uid, "zone") }
