package zonesock

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// TokenVerifier checks the allocation-scoped admission token a peer presents
// during the WebSocket upgrade and returns the observer entity the connection
// is allocated to replicate. Verification is fail-closed: any error refuses
// the peer before it attaches. The zone server only ever verifies — minting
// belongs to the allocation/handoff step (a later child of the server epic),
// which is why the verifier is an interface: the interim HMAC mechanism below
// can be swapped without touching the socket.
type TokenVerifier interface {
	Verify(token string) (sim.EntityID, error)
}

// Admission failures, distinguishable for callers and tests. The HTTP refusal
// stays a generic 401 either way — which check failed is not the peer's
// business.
var (
	ErrTokenFormat  = errors.New("zonesock: malformed admission token")
	ErrTokenExpired = errors.New("zonesock: admission token expired")
	ErrTokenForged  = errors.New("zonesock: admission token signature mismatch")
)

// tokenPrefix versions the token layout, so a future mechanism can change the
// format without ambiguity. Independent of wire.Version — tokens and frames
// evolve separately.
const tokenPrefix = "v1"

// minSecretBytes is the minimum admission-secret length. 32 bytes matches the
// HMAC-SHA256 output size, below which the MAC's strength degrades; a shorter
// secret is refused outright rather than silently accepted.
const minSecretBytes = 32

// MintToken mints an admission token binding one observer to one allocation
// window: "v1.<observer>.<unix expiry>.<hex hmac-sha256>". Exported for the
// allocation/handoff step and for tests; the zone server itself never mints.
func MintToken(secret []byte, observer sim.EntityID, expiry time.Time) (string, error) {
	if len(secret) < minSecretBytes {
		return "", fmt.Errorf("zonesock: admission secret is %d bytes, need at least %d", len(secret), minSecretBytes)
	}
	payload := fmt.Sprintf("%s.%d.%d", tokenPrefix, uint64(observer), expiry.Unix())
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payload))
	return payload + "." + hex.EncodeToString(mac.Sum(nil)), nil
}

// HMACVerifier is the interim TokenVerifier: HMAC-SHA256 over the token's
// public fields with a secret shared between the minting side and the zone
// server. It verifies integrity before trusting any field, so a forged token
// reports forged even when its expiry also lies.
type HMACVerifier struct {
	secret []byte
	now    func() time.Time
}

// NewHMACVerifier builds a verifier from the shared secret, refusing one too
// short to carry HMAC-SHA256's strength.
func NewHMACVerifier(secret []byte) (*HMACVerifier, error) {
	if len(secret) < minSecretBytes {
		return nil, fmt.Errorf("zonesock: admission secret is %d bytes, need at least %d", len(secret), minSecretBytes)
	}
	return &HMACVerifier{secret: append([]byte(nil), secret...), now: time.Now}, nil
}

// Verify checks token and returns the observer it admits. Order matters: the
// signature is verified before the expiry is trusted, because an attacker
// controls every unverified field.
func (v *HMACVerifier) Verify(token string) (sim.EntityID, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 4 || parts[0] != tokenPrefix {
		return 0, ErrTokenFormat
	}
	observer, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return 0, ErrTokenFormat
	}
	expiry, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return 0, ErrTokenFormat
	}
	sig, err := hex.DecodeString(parts[3])
	if err != nil {
		return 0, ErrTokenFormat
	}
	payload := parts[0] + "." + parts[1] + "." + parts[2]
	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(payload))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return 0, ErrTokenForged
	}
	if !v.now().Before(time.Unix(expiry, 0)) {
		return 0, ErrTokenExpired
	}
	return sim.EntityID(observer), nil
}
