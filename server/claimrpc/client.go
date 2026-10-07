package claimrpc

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

// Client implements zoneclaim.PrivateClaimer over one verified HTTPS endpoint.
type Client struct {
	endpoint  string
	http      *http.Client
	transport *http.Transport
}

// NewClient refuses plaintext, unverified TLS and missing client credentials.
// The caller owns certificate rotation; construct a replacement client on reload.
func NewClient(endpoint string, config *tls.Config) (*Client, error) {
	return newClient(endpoint, config, "/v1/claim", 5*time.Second)
}

// newClient validates the fixed private route and owns its isolated transport.
// A zero timeout requires the caller to apply a bounded request context.
func newClient(endpoint string, config *tls.Config, path string, timeout time.Duration) (*Client, error) {
	address, err := url.Parse(endpoint)
	if err != nil || address.Scheme != "https" || address.Host == "" || address.User != nil || address.Path != path || address.RawPath != "" || address.RawQuery != "" || address.Fragment != "" || config == nil || config.InsecureSkipVerify || config.RootCAs == nil || len(config.Certificates) == 0 {
		return nil, ErrRefused
	}
	tlsConfig := config.Clone()
	if tlsConfig.MinVersion < tls.VersionTLS12 {
		tlsConfig.MinVersion = tls.VersionTLS12
	}
	transport := &http.Transport{TLSClientConfig: tlsConfig, MaxConnsPerHost: 4, MaxIdleConnsPerHost: 2, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: timeout, DisableCompression: true}
	client := &http.Client{Transport: transport, Timeout: timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return &Client{endpoint: endpoint, http: client, transport: transport}, nil
}

// Close retires idle connections owned by this client without affecting peers.
func (c *Client) Close() { c.transport.CloseIdleConnections() }

// Claim commits admission or returns a generic refusal. It never retries a
// request or releases a lease after an uncertain response; a caller may replay
// the identical claim through the storage owner's idempotent transition.
func (c *Client) Claim(ctx context.Context, binding agones.ClaimBinding, token string, observer sim.EntityID) error {
	request := claimRequest{Namespace: binding.Namespace, AllocationID: binding.AllocationID, GameServerUID: binding.GameServerUID, LeaseObjectID: binding.LeaseObjectID, AttemptDigest: binding.AttemptDigest, Token: token, Observer: observer}
	if !validRequest(request) {
		return ErrRefused
	}
	body, err := json.Marshal(request)
	if err != nil {
		return ErrRefused
	}
	result, status, _, err := c.send(ctx, c.endpoint, body, 1025)
	if err != nil || status != http.StatusNoContent || len(result) != 0 {
		return ErrRefused
	}
	return nil
}

// ClaimWithReceipt explicitly selects the additive receipt protocol. It never
// falls back to a receipt-free acknowledgement or refreshes an old generation.
func (c *Client) ClaimWithReceipt(ctx context.Context, binding agones.ClaimBinding, token string, observer sim.EntityID) (zoneclaim.Receipt, error) {
	request := claimRequest{Namespace: binding.Namespace, AllocationID: binding.AllocationID, GameServerUID: binding.GameServerUID, LeaseObjectID: binding.LeaseObjectID, AttemptDigest: binding.AttemptDigest, Token: token, Observer: observer}
	if !validRequest(request) {
		return zoneclaim.Receipt{}, ErrRefused
	}
	body, err := json.Marshal(request)
	if err != nil {
		return zoneclaim.Receipt{}, ErrRefused
	}
	result, status, contentType, err := c.send(ctx, strings.TrimSuffix(c.endpoint, "/v1/claim")+"/v2/claim", body, 4097)
	if err != nil || status != http.StatusOK || contentType != "application/json" || len(result) > 4096 {
		return zoneclaim.Receipt{}, ErrRefused
	}
	receipt, err := decodeReceipt(bytes.NewReader(result))
	if err != nil || !receipt.Matches(binding, observer) {
		return zoneclaim.Receipt{}, ErrRefused
	}
	return receipt, nil
}

// send uses only constructor-validated destinations or their fixed private
// version routes. No player payload can choose a host, path or redirect.
func (c *Client) send(ctx context.Context, endpoint string, body []byte, limit int64) ([]byte, int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, 0, "", ErrRefused
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(req)
	if err != nil {
		return nil, 0, "", ErrRefused
	}
	defer func() { _ = response.Body.Close() }()
	result, err := io.ReadAll(io.LimitReader(response.Body, limit))
	if err != nil || ctx.Err() != nil {
		return nil, 0, "", ErrRefused
	}
	return result, response.StatusCode, response.Header.Get("Content-Type"), nil
}
