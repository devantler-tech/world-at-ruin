package claimrpc

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/sim"
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
	address, err := url.Parse(endpoint)
	if err != nil || address.Scheme != "https" || address.Host == "" || address.User != nil || address.Path != "/v1/claim" || address.RawPath != "" || address.RawQuery != "" || address.Fragment != "" || config == nil || config.InsecureSkipVerify || config.RootCAs == nil || len(config.Certificates) == 0 {
		return nil, ErrRefused
	}
	tlsConfig := config.Clone()
	if tlsConfig.MinVersion < tls.VersionTLS12 {
		tlsConfig.MinVersion = tls.VersionTLS12
	}
	transport := &http.Transport{TLSClientConfig: tlsConfig, MaxConnsPerHost: 4, MaxIdleConnsPerHost: 2, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: 5 * time.Second, DisableCompression: true}
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
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
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return ErrRefused
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(req)
	if err != nil {
		return ErrRefused
	}
	defer func() { _ = response.Body.Close() }()
	result, err := io.ReadAll(io.LimitReader(response.Body, 1025))
	if err != nil || ctx.Err() != nil || response.StatusCode != http.StatusNoContent || len(result) != 0 {
		return ErrRefused
	}
	return nil
}
