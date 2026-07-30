// Package admissionref opens identity-bound zone admission envelopes and
// derives the durable reference used by the handoff lease.
package admissionref

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	envelopePrefix      = "v1."
	referencePrefix     = "v1"
	oaepDomain          = "world-at-ruin/zone-admission/v1"
	admissionSecretSize = 32
	minimumRSAKeyBits   = 3072
	fingerprintLength   = 52
)

// ErrInvalidMaterial refuses malformed, unknown, or identity-mismatched
// admission material without exposing the failing value.
var ErrInvalidMaterial = errors.New("admission reference: invalid sealed material")

// Material is the exact allocated GameServer identity and sealed admission
// data that a durable handoff reference binds.
type Material struct {
	Namespace              string
	GameServerName         string
	GameServerUID          string
	WrappingKeyFingerprint string
	AdmissionEnvelope      string
	TLSPort                uint16
}

// Opened retains one decrypted admission secret and its durable reference.
// Secret returns copies so a caller cannot mutate the retained value.
type Opened struct {
	secret    [admissionSecretSize]byte
	secretRef string
}

// Secret returns a copy of the decrypted admission secret.
func (o Opened) Secret() []byte {
	return append([]byte(nil), o.secret[:]...)
}

// SecretRef returns the DNS-safe durable reference for the sealed material.
func (o Opened) SecretRef() string {
	return o.secretRef
}

// Keyring retains every private wrapping key needed to resolve live handoffs
// across a key rotation.
type Keyring struct {
	keys map[string]*rsa.PrivateKey
}

// NewKeyring validates private RSA wrapping keys and indexes them by the
// canonical SubjectPublicKeyInfo fingerprint used in GameServer metadata.
func NewKeyring(privateKeys ...*rsa.PrivateKey) (*Keyring, error) {
	if len(privateKeys) == 0 {
		return nil, ErrInvalidMaterial
	}
	keys := make(map[string]*rsa.PrivateKey, len(privateKeys))
	for _, privateKey := range privateKeys {
		if privateKey == nil ||
			privateKey.N == nil ||
			privateKey.N.BitLen() < minimumRSAKeyBits ||
			privateKey.Validate() != nil {
			return nil, ErrInvalidMaterial
		}
		fingerprint, err := wrappingKeyFingerprint(&privateKey.PublicKey)
		if err != nil {
			return nil, ErrInvalidMaterial
		}
		if _, exists := keys[fingerprint]; exists {
			return nil, ErrInvalidMaterial
		}
		keys[fingerprint] = privateKey
	}
	return &Keyring{keys: keys}, nil
}

// Open validates, decrypts, and derives the durable reference for newly
// allocated GameServer material.
func (k *Keyring) Open(material Material) (Opened, error) {
	return k.open("", material)
}

// Resolve verifies a previously durable reference against current GameServer
// material before returning the identity-bound admission secret.
func (k *Keyring) Resolve(secretRef string, material Material) (Opened, error) {
	if secretRef == "" {
		return Opened{}, ErrInvalidMaterial
	}
	return k.open(secretRef, material)
}

func (k *Keyring) open(expectedReference string, material Material) (Opened, error) {
	privateKey, ciphertext, secretRef, ok := k.validateMaterial(material)
	if !ok || (expectedReference != "" && expectedReference != secretRef) {
		return Opened{}, ErrInvalidMaterial
	}
	plaintext, err := rsa.DecryptOAEP(
		sha256.New(),
		nil,
		privateKey,
		ciphertext,
		admissionOAEPLabel(material),
	)
	if err != nil {
		return Opened{}, ErrInvalidMaterial
	}
	defer clear(plaintext)
	if len(plaintext) != admissionSecretSize {
		return Opened{}, ErrInvalidMaterial
	}
	var secret [admissionSecretSize]byte
	copy(secret[:], plaintext)
	return Opened{
		secret:    secret,
		secretRef: secretRef,
	}, nil
}

func (k *Keyring) validateMaterial(
	material Material,
) (*rsa.PrivateKey, []byte, string, bool) {
	if k == nil ||
		!validDNSLabel(material.Namespace) ||
		!validDNSSubdomain(material.GameServerName) ||
		!validGameServerUID(material.GameServerUID) ||
		!validFingerprint(material.WrappingKeyFingerprint) ||
		material.TLSPort == 0 {
		return nil, nil, "", false
	}
	privateKey, exists := k.keys[material.WrappingKeyFingerprint]
	if !exists {
		return nil, nil, "", false
	}
	ciphertext, ok := decodeEnvelope(material.AdmissionEnvelope)
	if !ok || len(ciphertext) != privateKey.Size() {
		return nil, nil, "", false
	}
	secretRef := strings.Join([]string{
		referencePrefix,
		"k" + material.WrappingKeyFingerprint,
		"u" + base32Digest([]byte(material.GameServerUID)),
		"e" + base32Digest(ciphertext),
		"p" + strconv.FormatUint(uint64(material.TLSPort), 10),
	}, ".")
	return privateKey, ciphertext, secretRef, true
}

func decodeEnvelope(value string) ([]byte, bool) {
	if !strings.HasPrefix(value, envelopePrefix) {
		return nil, false
	}
	encoded := strings.TrimPrefix(value, envelopePrefix)
	if encoded == "" {
		return nil, false
	}
	ciphertext, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil ||
		base64.RawURLEncoding.EncodeToString(ciphertext) != encoded {
		return nil, false
	}
	return ciphertext, true
}

func admissionOAEPLabel(material Material) []byte {
	return []byte(strings.Join([]string{
		oaepDomain,
		material.Namespace,
		material.GameServerName,
		material.GameServerUID,
		material.WrappingKeyFingerprint,
	}, "\x00"))
}

func wrappingKeyFingerprint(publicKey *rsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return "", fmt.Errorf("marshal wrapping public key: %w", err)
	}
	return base32Digest(der), nil
}

func base32Digest(value []byte) string {
	digest := sha256.Sum256(value)
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
}

func validFingerprint(value string) bool {
	if len(value) != fingerprintLength {
		return false
	}
	decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).
		DecodeString(strings.ToUpper(value))
	if err != nil || len(decoded) != sha256.Size {
		return false
	}
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(decoded),
	) == value
}

func validGameServerUID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') &&
			char != '-' &&
			char != '_' &&
			char != '.' {
			return false
		}
	}
	return true
}

func validDNSSubdomain(value string) bool {
	if value == "" || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !validDNSLabel(label) {
			return false
		}
	}
	return true
}

func validDNSLabel(value string) bool {
	if value == "" ||
		len(value) > 63 ||
		value[0] == '-' ||
		value[len(value)-1] == '-' {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < '0' || char > '9') &&
			char != '-' {
			return false
		}
	}
	return true
}
