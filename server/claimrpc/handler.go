// Package claimrpc provides the inert private HTTPS boundary for zone admission.
// Construction opens no listener and registers no public Nakama RPC.
package claimrpc

import (
	"context"
	"crypto/hmac"
	"crypto/tls"
	"errors"
	"net/http"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

// Config restricts a handler to one namespace, workload trust domain and deadline.
type Config struct {
	Namespace, TrustDomain string
	Timeout                time.Duration
}

// Resolver independently checks the exact GameServer and pinned sealed envelope.
// agonesresources.Adapter implements it; the request never supplies a secret.
type Resolver interface {
	Resolve(context.Context, nakamalease.Lease) (handoff.Allocation, error)
}

type handler struct {
	store    *nakamalease.Store
	resolver Resolver
	config   Config
}

// NewHandler constructs a private claim handler. Its TLS listener must verify
// client certificates against dedicated workload roots. Missing verified peer
// evidence is refused even if the handler is accidentally exposed over HTTP.
func NewHandler(store *nakamalease.Store, resolver Resolver, cfg Config) (http.Handler, error) {
	if store == nil || resolver == nil || !handoffidentity.DNSLabel(cfg.Namespace) || !handoffidentity.DNSSubdomain(cfg.TrustDomain) || cfg.Timeout <= 0 || cfg.Timeout > 30*time.Second {
		return nil, errors.New("claimrpc: invalid private handler configuration")
	}
	return &handler{store: store, resolver: resolver, config: cfg}, nil
}

// ServeHTTP admits only a verified workload request whose exact lease can be
// claimed durably; every refusal uses the same response without private detail.
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost || r.URL.Path != "/v1/claim" || r.URL.RawQuery != "" || r.Header.Get("Content-Type") != "application/json" || !verifiedPeer(r.TLS, time.Now()) {
		refuse(w)
		return
	}
	deadline := time.Now().Add(h.config.Timeout)
	control := http.NewResponseController(w)
	if control.SetReadDeadline(deadline) != nil || control.SetWriteDeadline(deadline) != nil {
		refuse(w)
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), deadline)
	defer cancel()
	request, err := decodeRequest(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil || ctx.Err() != nil {
		refuse(w)
		return
	}
	uri := "spiffe://" + h.config.TrustDomain + "/zone/" + h.config.Namespace + "/" + request.GameServerUID
	peer := r.TLS.PeerCertificates[0]
	if request.Namespace != h.config.Namespace || len(peer.URIs) != 1 || peer.URIs[0].String() != uri {
		refuse(w)
		return
	}
	if err := h.claim(ctx, request); err != nil || ctx.Err() != nil {
		refuse(w)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// claim independently resolves the pinned allocation before comparing its token
// and competing with cleanup on the observed lease version.
func (h *handler) claim(ctx context.Context, request claimRequest) error {
	record, err := h.store.LoadForClaim(ctx, request.LeaseObjectID)
	if err != nil {
		return err
	}
	lease := record.Lease
	digest, err := agones.CorrelationLabel(lease.AttemptID)
	if err != nil || digest != request.AttemptDigest || lease.AllocationID != request.AllocationID || lease.Observer != request.Observer || lease.Staging || lease.Releasing || !time.Now().Before(lease.ExpiresAt) || !admissionref.ReferenceBinds(lease.SecretRef, request.GameServerUID) {
		return ErrRefused
	}
	callCtx, cancel := context.WithDeadline(ctx, lease.ExpiresAt)
	defer cancel()
	allocation, err := h.resolver.Resolve(callCtx, lease)
	if err != nil || callCtx.Err() != nil || allocation.ID != lease.AllocationID || allocation.Observer != lease.Observer || !allocation.LeaseExpiresAt.Equal(lease.ExpiresAt) {
		return ErrRefused
	}
	expected, err := zonesock.MintToken(allocation.AdmissionSecret, lease.AllocationID, lease.Observer, lease.ExpiresAt)
	if err != nil || !hmac.Equal([]byte(expected), []byte(request.Token)) {
		return ErrRefused
	}
	_, err = h.store.ClaimByKey(callCtx, request.LeaseObjectID, record, time.Now())
	if callCtx.Err() != nil {
		return ErrRefused
	}
	return err
}

// TLS verifies chains at handshake time. Check their validity again so a
// pooled connection cannot outlive the workload credentials that authorized it.
func verifiedPeer(state *tls.ConnectionState, now time.Time) bool {
	if state == nil || !state.HandshakeComplete || len(state.PeerCertificates) == 0 {
		return false
	}
	for _, chain := range state.VerifiedChains {
		valid := len(chain) > 0 && chain[0].Equal(state.PeerCertificates[0])
		for _, cert := range chain {
			valid = valid && !now.Before(cert.NotBefore) && now.Before(cert.NotAfter)
		}
		if valid {
			return true
		}
	}
	return false
}

// refuse deliberately gives authentication, decoding and storage failures the
// same public shape so they cannot disclose private workload or lease state.
func refuse(w http.ResponseWriter) { http.Error(w, "zone claim refused", http.StatusForbidden) }

// ErrRefused intentionally carries no workload, token or storage detail.
var ErrRefused = errors.New("claimrpc: zone claim refused")
