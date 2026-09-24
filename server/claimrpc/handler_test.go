package claimrpc

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base32"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

type resolverFunc func(context.Context, nakamalease.Lease) (handoff.Allocation, error)

func (f resolverFunc) Resolve(ctx context.Context, lease nakamalease.Lease) (handoff.Allocation, error) {
	return f(ctx, lease)
}

type fixture struct {
	store                *nakamalease.Store
	storage              *nakamastoragetest.Fake
	record               nakamalease.Record
	binding              agones.ClaimBinding
	allocation           handoff.Allocation
	token                string
	serverTLS, clientTLS *tls.Config
}

func newFixture(t *testing.T, identity string) *fixture {
	t.Helper()
	f := &fixture{storage: nakamastoragetest.New()}
	var err error
	f.store, err = nakamalease.NewStore(f.storage)
	if err != nil {
		t.Fatal(err)
	}
	uidDigest := sha256.Sum256([]byte("uid-1"))
	digest := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(uidDigest[:]))
	ref := "v1.k" + strings.Repeat("a", 52) + ".u" + digest + ".e" + strings.Repeat("a", 52) + ".p443"
	f.record, err = f.store.Create(context.Background(), nakamalease.Lease{UserID: "11111111-1111-1111-1111-111111111111", ReservationID: "reservation-1", AttemptID: "attempt-1", AllocationID: "zone-1", Observer: 1, SecretRef: ref, ExpiresAt: time.Now().Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	attempt, err := agones.CorrelationLabel("attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	f.binding = agones.ClaimBinding{Namespace: "world", AllocationID: "zone-1", GameServerUID: "uid-1", LeaseObjectID: nakamalease.ReservationKey(f.record.Lease.UserID, f.record.Lease.ReservationID), AttemptDigest: attempt}
	f.allocation = handoff.Allocation{ID: "zone-1", Observer: 1, AdmissionSecret: []byte(strings.Repeat("s", 32)), LeaseExpiresAt: f.record.Lease.ExpiresAt}
	f.token, err = zonesock.MintToken(f.allocation.AdmissionSecret, "zone-1", 1, f.record.Lease.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	f.serverTLS, f.clientTLS = certificates(t, identity)
	return f
}

func certificates(t *testing.T, identity string) (*tls.Config, *tls.Config) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	root, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	issue := func(serial int64, client bool) tls.Certificate {
		leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		leaf := &x509.Certificate{SerialNumber: big.NewInt(serial), NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
		if client {
			leaf.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
			if identity != "" {
				uri, err := url.Parse(identity)
				if err != nil {
					t.Fatal(err)
				}
				leaf.URIs = []*url.URL{uri}
			}
		}
		encoded, err := x509.CreateCertificate(rand.Reader, leaf, ca, &leafKey.PublicKey, key)
		if err != nil {
			t.Fatal(err)
		}
		return tls.Certificate{Certificate: [][]byte{encoded}, PrivateKey: leafKey}
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{issue(2, false)}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert}, &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{issue(3, true)}}
}

func (f *fixture) serve(t *testing.T, resolve resolverFunc) (*Client, *httptest.Server) {
	t.Helper()
	handler, err := NewHandler(f.store, resolve, Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS = f.serverTLS
	server.StartTLS()
	t.Cleanup(server.Close)
	client, err := NewClient(server.URL+"/v1/claim", f.clientTLS)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client, server
}

func TestAuthenticatedClaimCommitsBeforeSuccess(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	client, _ := f.serve(t, func(_ context.Context, lease nakamalease.Lease) (handoff.Allocation, error) {
		if lease.AttemptID != "attempt-1" || lease.SecretRef != f.record.Lease.SecretRef {
			t.Fatal("resolver received wrong lease")
		}
		return f.allocation, nil
	})
	for range 2 {
		if err := client.Claim(context.Background(), f.binding, f.token, 1); err != nil {
			t.Fatalf("valid claim refused: %v", err)
		}
	}
	stored, err := f.store.Load(context.Background(), f.record.Lease.UserID, f.record.Lease.ReservationID)
	if err != nil || stored.Lease.ClaimedAt.IsZero() {
		t.Fatalf("success preceded durable claim: %v", err)
	}
	if len(f.storage.WrittenValues()) != 2 {
		t.Fatal("repeated request wrote another claim")
	}
	if _, err = f.store.BeginRelease(context.Background(), f.record, "attempt-1"); !errors.Is(err, nakamalease.ErrClaimed) {
		t.Fatalf("no-show cleanup did not lose: %v", err)
	}
}

func TestPrivateClaimRejectsWrongAuthorityAndBinding(t *testing.T) {
	for _, name := range []string{"no workload URI", "wrong trust domain", "sibling workload", "wrong namespace", "wrong UID", "wrong allocation", "wrong attempt", "wrong observer", "sibling token", "wrong expiry", "changed resource", "staging", "releasing", "expired"} {
		t.Run(name, func(t *testing.T) {
			identity := "spiffe://claims.example/zone/world/uid-1"
			switch name {
			case "no workload URI":
				identity = ""
			case "wrong trust domain":
				identity = "spiffe://other.example/zone/world/uid-1"
			case "sibling workload":
				identity = "spiffe://claims.example/zone/world/uid-2"
			}
			f := newFixture(t, identity)
			observer := f.record.Lease.Observer
			switch name {
			case "wrong namespace":
				f.binding.Namespace = "other"
			case "wrong UID":
				f.binding.GameServerUID = "uid-2"
			case "wrong allocation":
				f.binding.AllocationID = "zone-2"
			case "wrong attempt":
				f.binding.AttemptDigest = strings.Repeat("a", 52)
			case "wrong observer":
				observer = 2
			case "sibling token":
				f.token, _ = zonesock.MintToken([]byte(strings.Repeat("z", 32)), "zone-1", 1, f.record.Lease.ExpiresAt)
			case "wrong expiry":
				f.token, _ = zonesock.MintToken(f.allocation.AdmissionSecret, "zone-1", 1, f.record.Lease.ExpiresAt.Add(time.Second))
			case "changed resource":
				f.allocation.ID = "zone-2"
			case "staging", "releasing", "expired":
				object, _ := f.storage.Get(nakamalease.Collection, f.binding.LeaseObjectID, "")
				switch name {
				case "staging":
					object.Value = `{"schema":3,"attempt_id":"attempt-1","allocation_id":"","observer":0,"secret_ref":"","expires_at_nanos":` + big.NewInt(time.Now().Add(time.Minute).UnixNano()).String() + `,"staging":true,"dispatched":false,"releasing":false}`
				case "releasing":
					object.Value = strings.Replace(object.Value, `{`, `{"releasing":true,`, 1)
				case "expired":
					object.Value = strings.Replace(object.Value, big.NewInt(f.record.Lease.ExpiresAt.UnixNano()).String(), "1", 1)
				}
				f.storage.Seed(object)
			}
			client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
			before := len(f.storage.WrittenValues())
			if err := client.Claim(context.Background(), f.binding, f.token, observer); err == nil {
				t.Fatal("invalid claim accepted")
			}
			if len(f.storage.WrittenValues()) != before {
				t.Fatal("unauthorized claim changed storage")
			}
		})
	}
}

func TestPrivateHandlerRejectsPlainHTTPBeforeStorage(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	handler, err := NewHandler(f.store, resolverFunc(func(context.Context, nakamalease.Lease) (handoff.Allocation, error) {
		t.Fatal("public caller reached resolver")
		return handoff.Allocation{}, nil
	}), Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "https://claim.example/v1/claim", strings.NewReader(`{}`))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("plain request status=%d", response.Code)
	}
}
