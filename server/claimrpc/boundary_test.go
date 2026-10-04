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
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

func TestCompletionMalformedDescriptorsNeverReachAuthority(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	r := f.admittedReceipt(t)
	proofCalls := 0
	cleanupCalls := 0
	_, server := f.completion(t, func(context.Context, zoneclaim.Receipt) error { proofCalls++; return nil }, func(context.Context, nakamalease.Lease) error { cleanupCalls++; return nil })
	transport := &http.Transport{TLSClientConfig: f.clientTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	document, err := json.Marshal(map[string]any{"schema": 1, "namespace": "world", "lease_object_id": r.Fence.LeaseObjectID, "lease_version": r.Fence.LeaseVersion, "attempt_digest": r.Fence.AttemptDigest, "allocation_id": "zone-1", "gameserver_uid": "uid-1", "observer": 1, "generation_nanos": strconv.FormatInt(r.Fence.Generation.UnixNano(), 10)})
	if err != nil {
		t.Fatal(err)
	}
	valid := string(document)
	for name, body := range map[string]string{
		"duplicate":         strings.Replace(valid, "{", `{"namespace":"world",`, 1),
		"escaped duplicate": strings.Replace(valid, "{", `{"namespac\u0065":"world",`, 1),
		"alias":             strings.Replace(valid, `"namespace"`, `"Namespace"`, 1),
		"missing":           strings.Replace(valid, `,"schema":1`, "", 1),
		"null":              strings.Replace(valid, `"schema":1`, `"schema":null`, 1),
		"future":            strings.Replace(valid, `"schema":1`, `"schema":2`, 1),
		"trailing":          valid + `{}`, "oversize": strings.Repeat(" ", 4096) + valid, "array": `[]`,
		"negative generation": strings.Replace(valid, strconv.FormatInt(r.Fence.Generation.UnixNano(), 10), "-1", 1),
	} {
		t.Run(name, func(t *testing.T) {
			request, err := http.NewRequestWithContext(t.Context(), http.MethodPost, server.URL+"/v1/session/end", strings.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Content-Type", "application/json")
			response, err := client.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(response.Body)
			_ = response.Body.Close()
			if err != nil || response.StatusCode != http.StatusForbidden || string(data) != "zone claim refused\n" || proofCalls != 0 || cleanupCalls != 0 {
				t.Fatal("malformed completion reached authority or exposed details")
			}
		})
	}
	request, err := http.NewRequestWithContext(t.Context(), http.MethodPost, server.URL+"/v1/session/end", strings.NewReader(valid))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent || proofCalls != 1 || cleanupCalls != 1 {
		t.Fatal("valid completion control failed")
	}
}

func TestCompletionClientSendsOnceAndRefusesUnexpectedResponses(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	receipt := f.admittedReceipt(t)
	for _, mode := range []string{"redirect", "error", "extra body", "oversize", "canceled"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int32
			var redirected atomic.Int32
			release := make(chan struct{})
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.URL.Path != "/v1/session/end" {
					redirected.Add(1)
					return
				}
				switch mode {
				case "redirect":
					http.Redirect(w, r, "/other", http.StatusTemporaryRedirect)
				case "error":
					http.Error(w, "private failure", http.StatusServiceUnavailable)
				case "extra body":
					_, _ = io.WriteString(w, "private failure")
				case "oversize":
					_, _ = io.WriteString(w, strings.Repeat("x", 8192))
				case "canceled":
					select {
					case <-r.Context().Done():
					case <-release:
					}
				}
			}))
			server.TLS = f.serverTLS
			server.StartTLS()
			defer server.Close()
			defer close(release)
			client, err := NewCompletionClient(server.URL+"/v1/session/end", f.clientTLS)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
			defer cancel()
			if err := client.Complete(ctx, receipt); !errors.Is(err, ErrRefused) {
				t.Fatal("unexpected completion response acknowledged")
			}
			if calls.Load() != 1 || redirected.Load() != 0 {
				t.Fatal("completion followed redirect or retried")
			}
		})
	}
	for _, endpoint := range []string{"http://claims.example/v1/session/end", "https://claims.example/v1/session/end?x=1", "https://claims.example/v1/claim", "https://user@claims.example/v1/session/end"} {
		if client, err := NewCompletionClient(endpoint, f.clientTLS); err == nil {
			client.Close()
			t.Fatal("unsafe completion endpoint accepted")
		}
	}
}

