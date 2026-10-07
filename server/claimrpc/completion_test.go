package claimrpc

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kubetesting "k8s.io/client-go/testing"
)

func TestCompletionRejectsUnverifiedAndExpiredWorkloadBeforeAuthority(t *testing.T) {
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	receipt := f.admittedReceipt(t)
	h, err := NewCompletionHandler(f.store, endVerifierFunc(func(context.Context, zoneclaim.Receipt) error {
		t.Error("unverified peer reached termination authority")
		return nil
	}), func(context.Context, nakamalease.Lease) error { t.Error("unverified peer reached cleanup"); return nil }, Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(receiptDocument(receipt))
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(f.clientTLS.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"plain HTTP", "unverified chain", "expired pooled certificate"} {
		t.Run(mode, func(t *testing.T) {
			request := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "https://claims.example/v1/session/end", bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			switch mode {
			case "plain HTTP":
				request.TLS = nil
			case "unverified chain":
				request.TLS = &tls.ConnectionState{HandshakeComplete: true, PeerCertificates: []*x509.Certificate{leaf}}
			case "expired pooled certificate":
				expired := *leaf
				expired.NotAfter = time.Now().Add(-time.Second)
				request.TLS = &tls.ConnectionState{HandshakeComplete: true, PeerCertificates: []*x509.Certificate{&expired}, VerifiedChains: [][]*x509.Certificate{{&expired}}}
			}
			recorder := &deadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
			h.ServeHTTP(recorder, request)
			if recorder.Code != http.StatusForbidden || recorder.Body.String() != "zone claim refused\n" {
				t.Fatal("unauthenticated completion acknowledged")
			}
		})
	}
	if len(f.storage.WrittenValues()) != 2 {
		t.Fatal("unauthenticated completion changed lease")
	}
}

func TestCompletionRevalidatesOwnershipAfterTerminationVerification(t *testing.T) {
	for _, mode := range []string{"expanded before proof", "expanded during proof", "new owner during proof"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			r := f.admittedReceipt(t)
			expand := func() error {
				object, ok := f.storage.Get(nakamalease.Collection, r.Fence.LeaseObjectID, "")
				if !ok {
					return errors.New("missing claimed fixture")
				}
				var fields map[string]json.RawMessage
				if err := json.Unmarshal([]byte(object.Value), &fields); err != nil {
					return err
				}
				fields["schema"] = json.RawMessage(`4`)
				fields["allocator_generation_id"] = json.RawMessage(`"generation:1"`)
				fields["allocator_member_set_digest"] = json.RawMessage(`"` + strings.Repeat("a", 64) + `"`)
				fields["allocator_pod_uid"] = json.RawMessage(`"pod-allocator-1"`)
				data, err := json.Marshal(fields)
				if err != nil {
					return err
				}
				object.Value = string(data)
				f.storage.Seed(object)
				return nil
			}
			if mode == "expanded before proof" {
				if err := expand(); err != nil {
					t.Fatal(err)
				}
			}
			proofCalls := 0
			cleanupCalls := 0
			var protected any
			client, _ := f.completion(t, func(context.Context, zoneclaim.Receipt) error {
				proofCalls++
				if mode == "expanded during proof" {
					if err := expand(); err != nil {
						t.Error(err)
						return err
					}
				} else {
					object, _ := f.storage.Get(nakamalease.Collection, r.Fence.LeaseObjectID, "")
					object.Version = "replacement-version"
					f.storage.Seed(object)
				}
				protected = f.storage.Objects()
				return nil
			}, func(context.Context, nakamalease.Lease) error { cleanupCalls++; return nil })
			before := len(f.storage.WrittenValues())
			if mode == "expanded before proof" {
				protected = f.storage.Objects()
			}
			if err := client.Complete(t.Context(), r); !errors.Is(err, ErrRefused) {
				t.Fatal("changed ownership completed")
			}
			if cleanupCalls != 0 || len(f.storage.WrittenValues()) != before || !reflect.DeepEqual(protected, f.storage.Objects()) {
				t.Fatal("completion changed ownership after proof race")
			}
			if mode == "expanded before proof" && proofCalls != 0 {
				t.Fatal("reader-only observation reached authority verifier")
			}
		})
	}
}

type endVerifierFunc func(context.Context, zoneclaim.Receipt) error

func (f endVerifierFunc) VerifyEnded(ctx context.Context, r zoneclaim.Receipt) error {
	return f(ctx, r)
}

