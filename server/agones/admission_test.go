package agones

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

type failingReader struct {
	err error
}

func (r failingReader) Read([]byte) (int, error) {
	return 0, r.err
}

func deterministicAdmissionRandom(secret []byte) io.Reader {
	return io.MultiReader(
		bytes.NewReader(secret),
		bytes.NewReader(bytes.Repeat([]byte{0x24}, sha256.Size)),
	)
}

func wrappingKey(t *testing.T) (*rsa.PrivateKey, []byte) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatalf("generate wrapping key: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal wrapping key: %v", err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
}

func TestPrepareAdmissionObservesIdentityBoundEnvelopeBeforeReady(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	f.HoldWatchEvents()
	privateKey, publicPEM := wrappingKey(t)
	randomSecret := bytes.Repeat([]byte{0x42}, 32)

	type result struct {
		prepared *PreparedAdmission
		err      error
	}
	done := make(chan result, 1)
	go func() {
		prepared, err := PrepareAdmission(
			context.Background(),
			Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf},
			AdmissionConfig{
				WrappingPublicKeyPEM: publicPEM,
				Random:               deterministicAdmissionRandom(randomSecret),
				ObservationTimeout:   5 * time.Second,
			},
		)
		done <- result{prepared: prepared, err: err}
	}()

	waitFor(t, 5*time.Second, func() bool {
		return f.WatchCalls() == 1 &&
			f.Annotation(AdmissionEnvelopeAnnotation) != "" &&
			f.Annotation(AdmissionKeyAnnotation) != "" &&
			f.Label(AdmissionReadyLabel) != ""
	}, "the watch and all three metadata writes")
	select {
	case got := <-done:
		t.Fatalf("PrepareAdmission returned before WatchGameServer yielded the exact metadata: %+v", got)
	case <-time.After(100 * time.Millisecond):
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls before the observation barrier = %d, want 0", got)
	}

	f.ReleaseWatchEvents()
	got := <-done
	if got.err != nil {
		t.Fatalf("PrepareAdmission: %v", got.err)
	}
	if got.prepared.AllocationID() != "zone-17" {
		t.Fatalf("allocation ID = %q, want GameServer name zone-17", got.prepared.AllocationID())
	}
	if secret := got.prepared.Secret(); !bytes.Equal(secret, randomSecret) {
		t.Fatalf("prepared secret = %x, want the 32 bytes supplied by the random source", secret)
	}

	publicDER, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key for expected fingerprint: %v", err)
	}
	digest := sha256.Sum256(publicDER)
	wantFingerprint := strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
	if gotKey := f.Annotation(AdmissionKeyAnnotation); gotKey != wantFingerprint {
		t.Fatalf("key annotation = %q, want %q", gotKey, wantFingerprint)
	}
	if gotReady := f.Label(AdmissionReadyLabel); gotReady != "v1-"+wantFingerprint {
		t.Fatalf("ready label = %q, want v1 fingerprint", gotReady)
	}

	envelope := f.Annotation(AdmissionEnvelopeAnnotation)
	if !strings.HasPrefix(envelope, "v1.") {
		t.Fatalf("envelope annotation = %q, want versioned v1 ciphertext", envelope)
	}
	ciphertext, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(envelope, "v1."))
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	wantLabel := []byte(
		"world-at-ruin/zone-admission/v1\x00games\x00zone-17\x00uid-17\x00" +
			wantFingerprint,
	)
	plaintext, err := rsa.DecryptOAEP(sha256.New(), rand.Reader, privateKey, ciphertext, wantLabel)
	if err != nil {
		t.Fatalf("decrypt identity-bound envelope: %v", err)
	}
	if !bytes.Equal(plaintext, randomSecret) {
		t.Fatalf("envelope plaintext = %x, want generated admission secret", plaintext)
	}
	siblingLabel := []byte(
		"world-at-ruin/zone-admission/v1\x00games\x00zone-18\x00uid-18\x00" +
			wantFingerprint,
	)
	if _, err := rsa.DecryptOAEP(sha256.New(), rand.Reader, privateKey, ciphertext, siblingLabel); err == nil {
		t.Fatal("sibling GameServer label decrypted the envelope; want identity-bound refusal")
	}

	lifecycle, err := got.prepared.Ready()
	if err != nil {
		t.Fatalf("Ready: %v", err)
	}
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls after activating prepared admission = %d, want exactly 1", got)
	}
	waitFor(t, 5*time.Second, func() bool { return f.HealthBeats() >= 1 }, "the first health beat")
	if err := lifecycle.Shutdown(); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
}

func TestPrepareAdmissionAcceptsDNSSubdomainGameServerName(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17.games", "uid-17", "Starting")
	_, publicPEM := wrappingKey(t)

	prepared, err := PrepareAdmission(
		context.Background(),
		Config{Logf: t.Logf},
		AdmissionConfig{
			WrappingPublicKeyPEM: publicPEM,
			Random:               deterministicAdmissionRandom(bytes.Repeat([]byte{0x42}, 32)),
			ObservationTimeout:   time.Second,
		},
	)
	if err != nil {
		t.Fatalf("PrepareAdmission with DNS-subdomain GameServer name: %v", err)
	}
	if prepared.AllocationID() != "zone-17.games" {
		t.Fatalf("allocation ID = %q, want full GameServer name", prepared.AllocationID())
	}
	if err := prepared.Shutdown(); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
}

