package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
)

// claimOptions is explicit opt-in configuration; disabled mode owns no transport.
type claimOptions struct {
	enabled                             bool
	endpoint, caFile, certFile, keyFile string
}

// validate refuses contradictory modes before minting, file access or SDK calls.
func (c claimOptions) validate(listening, withAgones, sealed, plaintext, minting bool) error {
	if !c.enabled {
		return nil
	}
	if !listening || !withAgones || !sealed || plaintext || minting || c.endpoint == "" || c.caFile == "" || c.certFile == "" || c.keyFile == "" {
		return errors.New("private claims: require TLS -listen, -agones, -agones-admission-public-key, -claim-url, -claim-ca, -claim-cert and -claim-key; token minting is unavailable")
	}
	return nil
}

// client validates bounded material without opening a connection. The private
// handler authenticates the workload URI against the exact observed GameServer.
func (c claimOptions) client() (*claimrpc.Client, error) {
	if !c.enabled {
		return nil, nil
	}
	ca, err := readClaimMaterial(c.caFile)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errClaimMaterial
	}
	certPEM, err := readClaimMaterial(c.certFile)
	if err != nil {
		return nil, err
	}
	keyPEM, err := readClaimMaterial(c.keyFile)
	if err != nil {
		return nil, err
	}
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, errClaimMaterial
	}
	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil || time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return nil, errClaimMaterial
	}
	if len(leaf.ExtKeyUsage) > 0 && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageClientAuth) && !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageAny) {
		return nil, errClaimMaterial
	}
	client, err := claimrpc.NewClient(c.endpoint, &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{certificate}})
	if err != nil {
		return nil, errors.New("private claims: invalid HTTPS endpoint or TLS configuration")
	}
	return client, nil
}

var errClaimMaterial = errors.New("private claims: invalid certificate or key material")

// readClaimMaterial bounds each operator-supplied file and keeps contents and
// private paths out of errors. No claim material is persisted by the command.
func readClaimMaterial(path string) ([]byte, error) {
	clean := filepath.Clean(path)
	file, err := os.DirFS(filepath.Dir(clean)).Open(filepath.Base(clean))
	if err != nil {
		return nil, errClaimMaterial
	}
	defer func() { _ = file.Close() }()
	data, err := io.ReadAll(io.LimitReader(file, 1024*1024+1))
	if err != nil || len(data) == 0 || len(data) > 1024*1024 {
		return nil, errClaimMaterial
	}
	return data, nil
}
