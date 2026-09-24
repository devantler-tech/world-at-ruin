package claimrpc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
)

func requestBody(t *testing.T, f *fixture) string {
	t.Helper()
	// Literal protocol field names keep decoding tests independent of the
	// production request encoder and its JSON tags.
	data, err := json.Marshal(map[string]any{"namespace": "world", "allocation_id": "zone-1", "gameserver_uid": "uid-1", "lease_object_id": f.binding.LeaseObjectID, "attempt_digest": f.binding.AttemptDigest, "observer": 1, "token": f.token})
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestHandlerRefusesMalformedBodiesBeforeResolving(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	var calls atomic.Int32
	_, server := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) {
		calls.Add(1)
		return f.allocation, nil
	})
	transport := &http.Transport{TLSClientConfig: f.clientTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	valid := requestBody(t, f)
	for name, body := range map[string]string{
		"duplicate": strings.Replace(valid, "{", `{"observer":2,`, 1),
		"alias":     strings.Replace(valid, `"observer"`, `"Observer"`, 1),
		"unknown":   strings.Replace(valid, "{", `{"user_id":"secret",`, 1),
		"null":      strings.Replace(valid, `"observer":1`, `"observer":null`, 1),
		"missing":   strings.Replace(valid, `"observer":1,`, "", 1),
		"trailing":  valid + `{}`,
		"oversize":  strings.Repeat(" ", 4096) + valid,
		"fraction":  strings.Replace(valid, `"observer":1`, `"observer":1.5`, 1),
		"object":    `[]`,
	} {
		t.Run(name, func(t *testing.T) {
			request, err := http.NewRequestWithContext(context.Background(), http.MethodPost, server.URL+"/v1/claim", strings.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Content-Type", "application/json")
			response, err := client.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			content, err := io.ReadAll(response.Body)
			_ = response.Body.Close()
			if err != nil || response.StatusCode != http.StatusForbidden || string(content) != "zone claim refused\n" {
				t.Fatalf("unsafe refusal: status=%d error=%v body=%q", response.StatusCode, err, content)
			}
		})
	}
	if calls.Load() != 0 || len(f.storage.WrittenValues()) != 1 {
		t.Fatal("malformed input reached allocation or claim")
	}
}

func TestClientRefusesMissingOrUntrustedPeerCertificates(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	_, server := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
	for _, name := range []string{"missing certificate", "untrusted client", "untrusted server"} {
		t.Run(name, func(t *testing.T) {
			config := f.clientTLS.Clone()
			_, other := certificates(t, "spiffe://claims.example/zone/world/uid-1")
			switch name {
			case "missing certificate":
				config.Certificates = nil
			case "untrusted client":
				config.Certificates = other.Certificates
			case "untrusted server":
				config.RootCAs = other.RootCAs
			}
			client, err := NewClient(server.URL+"/v1/claim", config)
			if err == nil {
				defer client.Close()
				err = client.Claim(context.Background(), f.binding, f.token, 1)
			}
			if err == nil {
				t.Fatal("unverified identity accepted")
			}
		})
	}
	if len(f.storage.WrittenValues()) != 1 {
		t.Fatal("unauthenticated request wrote a claim")
	}
}

func TestClientRefusesRedirectAndUnsafeConfiguration(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	var redirected atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/claim" {
			redirected.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/redirected", http.StatusTemporaryRedirect)
	}))
	server.TLS = f.serverTLS
	server.StartTLS()
	defer server.Close()
	client, err := NewClient(server.URL+"/v1/claim", f.clientTLS)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.Claim(context.Background(), f.binding, f.token, 1); !errors.Is(err, ErrRefused) {
		t.Fatalf("redirect leaked detail or succeeded: %v", err)
	}
	if redirected.Load() != 0 {
		t.Fatal("private claim followed redirect")
	}
	for _, endpoint := range []string{"http://claim.example/v1/claim", "https://user:password@claim.example/v1/claim", "https://claim.example/v1/claim?token=secret", "https://claim.example/other"} {
		if client, err := NewClient(endpoint, f.clientTLS); err == nil {
			client.Close()
			t.Fatal("unsafe endpoint accepted")
		}
	}
	insecure := f.clientTLS.Clone()
	insecure.InsecureSkipVerify = true
	if client, err := NewClient(server.URL+"/v1/claim", insecure); err == nil {
		client.Close()
		t.Fatal("disabled TLS verification accepted")
	}
}

