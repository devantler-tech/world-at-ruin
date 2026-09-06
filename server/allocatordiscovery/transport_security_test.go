package allocatordiscovery

import (
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"k8s.io/client-go/rest"
)

// tlsRESTConfig trusts only the test API certificate and retains verification.
func tlsRESTConfig(server *httptest.Server, timeout time.Duration) *rest.Config {
	return &rest.Config{
		Host: server.URL, Timeout: timeout,
		TLSClientConfig: rest.TLSClientConfig{CAData: pem.EncodeToMemory(&pem.Block{
			Type: "CERTIFICATE", Bytes: server.Certificate().Raw,
		})},
	}
}

// Invalid transport configuration must fail before a credentialed client exists.
func TestNewRejectsUnverifiedAPIConnections(t *testing.T) {
	for _, test := range []struct {
		name string
		cfg  rest.Config
	}{
		{"plaintext", rest.Config{Host: "http://api.example", Timeout: time.Second}},
		{"implicit plaintext", rest.Config{Host: "api.example", Timeout: time.Second}},
		{"disabled verification", rest.Config{Host: "https://api.example", Timeout: time.Second, TLSClientConfig: rest.TLSClientConfig{Insecure: true}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			test.cfg.BearerToken = "test-only-token"
			reader, err := New(&test.cfg, config())
			if reader != nil || !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("unsafe API configuration accepted: reader=%v err=%v", reader != nil, err)
			}
		})
	}
}

// Redirects must never reach another endpoint, including a same-origin path.
func TestAPIRedirectsNeverForwardCredentials(t *testing.T) {
	for _, status := range []int{301, 302, 303, 307, 308} {
		for _, destination := range []string{"same-origin", "https", "http"} {
			t.Run(strconv.Itoa(status)+"/"+destination, func(t *testing.T) {
				var forwarded atomic.Int32
				targetHandler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
					forwarded.Add(1)
					w.WriteHeader(http.StatusForbidden)
				})
				var target *httptest.Server
				if destination == "http" {
					target = httptest.NewServer(targetHandler)
				} else {
					target = httptest.NewTLSServer(targetHandler)
				}
				t.Cleanup(target.Close)
				var authenticated atomic.Int32
				api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
					if req.URL.Path == "/redirected" {
						targetHandler.ServeHTTP(w, req)
						return
					}
					if req.Header.Get("Authorization") == "Bearer test-only-token" {
						authenticated.Add(1)
					}
					location := target.URL + "/redirected"
					if destination == "same-origin" {
						location = "/redirected"
					}
					http.Redirect(w, req, location, status)
				}))
				t.Cleanup(api.Close)
				cfg := tlsRESTConfig(api, time.Second)
				if destination != "http" {
					cfg.CAData = append(cfg.CAData, tlsRESTConfig(target, time.Second).CAData...)
				}
				cfg.BearerToken = "test-only-token"
				reader := readerFromRESTConfig(t, cfg)
				snapshot, err := reader.Discover(t.Context())
				if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(snapshot, Snapshot{}) {
					t.Fatalf("redirect supplied discovery evidence: %+v, %v", snapshot, err)
				}
				observation, err := reader.ObservePod(t.Context(), Identity{Namespace: "allocation", Name: "allocator-a", UID: "uid-a"})
				if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(observation, Observation{}) {
					t.Fatalf("redirect supplied Pod evidence: %+v, %v", observation, err)
				}
				if authenticated.Load() != 2 || forwarded.Load() != 0 {
					t.Fatalf("redirect followed: authenticated API calls=%d target calls=%d", authenticated.Load(), forwarded.Load())
				}
			})
		}
	}
}

// Valid TLS still authenticates, and an untrusted API certificate is refused.
func TestAPIRequiresTrustedCertificateAndPreservesCredentials(t *testing.T) {
	var authenticated atomic.Int32
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Header.Get("Authorization") == "Bearer test-only-token" {
			authenticated.Add(1)
		}
		current := pod("allocator-a", "uid-a", "10.0.0.1")
		current.APIVersion, current.Kind = "v1", "Pod"
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(current); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(api.Close)
	cfg := tlsRESTConfig(api, time.Second)
	cfg.BearerToken = "test-only-token"
	reader := readerFromRESTConfig(t, cfg)
	got, err := reader.ObservePod(t.Context(), Identity{Namespace: "allocation", Name: "allocator-a", UID: "uid-a"})
	if err != nil || got.Pod.Identity.UID != "uid-a" || authenticated.Load() != 1 {
		t.Fatalf("trusted API failed: %+v, %v calls=%d", got, err, authenticated.Load())
	}
	cfg.CAData = nil
	reader = readerFromRESTConfig(t, cfg)
	got, err = reader.ObservePod(t.Context(), Identity{Namespace: "allocation", Name: "allocator-a", UID: "uid-a"})
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Observation{}) || authenticated.Load() != 1 {
		t.Fatalf("untrusted API accepted: %+v, %v calls=%d", got, err, authenticated.Load())
	}
}
