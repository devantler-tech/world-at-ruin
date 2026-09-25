package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io/fs"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	sdkproto "agones.dev/agones/pkg/sdk"
	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

type commandResolver func(context.Context, nakamalease.Lease) (handoff.Allocation, error)

// Resolve substitutes only the resource lookup, retaining real claim and storage boundaries.
func (f commandResolver) Resolve(ctx context.Context, lease nakamalease.Lease) (handoff.Allocation, error) {
	return f(ctx, lease)
}

// claimIdentity issues a workload leaf under an isolated root for the private service.
func claimIdentity(t *testing.T, identity string) (*x509.CertPool, string, string) {
	t.Helper()
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	root, err = x509.ParseCertificate(rootDER)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri, err := url.Parse(identity)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: root.NotBefore, NotAfter: root.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, URIs: []*url.URL{uri}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, root, &key.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pool, claimFile(t, "CERTIFICATE", der), claimFile(t, "EC PRIVATE KEY", keyDER)
}

// claimFile writes only private temporary fixture material.
func claimFile(t *testing.T, kind string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "material.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: data}), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestPrivateClaimCommand proves the built artifact claims storage before upgrade;
// bypassing the gate opens refused sockets and leaves the successful lease unclaimed.
func TestPrivateClaimCommand(t *testing.T) {
	for _, scenario := range []string{"valid", "missing locator", "sibling identity", "cleanup won", "unavailable", "sibling token"} {
		t.Run(scenario, func(t *testing.T) {
			f, err := agonestest.Start(nil)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Stop()
			f.SetGameServer("world", "zone-1", "uid-1", "Starting")
			wrapping, err := rsa.GenerateKey(rand.Reader, 3072)
			if err != nil {
				t.Fatal(err)
			}
			public, err := x509.MarshalPKIXPublicKey(&wrapping.PublicKey)
			if err != nil {
				t.Fatal(err)
			}
			storage := nakamastoragetest.New()
			store, err := nakamalease.NewStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			var allocation handoff.Allocation
			materialReady := make(chan struct{})
			handler, err := claimrpc.NewHandler(store, commandResolver(func(ctx context.Context, lease nakamalease.Lease) (handoff.Allocation, error) {
				select {
				case <-materialReady:
				case <-ctx.Done():
					return handoff.Allocation{}, ctx.Err()
				}
				if lease.AllocationID != allocation.ID {
					return handoff.Allocation{}, errors.New("wrong allocation")
				}
				return allocation, nil
			}), claimrpc.Config{Namespace: "world", TrustDomain: "claims.example", Timeout: time.Second})
			if err != nil {
				t.Fatal(err)
			}
			identity := "spiffe://claims.example/zone/world/uid-1"
			if scenario == "sibling identity" {
				identity = "spiffe://claims.example/zone/world/uid-2"
			}
			clientRoots, clientCert, clientKey := claimIdentity(t, identity)
			var privateRequests atomic.Int32
			private := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				privateRequests.Add(1)
				if scenario == "unavailable" {
					http.Error(w, "unavailable", http.StatusServiceUnavailable)
					return
				}
				handler.ServeHTTP(w, r)
			}))
			private.TLS = &tls.Config{MinVersion: tls.VersionTLS12, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: clientRoots}
			private.StartTLS()
			defer private.Close()
			caPath := claimFile(t, "CERTIFICATE", private.Certificate().Raw)
			cert, key := writeSelfSignedCert(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))
			addr := "127.0.0.1:" + closedPort(t)
			cmd := zoneCommand(t, "-listen", addr, "-tls-cert", cert, "-tls-key", key, "-agones", "-agones-health-interval", "50ms", "-agones-admission-public-key", claimFile(t, "PUBLIC KEY", public), "-private-claims", "-claim-url", private.URL+"/v1/claim", "-claim-ca", caPath, "-claim-cert", clientCert, "-claim-key", clientKey)
			cmd.Env = append(os.Environ(), "AGONES_SDK_GRPC_HOST=127.0.0.1", "AGONES_SDK_GRPC_PORT="+f.PortString(), "WAR_ZONE_ADMISSION_SECRET=")
			var output bytes.Buffer
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			defer func() {
				_ = cmd.Process.Signal(syscall.SIGTERM)
				select {
				case err := <-done:
					if err != nil {
						t.Errorf("zone exit: %v\n%s", err, output.String())
					}
				case <-time.After(10 * time.Second):
					_ = cmd.Process.Kill()
					<-done
					t.Error("zone failed to drain")
				}
			}()
			deadline := time.Now().Add(5 * time.Second)
			for f.ReadyCalls() == 0 && time.Now().Before(deadline) {
				time.Sleep(5 * time.Millisecond)
			}
			if f.ReadyCalls() != 1 {
				t.Fatal("zone did not become ready")
			}
			gs, err := f.GetGameServer(t.Context(), &sdkproto.Empty{})
			if err != nil {
				t.Fatal(err)
			}
			material := admissionref.Material{Namespace: "world", GameServerName: "zone-1", GameServerUID: "uid-1", WrappingKeyFingerprint: gs.GetObjectMeta().GetAnnotations()[agones.AdmissionKeyAnnotation], AdmissionEnvelope: gs.GetObjectMeta().GetAnnotations()[agones.AdmissionEnvelopeAnnotation], TLSPort: 443}
			keyring, err := admissionref.NewKeyring(wrapping)
			if err != nil {
				t.Fatal(err)
			}
			opened, err := keyring.Open(material)
			if err != nil {
				t.Fatal(err)
			}
			lease := nakamalease.Lease{UserID: "11111111-1111-1111-1111-111111111111", ReservationID: "reservation-1", AttemptID: "attempt-1", AllocationID: "zone-1", Observer: 1, SecretRef: opened.SecretRef(), ExpiresAt: time.Now().Add(time.Minute)}
			record, err := store.Create(t.Context(), lease)
			if err != nil {
				t.Fatal(err)
			}
			allocation = handoff.Allocation{ID: lease.AllocationID, Observer: 1, AdmissionSecret: opened.Secret(), LeaseExpiresAt: lease.ExpiresAt}
			close(materialReady)
			attempt, err := agones.CorrelationLabel(lease.AttemptID)
			if err != nil {
				t.Fatal(err)
			}
			gs.Status.State = "Allocated"
			gs.ObjectMeta.Labels[agones.AttemptLabel] = attempt
			if scenario != "missing locator" {
				gs.ObjectMeta.Annotations[agones.ClaimLocatorAnnotation] = "v1." + nakamalease.ReservationKey(lease.UserID, lease.ReservationID) + "." + attempt
			}
			f.PublishGameServer(gs)
			if scenario == "cleanup won" {
				if _, err := store.BeginRelease(t.Context(), record, lease.AttemptID); err != nil {
					t.Fatal(err)
				}
			}
			secret := opened.Secret()
			if scenario == "sibling token" {
				secret = bytes.Repeat([]byte{42}, 32)
			}
			token, err := zonesock.MintToken(secret, lease.AllocationID, 1, lease.ExpiresAt)
			if err != nil {
				t.Fatal(err)
			}
			certBytes, err := fs.ReadFile(os.DirFS(filepath.Dir(cert)), filepath.Base(cert))
			if err != nil {
				t.Fatal(err)
			}
			zoneRoots := x509.NewCertPool()
			if !zoneRoots.AppendCertsFromPEM(certBytes) {
				t.Fatal("invalid zone fixture root")
			}
			transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: zoneRoots, ServerName: "zone.test"}}
			defer transport.CloseIdleConnections()
			options := &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}, HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			var connection *websocket.Conn
			for {
				var response *http.Response
				connection, response, err = websocket.Dial(ctx, "wss://"+addr+"/zone", options)
				if response != nil && response.Body != nil {
					_ = response.Body.Close()
				}
				localRefusal := scenario == "missing locator" || scenario == "sibling token"
				if localRefusal || err == nil || ctx.Err() != nil || privateRequests.Load() > 0 {
					break
				}
				time.Sleep(5 * time.Millisecond) // allow the real SDK watch to deliver allocation
			}
			if connection != nil {
				defer func() { _ = connection.CloseNow() }()
			}
			stored, loadErr := store.Load(t.Context(), lease.UserID, lease.ReservationID)
			if loadErr != nil {
				t.Fatal(loadErr)
			}
			if scenario != "valid" {
				if err == nil || !stored.Lease.ClaimedAt.IsZero() {
					t.Fatal("refused claim admitted or changed a lease")
				}
				localRefusal := scenario == "missing locator" || scenario == "sibling token"
				if localRefusal && privateRequests.Load() != 0 || !localRefusal && privateRequests.Load() == 0 {
					t.Fatal("refusal did not exercise its intended local or private boundary")
				}
				return
			}
			if err != nil {
				t.Fatalf("valid admission: %v", err)
			}
			if stored.Lease.ClaimedAt.IsZero() {
				t.Fatal("socket opened before its durable lease was claimed")
			}
			_, payload, err := connection.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			message, err := wire.Decode(payload)
			if err != nil || message.Snapshot.Observer != 1 {
				t.Fatal("missing real observer snapshot")
			}
			if _, err := store.BeginRelease(t.Context(), record, lease.AttemptID); !errors.Is(err, nakamalease.ErrClaimed) {
				t.Fatalf("no-show cleanup stole claim: %v", err)
			}
		})
	}
}

