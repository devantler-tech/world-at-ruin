package nakamaruntime

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/cryptotest"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

type materialFixture struct {
	listenerFixture
	material ClaimsTLSMaterial
	root     *x509.Certificate
	rootKey  *ecdsa.PrivateKey
	leaf     *x509.Certificate
}

// Each fixture has independently generated allocator and claims keys. The
// claims key is held directly in this process, without a claims key file.
func newMaterialFixture(t *testing.T) materialFixture {
	t.Helper()
	f := newListenerFixture(t)
	rootKey := cryptotest.NewKey(t)
	rootTemplate := &x509.Certificate{SerialNumber: big.NewInt(11), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER := cryptotest.Issue(t, rootTemplate, rootTemplate, &rootKey.PublicKey, rootKey)
	root := cryptotest.Parse(t, rootDER)
	key := cryptotest.NewKey(t)
	uri, err := url.Parse("spiffe://claims.example/role/claims-server")
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{SerialNumber: big.NewInt(12), DNSNames: []string{"localhost"}, URIs: []*url.URL{uri}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER := cryptotest.Issue(t, leafTemplate, root, &key.PublicKey, rootKey)
	material := ClaimsTLSMaterial{CertificateChainDER: [][]byte{leafDER}, Signer: key, ClientAuthoritiesDER: [][]byte{rootDER}, ExpectedServerDNS: "localhost", ExpectedServerURI: uri.String()}
	pool := x509.NewCertPool()
	// The peer owns independent trust bytes; mutating initializer input must
	// challenge the server snapshot without also corrupting the test client.
	pool.AddCert(cryptotest.Parse(t, bytes.Clone(rootDER)))
	zoneKey := cryptotest.NewKey(t)
	zoneURI, err := url.Parse("spiffe://claims.example/zone/world-at-ruin/uid-one")
	if err != nil {
		t.Fatal(err)
	}
	zoneTemplate := &x509.Certificate{SerialNumber: big.NewInt(13), URIs: []*url.URL{zoneURI}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	zoneDER := cryptotest.Issue(t, zoneTemplate, root, &zoneKey.PublicKey, rootKey)
	f.tls = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, ServerName: "localhost", Certificates: []tls.Certificate{{Certificate: [][]byte{zoneDER}, PrivateKey: zoneKey}}}
	return materialFixture{listenerFixture: f, material: material, root: root, rootKey: rootKey, leaf: cryptotest.Parse(t, leafDER)}
}

func (f materialFixture) startMaterial(t *testing.T) *registration {
	t.Helper()
	r := &registration{}
	if err := initializeWithClaimsMaterial(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return f.deps, nil }, &f.material); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.shutdown(r) })
	return r
}

func TestClaimsMaterialDefaultOff(t *testing.T) {
	for _, value := range []string{"", "false"} {
		env := validEnvironment()
		env["WAR_HANDOFF_ENABLED"] = value
		env["WAR_HANDOFF_CLAIMS_ENABLED"] = "invalid"
		if err := InitializeWithClaimsMaterial(environmentContext(env), nil, nil, nil, ClaimsTLSMaterial{ExpectedServerDNS: "invalid dns"}); err != nil {
			t.Fatal("disabled runtime inspected material", err)
		}
	}
	f := newMaterialFixture(t)
	f.env["WAR_HANDOFF_CLAIMS_ENABLED"] = "false"
	f.env["WAR_HANDOFF_CLAIMS_ADDRESS"] = "invalid"
	f.material = ClaimsTLSMaterial{ExpectedServerDNS: "invalid dns"}
	f.startMaterial(t)
}

func TestClaimsMaterialDoesNotFallBackToProjectedCredentials(t *testing.T) {
	f := newMaterialFixture(t)
	r := &registration{}
	missing := ClaimsTLSMaterial{}
	if err := initializeWithClaimsMaterial(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return f.deps, nil }, &missing); err == nil || r.rpc != nil || r.shutdown != nil {
		t.Fatal("missing material fell back to valid projected credentials")
	}
}

