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
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	sdkproto "agones.dev/agones/pkg/sdk"
)

const (
	AdmissionEnvelopeAnnotation = "agones.dev/sdk-war-admission-envelope"
	AdmissionKeyAnnotation      = "agones.dev/sdk-war-admission-key"
	AdmissionReadyLabel         = "agones.dev/sdk-war-admission-ready"
	ClaimLocatorAnnotation      = "world-at-ruin.dev/handoff-claim"

	admissionEnvelopeSuffix = "war-admission-envelope"
	admissionKeySuffix      = "war-admission-key"
	admissionReadySuffix    = "war-admission-ready"
	admissionEnvelopePrefix = "v1."
	admissionReadyPrefix    = "v1-"
	admissionSecretBytes    = 32
	minimumRSAKeyBits       = 3072
	defaultObserveTimeout   = 10 * time.Second
)

type AdmissionConfig struct {
	// WrappingPublicKeyPEM is one PEM-encoded PKIX RSA public key. PKCS #1
	// input is deliberately refused because the protocol fingerprints the
	// canonical SubjectPublicKeyInfo representation.
	WrappingPublicKeyPEM []byte
	// Random supplies the 32 admission-secret bytes. Nil uses crypto/rand.
	Random io.Reader
	// ObservationTimeout bounds the WatchGameServer metadata barrier.
	ObservationTimeout time.Duration
}

// PreparedAdmission owns one sidecar conversation whose identity-bound
// admission envelope is published and observed, but whose GameServer has not
// yet been marked Ready. The socket owner calls Ready only after it is serving.
type PreparedAdmission struct {
	mu           sync.Mutex
	ctx          context.Context
	lifecycleCfg Config
	sdk          sidecar
	secret       [admissionSecretBytes]byte
	allocationID string
	activated    bool
	shutDown     bool
	binding      *claimBindingState
}

// PrepareAdmission generates, seals, publishes, and observes one
// allocation-scoped admission secret while the GameServer is Starting. It
// never calls Ready; that remains the serving boundary's responsibility.
func PrepareAdmission(ctx context.Context, lifecycleCfg Config, cfg AdmissionConfig) (*PreparedAdmission, error) {
	publicKey, fingerprint, err := parseWrappingPublicKey(cfg.WrappingPublicKeyPEM)
	if err != nil {
		return nil, err
	}
	s, err := dial()
	if err != nil {
		return nil, fmt.Errorf("agones: dial sidecar: %w", err)
	}
	var secret [admissionSecretBytes]byte
	defer clear(secret[:])
	fail := func(cause error) error {
		if shutdownErr := s.Shutdown(); shutdownErr != nil {
			return fmt.Errorf("%w; shutdown after refusal also failed", cause)
		}
		return cause
	}

	gs, err := s.GameServer()
	if err != nil {
		return nil, fail(errors.New("agones: read GameServer identity failed"))
	}
	identity, err := startingIdentity(gs)
	if err != nil {
		return nil, fail(err)
	}

	randomSource := cfg.Random
	if randomSource == nil {
		randomSource = rand.Reader
	}
	if _, err := io.ReadFull(randomSource, secret[:]); err != nil {
		return nil, fail(errors.New("agones: generate admission secret failed"))
	}
	label := admissionOAEPLabel(identity, fingerprint)
	ciphertext, err := rsa.EncryptOAEP(sha256.New(), randomSource, publicKey, secret[:], label)
	if err != nil {
		return nil, fail(errors.New("agones: seal admission secret failed"))
	}
	envelope := admissionEnvelopePrefix + base64.RawURLEncoding.EncodeToString(ciphertext)
	readyValue := admissionReadyPrefix + fingerprint
	watchCtx, stopWatch := context.WithCancel(ctx)
	keepWatch := false
	defer func() {
		if !keepWatch {
			stopWatch()
		}
	}()
	binding := &claimBindingState{
		ctx: watchCtx, cancel: stopWatch, identity: identity, envelope: envelope,
		fingerprint: fingerprint, readyValue: readyValue,
	}

	observed := make(chan struct{}, 1)
	if err := s.WatchGameServer(watchCtx, func(current *sdkproto.GameServer) {
		binding.observe(current)
		if admissionMetadataMatches(current, identity, envelope, fingerprint, readyValue) {
			select {
			case observed <- struct{}{}:
			default:
			}
		}
	}, binding.close); err != nil {
		return nil, fail(errors.New("agones: watch GameServer admission metadata failed"))
	}
	if err := s.SetAnnotation(admissionEnvelopeSuffix, envelope); err != nil {
		return nil, fail(errors.New("agones: publish admission envelope failed"))
	}
	if err := s.SetAnnotation(admissionKeySuffix, fingerprint); err != nil {
		return nil, fail(errors.New("agones: publish admission key fingerprint failed"))
	}
	if err := s.SetLabel(admissionReadySuffix, readyValue); err != nil {
		return nil, fail(errors.New("agones: publish admission readiness label failed"))
	}

	timeout := cfg.ObservationTimeout
	if timeout <= 0 {
		timeout = defaultObserveTimeout
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-watchCtx.Done():
		return nil, fail(fmt.Errorf("agones: observe admission metadata: %w", context.Cause(watchCtx)))
	case <-timer.C:
		return nil, fail(fmt.Errorf("agones: observe admission metadata: timed out after %s", timeout))
	case <-observed:
	}
	if !binding.live() {
		return nil, fail(errors.New("agones: admission observation watch ended"))
	}

	keepWatch = true
	return &PreparedAdmission{
		ctx:          ctx,
		lifecycleCfg: lifecycleCfg,
		sdk:          s,
		secret:       secret,
		allocationID: identity.name,
		binding:      binding,
	}, nil
}

