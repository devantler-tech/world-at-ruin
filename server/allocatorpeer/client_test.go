package allocatorpeer

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net/netip"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/allocatordiscovery"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	corev1 "k8s.io/api/core/v1"
)

type generationSource struct {
	record nakamageneration.Record
	loads  int
	err    error
}

func (s *generationSource) Load(_ context.Context, id string) (nakamageneration.Record, error) {
	s.loads++
	if id != s.record.GenerationID {
		return nakamageneration.Record{}, errors.New("wrong generation")
	}
	return s.record, s.err
}

type discoverySource struct {
	snapshot allocatordiscovery.Snapshot
	reads    int
	err      error
}

func (s *discoverySource) Discover(context.Context) (allocatordiscovery.Snapshot, error) {
	s.reads++
	return s.snapshot, s.err
}

func recordFor(t *testing.T, members ...string) nakamageneration.Record {
	t.Helper()
	slices.Sort(members)
	data, err := json.Marshal(members)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-generation-members/v1\n"), data...))
	return nakamageneration.Record{GenerationID: "generation-1", MemberPodUIDs: members, MemberSetDigest: hex.EncodeToString(digest[:]), State: "open", Version: "version-1"}
}

func member(uid, name, address string, port uint16) allocatordiscovery.Member {
	return allocatordiscovery.Member{Identity: allocatordiscovery.Identity{Namespace: "allocators", Name: name, UID: uid}, ResourceVersion: "pod-1", Phase: corev1.PodRunning, Ready: corev1.ConditionTrue,
		Endpoints: []allocatordiscovery.Endpoint{{Address: netip.MustParseAddr(address), Port: port, Ready: corev1.ConditionTrue, Serving: corev1.ConditionTrue, Terminating: corev1.ConditionFalse}}}
}

func snapshotFor(members ...allocatordiscovery.Member) allocatordiscovery.Snapshot {
	return allocatordiscovery.Snapshot{PodResourceVersion: "pods-1", EndpointSliceResourceVersion: "slices-1", Members: members}
}

func baseConfig(t *testing.T) Config {
	t.Helper()
	ca, caKey := certificate(t, nil, nil, "root", true, false, false)
	client, clientKey := certificate(t, ca, caKey, "coordinator", false, true, false)
	key, err := x509.MarshalPKCS8PrivateKey(clientKey)
	if err != nil {
		t.Fatal(err)
	}
	return Config{Enabled: true, Record: recordFor(t, "uid-a", "uid-b"), ActorUID: "uid-a", AllocatorNamespace: "allocators", Peers: map[string]PeerIdentity{
		"uid-a": {ServerName: "allocator-a.test", SPKI: sha256.Sum256([]byte("key-a"))}, "uid-b": {ServerName: "allocator-b.test", SPKI: sha256.Sum256([]byte("key-b"))}},
		Credentials: Credentials{RootDER: [][]byte{ca.Raw}, CertificateDER: [][]byte{client.Raw}, PrivateKeyDER: key},
		Allocation:  agonesalloc.Config{Namespace: "zones", Fleet: "zone", TLSPortName: "tls", WrappingKeyFingerprint: strings.Repeat("a", 52)}, Timeout: 500 * time.Millisecond}
}

func certificate(t *testing.T, parent *x509.Certificate, signer *ecdsa.PrivateKey, name string, ca, client, expired bool) (*x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: name}, DNSNames: []string{name}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), BasicConstraintsValid: true, IsCA: ca, KeyUsage: x509.KeyUsageDigitalSignature}
	if ca {
		template.KeyUsage |= x509.KeyUsageCertSign
	}
	if client {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	} else if !ca {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	}
	if expired {
		template.NotAfter = now.Add(-time.Minute)
	}
	if parent == nil {
		parent = template
		signer = key
	}
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return cert, key
}

func TestDisabledHasNoSourceAccess(t *testing.T) {
	_, err := NewClient(Sources{}, Config{})
	if !errors.Is(err, ErrDisabled) {
		t.Fatalf("disabled constructor: %v", err)
	}
}

