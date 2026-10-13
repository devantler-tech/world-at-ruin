package nakamaruntime

import (
	"bytes"
	"crypto"
	"crypto/tls"
	"crypto/x509"
	"net"
	"net/url"
	"path"
	"reflect"
	"slices"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
)

// ClaimsTLSMaterial is a static, inspectable credential snapshot. Expectations
// are independently pinned configuration, not identity inferred from the leaf.
// The runtime owns cloned DER and its fixed TLS policy; the caller retains the
// signing object for the entire initialized lifetime. Input buffers and slice
// headers must stay stable until initialization returns. This conveys no issuance,
// attestation, key-transfer, rotation or recovery authority.
type ClaimsTLSMaterial struct {
	CertificateChainDER  [][]byte
	Signer               crypto.Signer
	ClientAuthoritiesDER [][]byte
	ExpectedServerDNS    string
	ExpectedServerURI    string
}

// claimsMaterialTLS validates every supplied certificate before socket
// reservation. It never accepts caller-controlled verification or TLS policy.
func claimsMaterialTLS(cfg privateConfig, material ClaimsTLSMaterial) (*tls.Config, error) {
	if !handoffidentity.DNSSubdomain(material.ExpectedServerDNS) || net.ParseIP(material.ExpectedServerDNS) != nil || !claimsServerURI(material.ExpectedServerURI, cfg.trustDomain) || nilSigningHandle(material.Signer) {
		return nil, errMaterial
	}
	chainDER, rootDER, err := cloneClaimsDER(material)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	chain, err := parseClaimsDER(chainDER, now)
	if err != nil {
		return nil, err
	}
	for i := 1; i < len(chain); i++ {
		if chain[i-1].CheckSignatureFrom(chain[i]) != nil {
			return nil, errMaterial
		}
	}
	roots, err := parseClaimsDER(rootDER, now)
	if err != nil {
		return nil, err
	}
	pool, err := clientAuthorityPool(roots, now)
	if err != nil {
		return nil, err
	}
	leaf := chain[0]
	if leaf.IsCA || leaf.KeyUsage&x509.KeyUsageDigitalSignature == 0 || !slices.Contains(leaf.ExtKeyUsage, x509.ExtKeyUsageServerAuth) || !slices.Contains(leaf.DNSNames, material.ExpectedServerDNS) || len(leaf.URIs) != 1 || leaf.URIs[0].String() != material.ExpectedServerURI {
		return nil, errMaterial
	}
	publicDER, err := x509.MarshalPKIXPublicKey(material.Signer.Public())
	if err != nil || !bytes.Equal(publicDER, leaf.RawSubjectPublicKeyInfo) {
		return nil, errMaterial
	}
	intermediates := x509.NewCertPool()
	for _, certificate := range chain[1:] {
		intermediates.AddCert(certificate)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, Intermediates: intermediates, CurrentTime: now, DNSName: material.ExpectedServerDNS, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err != nil {
		return nil, errMaterial
	}
	allocatorKeys, err := claimsAllocatorCertificates(cfg)
	if err != nil || sharesKey(slices.Concat(roots, chain), allocatorKeys) || sharesKey([]*x509.Certificate{leaf}, slices.Concat(roots, chain[1:])) {
		return nil, errMaterial
	}
	pair := tls.Certificate{Certificate: chainDER, PrivateKey: material.Signer, Leaf: leaf}
	return verifiedClaimsTLS(pair, pool), nil
}

// cloneClaimsDER bounds parsing and allocation across both supplied groups.
func cloneClaimsDER(material ClaimsTLSMaterial) ([][]byte, [][]byte, error) {
	if len(material.CertificateChainDER) == 0 || len(material.CertificateChainDER) > 8 || len(material.ClientAuthoritiesDER) == 0 || len(material.ClientAuthoritiesDER) > 32 {
		return nil, nil, errMaterial
	}
	total := 0
	for _, group := range [][][]byte{material.CertificateChainDER, material.ClientAuthoritiesDER} {
		for _, der := range group {
			if len(der) == 0 || len(der) > 64*1024 {
				return nil, nil, errMaterial
			}
			total += len(der)
			if total > 256*1024 {
				return nil, nil, errMaterial
			}
		}
	}
	clone := func(group [][]byte) [][]byte {
		result := make([][]byte, len(group))
		for i, der := range group {
			result[i] = bytes.Clone(der)
		}
		return result
	}
	return clone(material.CertificateChainDER), clone(material.ClientAuthoritiesDER), nil
}

// parseClaimsDER refuses malformed or currently invalid certificates before
// they can become retained listener material.
func parseClaimsDER(group [][]byte, now time.Time) ([]*x509.Certificate, error) {
	result := make([]*x509.Certificate, 0, len(group))
	for _, der := range group {
		certificate, err := x509.ParseCertificate(der)
		if err != nil || !currentlyValid(certificate, now) {
			return nil, errMaterial
		}
		result = append(result, certificate)
	}
	return result, nil
}

// claimsServerURI accepts canonical, bounded SPIFFE paths in the configured
// trust domain using the strict path alphabet, without legacy charset mode.
// The exact expected path remains operator policy.
func claimsServerURI(value, trustDomain string) bool {
	if len(value) > 2048 || !handoffidentity.DNSSubdomain(trustDomain) {
		return false
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "spiffe" || u.Host != trustDomain || u.User != nil || u.Opaque != "" || u.RawPath != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || !strings.HasPrefix(u.Path, "/") || u.Path == "/" || path.Clean(u.Path) != u.Path || u.String() != value {
		return false
	}
	for _, c := range u.Path {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("/-._", c) {
			continue
		}
		return false
	}
	return true
}

// Interfaces holding a typed nil key must refuse before Public is invoked.
func nilSigningHandle(signer crypto.Signer) bool {
	if signer == nil {
		return true
	}
	v := reflect.ValueOf(signer)
	kind := v.Kind()
	return (kind == reflect.Chan || kind == reflect.Func || kind == reflect.Interface || kind == reflect.Map || kind == reflect.Pointer || kind == reflect.Slice) && v.IsNil()
}

// clientAuthorityPool preserves the projected source's client-root policy.
func clientAuthorityPool(roots []*x509.Certificate, now time.Time) (*x509.CertPool, error) {
	pool := x509.NewCertPool()
	for _, root := range roots {
		if !root.IsCA || !currentlyValid(root, now) || root.KeyUsage != 0 && root.KeyUsage&x509.KeyUsageCertSign == 0 || !anchorsClientAuth(root) {
			return nil, errMaterial
		}
		pool.AddCert(root)
	}
	return pool, nil
}

// claimsAllocatorCertificates reads the separate allocator identities used
// to refuse key reuse across the two roles.
func claimsAllocatorCertificates(cfg privateConfig) ([]*x509.Certificate, error) {
	var certificates []*x509.Certificate
	for _, file := range []string{cfg.allocatorCA, cfg.allocatorCert} {
		material, err := readMaterial(file)
		if err != nil {
			return nil, errMaterial
		}
		parsed, err := parseCertificates(material)
		if err != nil {
			return nil, errMaterial
		}
		certificates = append(certificates, parsed...)
	}
	return certificates, nil
}

// verifiedClaimsTLS fixes transport policy for both supported material sources.
func verifiedClaimsTLS(pair tls.Certificate, roots *x509.CertPool) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert, NextProtos: []string{"http/1.1"}}
}