func (f *fixture) completion(t *testing.T, verifier endVerifierFunc, cleanup func(context.Context, nakamalease.Lease) error) (*CompletionClient, *httptest.Server) {
	t.Helper()
	h, err := NewCompletionHandler(f.store, verifier, cleanup, Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(h)
	server.TLS = f.serverTLS
	server.StartTLS()
	t.Cleanup(server.Close)
	client, err := NewCompletionClient(server.URL+"/v1/session/end", f.clientTLS)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client, server
}

func (f *fixture) admittedReceipt(t *testing.T) zoneclaim.Receipt {
	t.Helper()
	client, _ := f.serve(t, func(context.Context, nakamalease.Lease) (handoff.Allocation, error) { return f.allocation, nil })
	r, err := client.ClaimWithReceipt(t.Context(), f.binding, f.token, 1)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestCompletionRequiresIndependentExactTerminationAuthority(t *testing.T) {
	for _, mode := range []string{"denied", "canceled", "changed version", "changed generation", "sibling workload", "wrong namespace"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			r := f.admittedReceipt(t)
			original := r
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			proofCalls := 0
			cleanupCalls := 0
			client, _ := f.completion(t, func(callCtx context.Context, seen zoneclaim.Receipt) error {
				proofCalls++
				if seen != original {
					t.Error("verifier received refreshed or substituted receipt")
				}
				if _, ok := callCtx.Deadline(); !ok {
					t.Error("termination verification lacks deadline")
				}
				if mode == "canceled" {
					cancel()
					<-callCtx.Done()
					return callCtx.Err()
				}
				return errors.New("private authority details")
			}, func(context.Context, nakamalease.Lease) error { cleanupCalls++; return nil })
			switch mode {
			case "changed version":
				r.Fence.LeaseVersion = "stale-version"
			case "changed generation":
				r.Fence.Generation = r.Fence.Generation.Add(time.Nanosecond)
			case "sibling workload":
				r.Fence.GameServerUID = "uid-2"
			case "wrong namespace":
				r.Namespace = "other"
			}
			before := len(f.storage.WrittenValues())
			if err := client.Complete(ctx, r); !errors.Is(err, ErrRefused) {
				t.Fatal("unproved completion succeeded or leaked detail")
			}
			stored, err := f.store.LoadForClaim(t.Context(), original.Fence.LeaseObjectID)
			if err != nil || stored.Lease.ClaimedAt.IsZero() || stored.Lease.Releasing || len(f.storage.WrittenValues()) != before || cleanupCalls != 0 {
				t.Fatal("refused completion changed claimed ownership")
			}
			want := 0
			if mode == "denied" || mode == "canceled" {
				want = 1
			}
			if proofCalls != want {
				t.Fatalf("authority calls=%d want=%d", proofCalls, want)
			}
		})
	}
	f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
	if _, err := NewCompletionHandler(f.store, nil, func(context.Context, nakamalease.Lease) error { return nil }, Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second}); err == nil {
		t.Fatal("missing independent authority accepted")
	}
}

func TestAuthenticatedCompletionFencesBeforeExactUIDCleanup(t *testing.T) {
	for _, mode := range []string{"normal", "replacement UID", "cleanup failure"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, "spiffe://claims.example/zone/world/uid-1")
			adapter, kube, gs := f.resourceResolver(t)
			r := f.admittedReceipt(t)
			if mode == "replacement UID" {
				gs.UID = "replacement-uid"
				if _, err := kube.AgonesV1().GameServers("world").Update(t.Context(), gs, metav1.UpdateOptions{}); err != nil {
					t.Fatal(err)
				}
			}
			fail := mode == "cleanup failure"
			deletes := 0
			kube.PrependReactor("delete", "gameservers", func(action kubetesting.Action) (bool, runtime.Object, error) {
				deletes++
				deletion, ok := action.(kubetesting.DeleteAction)
				if !ok {
					t.Error("unexpected delete action")
					return true, nil, errors.New("unexpected delete action")
				}
				options := deletion.GetDeleteOptions()
				if options.Preconditions == nil || options.Preconditions.UID == nil || string(*options.Preconditions.UID) != "uid-1" {
					t.Error("cleanup lost exact UID")
					return true, nil, errors.New("cleanup lost exact UID")
				}
				barrier, err := f.store.LoadForClaim(t.Context(), r.Fence.LeaseObjectID)
				if err != nil || !barrier.Lease.Releasing || !barrier.Lease.ClaimedAt.IsZero() {
					t.Error("deletion preceded durable releasing barrier")
					return true, nil, errors.New("deletion preceded durable releasing barrier")
				}
				if fail {
					return true, nil, errors.New("private cleanup failure")
				}
				return false, nil, nil
			})
			proofCalls := 0
			client, _ := f.completion(t, func(_ context.Context, seen zoneclaim.Receipt) error {
				proofCalls++
				if seen != r {
					t.Error("completion adopted another receipt")
				}
				return nil
			}, adapter.Release)
			err := client.Complete(t.Context(), r)
			if fail {
				if !errors.Is(err, ErrRefused) {
					t.Fatal("failed cleanup acknowledged completion")
				}
				if err := client.Complete(t.Context(), r); err == nil || proofCalls != 1 {
					t.Fatal("old receipt resumed releasing session")
				}
				claimClient, _ := f.serve(t, adapter.Resolve)
				if err := claimClient.Claim(t.Context(), f.binding, f.token, 1); err == nil {
					t.Fatal("fresh claim bypassed durable barrier")
				}
				fail = false
				restarted, err := nakamalease.NewStore(f.storage)
				if err != nil {
					t.Fatal(err)
				}
				if err := restarted.ReclaimExpired(t.Context(), time.Now(), adapter.Release); err != nil {
					t.Fatal(err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.LoadForClaim(t.Context(), r.Fence.LeaseObjectID); !errors.Is(err, nakamalease.ErrNotFound) {
				t.Fatal("successful exact cleanup retained reservation")
			}
			current, err := kube.AgonesV1().GameServers("world").Get(t.Context(), "zone-1", metav1.GetOptions{})
			if mode == "replacement UID" {
				if err != nil || current.UID != "replacement-uid" || deletes != 0 {
					t.Fatal("old completion touched replacement UID")
				}
			} else if !apierrors.IsNotFound(err) || deletes == 0 {
				t.Fatal("owned GameServer survived cleanup")
			}
			if err := client.Complete(t.Context(), r); err != nil || proofCalls != 2 {
				t.Fatal("absence replay bypassed independent termination authority")
			}
			f.record.Lease.AttemptID = "attempt-2"
			if _, err := f.store.Create(t.Context(), f.record.Lease); err != nil {
				t.Fatal(err)
			}
			if err := client.Complete(t.Context(), r); err == nil || proofCalls != 2 {
				t.Fatal("stale completion reached replacement authority")
			}
		})
	}
}