// A successful response must carry the actual stored claim version; input
// mutation after initialization cannot change the served identity or roots.
func TestClaimsMaterialServesOriginalReceiptAndOwnsSnapshot(t *testing.T) {
	f := newMaterialFixture(t)
	for _, name := range []string{"WAR_HANDOFF_CLAIMS_CA_FILE", "WAR_HANDOFF_CLAIMS_CERT_FILE", "WAR_HANDOFF_CLAIMS_KEY_FILE"} {
		f.env[name] = "not-a-projected-path"
	}
	r := f.startMaterial(t)
	for _, group := range [][][]byte{f.material.CertificateChainDER, f.material.ClientAuthoritiesDER} {
		for _, der := range group {
			clear(der)
		}
	}
	f.material.Signer = cryptotest.NewKey(t)
	receipt, err := f.client(t, f.tls).ClaimWithReceipt(t.Context(), f.binding, f.token, 1)
	if err != nil {
		t.Fatal("material listener did not serve a verified claim", err)
	}
	stored, err := f.store.Load(t.Context(), moduleUser, playerReservation)
	if err != nil || stored.Lease.ClaimedAt.IsZero() || !receipt.Matches(f.binding, 1) || receipt.Fence.LeaseVersion != stored.Version || !receipt.Fence.Generation.Equal(stored.Lease.ClaimedAt) {
		t.Fatal("successful transport lacks a complete actual claim", err)
	}
	f.shutdown(r)
	if err := f.client(t, f.tls).Claim(t.Context(), f.binding, f.token, 1); err == nil {
		t.Fatal("shutdown material listener admitted a claim")
	}
}

// Keep the cancellation lifetime independent of the initializer's context.
func TestClaimsMaterialInitializationContextDoesNotOwnServingLifetime(t *testing.T) {
	f := newMaterialFixture(t)
	ctx, cancel := context.WithCancel(environmentContext(f.env))
	r := &registration{}
	if err := initializeWithClaimsMaterial(ctx, f.storage, r, func(config) (dependencies, error) { return f.deps, nil }, &f.material); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.shutdown(r) })
	cancel()
	if err := f.client(t, f.tls).Claim(t.Context(), f.binding, f.token, 1); err != nil {
		t.Fatal("initialization cancellation stole serving lifetime", err)
	}
}

// Reissued certificates isolate certificate policy from signature corruption.
func (f materialFixture) changeLeaf(t *testing.T, material *ClaimsTLSMaterial, mutate func(*x509.Certificate)) {
	t.Helper()
	leaf := *f.leaf
	leaf.DNSNames = slices.Clone(leaf.DNSNames)
	leaf.URIs = slices.Clone(leaf.URIs)
	leaf.ExtKeyUsage = slices.Clone(leaf.ExtKeyUsage)
	mutate(&leaf)
	material.CertificateChainDER = [][]byte{cryptotest.Issue(t, &leaf, f.root, material.Signer.Public(), f.rootKey)}
}

func (f materialFixture) changeRoot(t *testing.T, material *ClaimsTLSMaterial, mutate func(*x509.Certificate)) {
	t.Helper()
	root := *f.root
	mutate(&root)
	material.ClientAuthoritiesDER = [][]byte{cryptotest.Issue(t, &root, &root, &f.rootKey.PublicKey, f.rootKey)}
}