func TestPrepareAdmissionShutsDownInsteadOfRotatingAnAllocatableGameServer(t *testing.T) {
	for _, state := range []string{"Ready", "Reserved", "Allocated"} {
		t.Run(state, func(t *testing.T) {
			f := startFake(t, nil)
			f.SetGameServer("games", "zone-17", "uid-17", state)
			_, publicPEM := wrappingKey(t)

			prepared, err := PrepareAdmission(
				context.Background(),
				Config{Logf: t.Logf},
				AdmissionConfig{
					WrappingPublicKeyPEM: publicPEM,
					Random:               deterministicAdmissionRandom(bytes.Repeat([]byte{0x42}, 32)),
					ObservationTimeout:   time.Second,
				},
			)
			if err == nil {
				t.Fatalf("PrepareAdmission succeeded for %s GameServer: %+v", state, prepared)
			}
			if got := f.ShutdownCalls(); got != 1 {
				t.Fatalf("Shutdown calls for %s GameServer = %d, want exactly 1", state, got)
			}
			if got := f.ReadyCalls(); got != 0 {
				t.Fatalf("Ready calls for %s GameServer = %d, want 0", state, got)
			}
			if got := f.Annotation(AdmissionEnvelopeAnnotation); got != "" {
				t.Fatalf("%s GameServer envelope changed to %q; want no rotation", state, got)
			}
		})
	}
}

func TestPrepareAdmissionDoesNotEchoSecretGenerationFailure(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	_, publicPEM := wrappingKey(t)
	leakMarker := strings.Repeat("42", 32)

	_, err := PrepareAdmission(
		context.Background(),
		Config{Logf: t.Logf},
		AdmissionConfig{
			WrappingPublicKeyPEM: publicPEM,
			Random:               failingReader{err: errors.New("random source echoed " + leakMarker)},
			ObservationTimeout:   time.Second,
		},
	)
	if err == nil {
		t.Fatal("PrepareAdmission succeeded after the random source failed")
	}
	if strings.Contains(err.Error(), leakMarker) {
		t.Fatalf("secret-generation error echoed admission material: %v", err)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1", got)
	}
}

func TestPrepareAdmissionDoesNotEchoEnvelopeRandomFailure(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	_, publicPEM := wrappingKey(t)
	leakMarker := strings.Repeat("24", 32)
	randomSource := io.MultiReader(
		bytes.NewReader(bytes.Repeat([]byte{0x42}, 32)),
		failingReader{err: errors.New("OAEP random source echoed " + leakMarker)},
	)

	prepared, err := PrepareAdmission(
		context.Background(),
		Config{Logf: t.Logf},
		AdmissionConfig{
			WrappingPublicKeyPEM: publicPEM,
			Random:               randomSource,
			ObservationTimeout:   time.Second,
		},
	)
	if prepared != nil {
		t.Cleanup(func() { _ = prepared.Shutdown() })
	}
	if err == nil {
		t.Fatal("PrepareAdmission succeeded after OAEP randomness failed")
	}
	if strings.Contains(err.Error(), leakMarker) {
		t.Fatalf("envelope-randomness error echoed admission material: %v", err)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1", got)
	}
}

func TestPrepareAdmissionDoesNotEchoMetadataFailure(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	_, publicPEM := wrappingKey(t)
	leakMarker := strings.Repeat("42", 32)
	f.FailSetAnnotation(errors.New("sidecar echoed " + leakMarker))

	_, err := PrepareAdmission(
		context.Background(),
		Config{Logf: t.Logf},
		AdmissionConfig{
			WrappingPublicKeyPEM: publicPEM,
			Random:               deterministicAdmissionRandom(bytes.Repeat([]byte{0x42}, 32)),
			ObservationTimeout:   time.Second,
		},
	)
	if err == nil {
		t.Fatal("PrepareAdmission succeeded after metadata publication failed")
	}
	if strings.Contains(err.Error(), leakMarker) {
		t.Fatalf("metadata error echoed admission material: %v", err)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1", got)
	}
}

func TestPrepareAdmissionTimesOutWithoutObservedMetadata(t *testing.T) {
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	f.HoldWatchEvents()
	_, publicPEM := wrappingKey(t)

	_, err := PrepareAdmission(
		context.Background(),
		Config{Logf: t.Logf},
		AdmissionConfig{
			WrappingPublicKeyPEM: publicPEM,
			Random:               deterministicAdmissionRandom(bytes.Repeat([]byte{0x42}, 32)),
			ObservationTimeout:   25 * time.Millisecond,
		},
	)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("PrepareAdmission error = %v, want observation timeout", err)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1", got)
	}
}