func TestPrivateClaimFailsClosedAfterCancellationAndStorageAmbiguity(t *testing.T) {
	for _, name := range []string{"cancel while resolving", "cleanup while resolving", "lost acknowledgement", "storage unavailable"} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			client, _ := f.serve(t, func(callCtx context.Context, _ nakamalease.Lease) (handoff.Allocation, error) {
				if _, ok := callCtx.Deadline(); !ok {
					t.Error("resolver has no deadline")
				}
				switch name {
				case "cancel while resolving":
					cancel()
					<-callCtx.Done()
				case "cleanup while resolving":
					if _, err := f.store.BeginRelease(callCtx, f.record, "attempt-1"); err != nil {
						t.Error(err)
					}
				case "lost acknowledgement":
					f.storage.AfterWrite = func(int) error { return errors.New("private database details") }
				case "storage unavailable":
					f.storage.WriteErr = errors.New("private database details")
				}
				return f.allocation, nil
			})
			err := client.Claim(ctx, f.binding, f.token, 1)
			if name == "lost acknowledgement" {
				if err != nil {
					t.Fatalf("committed claim not recovered: %v", err)
				}
			} else if !errors.Is(err, ErrRefused) {
				t.Fatalf("unsafe claim result: %v", err)
			}
			stored, err := f.store.Load(context.Background(), f.record.Lease.UserID, f.record.Lease.ReservationID)
			if err != nil {
				t.Fatal(err)
			}
			if got := !stored.Lease.ClaimedAt.IsZero(); got != (name == "lost acknowledgement") {
				t.Fatal("incorrect durable claim outcome")
			}
		})
	}
}

func TestHandlerRejectsExpiredPooledWorkload(t *testing.T) {
	_, clientConfig := certificates(t, "spiffe://claims.example/zone/world/uid-1")
	// The actual TLS connection tests exercise chain creation. Here the clock
	// advances after that handshake: the handler must not trust an expired pool.
	leaf, err := x509.ParseCertificate(clientConfig.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	state := &tls.ConnectionState{HandshakeComplete: true, PeerCertificates: []*x509.Certificate{leaf}, VerifiedChains: [][]*x509.Certificate{{leaf}}}
	if !verifiedPeer(state, leaf.NotBefore.Add(time.Second)) || verifiedPeer(state, leaf.NotAfter) {
		t.Fatal("pooled workload validity was not enforced")
	}
}

func TestHandlerRefusesUnverifiedClientCertificateOverTLS(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	f.serverTLS.ClientAuth = tls.RequestClientCert
	client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) {
		t.Error("unverified certificate reached resolver")
		return f.allocation, nil
	})
	if err := client.Claim(context.Background(), f.binding, f.token, 1); !errors.Is(err, ErrRefused) {
		t.Fatal("TLS without verified client chain authorized a claim")
	}
	if len(f.storage.WrittenValues()) != 1 {
		t.Fatal("unverified workload changed storage")
	}
}

func TestClientRefusesUnexpectedResponsesWithoutLeakingDetails(t *testing.T) {
	for _, body := range []string{"private storage details", strings.Repeat("s", 8192)} {
		f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
		server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = io.WriteString(w, body)
		}))
		server.TLS = f.serverTLS
		server.StartTLS()
		client, err := NewClient(server.URL+"/v1/claim", f.clientTLS)
		if err != nil {
			server.Close()
			t.Fatal(err)
		}
		err = client.Claim(context.Background(), f.binding, f.token, 1)
		client.Close()
		server.Close()
		if !errors.Is(err, ErrRefused) || err.Error() != "claimrpc: zone claim refused" {
			t.Fatal("unexpected response accepted or leaked private details")
		}
	}
}
