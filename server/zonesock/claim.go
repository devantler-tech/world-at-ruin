package zonesock

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// AdmissionClaimer commits the exact durable handoff before socket admission.
// Implementations must honor context cancellation and independently verify the
// token against server-owned lease state; observer is a local assertion only.
type AdmissionClaimer interface {
	Claim(context.Context, string, sim.EntityID) error
}

// Reject deterministic handshake failures before committing a durable claim.
// Accept remains the final protocol authority; a later network failure retains
// the claim for the server's separate fenced session-end recovery path.
func validClaimHandshake(r *http.Request) bool {
	if r.Method != http.MethodGet || !r.ProtoAtLeast(1, 1) ||
		!headerHasToken(r.Header, "Connection", "Upgrade") ||
		!headerHasToken(r.Header, "Upgrade", "websocket") ||
		r.Header.Get("Sec-WebSocket-Version") != "13" {
		return false
	}
	keys := r.Header.Values("Sec-WebSocket-Key")
	if len(keys) != 1 {
		return false
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(keys[0]))
	if err != nil || len(key) != 16 {
		return false
	}
	if raw := r.Header.Get("Origin"); raw != "" {
		origin, err := url.Parse(raw)
		if err != nil || origin.Host == "" || !strings.EqualFold(origin.Host, r.Host) {
			return false
		}
	}
	return true
}

func headerHasToken(header http.Header, name, token string) bool {
	for _, value := range header.Values(name) {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

// NewClaimedHub requires a durable handoff claim in addition to local token
// verification. NewHub remains the local-development admission constructor.
func NewClaimedHub(cfg Config, claim AdmissionClaimer, timeout time.Duration) (*Hub, error) {
	if claim == nil {
		return nil, errors.New("zonesock: admission claimant is required")
	}
	if timeout < 0 || timeout > 30*time.Second {
		return nil, errors.New("zonesock: claim timeout must be between zero and thirty seconds")
	}
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	hub, err := NewHub(cfg)
	if err != nil {
		return nil, err
	}
	hub.claim = claim
	hub.claimTimeout = timeout
	return hub, nil
}

func (h *Hub) claimAdmission(parent context.Context, token string, observer sim.EntityID) bool {
	ctx, cancel := context.WithTimeout(parent, h.claimTimeout)
	defer cancel()
	if ctx.Err() != nil || h.claim.Claim(ctx, token, observer) != nil || ctx.Err() != nil {
		return false
	}
	// A claim can consume the token's remaining lifetime or acknowledge a
	// canceled request. A durable success is retained but grants no late socket.
	currentObserver, err := h.cfg.Verifier.Verify(token)
	return err == nil && currentObserver == observer && ctx.Err() == nil
}
