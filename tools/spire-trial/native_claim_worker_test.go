//go:build war_spire_trial && linux

package spiretrial

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base32"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

const claimsFixtureDNS = "claims.fixture.test"

// runClaimCaller needs no listener: its own attested credential is used only to
// invoke the real client over the controller-selected owned loopback endpoint.
func runClaimCaller(material *workloadapi.X509Context, out *json.Encoder) int {
	if out.Encode(response{ID: material.DefaultSVID().ID.String()}) != nil {
		return 1
	}
	input := json.NewDecoder(os.Stdin)
	for {
		var c command
		if err := input.Decode(&c); err != nil {
			if errors.Is(err, io.EOF) {
				return 0
			}
			return 1
		}
		r := response{Error: "unknown private caller command"}
		if c.Op == "claim" {
			r = callPrivateClaim(c, material)
		}
		if out.Encode(r) != nil {
			return 1
		}
	}
}

// fixtureBinding carries synthetic storage routing, not production authority.
func fixtureBinding() agones.ClaimBinding {
	attempt, _ := agones.CorrelationLabel("attempt-1")
	return agones.ClaimBinding{Namespace: "world", AllocationID: "zone-1", GameServerUID: "uid-1", LeaseObjectID: nakamalease.ReservationKey("11111111-1111-1111-1111-111111111111", "reservation-1"), AttemptDigest: attempt}
}

type fixtureResolver struct{ allocation handoff.Allocation }

func (r fixtureResolver) Resolve(context.Context, nakamalease.Lease) (handoff.Allocation, error) {
	return r.allocation, nil
}

// observedClaimWriter preserves the real server's read/write-deadline support.
type observedClaimWriter struct {
	http.ResponseWriter
	status int
}

func (w *observedClaimWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *observedClaimWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
		w.ResponseWriter.WriteHeader(status)
	}
}
func (w *observedClaimWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}

// runClaimServer keeps its own fetched key and uses the unchanged private handler.
// Its storage and resolver are explicitly synthetic; this is a TLS/response proof.
func runClaimServer(material *workloadapi.X509Context, out *json.Encoder) int {
	fail := func() int { _ = out.Encode(response{Error: "private claims fixture failed"}); return 1 }
	storage := nakamastoragetest.New()
	store, err := nakamalease.NewStore(storage)
	if err != nil {
		return fail()
	}
	expiry := time.Now().Add(2 * time.Minute)
	uidDigest := sha256.Sum256([]byte("uid-1"))
	digest := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(uidDigest[:]))
	ref := "v1.k" + strings.Repeat("a", 52) + ".u" + digest + ".e" + strings.Repeat("a", 52) + ".p443"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	record, err := store.Create(ctx, nakamalease.Lease{UserID: "11111111-1111-1111-1111-111111111111", ReservationID: "reservation-1", AttemptID: "attempt-1", AllocationID: "zone-1", Observer: 1, SecretRef: ref, ExpiresAt: expiry})
	cancel()
	if err != nil {
		return fail()
	}
	allocation := handoff.Allocation{ID: "zone-1", Observer: 1, AdmissionSecret: []byte(strings.Repeat("s", 32)), LeaseExpiresAt: expiry}
	handler, err := claimrpc.NewHandler(store, fixtureResolver{allocation}, claimrpc.Config{Namespace: "world", TrustDomain: "war-fixture.test", Timeout: time.Second})
	if err != nil {
		return fail()
	}
	config, err := claimServerTLS(material)
	if err != nil {
		return fail()
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", config)
	if err != nil {
		return fail()
	}
	var effects atomic.Uint64
	var verified atomic.Bool
	server := &http.Server{ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second, IdleTimeout: 3 * time.Second, ErrorLog: log.New(io.Discard, "", 0), Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observed := &observedClaimWriter{ResponseWriter: w}
		handler.ServeHTTP(observed, r)
		if observed.status == http.StatusOK && r.URL.Path == "/v2/claim" {
			effects.Add(1)
			verified.Store(r.TLS != nil && r.TLS.HandshakeComplete && len(r.TLS.VerifiedChains) > 0)
		}
	})}
	stopped := make(chan error, 1)
	go func() { stopped <- server.Serve(listener) }()
	defer func() {
		_ = server.Close()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
		}
	}()
	if out.Encode(response{ID: material.DefaultSVID().ID.String(), Address: listener.Addr().String(), Expiry: expiry.UnixNano()}) != nil {
		return 1
	}
	input := json.NewDecoder(os.Stdin)
	for {
		var c command
		if err := input.Decode(&c); err != nil {
			if errors.Is(err, io.EOF) {
				return 0
			}
			return 1
		}
		if c.Op != "stats" {
			if out.Encode(response{Error: "unknown private claims command"}) != nil {
				return 1
			}
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		current, err := store.Load(ctx, record.Lease.UserID, record.Lease.ReservationID)
		cancel()
		if err != nil {
			return fail()
		}
		generation := int64(0)
		if !current.Lease.ClaimedAt.IsZero() {
			generation = current.Lease.ClaimedAt.UnixNano()
		}
		if out.Encode(response{Effects: effects.Load(), Verified: verified.Load(), Claimed: !current.Lease.ClaimedAt.IsZero(), Version: current.Version, Generation: generation, Writes: uint64(len(storage.WrittenValues()))}) != nil {
			return 1
		}
	}
}

