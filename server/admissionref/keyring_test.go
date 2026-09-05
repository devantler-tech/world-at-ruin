package admissionref

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
)

const (
	testNamespace  = "world-at-ruin"
	testServerName = "zone-17"
	testServerUID  = "42f37cd7-a968-442f-9a8b-b23bb2c31bd4"
	testTLSPort    = uint16(8443)
)

var (
	testKeysOnce sync.Once
	testKeys     []*rsa.PrivateKey
	testKeysErr  error
)

func TestOpenDecryptsIdentityBoundMaterialAndMintsReference(t *testing.T) {
	key := generatedKeys(t)[0]
	material := validMaterial(t, key, testAdmissionSecret())
	keyring := newTestKeyring(t, key)

	opened, err := keyring.Open(material)
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}

	if got := opened.Secret(); !bytes.Equal(got, testAdmissionSecret()) {
		t.Fatalf("Secret() = %x, want the original 32-byte secret", got)
	}
	if got, want := opened.SecretRef(), expectedReference(t, material); got != want {
		t.Fatalf("SecretRef() = %q, want %q", got, want)
	}
}

func TestOpenedSecretReturnsAnIsolatedCopy(t *testing.T) {
	key := generatedKeys(t)[0]
	opened, err := newTestKeyring(t, key).Open(
		validMaterial(t, key, testAdmissionSecret()),
	)
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}

	first := opened.Secret()
	first[0] ^= 0xff
	if got := opened.Secret(); !bytes.Equal(got, testAdmissionSecret()) {
		t.Fatalf("mutating one Secret() result changed the retained secret: %x", got)
	}
}

func TestKeyringRetainsKeysAcrossRotation(t *testing.T) {
	keys := generatedKeys(t)
	keyring := newTestKeyring(t, keys[:2]...)

	for index, key := range keys[:2] {
		t.Run(fmt.Sprintf("key-%d", index+1), func(t *testing.T) {
			material := validMaterial(t, key, testAdmissionSecret())
			opened, err := keyring.Open(material)
			if err != nil {
				t.Fatalf("Open returned error for retained key: %v", err)
			}
			if got := opened.SecretRef(); got != expectedReference(t, material) {
				t.Fatalf("SecretRef() = %q, want the retained key reference", got)
			}
		})
	}
}

func TestNewKeyringRejectsInvalidKeySets(t *testing.T) {
	keys := generatedKeys(t)
	tests := []struct {
		name string
		keys []*rsa.PrivateKey
	}{
		{name: "empty"},
		{name: "nil key", keys: []*rsa.PrivateKey{nil}},
		{name: "weak key", keys: []*rsa.PrivateKey{keys[2]}},
		{name: "duplicate fingerprint", keys: []*rsa.PrivateKey{keys[0], keys[0]}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := NewKeyring(test.keys...)
			if !errorsIsInvalidMaterial(err) {
				t.Fatalf("NewKeyring() error = %v, want ErrInvalidMaterial", err)
			}
		})
	}
}

