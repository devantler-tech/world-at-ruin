// Package envelopetest assembles independent admission material for tests.
package envelopetest

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
)

// Seal preserves explicit caller-owned identity and plaintext. It has no
// dependency on production sealing, label construction or key policy.
func Seal(tb testing.TB, key *rsa.PublicKey, namespace, name, uid, fingerprint string, secret []byte) string {
	tb.Helper()
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", namespace, name, uid, fingerprint}, "\x00"))
	ciphertext, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, key, secret, label)
	if err != nil {
		tb.Fatalf("encrypt test envelope: %v", err)
	}
	return "v1." + base64.RawURLEncoding.EncodeToString(ciphertext)
}
