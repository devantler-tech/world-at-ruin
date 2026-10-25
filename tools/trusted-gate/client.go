package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

// Client confines read-only historical inspection to the World repository API.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

const gateAPIPath = "/repos/devantler-tech/world-at-ruin"

const gateMaxBody = 8 * 1024 * 1024

// DoJSON rejects redirects, noncanonical endpoints and partial API responses.
// Error messages never include an authenticated response body or token.
func (c Client) DoJSON(ctx context.Context, method, endpoint string, payload, result any) error {
	if method != http.MethodGet || payload != nil {
		return errors.New("historical inspection permits only GET requests without a body")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.Fragment != "" ||
		parsed.RawPath != "" || path.Clean(parsed.Path) != parsed.Path ||
		(parsed.Path != gateAPIPath && !strings.HasPrefix(parsed.Path, gateAPIPath+"/")) {
		return errors.New("API endpoint is outside the canonical World repository")
	}
	base := c.BaseURL
	if base == "" {
		base = "https://api.github.com"
	}
	baseURL, err := url.Parse(base)
	if err != nil || baseURL.Host == "" || baseURL.User != nil || baseURL.RawQuery != "" ||
		baseURL.Fragment != "" || (baseURL.Path != "" && baseURL.Path != "/") ||
		(baseURL.Scheme != "https" && baseURL.Scheme != "http") {
		return errors.New("invalid API origin")
	}
	if baseURL.Scheme == "http" {
		ip := net.ParseIP(baseURL.Hostname())
		if ip == nil || !ip.IsLoopback() {
			return errors.New("API authentication requires HTTPS")
		}
	}
	requestURL := baseURL.ResolveReference(parsed)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return errors.New("API request could not be constructed")
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	transport := http.Client{Timeout: 30 * time.Second}
	if c.HTTP != nil {
		transport = *c.HTTP
		if transport.Timeout <= 0 || transport.Timeout > 30*time.Second {
			transport.Timeout = 30 * time.Second
		}
	}
	transport.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("authenticated API redirects are refused")
	}
	response, err := transport.Do(req)
	if err != nil {
		return errors.New("API request failed")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("API request returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, gateMaxBody+1))
	if err != nil || len(body) > gateMaxBody {
		return errors.New("API response is incomplete or oversized")
	}
	if bytes.Equal(bytes.TrimSpace(body), []byte("null")) {
		return errors.New("API response is null")
	}
	var discard any
	if result == nil {
		result = &discard
	}
	if err := json.Unmarshal(body, result); err != nil {
		return errors.New("API response is not one complete JSON document")
	}
	return nil
}
