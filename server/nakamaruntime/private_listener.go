package nakamaruntime

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"golang.org/x/net/netutil"
)

type privateConfig struct {
	enabled                             bool
	address, ca, cert, key, trustDomain string
	// allocatorCA and allocatorCert are the allocator credentials the claim
	// listener must never share trust or keys with.
	allocatorCA, allocatorCert string
}

// readPrivateConfig requires a deliberate address and dedicated credentials.
// Disabled mode ignores all listener configuration and performs no I/O.
func readPrivateConfig(env map[string]string) (privateConfig, error) {
	var cfg privateConfig
	switch env["WAR_HANDOFF_CLAIMS_ENABLED"] {
	case "", "false":
		return cfg, nil
	case "true":
		cfg.enabled = true
	default:
		return cfg, invalidConfig("WAR_HANDOFF_CLAIMS_ENABLED")
	}
	cfg.address = env["WAR_HANDOFF_CLAIMS_ADDRESS"]
	host, port, err := net.SplitHostPort(cfg.address)
	number, portErr := strconv.ParseUint(port, 10, 16)
	if err != nil || net.ParseIP(host) == nil || portErr != nil || number == 0 {
		return privateConfig{}, invalidConfig("WAR_HANDOFF_CLAIMS_ADDRESS")
	}
	for name, target := range map[string]*string{
		"WAR_HANDOFF_CLAIMS_CA_FILE":   &cfg.ca,
		"WAR_HANDOFF_CLAIMS_CERT_FILE": &cfg.cert,
		"WAR_HANDOFF_CLAIMS_KEY_FILE":  &cfg.key,
	} {
		*target = env[name]
		if !validPath(*target) {
			return privateConfig{}, invalidConfig(name)
		}
	}
	cfg.trustDomain = env["WAR_HANDOFF_CLAIMS_TRUST_DOMAIN"]
	if !handoffidentity.DNSSubdomain(cfg.trustDomain) {
		return privateConfig{}, invalidConfig("WAR_HANDOFF_CLAIMS_TRUST_DOMAIN")
	}
	return cfg, nil
}

// privateTLS loads bounded projected files before binding any socket. The roots
// authorize workload clients only; allocator trust and credentials stay separate.
func privateTLS(cfg privateConfig) (*tls.Config, error) {
	now := time.Now()
	ca, err := readMaterial(cfg.ca)
	if err != nil {
		return nil, errMaterial
	}
	roots, err := parseCertificates(ca)
	if err != nil {
		return nil, errMaterial
	}
	pool := x509.NewCertPool()
	for _, root := range roots {
		// A root that is stale, not yet valid, not allowed to sign certificates, or
		// restricted to purposes other than client authentication would start a
		// listener that rejects every workload, so it fails startup and the module
		// rolls back instead.
		if !root.IsCA || !currentlyValid(root, now) || root.KeyUsage != 0 && root.KeyUsage&x509.KeyUsageCertSign == 0 || !anchorsClientAuth(root) {
			return nil, errMaterial
		}
		pool.AddCert(root)
	}
	allocatorCA, err := readMaterial(cfg.allocatorCA)
	if err != nil {
		return nil, errMaterial
	}
	allocatorRoots, err := parseCertificates(allocatorCA)
	if err != nil || sharesKey(roots, allocatorRoots) {
		return nil, errMaterial
	}
	cert, err := readMaterial(cfg.cert)
	if err != nil {
		return nil, errMaterial
	}
	key, err := readMaterial(cfg.key)
	if err != nil {
		return nil, errMaterial
	}
	pair, err := tls.X509KeyPair(cert, key)
	if err != nil {
		return nil, errMaterial
	}
	// Zone clients reject the whole served chain if any certificate in it is
	// unusable, so every one is checked, not only the leaf.
	chain := make([]*x509.Certificate, 0, len(pair.Certificate))
	for _, der := range pair.Certificate {
		certificate, err := x509.ParseCertificate(der)
		if err != nil || !currentlyValid(certificate, now) {
			return nil, errMaterial
		}
		chain = append(chain, certificate)
	}
	leaf := chain[0]
	allocatorCert, err := readMaterial(cfg.allocatorCert)
	if err != nil {
		return nil, errMaterial
	}
	allocatorLeaves, err := parseCertificates(allocatorCert)
	// The server key is ordinary HTTPS material, so it may belong to neither the
	// allocator nor any root that authorizes workload identities.
	if err != nil || sharesKey([]*x509.Certificate{leaf}, allocatorLeaves[:1]) || sharesKey([]*x509.Certificate{leaf}, roots) {
		return nil, errMaterial
	}
	if len(leaf.DNSNames)+len(leaf.IPAddresses) == 0 || len(leaf.ExtKeyUsage) > 0 && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageServerAuth) && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageAny) {
		return nil, errMaterial
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert, NextProtos: []string{"http/1.1"}}, nil
}