// callPrivateClaim constructs the actual client from this process's snapshot.
// Only aggregate verdicts and non-secret receipt fences leave the calling worker.
func callPrivateClaim(c command, material *workloadapi.X509Context) response {
	host, port, err := net.SplitHostPort(c.Address)
	if err != nil || host != "127.0.0.1" || port == "" {
		return response{Error: "claims peer must be owned loopback"}
	}
	dns := claimsFixtureDNS
	if c.DNS != "" {
		dns = c.DNS
	}
	expected := roleID("claims").String()
	if c.Server != "" {
		expected = roleID(c.Server).String()
	}
	config, err := claimClientTLS(material, dns, expected)
	if err != nil {
		return response{Error: "issued claims TLS material refused", Code: "Material"}
	}
	if c.TrustBundle != "" {
		bundle, err := x509bundle.Load(spiffeid.RequireTrustDomainFromString("war-fixture.test"), c.TrustBundle)
		if err != nil {
			return response{Error: "public claims trust bundle refused", Code: "Bundle"}
		}
		config.RootCAs = x509.NewCertPool()
		for _, root := range bundle.X509Authorities() {
			config.RootCAs.AddCert(root)
		}
	}
	switch c.Credential {
	case "":
	case "missing":
		config.Certificates = nil
	case "mismatched":
		wrong, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return response{Error: "mismatched claims key control failed"}
		}
		config.Certificates[0].PrivateKey = wrong
	default:
		return response{Error: "unknown claims key control"}
	}
	client, err := claimrpc.NewClient("https://"+c.Address+"/v1/claim", config)
	if err != nil {
		return response{Error: "private claims constructor refused", Code: "Constructor"}
	}
	defer client.Close()
	binding := fixtureBinding()
	expiry := time.Unix(0, c.Expiry)
	token, err := zonesock.MintToken([]byte(strings.Repeat("s", 32)), binding.AllocationID, 1, expiry)
	if err != nil {
		return response{Error: "synthetic token setup refused", Code: "Token"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	receipt, err := client.ClaimWithReceipt(ctx, binding, token, 1)
	if err != nil {
		return response{Error: "private claims request refused", Code: "Request", Receipt: receipt.Matches(binding, 1)}
	}
	if !receipt.Matches(binding, 1) {
		return response{Error: "originating receipt did not bind request", Code: "Receipt"}
	}
	return response{Receipt: true, Version: receipt.Fence.LeaseVersion, Generation: receipt.Fence.Generation.UnixNano()}
}