type gameServerIdentity struct {
	namespace string
	name      string
	uid       string
}

func startingIdentity(gs *sdkproto.GameServer) (gameServerIdentity, error) {
	if gs == nil || gs.GetObjectMeta() == nil || gs.GetStatus() == nil {
		return gameServerIdentity{}, fmt.Errorf("agones: GameServer identity is incomplete")
	}
	meta := gs.GetObjectMeta()
	identity := gameServerIdentity{
		namespace: meta.GetNamespace(),
		name:      meta.GetName(),
		uid:       meta.GetUid(),
	}
	if identity.namespace == "" ||
		identity.name == "" ||
		identity.uid == "" ||
		strings.ContainsRune(identity.namespace, '\x00') ||
		strings.ContainsRune(identity.name, '\x00') ||
		strings.ContainsRune(identity.uid, '\x00') {
		return gameServerIdentity{}, fmt.Errorf("agones: GameServer identity is invalid")
	}
	if state := gs.GetStatus().GetState(); state != "Starting" {
		return gameServerIdentity{}, fmt.Errorf(
			"agones: refuse admission bootstrap for GameServer state %q: expected Starting",
			state,
		)
	}
	return identity, nil
}

func parseWrappingPublicKey(data []byte) (*rsa.PublicKey, string, error) {
	block, rest := pem.Decode(data)
	if block == nil ||
		block.Type != "PUBLIC KEY" ||
		len(block.Headers) != 0 ||
		len(bytes.TrimSpace(rest)) != 0 {
		return nil, "", fmt.Errorf("agones: wrapping public key must be one PEM PKIX PUBLIC KEY")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, "", fmt.Errorf("agones: parse wrapping public key: %w", err)
	}
	publicKey, ok := parsed.(*rsa.PublicKey)
	if !ok || publicKey.N.BitLen() < minimumRSAKeyBits {
		return nil, "", fmt.Errorf("agones: wrapping public key must be RSA with at least %d bits", minimumRSAKeyBits)
	}
	der, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return nil, "", fmt.Errorf("agones: canonicalize wrapping public key: %w", err)
	}
	digest := sha256.Sum256(der)
	fingerprint := strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
	return publicKey, fingerprint, nil
}

func admissionOAEPLabel(identity gameServerIdentity, fingerprint string) []byte {
	return []byte(strings.Join([]string{
		"world-at-ruin/zone-admission/v1",
		identity.namespace,
		identity.name,
		identity.uid,
		fingerprint,
	}, "\x00"))
}

func admissionMetadataMatches(
	gs *sdkproto.GameServer,
	identity gameServerIdentity,
	envelope string,
	fingerprint string,
	readyValue string,
) bool {
	return admissionIdentityMetadataMatches(gs, identity, envelope, fingerprint, readyValue) &&
		gs.GetStatus().GetState() == "Starting"
}

func admissionIdentityMetadataMatches(
	gs *sdkproto.GameServer,
	identity gameServerIdentity,
	envelope string,
	fingerprint string,
	readyValue string,
) bool {
	if gs == nil || gs.GetObjectMeta() == nil || gs.GetStatus() == nil {
		return false
	}
	meta := gs.GetObjectMeta()
	return meta.GetNamespace() == identity.namespace &&
		meta.GetName() == identity.name &&
		meta.GetUid() == identity.uid &&
		meta.GetAnnotations()[AdmissionEnvelopeAnnotation] == envelope &&
		meta.GetAnnotations()[AdmissionKeyAnnotation] == fingerprint &&
		meta.GetLabels()[AdmissionReadyLabel] == readyValue
}

func (p *PreparedAdmission) AllocationID() string { return p.allocationID }

// Secret returns a copy of the in-memory admission bytes for the zone's HMAC
// verifier. It is never serialized or logged by this package.
func (p *PreparedAdmission) Secret() []byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]byte(nil), p.secret[:]...)
}

// Ready marks the observed GameServer Ready and transfers lifecycle shutdown
// ownership to the returned Lifecycle.
func (p *PreparedAdmission) Ready() (*Lifecycle, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.shutDown {
		return nil, errors.New("agones: prepared admission is already shut down")
	}
	if p.activated {
		return nil, errors.New("agones: prepared admission is already ready")
	}
	if !p.binding.live() {
		return nil, errors.New("agones: admission observation watch ended before readiness")
	}
	if err := p.sdk.Ready(); err != nil {
		return nil, errors.New("agones: mark ready failed")
	}
	p.activated = true
	return startHealthWithBinding(p.ctx, p.sdk, p.lifecycleCfg, p.binding), nil
}

// Shutdown abandons an unactivated prepared GameServer. Once Ready succeeds,
// shutdown ownership belongs to the returned Lifecycle.
func (p *PreparedAdmission) Shutdown() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activated {
		return errors.New("agones: prepared admission shutdown ownership transferred to Lifecycle")
	}
	if p.shutDown {
		return errors.New("agones: prepared admission is already shut down")
	}
	p.shutDown = true
	p.binding.close()
	defer clear(p.secret[:])
	if err := p.sdk.Shutdown(); err != nil {
		return errors.New("agones: shutdown prepared admission failed")
	}
	return nil
}