func TestInvalidConfiguration(t *testing.T) {
	cases := map[string]func(*Config){
		"missing member":      func(c *Config) { delete(c.Peers, "uid-b") },
		"extra member":        func(c *Config) { c.Peers["uid-c"] = c.Peers["uid-b"] },
		"duplicate key":       func(c *Config) { c.Peers["uid-b"] = c.Peers["uid-a"] },
		"zero key":            func(c *Config) { c.Peers["uid-a"] = PeerIdentity{ServerName: "a.test"} },
		"wrong actor":         func(c *Config) { c.ActorUID = "uid-c" },
		"digest":              func(c *Config) { c.Record.MemberSetDigest = strings.Repeat("0", 64) },
		"unsorted":            func(c *Config) { slices.Reverse(c.Record.MemberPodUIDs) },
		"version wildcard":    func(c *Config) { c.Record.Version = "*" },
		"closed":              func(c *Config) { c.Record.State = "closed" },
		"budget":              func(c *Config) { c.Timeout = time.Minute },
		"namespace":           func(c *Config) { c.AllocatorNamespace = "../" },
		"pool":                func(c *Config) { c.Allocation.Fleet = "../" },
		"root bytes":          func(c *Config) { c.Credentials.RootDER[0] = []byte("invalid") },
		"missing roots":       func(c *Config) { c.Credentials.RootDER = nil },
		"wrong key":           func(c *Config) { c.Credentials.PrivateKeyDER = []byte("invalid") },
		"server name":         func(c *Config) { p := c.Peers["uid-a"]; p.ServerName = "wrong name"; c.Peers["uid-a"] = p },
		"numeric server name": func(c *Config) { p := c.Peers["uid-a"]; p.ServerName = "10.0.0.1"; c.Peers["uid-a"] = p },
		"coordinator key": func(c *Config) {
			certificate, err := x509.ParseCertificate(c.Credentials.CertificateDER[0])
			if err != nil {
				t.Fatal(err)
			}
			p := c.Peers["uid-a"]
			p.SPKI = sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
			c.Peers["uid-a"] = p
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := baseConfig(t)
			mutate(&cfg)
			g := &generationSource{record: cfg.Record}
			d := &discoverySource{}
			_, err := NewClient(Sources{Generations: g, Discovery: d}, cfg)
			if !errors.Is(err, ErrInvalidArgument) || g.loads != 0 || d.reads != 0 {
				t.Fatalf("invalid constructor: %v, reads %d/%d", err, g.loads, d.reads)
			}
		})
	}
	var nilGeneration *generationSource
	if _, err := NewClient(Sources{Generations: nilGeneration, Discovery: &discoverySource{}}, baseConfig(t)); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("typed nil accepted: %v", err)
	}
}

func TestSelectionRejectsIncompleteObservations(t *testing.T) {
	cases := map[string]func(*allocatordiscovery.Snapshot){
		"missing":        func(s *allocatordiscovery.Snapshot) { s.Members = s.Members[:1] },
		"replacement":    func(s *allocatordiscovery.Snapshot) { s.Members[0].Identity.UID = "replacement" },
		"duplicate UID":  func(s *allocatordiscovery.Snapshot) { s.Members[1].Identity.UID = "uid-a" },
		"duplicate name": func(s *allocatordiscovery.Snapshot) { s.Members[1].Identity.Name = "a" },
		"namespace":      func(s *allocatordiscovery.Snapshot) { s.Members[0].Identity.Namespace = "other" },
		"empty RV":       func(s *allocatordiscovery.Snapshot) { s.PodResourceVersion = "" },
		"pod RV":         func(s *allocatordiscovery.Snapshot) { s.Members[0].ResourceVersion = "" },
		"not ready":      func(s *allocatordiscovery.Snapshot) { s.Members[0].Ready = corev1.ConditionFalse },
		"deleting":       func(s *allocatordiscovery.Snapshot) { s.Members[0].Deleting = true },
		"terminating":    func(s *allocatordiscovery.Snapshot) { s.Members[0].Endpoints[0].Terminating = corev1.ConditionTrue },
		"loopback": func(s *allocatordiscovery.Snapshot) {
			s.Members[0].Endpoints[0].Address = netip.MustParseAddr("127.0.0.1")
		},
		"mapped": func(s *allocatordiscovery.Snapshot) {
			s.Members[0].Endpoints[0].Address = netip.MustParseAddr("::ffff:10.0.0.1")
		},
		"zone": func(s *allocatordiscovery.Snapshot) {
			s.Members[0].Endpoints[0].Address = netip.MustParseAddr("fe80::1%en0")
		},
		"zero port":     func(s *allocatordiscovery.Snapshot) { s.Members[0].Endpoints[0].Port = 0 },
		"shared socket": func(s *allocatordiscovery.Snapshot) { s.Members[1].Endpoints[0] = s.Members[0].Endpoints[0] },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := baseConfig(t)
			s := snapshotFor(member("uid-a", "a", "10.0.0.2", 5000), member("uid-b", "b", "10.0.0.3", 5000))
			mutate(&s)
			if _, err := selectBinding(cfg, s); !errors.Is(err, ErrObservation) {
				t.Fatalf("accepted invalid observation: %v", err)
			}
		})
	}
}