// Every refusal runs through initialization: no socket, registered RPC or
// claimed storage result may survive validation, and dependencies retire once.
func TestClaimsMaterialRefusesInvalidSnapshotsBeforeServing(t *testing.T) {
	f := newMaterialFixture(t)
	cases := map[string]func(*ClaimsTLSMaterial){
		"missing chain":         func(m *ClaimsTLSMaterial) { m.CertificateChainDER = nil },
		"missing authorities":   func(m *ClaimsTLSMaterial) { m.ClientAuthoritiesDER = nil },
		"empty certificate":     func(m *ClaimsTLSMaterial) { m.CertificateChainDER = [][]byte{nil} },
		"malformed leaf":        func(m *ClaimsTLSMaterial) { m.CertificateChainDER = [][]byte{[]byte("not DER")} },
		"malformed authority":   func(m *ClaimsTLSMaterial) { m.ClientAuthoritiesDER = [][]byte{[]byte("not DER")} },
		"oversized certificate": func(m *ClaimsTLSMaterial) { m.CertificateChainDER = [][]byte{make([]byte, 64*1024+1)} },
		"chain count":           func(m *ClaimsTLSMaterial) { m.CertificateChainDER = make([][]byte, 9) },
		"authority count":       func(m *ClaimsTLSMaterial) { m.ClientAuthoritiesDER = make([][]byte, 33) },
		"total bytes": func(m *ClaimsTLSMaterial) {
			m.ClientAuthoritiesDER = [][]byte{make([]byte, 64*1024), make([]byte, 64*1024), make([]byte, 64*1024), make([]byte, 64*1024)}
		},
		"nil signer":              func(m *ClaimsTLSMaterial) { m.Signer = nil },
		"typed nil signer":        func(m *ClaimsTLSMaterial) { var key *ecdsa.PrivateKey; m.Signer = key },
		"different signer":        func(m *ClaimsTLSMaterial) { m.Signer = cryptotest.NewKey(t) },
		"missing DNS expectation": func(m *ClaimsTLSMaterial) { m.ExpectedServerDNS = "" },
		"wrong DNS expectation":   func(m *ClaimsTLSMaterial) { m.ExpectedServerDNS = "other.example" },
		"missing URI expectation": func(m *ClaimsTLSMaterial) { m.ExpectedServerURI = "" },
		"wrong URI expectation":   func(m *ClaimsTLSMaterial) { m.ExpectedServerURI = "spiffe://claims.example/role/other" },
		"other trust domain":      func(m *ClaimsTLSMaterial) { m.ExpectedServerURI = "spiffe://other.example/role/claims-server" },
		"encoded path":            func(m *ClaimsTLSMaterial) { m.ExpectedServerURI = "spiffe://claims.example/role/%63laims-server" },
		"query":                   func(m *ClaimsTLSMaterial) { m.ExpectedServerURI += "?source=fixture" },
		"fragment":                func(m *ClaimsTLSMaterial) { m.ExpectedServerURI += "#fixture" },
		"dot path":                func(m *ClaimsTLSMaterial) { m.ExpectedServerURI = "spiffe://claims.example/role/../claims-server" },
		"expired leaf": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.NotAfter = time.Now().Add(-time.Minute) })
		},
		"future leaf": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.NotBefore = time.Now().Add(time.Minute) })
		},
		"CA leaf": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.IsCA, c.BasicConstraintsValid = true, true })
		},
		"unsigned purpose": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.KeyUsage = x509.KeyUsageKeyEncipherment })
		},
		"client-only leaf": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth} })
		},
		"missing URI": func(m *ClaimsTLSMaterial) { f.changeLeaf(t, m, func(c *x509.Certificate) { c.URIs = nil }) },
		"multiple URIs": func(m *ClaimsTLSMaterial) {
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.URIs = append(c.URIs, c.URIs[0]) })
		},
		"wildcard-only DNS": func(m *ClaimsTLSMaterial) {
			m.ExpectedServerDNS = "claims.example"
			f.changeLeaf(t, m, func(c *x509.Certificate) { c.DNSNames = []string{"*.example"} })
		},
		"expired root": func(m *ClaimsTLSMaterial) {
			f.changeRoot(t, m, func(c *x509.Certificate) { c.NotAfter = time.Now().Add(-time.Minute) })
		},
		"future root": func(m *ClaimsTLSMaterial) {
			f.changeRoot(t, m, func(c *x509.Certificate) { c.NotBefore = time.Now().Add(time.Minute) })
		},
		"non-CA root": func(m *ClaimsTLSMaterial) { f.changeRoot(t, m, func(c *x509.Certificate) { c.IsCA = false }) },
		"non-signing root": func(m *ClaimsTLSMaterial) {
			f.changeRoot(t, m, func(c *x509.Certificate) { c.KeyUsage = x509.KeyUsageDigitalSignature })
		},
		"server-only root": func(m *ClaimsTLSMaterial) {
			f.changeRoot(t, m, func(c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth} })
		},
		"client-only root cannot anchor server": func(m *ClaimsTLSMaterial) {
			f.changeRoot(t, m, func(c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth} })
		},
		"root as first served certificate": func(m *ClaimsTLSMaterial) {
			m.CertificateChainDER = slices.Concat(m.ClientAuthoritiesDER, m.CertificateChainDER)
		},
		"unanchored server": func(m *ClaimsTLSMaterial) {
			other := cryptotest.NewKey(t)
			root := *f.root
			root.PublicKey = &other.PublicKey
			m.ClientAuthoritiesDER = [][]byte{cryptotest.Issue(t, &root, &root, &other.PublicKey, other)}
		},
		"unrelated served issuer": func(m *ClaimsTLSMaterial) {
			other := cryptotest.NewKey(t)
			root := *f.root
			root.PublicKey = &other.PublicKey
			m.CertificateChainDER = append(slices.Clone(m.CertificateChainDER), cryptotest.Issue(t, &root, &root, &other.PublicKey, other))
		},
		"server uses root key": func(m *ClaimsTLSMaterial) { m.Signer = f.rootKey; f.changeLeaf(t, m, func(*x509.Certificate) {}) },
		"allocator root added as authority": func(m *ClaimsTLSMaterial) {
			data, err := os.ReadFile(f.env["WAR_HANDOFF_ALLOCATOR_CA_FILE"])
			if err != nil {
				t.Fatal(err)
			}
			roots, err := parseCertificates(data)
			if err != nil {
				t.Fatal(err)
			}
			m.ClientAuthoritiesDER = append(slices.Clone(m.ClientAuthoritiesDER), roots[0].Raw)
		},
		"claims root uses allocator leaf key": func(m *ClaimsTLSMaterial) {
			signer := pairSigner(t, f.env["WAR_HANDOFF_ALLOCATOR_CERT_FILE"], f.env["WAR_HANDOFF_ALLOCATOR_KEY_FILE"])
			root := *f.root
			root.PublicKey = signer.Public()
			m.ClientAuthoritiesDER = append(slices.Clone(m.ClientAuthoritiesDER), cryptotest.Issue(t, &root, &root, signer.Public(), signer))
		},
		"server uses allocator leaf key": func(m *ClaimsTLSMaterial) {
			m.Signer = pairSigner(t, f.env["WAR_HANDOFF_ALLOCATOR_CERT_FILE"], f.env["WAR_HANDOFF_ALLOCATOR_KEY_FILE"])
			f.changeLeaf(t, m, func(*x509.Certificate) {})
		},
	}
	before, err := f.store.Load(t.Context(), moduleUser, playerReservation)
	if err != nil {
		t.Fatal(err)
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			material := f.material
			mutate(&material)
			var closed atomic.Int32
			deps := f.deps
			deps.close = func() { closed.Add(1) }
			r := &registration{}
			err := initializeWithClaimsMaterial(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return deps, nil }, &material)
			if err == nil || err.Error() != "nakama handoff: configure private listener" || r.rpc != nil || r.shutdown != nil || closed.Load() != 1 {
				t.Fatalf("invalid material did not refuse cleanly: err=%v closed=%d", err, closed.Load())
			}
			probe, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
			if err != nil {
				t.Fatal("refusal reserved a socket", err)
			}
			_ = probe.Close()
			after, err := f.store.Load(t.Context(), moduleUser, playerReservation)
			if err != nil || after.Version != before.Version || !after.Lease.ClaimedAt.IsZero() {
				t.Fatal("refused material changed actual claim storage", err)
			}
		})
	}
}

