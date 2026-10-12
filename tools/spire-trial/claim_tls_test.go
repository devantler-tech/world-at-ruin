package spiretrial

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

// syntheticIssuer exercises ordinary Go TLS and the real private client without
// claiming native issuance. Only the tagged SPIRE suite proves the issuer path.
type syntheticIssuer struct {
	root *x509.Certificate
	key  *ecdsa.PrivateKey
}

func newSyntheticIssuer(t *testing.T) syntheticIssuer {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, root, root, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	root, err = x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return syntheticIssuer{root, key}
}

func (i syntheticIssuer) material(t *testing.T, identity string, dns ...string) *workloadapi.X509Context {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	id := spiffeid.RequireFromString(identity)
	uri, err := url.Parse(identity)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: i.root.NotBefore, NotAfter: i.root.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}, URIs: []*url.URL{uri}, DNSNames: dns}
	der, err := x509.CreateCertificate(rand.Reader, leaf, i.root, &key.PublicKey, i.key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err = x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	bundle := x509bundle.FromX509Authorities(id.TrustDomain(), []*x509.Certificate{i.root})
	return &workloadapi.X509Context{SVIDs: []*x509svid.SVID{{ID: id, Certificates: []*x509.Certificate{leaf}, PrivateKey: key}}, Bundles: x509bundle.NewSet(bundle)}
}

// TestPrivateClientStandardTLS requires a real verified chain and DNS check,
// then the additive exact server URI check, before the HTTP effect can occur.
func TestPrivateClientStandardTLS(t *testing.T) {
	issuer := newSyntheticIssuer(t)
	for _, control := range []string{"positive", "wrong-DNS", "wrong-server-URI", "wrong-root", "missing-key", "mismatched-key", "URI-only-server"} {
		t.Run(control, func(t *testing.T) {
			serverMaterial := issuer.material(t, "spiffe://war-fixture.test/claims/private", "claims.fixture.test")
			if control == "URI-only-server" {
				serverMaterial = issuer.material(t, "spiffe://war-fixture.test/claims/private")
			}
			serverConfig, err := claimServerTLS(serverMaterial)
			if err != nil {
				t.Fatal(err)
			}
			var effects atomic.Uint64
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 || len(r.TLS.PeerCertificates[0].URIs) != 1 || r.TLS.PeerCertificates[0].URIs[0].String() != "spiffe://war-fixture.test/zone/world/uid-1" {
					w.WriteHeader(http.StatusForbidden)
					return
				}
				effects.Add(1)
				w.WriteHeader(http.StatusNoContent)
			}))
			server.TLS = serverConfig
			server.StartTLS()
			t.Cleanup(server.Close)
			clientMaterial := issuer.material(t, "spiffe://war-fixture.test/zone/world/uid-1")
			dns, expected := "claims.fixture.test", "spiffe://war-fixture.test/claims/private"
			if control == "wrong-DNS" {
				dns = "other.fixture.test"
			}
			if control == "wrong-server-URI" {
				expected = "spiffe://war-fixture.test/claims/other"
			}
			if control == "wrong-root" {
				clientMaterial.Bundles = newSyntheticIssuer(t).material(t, "spiffe://war-fixture.test/zone/world/uid-1").Bundles
			}
			config, err := claimClientTLS(clientMaterial, dns, expected)
			if err != nil {
				t.Fatal(err)
			}
			if control == "missing-key" {
				config.Certificates = nil
			}
			if control == "mismatched-key" {
				config.Certificates[0].PrivateKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
			}
			client, err := claimrpc.NewClient(server.URL+"/v1/claim", config)
			if control == "missing-key" {
				if err == nil || effects.Load() != 0 {
					t.Fatal("missing credential did not refuse before any effect")
				}
				return
			}
			if err != nil {
				t.Fatalf("static TLS material rejected by real client: %v", err)
			}
			t.Cleanup(client.Close)
			binding := agones.ClaimBinding{Namespace: "world", AllocationID: "zone-1", GameServerUID: "uid-1", LeaseObjectID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", AttemptDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
			err = client.Claim(t.Context(), binding, "token", 1)
			if control == "positive" {
				if err != nil || effects.Load() != 1 {
					t.Fatal("verified standard-TLS positive did not reach HTTP")
				}
			} else if err == nil || effects.Load() != 0 {
				t.Fatal("TLS refusal produced an accepted effect")
			}
		})
	}
}

// TestMultipleURIIsSyntheticParserRefusal does not pretend an invalid two-URI
// certificate was issued by SPIRE. The actual SDK parser must reject this fixture.
func TestMultipleURIIsSyntheticParserRefusal(t *testing.T) {
	issuer := newSyntheticIssuer(t)
	m := issuer.material(t, "spiffe://war-fixture.test/zone/world/uid-1")
	svid := m.DefaultSVID()
	key, err := x509.MarshalPKCS8PrivateKey(svid.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = x509svid.ParseRaw(svid.Certificates[0].Raw, key); err != nil {
		t.Fatal("single-URI parser control failed", err)
	}
	leaf := *svid.Certificates[0]
	other, err := url.Parse("spiffe://war-fixture.test/zone/world/uid-2")
	if err != nil {
		t.Fatal(err)
	}
	leaf.URIs = append(leaf.URIs, other)
	der, err := x509.CreateCertificate(rand.Reader, &leaf, issuer.root, svid.PrivateKey.Public(), issuer.key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = x509svid.ParseRaw(der, key); err == nil || !strings.Contains(err.Error(), "more than one URI SAN") {
		t.Fatal("multiple URI parser fixture was accepted")
	}
}
