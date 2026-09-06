package allocatordiscovery

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"sync"

	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	discoveryclient "k8s.io/client-go/kubernetes/typed/discovery/v1"
	"k8s.io/client-go/rest"
)

const maxResponseBytes = 4 << 20

// New binds namespaced reads to an owned client that limits response bytes
// before API decoding. Each operation may consume at most 4 MiB across all
// pages, collections and retries, including decompressed and error responses.
// kubeConfig.Timeout must be positive and bounds each request; callers supply
// an operation context to bound the entire discovery. No watcher is registered.
func New(kubeConfig *rest.Config, config Config) (*Reader, error) {
	if kubeConfig == nil || kubeConfig.Timeout <= 0 {
		return nil, ErrInvalidArgument
	}
	cfg := rest.CopyConfig(kubeConfig)
	client, err := rest.HTTPClientFor(cfg)
	if err != nil {
		return nil, ErrInvalidArgument
	}
	// HTTPClientFor may return a shared client. Never mutate its transport.
	owned := *client
	transport := owned.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	owned.Transport = boundedTransport{next: transport}
	core, err := coreclient.NewForConfigAndClient(cfg, &owned)
	if err != nil {
		return nil, ErrInvalidArgument
	}
	discovery, err := discoveryclient.NewForConfigAndClient(cfg, &owned)
	if err != nil {
		return nil, ErrInvalidArgument
	}
	return newReader(core, discovery, config)
}

type responseBudgetKey struct{}

// responseBudget belongs to one operation, even when a Reader is shared.
type responseBudget struct {
	mu        sync.Mutex
	remaining int64
}

// withResponseBudget gives later operations a fresh allowance after failures.
func withResponseBudget(ctx context.Context) context.Context {
	return context.WithValue(ctx, responseBudgetKey{}, &responseBudget{remaining: maxResponseBytes})
}

type boundedTransport struct{ next http.RoundTripper }

// RoundTrip buffers only a bounded, already decompressed response before the
// typed client can allocate nested API objects. The private context budget is
// shared by all requests in the operation, including retries on HTTP errors.
func (t boundedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	budget, ok := req.Context().Value(responseBudgetKey{}).(*responseBudget)
	if !ok {
		return nil, ErrObservation
	}
	budget.mu.Lock()
	defer budget.mu.Unlock()
	if budget.remaining <= 0 {
		return nil, ErrObservation
	}
	response, err := t.next.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	if response == nil || response.Body == nil {
		return nil, ErrObservation
	}
	originalBody := response.Body
	defer func() { _ = originalBody.Close() }()
	// The standard transport removes Content-Encoding after decompression.
	// An encoding left by a custom transport must never bypass the byte cap.
	if encoding := response.Header.Get("Content-Encoding"); (encoding != "" && encoding != "identity") || response.ContentLength > budget.remaining {
		budget.remaining = 0
		return nil, ErrObservation
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, budget.remaining+1))
	budget.remaining -= int64(len(body))
	if err != nil {
		return nil, err
	}
	if budget.remaining < 0 {
		return nil, ErrObservation
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	response.ContentLength = int64(len(body))
	return response, nil
}
