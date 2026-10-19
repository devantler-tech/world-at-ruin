package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"math/big"
	"net/url"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/testfixture"
	"github.com/heroiclabs/nakama-common/runtime"
	"github.com/spiffe/go-spiffe/v2/proto/spiffe/workload"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Unknown enablement must veto even a handoff-disabled runtime rather than
// silently selecting the ordinary projected initializer.
func TestIssuedClaimsUnknownFlagVetoesInitialization(t *testing.T) {
	ctx := claimsRuntimeContext{Context: context.Background(), env: map[string]string{
		"WAR_ISSUED_CLAIMS_ENABLED": "yes",
	}}
	err := InitModule(ctx, nil, nil, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "issued claims enablement refused") {
		t.Fatalf("unknown claims enablement did not veto startup: %v", err)
	}
}

// Nakama owns its string context key; preserve its native runtime boundary.
type claimsRuntimeContext struct {
	context.Context
	env map[string]string
}

func (c claimsRuntimeContext) Value(key any) any {
	if name, ok := key.(string); ok && name == runtime.RUNTIME_CTX_ENV {
		return c.env
	}
	return c.Context.Value(key)
}

func claimsEnv(socket string) map[string]string {
	return map[string]string{
		"WAR_ISSUED_CLAIMS_ENABLED": "true", "WAR_HANDOFF_ENABLED": "true",
		"WAR_HANDOFF_CLAIMS_ENABLED": "true", "WAR_ISSUED_CLAIMS_SOCKET": socket,
		"WAR_ISSUED_CLAIMS_SERVER_DNS":    "claims.fixture.example",
		"WAR_ISSUED_CLAIMS_SERVER_URI":    "spiffe://fixture.example/claims/private",
		"WAR_HANDOFF_CLAIMS_TRUST_DOMAIN": "fixture.example",
	}
}

func TestIssuedClaimsDisabledDoesNotFetch(t *testing.T) {
	for _, enable := range []string{"", "false"} {
		env := claimsEnv("malformed")
		env["WAR_ISSUED_CLAIMS_ENABLED"] = enable
		got, err := issuedClaimsMaterial(context.Background(), env)
		if err != nil || got != nil {
			t.Fatalf("disabled material: %v, %v", got, err)
		}
	}
}

func TestIssuedClaimsConfigurationRefusesBeforeFetch(t *testing.T) {
	changes := []struct{ key, value string }{
		{"WAR_HANDOFF_ENABLED", "false"}, {"WAR_HANDOFF_CLAIMS_ENABLED", ""},
		{"WAR_ISSUED_SDK_PROBE_ENABLED", "true"}, {"WAR_ISSUED_SDK_PROBE_ENABLED", "yes"},
		{"WAR_ISSUED_CLAIMS_SOCKET", "relative.sock"}, {"WAR_ISSUED_CLAIMS_SOCKET", "/tmp/a/../b.sock"},
		{"WAR_ISSUED_CLAIMS_SOCKET", "/tmp/socket?query"}, {"WAR_ISSUED_CLAIMS_SOCKET", "/tmp/socket#fragment"},
		{"WAR_ISSUED_CLAIMS_SOCKET", "/tmp/a%2fb.sock"},
		{"WAR_ISSUED_CLAIMS_SERVER_DNS", "127.0.0.1"}, {"WAR_ISSUED_CLAIMS_SERVER_DNS", "*.fixture.example"},
		{"WAR_ISSUED_CLAIMS_SERVER_URI", "spiffe://other.example/claims/private"},
		{"WAR_ISSUED_CLAIMS_SERVER_URI", "spiffe://fixture.example/claims/../private"},
		{"WAR_HANDOFF_CLAIMS_TRUST_DOMAIN", ""},
	}
	for _, change := range changes {
		t.Run(change.key+"="+change.value, func(t *testing.T) {
			issuer, socket := startClaimsIssuer(t, fixtureSVID(t))
			env := claimsEnv(socket)
			env[change.key] = change.value
			got, err := issuedClaimsMaterial(context.Background(), env)
			if err == nil || got != nil || issuer.requests.Load() != 0 {
				t.Fatal("invalid configuration reached issuer or returned material")
			}
			if change.key == "WAR_ISSUED_CLAIMS_SOCKET" && err.Error() != "issued claims configuration refused" {
				t.Fatal("invalid endpoint reached SDK construction")
			}
		})
	}
}

func TestIssuedClaimsFetchRetainsSignerAndClosesStream(t *testing.T) {
	response := fixtureSVID(t)
	issuer, socket := startClaimsIssuer(t, response)
	got, err := issuedClaimsMaterial(context.Background(), claimsEnv(socket))
	if err != nil || got == nil {
		t.Fatalf("fetch material: %v", err)
	}
	select {
	case <-issuer.closed:
	case <-time.After(time.Second):
		t.Fatal("SDK transport remained open after credential snapshot")
	}
	if issuer.requests.Load() != 1 || got.ExpectedServerDNS != "claims.fixture.example" || got.ExpectedServerURI != "spiffe://fixture.example/claims/private" || len(got.CertificateChainDER) != 1 || len(got.ClientAuthoritiesDER) != 1 {
		t.Fatal("credential snapshot lost independent pins or fetched more than once")
	}
	leaf, err := x509.ParseCertificate(got.CertificateChainDER[0])
	if err != nil {
		t.Fatal(err)
	}
	// A retained signing handle must still sign after SDK transport retirement.
	ec, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		t.Fatal("fixture public key type")
	}
	digest := make([]byte, 32)
	signature, err := got.Signer.Sign(rand.Reader, digest, crypto.SHA256)
	if err != nil || !ecdsa.VerifyASN1(ec, digest, signature) {
		t.Fatal("SDK cleanup invalidated the retained signer")
	}
	response.Svids[0].X509Svid[0] ^= 1
	if _, err := x509.ParseCertificate(got.CertificateChainDER[0]); err != nil {
		t.Fatal("retained certificate aliases issuer response")
	}
}