func TestOpenRejectsMalformedOrUnboundMaterial(t *testing.T) {
	keys := generatedKeys(t)
	keyring := newTestKeyring(t, keys[0])
	valid := validMaterial(t, keys[0], testAdmissionSecret())
	otherFingerprint := keyFingerprint(t, keys[1])
	wrongKeyEnvelope := envelopeFor(
		t,
		keys[1],
		valid.Namespace,
		valid.GameServerName,
		valid.GameServerUID,
		valid.WrappingKeyFingerprint,
		testAdmissionSecret(),
	)
	shortPlaintextEnvelope := envelopeFor(
		t,
		keys[0],
		valid.Namespace,
		valid.GameServerName,
		valid.GameServerUID,
		valid.WrappingKeyFingerprint,
		testAdmissionSecret()[:31],
	)

	tests := []struct {
		name   string
		mutate func(Material) Material
	}{
		{
			name: "invalid namespace",
			mutate: func(material Material) Material {
				material.Namespace = "World_At_Ruin"
				return material
			},
		},
		{
			name: "changed namespace binding",
			mutate: func(material Material) Material {
				material.Namespace = "other-namespace"
				return material
			},
		},
		{
			name: "changed name binding",
			mutate: func(material Material) Material {
				material.GameServerName = "zone-18"
				return material
			},
		},
		{
			name: "changed UID binding",
			mutate: func(material Material) Material {
				material.GameServerUID = "dfe75609-0e04-460e-a11c-b7518970ffad"
				return material
			},
		},
		{
			name: "unknown wrapping key",
			mutate: func(material Material) Material {
				material.WrappingKeyFingerprint = otherFingerprint
				return material
			},
		},
		{
			name: "wrong private key",
			mutate: func(material Material) Material {
				material.AdmissionEnvelope = wrongKeyEnvelope
				return material
			},
		},
		{
			name: "wrong plaintext length",
			mutate: func(material Material) Material {
				material.AdmissionEnvelope = shortPlaintextEnvelope
				return material
			},
		},
		{
			name: "padded base64 envelope",
			mutate: func(material Material) Material {
				material.AdmissionEnvelope += "="
				return material
			},
		},
		{
			name: "wrong envelope version",
			mutate: func(material Material) Material {
				material.AdmissionEnvelope = strings.Replace(
					material.AdmissionEnvelope,
					"v1.",
					"v2.",
					1,
				)
				return material
			},
		},
		{
			name: "zero TLS port",
			mutate: func(material Material) Material {
				material.TLSPort = 0
				return material
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			material := test.mutate(valid)
			_, err := keyring.Open(material)
			if !errorsIsInvalidMaterial(err) {
				t.Fatalf("Open() error = %v, want ErrInvalidMaterial", err)
			}
			assertSanitizedError(t, err, material.AdmissionEnvelope)
		})
	}
}

func TestResolveRefusesChangedMaterialAndReferences(t *testing.T) {
	keys := generatedKeys(t)
	keyring := newTestKeyring(t, keys[:2]...)
	valid := validMaterial(t, keys[0], testAdmissionSecret())
	opened, err := keyring.Open(valid)
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	validReference := opened.SecretRef()
	otherKeyMaterial := validMaterial(t, keys[1], testAdmissionSecret())
	otherEnvelope := validMaterial(t, keys[0], testAdmissionSecret()).AdmissionEnvelope

	tests := []struct {
		name      string
		reference string
		mutate    func(Material) Material
	}{
		{
			name:      "malformed reference",
			reference: validReference + ".extra",
		},
		{
			name: "changed namespace",
			mutate: func(material Material) Material {
				material.Namespace = "other-namespace"
				return material
			},
		},
		{
			name: "changed GameServer name",
			mutate: func(material Material) Material {
				material.GameServerName = "zone-18"
				return material
			},
		},
		{
			name: "changed GameServer UID",
			mutate: func(material Material) Material {
				material.GameServerUID = "dfe75609-0e04-460e-a11c-b7518970ffad"
				return material
			},
		},
		{
			name: "changed envelope",
			mutate: func(material Material) Material {
				material.AdmissionEnvelope = otherEnvelope
				return material
			},
		},
		{
			name: "changed wrapping key",
			mutate: func(Material) Material {
				return otherKeyMaterial
			},
		},
		{
			name: "changed TLS port",
			mutate: func(material Material) Material {
				material.TLSPort = 9443
				return material
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			material := valid
			if test.mutate != nil {
				material = test.mutate(material)
			}
			reference := test.reference
			if reference == "" {
				reference = validReference
			}
			_, err := keyring.Resolve(reference, material)
			if !errorsIsInvalidMaterial(err) {
				t.Fatalf("Resolve() error = %v, want ErrInvalidMaterial", err)
			}
			assertSanitizedError(t, err, material.AdmissionEnvelope)
		})
	}
}

func TestResolveRefusesAnEmptyDurableReference(t *testing.T) {
	key := generatedKeys(t)[0]
	material := validMaterial(t, key, testAdmissionSecret())

	_, err := newTestKeyring(t, key).Resolve("", material)
	if !errorsIsInvalidMaterial(err) {
		t.Fatalf("Resolve() error = %v, want ErrInvalidMaterial", err)
	}
}

func newTestKeyring(t *testing.T, keys ...*rsa.PrivateKey) *Keyring {
	t.Helper()
	keyring, err := NewKeyring(keys...)
	if err != nil {
		t.Fatalf("NewKeyring returned error: %v", err)
	}
	return keyring
}

