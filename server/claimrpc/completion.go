package claimrpc

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

// SessionEndVerifier independently establishes irreversible termination of the
// exact original allocation lifetime, including that its old process cannot
// resume authority. Its fence must remain effective throughout cleanup. Receipt
// possession, mTLS identity, socket loss, expiry and Pod absence are insufficient.
// No production implementation or automatic shutdown hook is supplied here.
type SessionEndVerifier interface {
	VerifyEnded(context.Context, zoneclaim.Receipt) error
}

type completionHandler struct {
	store    *nakamalease.Store
	verifier SessionEndVerifier
	cleanup  func(context.Context, nakamalease.Lease) error
	config   Config
}

// NewCompletionHandler constructs an inert private boundary. It opens no
// listener and refuses construction without independent termination authority.
func NewCompletionHandler(store *nakamalease.Store, verifier SessionEndVerifier, cleanup func(context.Context, nakamalease.Lease) error, cfg Config) (http.Handler, error) {
	if store == nil || verifier == nil || cleanup == nil || !handoffidentity.DNSLabel(cfg.Namespace) || !handoffidentity.DNSSubdomain(cfg.TrustDomain) || cfg.Timeout <= 0 || cfg.Timeout > 30*time.Second {
		return nil, ErrRefused
	}
	return &completionHandler{store: store, verifier: verifier, cleanup: cleanup, config: cfg}, nil
}

func (h *completionHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost || r.URL.Path != "/v1/session/end" || r.URL.RawPath != "" || r.URL.RawQuery != "" || r.Header.Get("Content-Type") != "application/json" || !verifiedPeer(r.TLS, time.Now()) {
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
	receipt, err := decodeReceipt(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil || ctx.Err() != nil || receipt.Namespace != h.config.Namespace {
		refuse(w)
		return
	}
	uri := "spiffe://" + h.config.TrustDomain + "/zone/" + h.config.Namespace + "/" + receipt.Fence.GameServerUID
	peer := r.TLS.PeerCertificates[0]
	if len(peer.URIs) != 1 || peer.URIs[0].String() != uri {
		refuse(w)
		return
	}
	// Never invoke external authority for an observed incompatible reader or
	// different owner. Absence still requires proof before acknowledging replay.
	current, err := h.store.LoadForClaim(ctx, receipt.Fence.LeaseObjectID)
	if err != nil && !errors.Is(err, nakamalease.ErrNotFound) {
		refuse(w)
		return
	}
	if err == nil && !completionMatches(current, receipt) {
		refuse(w)
		return
	}
	if ctx.Err() != nil || h.verifier.VerifyEnded(ctx, receipt) != nil || ctx.Err() != nil {
		refuse(w)
		return
	}
	// EndSession freshly revalidates the durable owner after authority lookup,
	// then consumes only the original version/generation before UID cleanup.
	if h.store.EndSession(ctx, receipt.Fence, h.cleanup) != nil || ctx.Err() != nil {
		refuse(w)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func completionMatches(record nakamalease.Record, r zoneclaim.Receipt) bool {
	l := record.Lease
	digest, err := agones.CorrelationLabel(l.AttemptID)
	return err == nil && !l.ReaderOnly() && !l.Staging && !l.Releasing && record.Version == r.Fence.LeaseVersion &&
		l.Observer == r.Observer && !l.ClaimedAt.IsZero() && l.ClaimedAt.Equal(r.Fence.Generation) &&
		digest == r.Fence.AttemptDigest && l.AllocationID == r.Fence.AllocationID && admissionref.ReferenceBinds(l.SecretRef, r.Fence.GameServerUID)
}

// CompletionClient sends an explicit completion to one verified private service.
// It is separately constructed and never changes the legacy claim client's path.
type CompletionClient struct{ client *Client }

func NewCompletionClient(endpoint string, config *tls.Config) (*CompletionClient, error) {
	client, err := newClient(endpoint, config, "/v1/session/end")
	if err != nil {
		return nil, err
	}
	return &CompletionClient{client: client}, nil
}

func (c *CompletionClient) Close() { c.client.Close() }

// Complete sends once. A lost or refused acknowledgement never invokes cleanup
// locally, refreshes the descriptor, follows a redirect or automatically retries.
func (c *CompletionClient) Complete(ctx context.Context, r zoneclaim.Receipt) error {
	body, err := json.Marshal(receiptDocument(r))
	if err != nil {
		return ErrRefused
	}
	if _, err := decodeReceipt(bytes.NewReader(body)); err != nil {
		return ErrRefused
	}
	result, status, _, err := c.client.send(ctx, c.client.endpoint, body, 1025)
	if err != nil || status != http.StatusNoContent || len(result) != 0 {
		return ErrRefused
	}
	return nil
}