func (f materialFixture) zoneCertificate(t *testing.T, identity string) tls.Certificate {
	t.Helper()
	key := cryptotest.NewKey(t)
	uri, err := url.Parse(identity)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(14), URIs: []*url.URL{uri}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	return tls.Certificate{Certificate: [][]byte{cryptotest.Issue(t, leaf, f.root, &key.PublicKey, f.rootKey)}, PrivateKey: key}
}

// These controls complete real verified TLS handshakes or exercise real TLS
// refusal; constructor rejection alone is not evidence of server enforcement.
func TestClaimsMaterialVerifiedTransportRefusesChangedPrincipals(t *testing.T) {
	for _, name := range []string{"anonymous", "other issuer", "other role", "other UID", "other namespace", "other trust domain", "wrong client key", "wrong server DNS", "wrong server URI", "wrong route"} {
		t.Run(name, func(t *testing.T) {
			f := newMaterialFixture(t)
			f.startMaterial(t)
			before, err := f.store.Load(t.Context(), moduleUser, playerReservation)
			if err != nil {
				t.Fatal(err)
			}
			config := f.tls.Clone()
			switch name {
			case "anonymous":
				config.Certificates = nil
				config.MaxVersion = tls.VersionTLS12
			case "other issuer":
				_, stranger, _ := certificateFixture(t, t.TempDir(), "spiffe://claims.example/zone/world-at-ruin/uid-one")
				config.Certificates = []tls.Certificate{stranger}
			case "other role":
				config.Certificates = []tls.Certificate{f.zoneCertificate(t, "spiffe://claims.example/role/supervisor")}
			case "other UID":
				config.Certificates = []tls.Certificate{f.zoneCertificate(t, "spiffe://claims.example/zone/world-at-ruin/uid-other")}
			case "other namespace":
				config.Certificates = []tls.Certificate{f.zoneCertificate(t, "spiffe://claims.example/zone/other/uid-one")}
			case "other trust domain":
				config.Certificates = []tls.Certificate{f.zoneCertificate(t, "spiffe://other.example/zone/world-at-ruin/uid-one")}
			case "wrong client key":
				pair := config.Certificates[0]
				pair.PrivateKey = cryptotest.NewKey(t)
				config.Certificates = []tls.Certificate{pair}
			case "wrong server DNS":
				config.ServerName = "other.example"
			}
			var checked atomic.Bool
			if name == "wrong server URI" {
				config.VerifyConnection = func(state tls.ConnectionState) error {
					checked.Store(true)
					if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 || len(state.PeerCertificates[0].URIs) != 1 || state.PeerCertificates[0].URIs[0].String() != "spiffe://claims.example/role/other" {
						return errMaterial
					}
					return nil
				}
			}
			switch name {
			case "anonymous":
				ctx, cancel := context.WithTimeout(t.Context(), time.Second)
				defer cancel()
				connection, err := (&tls.Dialer{Config: config}).DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if connection != nil {
					_ = connection.Close()
				}
				if err == nil {
					t.Fatal("anonymous connection passed actual TLS")
				}
			case "wrong route":
				ctx, cancel := context.WithTimeout(t.Context(), time.Second)
				defer cancel()
				connection, err := (&tls.Dialer{Config: config}).DialContext(ctx, "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if err != nil {
					t.Fatal("wrong-route control did not reach the verified listener", err)
				}
				defer func() { _ = connection.Close() }()
				if err := connection.SetDeadline(time.Now().Add(time.Second)); err != nil {
					t.Fatal(err)
				}
				if _, err := io.WriteString(connection, "POST /not-a-claim HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"); err != nil {
					t.Fatal(err)
				}
				response, err := http.ReadResponse(bufio.NewReader(connection), nil)
				if err != nil {
					t.Fatal(err)
				}
				_ = response.Body.Close()
				if response.StatusCode >= 200 && response.StatusCode < 300 {
					t.Fatal("unrecognized route succeeded")
				}
			default:
				if err := f.client(t, config).Claim(t.Context(), f.binding, f.token, 1); err == nil {
					t.Fatal("changed principal or peer expectation claimed the allocation")
				}
				if name == "wrong server URI" && !checked.Load() {
					t.Fatal("server URI control never inspected the verified peer")
				}
			}
			after, err := f.store.Load(t.Context(), moduleUser, playerReservation)
			if err != nil || after.Version != before.Version || !after.Lease.ClaimedAt.IsZero() {
				t.Fatal("transport refusal changed claim storage", err)
			}
		})
	}
}