func TestIssuedClaimsRefusesAmbiguousOrInvalidResponses(t *testing.T) {
	for _, name := range []string{"multiple", "wrong-URI", "wrong-bundle", "invalid-key", "empty-bundle", "oversize"} {
		t.Run(name, func(t *testing.T) {
			response := fixtureSVID(t)
			switch name {
			case "multiple":
				other, ok := proto.Clone(response.GetSvids()[0]).(*workload.X509SVID)
				if !ok {
					t.Fatal("fixture clone type")
				}
				other.Hint = "second"
				response.Svids = append(response.Svids, other)
			case "wrong-URI":
				// Wire identity does not replace the leaf identity checked by SDK.
				response.Svids[0].SpiffeId = "spiffe://other.example/claims/private"
			case "wrong-bundle":
				response.Svids[0].Bundle = fixtureSVID(t).GetSvids()[0].GetBundle()
			case "invalid-key":
				response.Svids[0].X509SvidKey = fixtureSVID(t).GetSvids()[0].GetX509SvidKey()
			case "empty-bundle":
				response.Svids[0].Bundle = nil
			case "oversize":
				response.Crl = [][]byte{make([]byte, 300*1024)}
			}
			_, socket := startClaimsIssuer(t, response)
			got, err := issuedClaimsMaterial(context.Background(), claimsEnv(socket))
			// An unrelated but parseable root is deliberately left to the runtime's
			// anchored-chain check; the adapter does not invent TLS verification.
			if name == "wrong-bundle" {
				if err != nil || got == nil {
					t.Fatal("parseable root did not reach fixed runtime validation")
				}
				return
			}
			if err == nil || got != nil || strings.Contains(err.Error(), socket) {
				t.Fatal("invalid response returned material or leaked endpoint")
			}
		})
	}
}

func TestIssuedClaimsCanceledAndUnavailableRefuse(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
		if canceled {
			cancel()
		}
		socket := filepath.Join(testfixture.Directory(t), "missing.sock")
		got, err := issuedClaimsMaterial(ctx, claimsEnv(socket))
		cancel()
		if err == nil || got != nil || strings.Contains(err.Error(), socket) {
			t.Fatal("canceled or unavailable issuer returned material")
		}
	}
	issuer, socket := startClaimsIssuer(t, nil)
	if got, err := issuedClaimsMaterial(context.Background(), claimsEnv(socket)); got != nil || err == nil || strings.Contains(err.Error(), "private issuer") || issuer.requests.Load() != 1 {
		t.Fatal("issuer refusal was accepted or exposed")
	}
}

func TestIssuedClaimsStalledStreamHasOwnedDeadline(t *testing.T) {
	issuer, socket := startClaimsIssuer(t, fixtureSVID(t))
	issuer.hold.Store(true)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := time.Now()
	got, err := issuedClaimsMaterial(ctx, claimsEnv(socket))
	if got != nil || err == nil || time.Since(started) >= 4*time.Second || issuer.requests.Load() != 1 {
		t.Fatal("stalled issuer escaped the bounded startup fetch")
	}
	select {
	case <-issuer.closed:
	case <-time.After(time.Second):
		t.Fatal("timed-out SDK stream remained live")
	}
}

type claimsIssuer struct {
	workload.UnimplementedSpiffeWorkloadAPIServer
	response *workload.X509SVIDResponse
	requests atomic.Uint32
	closed   chan struct{}
	hold     atomic.Bool
}

func (s *claimsIssuer) FetchX509SVID(_ *workload.X509SVIDRequest, stream workload.SpiffeWorkloadAPI_FetchX509SVIDServer) error {
	s.requests.Add(1)
	defer close(s.closed)
	if s.hold.Load() {
		<-stream.Context().Done()
		return stream.Context().Err()
	}
	if s.response == nil {
		return status.Error(codes.PermissionDenied, "private issuer diagnostic")
	}
	if err := stream.Send(s.response); err != nil {
		return err
	}
	<-stream.Context().Done()
	return stream.Context().Err()
}

func startClaimsIssuer(t *testing.T, response *workload.X509SVIDResponse) (*claimsIssuer, string) {
	t.Helper()
	issuer := &claimsIssuer{response: response, closed: make(chan struct{})}
	return issuer, testfixture.WorkloadAPI(t, issuer)
}

// This protocol fixture transfers synthetic key bytes and attests no process.
func fixtureSVID(t *testing.T) *workload.X509SVIDResponse {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	root, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri, _ := url.Parse("spiffe://fixture.example/claims/private")
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, DNSNames: []string{"claims.fixture.example"}, URIs: []*url.URL{uri}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, &leafKey.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(leafKey)
	if err != nil {
		t.Fatal(err)
	}
	return &workload.X509SVIDResponse{Svids: []*workload.X509SVID{{SpiffeId: uri.String(), X509Svid: der, X509SvidKey: private, Bundle: root}}}
}