func validMaterial(t *testing.T, key *rsa.PrivateKey, secret []byte) Material {
	t.Helper()
	fingerprint := keyFingerprint(t, key)
	return Material{
		Namespace:              testNamespace,
		GameServerName:         testServerName,
		GameServerUID:          testServerUID,
		WrappingKeyFingerprint: fingerprint,
		AdmissionEnvelope: envelopeFor(
			t,
			key,
			testNamespace,
			testServerName,
			testServerUID,
			fingerprint,
			secret,
		),
		TLSPort: testTLSPort,
	}
}

func envelopeFor(
	t *testing.T,
	key *rsa.PrivateKey,
	namespace string,
	name string,
	uid string,
	fingerprint string,
	secret []byte,
) string {
	t.Helper()
	label := []byte(strings.Join([]string{
		"world-at-ruin/zone-admission/v1",
		namespace,
		name,
		uid,
		fingerprint,
	}, "\x00"))
	ciphertext, err := rsa.EncryptOAEP(
		sha256.New(),
		rand.Reader,
		&key.PublicKey,
		secret,
		label,
	)
	if err != nil {
		t.Fatalf("encrypt test envelope: %v", err)
	}
	return "v1." + base64.RawURLEncoding.EncodeToString(ciphertext)
}

func expectedReference(t *testing.T, material Material) string {
	t.Helper()
	ciphertext, err := base64.RawURLEncoding.Strict().DecodeString(
		strings.TrimPrefix(material.AdmissionEnvelope, "v1."),
	)
	if err != nil {
		t.Fatalf("decode test envelope: %v", err)
	}
	return fmt.Sprintf(
		"v1.k%s.u%s.e%s.p%d",
		material.WrappingKeyFingerprint,
		expectedBase32Digest([]byte(material.GameServerUID)),
		expectedBase32Digest(ciphertext),
		material.TLSPort,
	)
}

func keyFingerprint(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal test public key: %v", err)
	}
	return expectedBase32Digest(der)
}

func expectedBase32Digest(value []byte) string {
	digest := sha256.Sum256(value)
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
}

func generatedKeys(t *testing.T) []*rsa.PrivateKey {
	t.Helper()
	testKeysOnce.Do(func() {
		for _, bits := range []int{3072, 3072, 2048} {
			key, err := rsa.GenerateKey(rand.Reader, bits)
			if err != nil {
				testKeysErr = err
				return
			}
			testKeys = append(testKeys, key)
		}
	})
	if testKeysErr != nil {
		t.Fatalf("generate RSA test keys: %v", testKeysErr)
	}
	return testKeys
}

func testAdmissionSecret() []byte {
	return []byte("0123456789abcdef0123456789abcdef")
}

func errorsIsInvalidMaterial(err error) bool {
	return errors.Is(err, ErrInvalidMaterial)
}

func assertSanitizedError(t *testing.T, err error, envelope string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, forbidden := range []string{
		string(testAdmissionSecret()),
		envelope,
	} {
		if forbidden != "" && strings.Contains(err.Error(), forbidden) {
			t.Fatalf("error exposes sealed material: %q", err)
		}
	}
}

// TestReferenceDerivesTheDurableReferenceWithoutAKey checks that key-free
// derivation agrees with Open and changes when the GameServer UID changes.
func TestReferenceDerivesTheDurableReferenceWithoutAKey(t *testing.T) {
	key := generatedKeys(t)[0]
	material := validMaterial(t, key, testAdmissionSecret())

	got, err := Reference(material)
	if err != nil {
		t.Fatalf("Reference returned error: %v", err)
	}
	if want := expectedReference(t, material); got != want {
		t.Fatalf("Reference = %q, want %q", got, want)
	}
	opened, err := newTestKeyring(t, key).Open(material)
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	if opened.SecretRef() != got {
		t.Fatalf("Open reference %q differs from Reference %q", opened.SecretRef(), got)
	}

	changed := material
	changed.GameServerUID = "other-uid"
	if other, err := Reference(changed); err != nil || other == got {
		t.Fatalf("Reference ignored a changed UID: %q, %v", other, err)
	}
}

