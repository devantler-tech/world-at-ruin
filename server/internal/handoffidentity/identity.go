// Package handoffidentity defines the shared ASCII identity grammars used by
// allocation correlation, sealed admission material and durable handoff leases.
package handoffidentity

import (
	"crypto/sha256"
	"encoding/base32"
	"strings"
)

// Fingerprint requires the canonical lowercase, unpadded base32 encoding of a
// SHA-256 digest. Re-encoding rejects aliases with nonzero unused padding bits.
func Fingerprint(value string) bool {
	if len(value) != 52 {
		return false
	}
	encoding := base32.StdEncoding.WithPadding(base32.NoPadding)
	decoded, err := encoding.DecodeString(strings.ToUpper(value))
	if err != nil || len(decoded) != sha256.Size {
		return false
	}
	return strings.ToLower(encoding.EncodeToString(decoded)) == value
}

// CorrelationID permits 1..128 bytes of ASCII letters, digits, '-' and '_'.
func CorrelationID(value string) bool { return token(value, "-_") }

// GameServerUID additionally permits dots. It is intentionally broader than a
// lease or correlation identifier and must not be substituted for one.
func GameServerUID(value string) bool { return token(value, "-_.") }

// token shares the size and ASCII rules while keeping punctuation explicit.
func token(value, punctuation string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		alphanumeric := (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9')
		if !alphanumeric && !strings.ContainsRune(punctuation, char) {
			return false
		}
	}
	return true
}

// DNSSubdomain requires nonempty lowercase labels and at most 253 total bytes.
func DNSSubdomain(value string) bool {
	if value == "" || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !DNSLabel(label) {
			return false
		}
	}
	return true
}

// DNSLabel permits lowercase letters, digits and interior hyphens, with a
// maximum of 63 bytes. Numeric first characters remain valid.
func DNSLabel(value string) bool {
	if value == "" || len(value) > 63 || value[0] == '-' || value[len(value)-1] == '-' {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '-' {
			return false
		}
	}
	return true
}
