package nakamaruntime

import (
	"context"
	"crypto/tls"
	"crypto/x509"
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
	ca, err := readMaterial(cfg.ca)
	if err != nil {
		return nil, errMaterial
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
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
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil || time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return nil, errMaterial
	}
	if len(leaf.DNSNames)+len(leaf.IPAddresses) == 0 || len(leaf.ExtKeyUsage) > 0 && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageServerAuth) && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageAny) {
		return nil, errMaterial
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert, NextProtos: []string{"http/1.1"}}, nil
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