func TestDeterministicSelectedUIDAndIPv6(t *testing.T) {
	cfg := baseConfig(t)
	a := member("uid-a", "a", "2001:db8::2", 6000)
	a.Endpoints = append(a.Endpoints, allocatordiscovery.Endpoint{Address: netip.MustParseAddr("2001:db8::1"), Port: 5000, Ready: corev1.ConditionTrue, Serving: corev1.ConditionUnknown, Terminating: corev1.ConditionUnknown})
	s := snapshotFor(member("uid-b", "b", "10.0.0.1", 1), a)
	b, err := selectBinding(cfg, s)
	if err != nil || b.ActorUID != "uid-a" || b.Address.String() != "[2001:db8::1]:5000" || b.SourceVersion != "version-1" {
		t.Fatalf("selection: %+v %v", b, err)
	}
	slices.Reverse(a.Endpoints)
	s.Members[1] = a
	slices.Reverse(s.Members)
	other, err := selectBinding(cfg, s)
	if err != nil || b != other {
		t.Fatalf("selection moved: %+v %v", other, err)
	}
}

func TestGenerationRefusalPrecedesDiscovery(t *testing.T) {
	cfg := baseConfig(t)
	g := &generationSource{record: cfg.Record}
	d := &discoverySource{}
	c, err := NewClient(Sources{Generations: g, Discovery: d}, cfg)
	if err != nil {
		t.Fatal(err)
	}
	g.record.Version = "new-version"
	_, err = c.Reserve(context.Background(), agonesalloc.Request{})
	if !errors.Is(err, ErrObservation) || d.reads != 0 {
		t.Fatalf("changed generation allowed discovery: %v reads=%d", err, d.reads)
	}
}

// Readable expanded membership cannot authorize discovery or active peer configuration.
func TestExpandedGenerationCannotAuthorizeLegacyPeerDispatch(t *testing.T) {
	t.Parallel()
	for _, state := range []string{"open", "draining"} {
		t.Run(state, func(t *testing.T) {
			t.Parallel()
			cfg := baseConfig(t)
			raw, err := json.Marshal(map[string]any{
				"schema": 2, "generation_id": cfg.Record.GenerationID,
				"member_pod_uids": cfg.Record.MemberPodUIDs, "member_set_digest": cfg.Record.MemberSetDigest, "state": state,
			})
			if err != nil {
				t.Fatal(err)
			}
			storage := nakamastoragetest.New()
			storage.Seed(nakamastoragetest.Object{Collection: nakamageneration.Collection, Key: cfg.Record.GenerationID, Value: string(raw), Version: cfg.Record.Version})
			generations, err := nakamageneration.NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			d := &discoverySource{snapshot: snapshotFor(member("uid-a", "allocator-a", "192.0.2.1", 443), member("uid-b", "allocator-b", "192.0.2.2", 443))}
			client, err := NewClient(Sources{Generations: generations, Discovery: d}, cfg)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := client.observe(t.Context()); !errors.Is(err, ErrObservation) || d.reads != 0 {
				t.Fatalf("expanded generation reached peer selection: %v, discovery=%d", err, d.reads)
			}
			expanded, err := generations.Load(t.Context(), cfg.Record.GenerationID)
			if err != nil {
				t.Fatal(err)
			}
			cfg.Record = expanded
			if _, err := NewClient(Sources{Generations: generations, Discovery: d}, cfg); !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("expanded record accepted as active client configuration: %v", err)
			}
		})
	}
}