// parseCertificates decodes every certificate in a PEM bundle. Unlike a cert
// pool it rejects a bundle holding an unparsable certificate or none at all.
func parseCertificates(bundle []byte) ([]*x509.Certificate, error) {
	var certificates []*x509.Certificate
	for rest := bundle; ; {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errMaterial
		}
		certificates = append(certificates, certificate)
	}
	if len(certificates) == 0 {
		return nil, errMaterial
	}
	return certificates, nil
}

// currentlyValid reports whether now falls inside the certificate's validity window.
func currentlyValid(certificate *x509.Certificate, now time.Time) bool {
	return !now.Before(certificate.NotBefore) && now.Before(certificate.NotAfter)
}

// anchorsClientAuth reports whether Go will verify a client-authentication chain
// beneath root. The verifier applies every certificate's extended key usage, the
// root's included, so a root restricted to other purposes — named or unknown —
// rejects every workload beneath it. A root with no extended key usage restricts
// nothing.
func anchorsClientAuth(root *x509.Certificate) bool {
	if len(root.ExtKeyUsage)+len(root.UnknownExtKeyUsage) == 0 {
		return true
	}
	return slices.Contains(root.ExtKeyUsage, x509.ExtKeyUsageClientAuth) || slices.Contains(root.ExtKeyUsage, x509.ExtKeyUsageAny)
}

// sharesKey reports whether any certificate in a uses a public key from b. The
// claim listener keeps its own trust anchors and key, so allocator PKI
// misissuance can never authenticate to durable lease ownership.
func sharesKey(a, b []*x509.Certificate) bool {
	for _, left := range a {
		for _, right := range b {
			if bytes.Equal(left.RawSubjectPublicKeyInfo, right.RawSubjectPublicKeyInfo) {
				return true
			}
		}
	}
	return false
}

type privateListener struct {
	listener net.Listener
	server   *http.Server
	done     chan struct{}
}

// preparePrivateListener reserves the socket without accepting work. Serving
// starts only after runtime registration has succeeded; rollback closes it.
func preparePrivateListener(cfg privateConfig, life context.Context, gate *handlerGate, handler http.Handler) (*privateListener, error) {
	if !cfg.enabled {
		return nil, nil
	}
	config, err := privateTLS(cfg)
	if err != nil {
		return nil, err
	}
	listener, err := (&net.ListenConfig{}).Listen(life, "tcp", cfg.address)
	if err != nil {
		return nil, errors.New("nakama handoff: private listener unavailable")
	}
	server := &http.Server{
		TLSConfig: config, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8 * 1024,
		// Keep one active request per bounded connection rather than enabling an
		// independently multiplexed HTTP/2 stream budget on this private surface.
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
		ErrorLog:     log.New(io.Discard, "", 0),
		BaseContext:  func(net.Listener) context.Context { return life },
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if life.Err() != nil || !gate.enter() {
				http.Error(w, "zone claim refused", http.StatusForbidden)
				return
			}
			defer gate.leave()
			handler.ServeHTTP(w, r)
		}),
	}
	return &privateListener{listener: netutil.LimitListener(listener, 64), server: server, done: make(chan struct{})}, nil
}

// start makes unexpected serving failure terminal for the whole handoff module.
func (p *privateListener) start(cancel context.CancelFunc) {
	go func() {
		defer close(p.done)
		if err := p.server.ServeTLS(p.listener, "", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
			cancel()
			log.Print("nakama handoff: private listener stopped; module admission disabled")
		}
	}()
}

// stop refuses new connections and force-closes remaining ones at the caller's
// deadline. The module gate separately tracks every active private handler.
func (p *privateListener) stop(ctx context.Context) {
	if err := p.server.Shutdown(ctx); err != nil {
		_ = p.server.Close()
	}
	// Shutdown can race start before ServeTLS owns the prepared listener.
	_ = p.listener.Close()
	select {
	case <-p.done:
	case <-ctx.Done():
	}
}
