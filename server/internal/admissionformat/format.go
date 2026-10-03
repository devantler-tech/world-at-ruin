// Package admissionformat owns admission wire bytes, independently of key and
// ciphertext-size policy at each consumer.
package admissionformat

import (
	"encoding/base64"
	"strings"
)

// OAEPLabel binds the exact versioned domain and ordered GameServer identity.
func OAEPLabel(namespace, name, uid, fingerprint string) []byte {
	return []byte(strings.Join([]string{
		"world-at-ruin/zone-admission/v1", namespace, name, uid, fingerprint,
	}, "\x00"))
}

// DecodeEnvelope refuses empty payloads and every noncanonical base64 spelling.
// Size constraints belong to the consumer, including key-free references.
func DecodeEnvelope(value string) ([]byte, bool) {
	const prefix = "v1."
	if !strings.HasPrefix(value, prefix) {
		return nil, false
	}
	encoded := strings.TrimPrefix(value, prefix)
	if encoded == "" {
		return nil, false
	}
	ciphertext, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil || base64.RawURLEncoding.EncodeToString(ciphertext) != encoded {
		return nil, false
	}
	return ciphertext, true
}