func TestReceiptClientRejectsMalformedOrSubstitutedIdentity(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	document := `{"schema":1,"namespace":"world","lease_object_id":"` + f.binding.LeaseObjectID + `","lease_version":"v2","attempt_digest":"` + f.binding.AttemptDigest + `","allocation_id":"zone-1","gameserver_uid":"uid-1","observer":1,"generation_nanos":"2000000000000000001"}`
	for name, body := range map[string]string{
		"valid": document, "duplicate": strings.Replace(document, "{", `{"namespace":"world",`, 1),
		"alias":           strings.Replace(document, `"namespace"`, `"Namespace"`, 1),
		"unknown":         strings.Replace(document, "{", `{"secret":"x",`, 1),
		"null":            strings.Replace(document, `"lease_version":"v2"`, `"lease_version":null`, 1),
		"wildcard":        strings.Replace(document, `"lease_version":"v2"`, `"lease_version":"*"`, 1),
		"control version": strings.Replace(document, `"lease_version":"v2"`, `"lease_version":"v\n2"`, 1),
		"trailing":        document + `{}`, "oversize": strings.Repeat(" ", 4096) + document,
		"leading zero":     strings.Replace(document, `"2000000000000000001"`, `"02000000000000000001"`, 1),
		"float generation": strings.Replace(document, `"2000000000000000001"`, `2000000000000000001`, 1),
		"overflow":         strings.Replace(document, `"2000000000000000001"`, `"9223372036854775808"`, 1),
		"other uid":        strings.Replace(document, `"uid-1"`, `"uid-2"`, 1),
		"other observer":   strings.Replace(document, `"observer":1`, `"observer":2`, 1),
		"other namespace":  strings.Replace(document, `"namespace":"world"`, `"namespace":"other"`, 1),
		"other key":        strings.Replace(document, f.binding.LeaseObjectID, strings.Repeat("0", 64), 1),
		"other allocation": strings.Replace(document, `"zone-1"`, `"zone-2"`, 1),
		"other attempt":    strings.Replace(document, f.binding.AttemptDigest, strings.Repeat("a", 52), 1),
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v2/claim" {
					t.Error("receipt client did not select additive version")
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(w, body)
			}))
			server.TLS = f.serverTLS
			server.StartTLS()
			defer server.Close()
			client, err := NewClient(server.URL+"/v1/claim", f.clientTLS)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			receipt, err := client.ClaimWithReceipt(t.Context(), f.binding, f.token, 1)
			if name == "valid" {
				if err != nil || receipt.Fence.LeaseVersion != "v2" || receipt.Fence.Generation.UnixNano() != 2000000000000000001 {
					t.Fatalf("exact receipt refused or rounded: %v", err)
				}
			} else if !errors.Is(err, ErrRefused) || receipt.Fence.LeaseVersion != "" {
				t.Fatal("unsafe receipt accepted or returned partial identity")
			}
		})
	}
}

func TestReceiptClientReplaysOnlyOriginalClaim(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
	first, err := client.ClaimWithReceipt(t.Context(), f.binding, f.token, 1)
	if err != nil {
		t.Fatal(err)
	}
	repeat, err := client.ClaimWithReceipt(t.Context(), f.binding, f.token, 1)
	if err != nil || repeat != first {
		t.Fatal("reconnect replaced original receipt")
	}
	bad := f.binding
	bad.GameServerUID = "uid-2"
	if _, err := client.ClaimWithReceipt(t.Context(), bad, f.token, 1); err == nil {
		t.Fatal("substituted binding authorized")
	}
	if len(f.storage.WrittenValues()) != 2 {
		t.Fatal("replay wrote another claim")
	}
}

func TestV2ClaimReturnsOriginalDurableReceipt(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	f.storage.AfterWrite = func(int) error { return errors.New("lost acknowledgement") }
	_, server := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
	transport := &http.Transport{TLSClientConfig: f.clientTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	var original string
	for range 2 {
		request, err := http.NewRequestWithContext(t.Context(), http.MethodPost, server.URL+"/v2/claim", strings.NewReader(requestBody(t, f)))
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Content-Type", "application/json")
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if err != nil || response.StatusCode != http.StatusOK || response.Header.Get("Cache-Control") != "no-store" || response.Header.Get("Content-Type") != "application/json" {
			t.Fatalf("claim receipt missing: status=%d err=%v", response.StatusCode, err)
		}
		var receipt map[string]any
		if err := json.Unmarshal(data, &receipt); err != nil {
			t.Fatal(err)
		}
		stored, err := f.store.LoadForClaim(t.Context(), f.binding.LeaseObjectID)
		if err != nil {
			t.Fatal(err)
		}
		if len(receipt) != 9 || receipt["schema"] != float64(1) || receipt["namespace"] != "world" || receipt["lease_object_id"] != f.binding.LeaseObjectID || receipt["lease_version"] != stored.Version || receipt["attempt_digest"] != f.binding.AttemptDigest || receipt["allocation_id"] != "zone-1" || receipt["gameserver_uid"] != "uid-1" || receipt["observer"] != float64(1) || receipt["generation_nanos"] != strconv.FormatInt(stored.Lease.ClaimedAt.UnixNano(), 10) {
			t.Fatalf("receipt does not identify original durable claim: %s", data)
		}
		if original != "" && string(data) != original {
			t.Fatal("replay replaced the original receipt")
		}
		original = string(data)
	}
	if len(f.storage.WrittenValues()) != 2 {
		t.Fatal("receipt replay rewrote the claim generation")
	}
}

// requestBody uses literal protocol keys so a production encoder regression
// cannot silently change both sides of the decoding tests.
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

// TestHandlerRefusesMalformedBodiesBeforeResolving proves malformed input has
// no resource-lookup or storage side effects and receives only a generic refusal.
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

// TestClientRefusesMissingOrUntrustedPeerCertificates exercises actual TLS
// handshakes so a permissive HTTP test double cannot mask a missing trust check.
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

// TestClientRefusesRedirectAndUnsafeConfiguration protects workload credentials
// from plaintext transport, unverified peers and redirected destinations.
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

// TestPrivateClaimFailsClosedAfterCancellationAndStorageAmbiguity distinguishes
// a refused response from a claim that may already have committed durably.
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

// TestHandlerRejectsExpiredPooledWorkload prevents an existing TLS connection
// from extending the authority of its expired workload certificate.
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

// TestHandlerRefusesUnverifiedClientCertificateOverTLS checks that presenting a
// certificate is insufficient when the listener has not verified its chain.
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

// TestClientRefusesUnexpectedResponsesWithoutLeakingDetails keeps remote error
// bodies and malformed successes out of the zone's admission result.
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
