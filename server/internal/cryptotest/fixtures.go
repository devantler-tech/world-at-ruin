// Package cryptotest constructs independent cryptographic test material.
package cryptotest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/admissionref"
)

// Seal builds an RSA admission envelope without using the production sealer.
// Identity fields and plaintext remain explicit at each scenario's call site.
func Seal(tb testing.TB, namespace, name, uid string, secret []byte) (*rsa.PrivateKey, string, string) {
	tb.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		tb.Fatal(err)
	}
	fingerprint, err := admissionref.Fingerprint(&key.PublicKey)
	if err != nil {
		tb.Fatal(err)
	}
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", namespace, name, uid, fingerprint}, "\x00"))
	sealed, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.PublicKey, secret, label)
	if err != nil {
		tb.Fatal(err)
	}
	return key, fingerprint, "v1." + base64.RawURLEncoding.EncodeToString(sealed)
}

// NewKey generates the P-256 key used by certificate fixtures.
func NewKey(tb testing.TB) *ecdsa.PrivateKey {
	tb.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		tb.Fatal(err)
	}
	return key
}

// Issue signs the caller's explicit certificate template with its chosen key.
func Issue(tb testing.TB, template, parent *x509.Certificate, publicKey, signer any) []byte {
	tb.Helper()
	der, err := x509.CreateCertificate(rand.Reader, template, parent, publicKey, signer)
	if err != nil {
		tb.Fatal(err)
	}
	return der
}

// Parse decodes a fixture certificate for trust-pool and signer construction.
func Parse(tb testing.TB, der []byte) *x509.Certificate {
	tb.Helper()
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		tb.Fatal(err)
	}
	return certificate
}
