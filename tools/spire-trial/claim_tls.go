package spiretrial

import (
	"crypto/tls"
	"crypto/x509"
	"errors"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

// issuedTLSMaterial snapshots the locally fetched SVID and its own-domain bundle.
// It never manufactures verification results or fetches another process's key.
func issuedTLSMaterial(material *workloadapi.X509Context) (tls.Certificate, *x509.CertPool, error) {
	if material == nil || len(material.SVIDs) != 1 || material.SVIDs[0] == nil || material.Bundles == nil {
		return tls.Certificate{}, nil, errors.New("missing issued TLS material")
	}
	svid := material.DefaultSVID()
	if len(svid.Certificates) == 0 || svid.PrivateKey == nil {
		return tls.Certificate{}, nil, errors.New("missing issued certificate or key")
	}
	leaf := svid.Certificates[0]
	if leaf == nil || len(leaf.URIs) != 1 || leaf.URIs[0].String() != svid.ID.String() {
		return tls.Certificate{}, nil, errors.New("issued certificate identity mismatch")
	}
	bundle, err := material.Bundles.GetX509BundleForTrustDomain(svid.ID.TrustDomain())
	if err != nil || len(bundle.X509Authorities()) == 0 {
		return tls.Certificate{}, nil, errors.New("missing issued trust bundle")
	}
	pool := x509.NewCertPool()
	for _, root := range bundle.X509Authorities() {
		pool.AddCert(root)
	}
	cert := tls.Certificate{PrivateKey: svid.PrivateKey, Leaf: leaf}
	for _, chain := range svid.Certificates {
		cert.Certificate = append(cert.Certificate, append([]byte(nil), chain.Raw...))
	}
	return cert, pool, nil
}

// claimClientTLS keeps ordinary chain and DNS verification enabled. VerifyConnection
// adds exact server URI authorization after Go has populated its verified chains.
func claimClientTLS(material *workloadapi.X509Context, dns, expected string) (*tls.Config, error) {
	cert, roots, err := issuedTLSMaterial(material)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, Certificates: []tls.Certificate{cert}, ServerName: dns, VerifyConnection: func(state tls.ConnectionState) error {
		if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 || len(state.PeerCertificates[0].URIs) != 1 || state.PeerCertificates[0].URIs[0].String() != expected {
			return errors.New("unexpected verified claims server")
		}
		return nil
	}}, nil
}

// claimServerTLS delegates client chain verification to Go itself. The unchanged
// private claim handler subsequently enforces its exact zone URI authorization.
func claimServerTLS(material *workloadapi.X509Context) (*tls.Config, error) {
	cert, roots, err := issuedTLSMaterial(material)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert, SessionTicketsDisabled: true}, nil
}