// TestPrivateClaimsDisabledIgnoresMaterial catches eager credential loading and activation.
func TestPrivateClaimsDisabledIgnoresMaterial(t *testing.T) {
	cmd := zoneCommand(t, "-ticks", "1", "-claim-url", "https://127.0.0.1:1/v1/claim", "-claim-ca", "/does-not-exist", "-claim-cert", "/does-not-exist", "-claim-key", "/does-not-exist")
	if output, err := cmd.CombinedOutput(); err != nil || !strings.Contains(string(output), "hash=") {
		t.Fatalf("disabled mode touched private dependencies: %v\n%s", err, output)
	}
}

// TestPrivateClaimConfigurationRefusedBeforeReady catches a partially configured
// opt-in silently falling back to the local token-only path or developer minting.
func TestPrivateClaimConfigurationRefusedBeforeReady(t *testing.T) {
	for _, args := range [][]string{
		{"-ticks", "1"},
		{"-mint-token", "1", "-allocation-id", "zone-1"},
		{"-listen", "127.0.0.1:0", "-insecure-plaintext", "-allocation-id", "zone-1", "-duration", "10ms"},
		{"-listen", "127.0.0.1:0", "-agones", "-insecure-plaintext", "-agones-admission-public-key", "unused", "-duration", "10ms"},
	} {
		cmd := zoneCommand(t, append(args, "-private-claims")...)
		cmd.Env = append(os.Environ(), "WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32))
		output, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(output), "private claims:") {
			t.Errorf("incomplete private mode was not refused at its boundary: %v\n%s", err, output)
		}
	}
}

// TestPrivateClaimClientRejectsUnusableMaterial prevents reporting a configured
// claim path whose local credential is unusable for client authentication.
func TestPrivateClaimClientRejectsUnusableMaterial(t *testing.T) {
	cert, key := writeSelfSignedCert(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))
	options := claimOptions{enabled: true, endpoint: "https://claims.example/v1/claim", caFile: cert, certFile: cert, keyFile: key}
	client, err := options.client()
	if client != nil {
		client.Close()
	}
	if err == nil {
		t.Fatal("server-only certificate accepted as a workload client")
	}
}