// TestReferenceRefusesMalformedMaterial checks that malformed identity,
// fingerprint, envelope and port fields cannot produce a durable reference.
func TestReferenceRefusesMalformedMaterial(t *testing.T) {
	key := generatedKeys(t)[0]
	tests := []struct {
		name   string
		mutate func(*Material)
	}{
		{name: "namespace", mutate: func(m *Material) { m.Namespace = "World" }},
		{name: "name", mutate: func(m *Material) { m.GameServerName = "" }},
		{name: "uid", mutate: func(m *Material) { m.GameServerUID = "uid/1" }},
		{name: "fingerprint", mutate: func(m *Material) { m.WrappingKeyFingerprint = "short" }},
		{name: "envelope", mutate: func(m *Material) { m.AdmissionEnvelope = "v2.abc" }},
		{name: "port", mutate: func(m *Material) { m.TLSPort = 0 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			material := validMaterial(t, key, testAdmissionSecret())
			test.mutate(&material)
			got, err := Reference(material)
			if got != "" || !errorsIsInvalidMaterial(err) {
				t.Fatalf("Reference = %q, %v; want ErrInvalidMaterial", got, err)
			}
		})
	}
}

// TestHoldsReportsOnlyRetainedKeys checks retained-key membership and refuses
// unknown or malformed fingerprints, including on a nil keyring.
func TestHoldsReportsOnlyRetainedKeys(t *testing.T) {
	keys := generatedKeys(t)
	keyring := newTestKeyring(t, keys[0])

	if !keyring.Holds(keyFingerprint(t, keys[0])) {
		t.Fatal("Holds refused the retained key")
	}
	if keyring.Holds(keyFingerprint(t, keys[1])) {
		t.Fatal("Holds accepted a key the keyring never retained")
	}
	if keyring.Holds("") || keyring.Holds(strings.Repeat("A", 52)) {
		t.Fatal("Holds accepted a malformed fingerprint")
	}
	var absent *Keyring
	if absent.Holds(keyFingerprint(t, keys[0])) {
		t.Fatal("a nil keyring reported a key")
	}
}

// TestFingerprintMatchesTheMetadataDigest checks the exported derivation equals
// the digest the zone publishes and the keyring indexes by.
func TestFingerprintMatchesTheMetadataDigest(t *testing.T) {
	key := generatedKeys(t)[0]
	got, err := Fingerprint(&key.PublicKey)
	if err != nil {
		t.Fatalf("Fingerprint returned error: %v", err)
	}
	if want := keyFingerprint(t, key); got != want {
		t.Fatalf("Fingerprint = %q, want %q", got, want)
	}
	if !newTestKeyring(t, key).Holds(got) {
		t.Fatal("the keyring does not hold the fingerprint it was built from")
	}
}

// TestReferenceBindsPinsUIDAndEnvelopeOnly checks that the cleanup-side proof
// keys on the UID digest and ciphertext digest alone, so a changed port, key
// or node never blocks a release while a changed UID or envelope always does.
func TestReferenceBindsPinsUIDAndEnvelopeOnly(t *testing.T) {
	key := generatedKeys(t)[0]
	material := validMaterial(t, key, testAdmissionSecret())
	reference := expectedReference(t, material)

	if !ReferenceBinds(reference, material.GameServerUID, material.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds refused the material the reference was minted from")
	}
	otherPort := strings.Replace(reference, ".p"+"8443", ".p9443", 1)
	if otherPort == reference {
		t.Fatalf("test reference %q did not carry the expected port", reference)
	}
	if !ReferenceBinds(otherPort, material.GameServerUID, material.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds demanded the port, which cleanup must not need")
	}
	otherKey := strings.Replace(reference, ".k"+material.WrappingKeyFingerprint, ".k"+strings.Repeat("a", 52), 1)
	if !ReferenceBinds(otherKey, material.GameServerUID, material.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds demanded the key, which cleanup must not need")
	}
	if ReferenceBinds(reference, "other-uid", material.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds accepted a changed UID")
	}
	resealed := validMaterial(t, key, []byte("fedcba9876543210fedcba9876543210"))
	if ReferenceBinds(reference, material.GameServerUID, resealed.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds accepted a re-sealed envelope")
	}
	for _, malformed := range []string{"", "v1.k.u.e", "v2." + reference[3:], reference + ".x"} {
		if ReferenceBinds(malformed, material.GameServerUID, material.AdmissionEnvelope) {
			t.Fatalf("ReferenceBinds accepted malformed reference %q", malformed)
		}
	}
	if ReferenceBinds(reference, material.GameServerUID, "v1.not-base64!") ||
		ReferenceBinds(reference, "uid/1", material.AdmissionEnvelope) {
		t.Fatal("ReferenceBinds accepted malformed material")
	}
}
