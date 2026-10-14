//go:build war_native_trial && war_issued_trial

package nakamatrial

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"maps"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/spiffe/go-spiffe/v2/proto/spiffe/workload"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// This synthetic WorkloadAPI transfers fixture keys to the real loaded plugin.
// It proves SDK-to-native-storage integration, never workload attestation.
type nativeClaimsIssuer struct {
	workload.UnimplementedSpiffeWorkloadAPIServer
	response *workload.X509SVIDResponse
	requests atomic.Int32
	active   atomic.Int32
}

func (s *nativeClaimsIssuer) FetchX509SVID(_ *workload.X509SVIDRequest, stream workload.SpiffeWorkloadAPI_FetchX509SVIDServer) error {
	s.requests.Add(1)
	s.active.Add(1)
	defer s.active.Add(-1)
	if s.response == nil {
		return status.Error(codes.PermissionDenied, "private fixture refusal")
	}
	if err := stream.Send(s.response); err != nil {
		return err
	}
	<-stream.Context().Done()
	return stream.Context().Err()
}

func nativeClaimsAPI(t *testing.T, response *workload.X509SVIDResponse) (*nativeClaimsIssuer, string) {
	t.Helper()
	// Bound Unix paths independently of the test's descriptive name.
	dir, err := os.MkdirTemp("/tmp", "war-wapi-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Error(err)
		}
	})
	socket := filepath.Join(dir, "api.sock")
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	issuer := &nativeClaimsIssuer{response: response}
	workload.RegisterSpiffeWorkloadAPIServer(server, issuer)
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		_ = listener.Close()
		if err := <-done; err != nil && err != grpc.ErrServerStopped {
			t.Error(err)
		}
		if issuer.active.Load() != 0 {
			t.Error("WorkloadAPI stream survived fixture retirement")
		}
	})
	return issuer, socket
}

func (f *fixture) issuedClaimsEnv(socket string) map[string]string {
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
	env["WAR_ISSUED_CLAIMS_ENABLED"] = "true"
	env["WAR_ISSUED_CLAIMS_SOCKET"] = socket
	env["WAR_ISSUED_CLAIMS_SERVER_DNS"] = "localhost"
	env["WAR_ISSUED_CLAIMS_SERVER_URI"] = "spiffe://fixture.example/claims/private"
	// Any fallback to projected claims files must fail this positive execution.
	for _, key := range []string{"WAR_HANDOFF_CLAIMS_CERT_FILE", "WAR_HANDOFF_CLAIMS_KEY_FILE", "WAR_HANDOFF_CLAIMS_CA_FILE"} {
		env[key] = filepath.Join(f.dir, "absent-projected-claims")
	}
	return env
}

func nativeClaimsResponse(t *testing.T, f *fixture) *workload.X509SVIDResponse {
	t.Helper()
	cert, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/claims/private", true)
	key, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	return &workload.X509SVIDResponse{Svids: []*workload.X509SVID{{
		SpiffeId: "spiffe://fixture.example/claims/private",
		X509Svid: cert.Certificate[0], X509SvidKey: key, Bundle: nativeCertificateDER(t, f.claimsPEM),
	}}}
}

func nativeCertificateDER(t *testing.T, data []byte) []byte {
	t.Helper()
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" || len(rest) != 0 {
		t.Fatal("invalid fixture certificate PEM")
	}
	return block.Bytes
}