func TestClaimsMaterialStartupRollbackUsesTheExistingOwner(t *testing.T) {
	for _, stage := range []string{"occupied", "rpc", "shutdown"} {
		t.Run(stage, func(t *testing.T) {
			f := newMaterialFixture(t)
			r := &registration{}
			var closed atomic.Int32
			f.deps.close = func() { closed.Add(1) }
			switch stage {
			case "occupied":
				occupied, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = occupied.Close() }()
			case "rpc":
				r.rpcErr = errMaterial
			default:
				r.shutdownErr = errMaterial
			}
			if err := initializeWithClaimsMaterial(environmentContext(f.env), f.storage, r, func(config) (dependencies, error) { return f.deps, nil }, &f.material); err == nil || closed.Load() != 1 {
				t.Fatalf("startup did not roll back exactly once: err=%v closed=%d", err, closed.Load())
			}
			if r.rpc != nil {
				if _, err := r.rpc(signedContext(), nil, nil, f.storage, `{}`); err == nil {
					t.Fatal("failed registration left public admission open")
				}
			}
			if stage != "occupied" {
				probe, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", f.env["WAR_HANDOFF_CLAIMS_ADDRESS"])
				if err != nil {
					t.Fatal("failed registration retained a socket", err)
				}
				_ = probe.Close()
			}
		})
	}
}