func TestNativeIssuedClaimsPlugin(t *testing.T) {
	f := newFixture(t)
	modules := filepath.Join(*bundle, "modules")
	for _, enable := range []string{"", "false"} {
		issuer, socket := nativeClaimsAPI(t, nativeClaimsResponse(t, f))
		env := map[string]string{"WAR_ISSUED_CLAIMS_ENABLED": enable, "WAR_ISSUED_CLAIMS_SOCKET": socket}
		p := f.launch(env, modules, 10, true)
		p.stop(t)
		if issuer.requests.Load() != 0 {
			t.Fatal("disabled issued entry contacted WorkloadAPI")
		}
	}
	for _, fault := range []string{"flag", "handoff-off", "claims-off", "probe", "DNS", "URI", "root", "key", "issuer"} {
		t.Run("startup-"+fault, func(t *testing.T) {
			response := nativeClaimsResponse(t, f)
			if fault == "root" {
				_, _, ca := newCA(t)
				response.Svids[0].Bundle = nativeCertificateDER(t, ca)
			}
			if fault == "key" {
				response.Svids[0].X509SvidKey = []byte("invalid")
			}
			if fault == "issuer" {
				response = nil
			}
			issuer, socket := nativeClaimsAPI(t, response)
			env := f.issuedClaimsEnv(socket)
			switch fault {
			case "flag":
				env["WAR_ISSUED_CLAIMS_ENABLED"] = "yes"
			case "handoff-off":
				env["WAR_HANDOFF_ENABLED"] = "false"
			case "claims-off":
				env["WAR_HANDOFF_CLAIMS_ENABLED"] = "false"
			case "probe":
				env["WAR_ISSUED_SDK_PROBE_ENABLED"] = "true"
			case "DNS":
				env["WAR_ISSUED_CLAIMS_SERVER_DNS"] = "wrong.example"
			case "URI":
				env["WAR_ISSUED_CLAIMS_SERVER_URI"] = "spiffe://fixture.example/claims/other"
			}
			p := f.launch(env, modules, 10, false)
			if p.err == nil || strings.Contains(p.log.String(), "Go runtime modules loaded") || strings.Contains(p.log.String(), socket) {
				t.Fatal("issued startup did not refuse before runtime readiness")
			}
			waitFor(t, time.Second, "refused WorkloadAPI retirement", func() bool { return issuer.active.Load() == 0 })
			var count int
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if err := f.db.QueryRowContext(ctx, "SELECT count(*) FROM storage WHERE collection=$1", collection).Scan(&count); err != nil || count != 0 {
				t.Fatal("refused startup created native lease storage")
			}
		})
	}
	issuer, socket := nativeClaimsAPI(t, nativeClaimsResponse(t, f))
	p := f.launch(f.issuedClaimsEnv(socket), modules, 10, true)
	waitFor(t, time.Second, "successful SDK transport retirement", func() bool { return issuer.active.Load() == 0 })
	if issuer.requests.Load() != 1 {
		t.Fatal("issued plugin did not use one startup fetch")
	}
	token, uid := f.account("issued-native-claims")
	handoff := f.handoff(token)
	gs := f.resource("zone-1")
	binding := agones.ClaimBinding{Namespace: "world-at-ruin", AllocationID: gs.Name, GameServerUID: string(gs.UID), LeaseObjectID: leaseKey(uid), AttemptDigest: gs.Labels[agones.AttemptLabel]}
	before, version, _, _ := f.row(binding.LeaseObjectID)
	peer, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/zone/world-at-ruin/"+binding.GameServerUID, false)
	wrong, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/zone/world-at-ruin/wrong-uid", false)
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(f.claimsPEM) {
		t.Fatal("missing native fixture root")
	}
	client := func(cert tls.Certificate, dns, uri string) *claimrpc.Client {
		config := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{cert}, ServerName: dns,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 || len(state.PeerCertificates[0].URIs) != 1 || state.PeerCertificates[0].URIs[0].String() != uri {
					return status.Error(codes.PermissionDenied, "fixture server identity refused")
				}
				return nil
			}}
		c, err := claimrpc.NewClient("https://localhost:7443/v1/claim", config)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(c.Close)
		return c
	}
	for _, control := range []struct {
		cert     tls.Certificate
		dns, uri string
	}{
		{wrong, "localhost", "spiffe://fixture.example/claims/private"},
		{peer, "wrong.example", "spiffe://fixture.example/claims/private"},
		{peer, "localhost", "spiffe://fixture.example/claims/other"},
	} {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, err := client(control.cert, control.dns, control.uri).ClaimWithReceipt(ctx, binding, handoff.Token, 1)
		cancel()
		if err == nil {
			t.Fatal("unverified native client received a receipt")
		}
		value, actualVersion, _, _ := f.row(binding.LeaseObjectID)
		if value != before || actualVersion != version {
			t.Fatal("refused claim changed native lease")
		}
	}
	c := client(peer, "localhost", "spiffe://fixture.example/claims/private")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	receipt, err := c.ClaimWithReceipt(ctx, binding, handoff.Token, 1)
	cancel()
	if err != nil {
		t.Fatal("native SDK-material claim refused")
	}
	value, actualVersion, read, write := f.row(binding.LeaseObjectID)
	var persisted struct {
		AllocationID string `json:"allocation_id"`
		Attempt      string `json:"attempt_id"`
		Observer     uint64 `json:"observer"`
		ClaimedAt    int64  `json:"claimed_at_nanos"`
	}
	if err := json.Unmarshal([]byte(value), &persisted); err != nil {
		t.Fatal(err)
	}
	expected := zoneclaim.Receipt{Namespace: "world-at-ruin", Observer: 1, Fence: nakamalease.SessionFence{
		LeaseObjectID: binding.LeaseObjectID, LeaseVersion: actualVersion, AttemptDigest: binding.AttemptDigest,
		AllocationID: binding.AllocationID, GameServerUID: binding.GameServerUID, Generation: time.Unix(0, persisted.ClaimedAt).UTC(),
	}}
	attempt, digestErr := agones.CorrelationLabel(persisted.Attempt)
	if actualVersion == version || read != 0 || write != 0 || persisted.ClaimedAt <= 0 || persisted.AllocationID != gs.Name || persisted.Observer != 1 || digestErr != nil || attempt != binding.AttemptDigest || !receipt.Equal(expected) {
		t.Fatal("complete receipt does not match independent native storage")
	}
	ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
	replay, err := c.ClaimWithReceipt(ctx, binding, handoff.Token, 1)
	cancel()
	after, afterVersion, _, _ := f.row(binding.LeaseObjectID)
	if err != nil || !replay.Equal(receipt) || after != value || afterVersion != actualVersion {
		t.Fatal("native replay changed original receipt or storage")
	}
	p.stop(t)
	conn, err := net.DialTimeout("tcp", "127.0.0.1:7443", 100*time.Millisecond)
	if err == nil {
		_ = conn.Close()
		t.Fatal("issued listener survived runtime shutdown")
	}
	t.Log("ISSUED CLAIMS NATIVE PASS: synthetic WorkloadAPI; loaded plugin; one fetch and closed stream; fixed verified TLS; native receipt and replay; refusal storage unchanged; owned shutdown")
}