// A short shutdown hook may return while an admitted storage call is still
// finishing. It cannot retire dependencies ahead of that actual owned drain.
func TestClaimsMaterialShutdownRetainsDependenciesUntilActualDrain(t *testing.T) {
	f := newMaterialFixture(t)
	storage := &materialHeldStorage{moduleStorage: f.storage, started: make(chan struct{}), canceled: make(chan struct{}), release: make(chan struct{})}
	var closed atomic.Int32
	f.deps.close = func() {
		if !storage.finished.Load() {
			t.Error("dependencies retired before actual handler completion")
		}
		closed.Add(1)
	}
	r := &registration{}
	if err := initializeWithClaimsMaterial(environmentContext(f.env), storage, r, func(config) (dependencies, error) { return f.deps, nil }, &f.material); err != nil {
		t.Fatal(err)
	}
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(storage.release) }) }
	t.Cleanup(func() { release(); f.shutdown(r) })
	result := make(chan error, 1)
	client := f.client(t, f.tls)
	go func() { result <- client.Claim(t.Context(), f.binding, f.token, 1) }()
	select {
	case <-storage.started:
	case <-time.After(time.Second):
		t.Fatal("claim did not enter actual storage")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 25*time.Millisecond)
	defer cancel()
	r.shutdown(ctx, nil, nil, storage)
	select {
	case <-storage.canceled:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not cancel admitted storage")
	}
	if closed.Load() != 0 {
		t.Fatal("bounded hook retired active dependencies")
	}
	release()
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("canceled claim succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("released storage did not complete its claim")
	}
	f.shutdown(r)
	if closed.Load() != 1 {
		t.Fatal("actual drain did not retire dependencies exactly once")
	}
}

type materialHeldStorage struct {
	*moduleStorage
	started, canceled, release chan struct{}
	finished                   atomic.Bool
}

func (s *materialHeldStorage) StorageRead(ctx context.Context, _ []*runtime.StorageRead) ([]*api.StorageObject, error) {
	close(s.started)
	<-ctx.Done()
	close(s.canceled)
	<-s.release
	s.finished.Store(true)
	return nil, ctx.Err()
}
