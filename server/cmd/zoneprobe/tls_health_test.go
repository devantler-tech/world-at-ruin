package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// The regression is a probe that drops TCP before TLS completes, enters HTTP
// admission, reads an ambient token, or leaves its connection open.
func TestTLSOnlyRepeatedHandshakeHasNoAdmissionOrHTTPEffects(t *testing.T) {
	var requests, opened, closed atomic.Int64
	var serverLog lockedProbeLog
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		requests.Add(1)
	}))
	server.TLS = healthTLSConfig(t)
	server.Config.ErrorLog = log.New(&serverLog, "", 0)
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		switch state {
		case http.StateNew:
			opened.Add(1)
		case http.StateClosed:
			closed.Add(1)
		case http.StateActive, http.StateIdle, http.StateHijacked:
		}
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	target, ca := probeTarget(t, server)
	for range 20 {
		var out, errOut bytes.Buffer
		code := run(t.Context(), []string{"-tls-only", "-url", target, "-ca-file", ca, "-tls-server-name-file", ca, "-timeout", "1s"}, func(string) string {
			t.Fatal("TLS health read the admission environment")
			return ""
		}, &out, &errOut)
		if code != 0 || out.String() != "ZONEPROBE TLS PASS\n" || errOut.Len() != 0 {
			t.Fatalf("TLS-only check failed: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
		}
		assertPrivateOutput(t, out.String()+errOut.String(), target, ca, server.Certificate().DNSNames[0])
	}
	deadline := time.Now().Add(time.Second)
	for closed.Load() < 20 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if opened.Load() != 20 || closed.Load() != 20 || requests.Load() != 0 || serverLog.String() != "" {
		t.Fatalf("health check side effects: opened=%d closed=%d requests=%d log=%q", opened.Load(), closed.Load(), requests.Load(), serverLog.String())
	}
}

type lockedProbeLog struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

// Write records concurrent server diagnostics for the quiet-handshake assertion.
func (l *lockedProbeLog) Write(data []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buffer.Write(data)
}

// String returns diagnostics without racing the server's log writer.
func (l *lockedProbeLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buffer.String()
}

// Keep the actual parent context part of the health contract.
func TestTLSOnlyCancelledParentFails(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("cancelled TLS-only check entered HTTP")
	}))
	t.Cleanup(server.Close)
	target, ca := probeTarget(t, server)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	var out, errOut bytes.Buffer
	code := run(ctx, []string{"-tls-only", "-url", target, "-ca-file", ca}, fixtureEnvironment, &out, &errOut)
	if code != 1 || out.Len() != 0 || errOut.String() != "zoneprobe: TLS health verification failed\n" {
		t.Fatalf("cancelled parent accepted: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
	}
}

// TestTLSOnlyRejectsUnverifiedPeers requires trust, identity, expiry and TLS itself.
func TestTLSOnlyRejectsUnverifiedPeers(t *testing.T) {
	for _, kind := range []string{"untrusted", "wrong identity", "expired", "plaintext"} {
		t.Run(kind, func(t *testing.T) {
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
				t.Error("TLS health entered HTTP")
			}))
			if kind == "expired" {
				// StartTLS supplies the fixture key before installing the expired leaf.
				fixture := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
				certificate := changedProbeCertificate(t, fixture, func(cert *x509.Certificate) {
					cert.NotBefore = time.Now().Add(-2 * time.Hour)
					cert.NotAfter = time.Now().Add(-time.Hour)
				})
				server.TLS = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}}
				fixture.Close()
			}
			if kind == "plaintext" {
				server.Start()
			} else {
				server.StartTLS()
			}
			t.Cleanup(server.Close)
			target := "wss" + strings.TrimPrefix(strings.TrimPrefix(server.URL, "https"), "http") + "/zone"
			args := []string{"-tls-only", "-url", target, "-timeout", "250ms"}
			if kind != "plaintext" && kind != "untrusted" {
				_, ca := probeTarget(t, server)
				args = append(args, "-ca-file", ca)
			}
			if kind == "wrong identity" {
				args = append(args, "-tls-server-name", "wrong.example")
			}
			var out, errOut bytes.Buffer
			code := run(t.Context(), args, fixtureEnvironment, &out, &errOut)
			if code != 1 || out.Len() != 0 || errOut.String() != "zoneprobe: TLS health verification failed\n" {
				t.Fatalf("unverified TLS peer accepted: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
			}
			assertPrivateOutput(t, out.String()+errOut.String(), target, "wrong.example")
		})
	}
}

// TestTLSOnlyIdentityFileDoesNotTrustOrAdoptThePeer keeps identity and trust independent.
func TestTLSOnlyIdentityFileDoesNotTrustOrAdoptThePeer(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("TLS health entered HTTP")
	}))
	server.TLS = healthTLSConfig(t)
	server.StartTLS()
	t.Cleanup(server.Close)
	target, ca := probeTarget(t, server)
	for _, kind := range []string{"untrusted peer", "wrong local identity"} {
		t.Run(kind, func(t *testing.T) {
			identity := ca
			args := []string{"-tls-only", "-url", target, "-timeout", "250ms"}
			if kind == "wrong local identity" {
				cert := changedProbeCertificate(t, server, func(cert *x509.Certificate) {
					cert.DNSNames = []string{"wrong.example"}
					cert.IPAddresses = nil
				})
				identity = writeIdentityCertificate(t, cert.Certificate[0])
				args = append(args, "-ca-file", ca)
			}
			args = append(args, "-tls-server-name-file", identity)
			var out, errOut bytes.Buffer
			code := run(t.Context(), args, fixtureEnvironment, &out, &errOut)
			if code != 1 || out.Len() != 0 || errOut.String() != "zoneprobe: TLS health verification failed\n" {
				t.Fatalf("identity file became peer trust/identity: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
			}
			assertPrivateOutput(t, out.String()+errOut.String(), target, ca, identity, "wrong.example")
		})
	}
}

// TestTLSOnlyStalledPeerIsBoundedAndConnectionCloses checks timeout and socket release.
func TestTLSOnlyStalledPeerIsBoundedAndConnectionCloses(t *testing.T) {
	listener, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	var out, errOut bytes.Buffer
	started := time.Now()
	code := run(t.Context(), []string{"-tls-only", "-url", "wss://" + listener.Addr().String() + "/zone", "-timeout", "80ms"}, fixtureEnvironment, &out, &errOut)
	if code != 1 || time.Since(started) > time.Second || errOut.String() != "zoneprobe: TLS health verification failed\n" {
		t.Fatalf("stalled peer not bounded: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
	}
	select {
	case conn := <-accepted:
		defer func() { _ = conn.Close() }()
		if err := conn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		if _, err := io.Copy(io.Discard, conn); err != nil {
			t.Fatalf("probe retained stalled connection: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("test never reached the stalled listener")
	}
}

// TestTLSOnlyDeadlineIncludesBlockedCloseNotify covers cancellation of a peer
// that has completed its handshake but refuses to read the shutdown record.
func TestTLSOnlyDeadlineIncludesBlockedCloseNotify(t *testing.T) {
	serverRaw, clientRaw := net.Pipe()
	defer func() { _ = serverRaw.Close() }()
	defer func() { _ = clientRaw.Close() }()
	serverConfig := healthTLSConfig(t)
	serverConfig.MinVersion = tls.VersionTLS13
	leaf, err := x509.ParseCertificate(serverConfig.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	trust := x509.NewCertPool()
	trust.AddCert(leaf)
	server := tls.Server(serverRaw, serverConfig)
	handshake := make(chan error, 1)
	go func() {
		handshake <- server.HandshakeContext(t.Context())
		// Deliberately do not read after handshake.
	}()
	// Setup has its own safety bound. Cancellation starts only after observing
	// the real close-notify write, so a slow handshake cannot satisfy this test.
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	shutdown := &closeNotifyProbeConn{Conn: clientRaw, started: make(chan struct{})}
	result := make(chan error, 1)
	go func() {
		result <- completeTLSHealth(ctx, shutdown, &tls.Config{
			MinVersion: tls.VersionTLS13,
			RootCAs:    trust, ServerName: "zoneprobe.example",
		})
	}()
	select {
	case <-shutdown.started:
	case err := <-result:
		t.Fatalf("probe ended before reaching blocked TLS shutdown: %v", err)
	case <-ctx.Done():
		t.Fatal("test did not reach the shutdown record")
	}
	select {
	case err := <-handshake:
		if err != nil {
			t.Fatalf("test did not reach a successful handshake: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("server handshake remained blocked")
	}
	started := time.Now()
	cancel()
	select {
	case err := <-result:
		if err == nil || time.Since(started) > time.Second {
			t.Fatalf("TLS close escaped cancellation: elapsed=%s err=%v", time.Since(started), err)
		}
	case <-time.After(time.Second):
		t.Fatal("TLS close remained blocked after cancellation")
	}
}

// closeNotifyProbeConn observes the second encrypted record from this TLS 1.3
// client: Finished completes its unauthenticated-client handshake, then Close
// writes the alert. net.Pipe still blocks that write until production releases it.
type closeNotifyProbeConn struct {
	net.Conn
	started          chan struct{}
	once             sync.Once
	encryptedRecords int
}

func (conn *closeNotifyProbeConn) Write(payload []byte) (int, error) {
	// A write can contain several complete TLS records (including the
	// compatibility ChangeCipherSpec); count encrypted records by framing.
	for remaining := payload; len(remaining) >= 5; {
		size := 5 + (int(remaining[3]) << 8) + int(remaining[4])
		if size > len(remaining) {
			break
		}
		if remaining[0] == 23 { // TLS 1.3 encrypted record.
			conn.encryptedRecords++
			if conn.encryptedRecords == 2 {
				conn.once.Do(func() { close(conn.started) })
			}
		}
		remaining = remaining[size:]
	}
	return conn.Conn.Write(payload)
}

// changedProbeCertificate signs controlled identity or lifetime variations with a fixture key.
func changedProbeCertificate(t *testing.T, server *httptest.Server, change func(*x509.Certificate)) tls.Certificate {
	t.Helper()
	certificate := server.TLS.Certificates[0]
	template := *server.Certificate()
	template.SerialNumber = big.NewInt(2)
	change(&template)
	encoded, err := x509.CreateCertificate(rand.Reader, &template, &template, template.PublicKey, certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate.Certificate = [][]byte{encoded}
	certificate.Leaf = nil
	return certificate
}

// healthTLSConfig supplies the single-DNS leaf required by configured-identity probes.
func healthTLSConfig(t *testing.T) *tls.Config {
	t.Helper()
	fixture := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer fixture.Close()
	certificate := changedProbeCertificate(t, fixture, func(cert *x509.Certificate) {
		cert.DNSNames = []string{"zoneprobe.example"}
	})
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}}
}

// writeIdentityCertificate stores only a fixture public certificate with private file permissions.
func writeIdentityCertificate(t *testing.T, encoded []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "declared-identity.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: encoded}), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestCertificateInputsRejectMalformedBlocksBeforeValidMaterial prevents PEM scan-ahead.
func TestCertificateInputsRejectMalformedBlocksBeforeValidMaterial(t *testing.T) {
	config := healthTLSConfig(t)
	valid := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: config.Certificates[0].Certificate[0]})
	malformed := []byte("-----BEGIN CERTIFICATE-----\ninvalid-base64!\n-----END CERTIFICATE-----\n")
	for _, data := range [][]byte{
		append(append([]byte{}, malformed...), valid...),
		append(append(append([]byte{}, valid...), malformed...), valid...),
		append([]byte("-----BEGIN CERTIFICATE-----\n"), valid...),
		append([]byte("untrusted preamble\n"), valid...),
		append(append([]byte{}, bytes.TrimSpace(valid)...), valid...),
		append(append([]byte{}, valid...), []byte("trailing junk")...),
	} {
		path := filepath.Join(t.TempDir(), "malformed.pem")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := certificateDNSName(path); err == nil {
			t.Error("malformed declared identity accepted")
		}
		if _, err := roots(path); err == nil {
			t.Error("malformed trust input accepted")
		}
	}
}

// TestTLSOnlyInvalidIdentityConfigurationFailsBeforeEnvironmentOrNetwork refuses ambiguous overrides.
func TestTLSOnlyInvalidIdentityConfigurationFailsBeforeEnvironmentOrNetwork(t *testing.T) {
	config := healthTLSConfig(t)
	leaf, err := x509.ParseCertificate(config.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, names := range [][]string{nil, {"one.example", "two.example"}, {"*.example"}, {"localhost"}, {"127.0.0.1"}} {
		copy := *leaf
		copy.DNSNames = names
		encoded, err := x509.CreateCertificate(rand.Reader, &copy, &copy, copy.PublicKey, config.Certificates[0].PrivateKey)
		if err != nil {
			t.Fatal(err)
		}
		path := writeIdentityCertificate(t, encoded)
		var out, errOut bytes.Buffer
		code := run(t.Context(), []string{"-tls-only", "-url", "wss://127.0.0.1:1/zone", "-tls-server-name-file", path}, func(string) string {
			t.Fatal("invalid health configuration read admission material")
			return ""
		}, &out, &errOut)
		if code != 2 || out.Len() != 0 || errOut.String() != "zoneprobe: invalid TLS identity material\n" {
			t.Fatalf("invalid identity accepted: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
		}
		assertPrivateOutput(t, out.String()+errOut.String(), path)
	}
	for _, args := range [][]string{
		{"-url", "wss://127.0.0.1:1/zone", "-tls-server-name-file", "private.pem"},
		{"-tls-only", "-url", "wss://remote.example/zone", "-tls-server-name-file", "private.pem"},
		{"-tls-only", "-url", "wss://127.0.0.1:1/zone", "-tls-server-name-file", "private.pem", "-tls-server-name", "zoneprobe.example"},
	} {
		var out, errOut bytes.Buffer
		code := run(t.Context(), args, func(string) string {
			t.Fatal("invalid override read admission material")
			return ""
		}, &out, &errOut)
		if code != 2 || out.Len() != 0 || errOut.String() != "zoneprobe: invalid TLS identity override\n" {
			t.Fatalf("invalid override accepted: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
		}
		assertPrivateOutput(t, out.String()+errOut.String(), "private.pem", "remote.example")
	}
}

// TestTLSOnlyCertificateInputBoundsAndValidChain requires bounded strict PEM while accepting chains.
func TestTLSOnlyCertificateInputBoundsAndValidChain(t *testing.T) {
	config := healthTLSConfig(t)
	valid := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: config.Certificates[0].Certificate[0]})
	for _, data := range [][]byte{nil, bytes.Repeat([]byte(" "), maxCABytes+1), pem.EncodeToMemory(&pem.Block{
		Type: "CERTIFICATE", Headers: map[string]string{"Unexpected": "header"}, Bytes: config.Certificates[0].Certificate[0],
	})} {
		path := filepath.Join(t.TempDir(), "refused.pem")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := certificateDNSName(path); err == nil {
			t.Fatal("empty, oversized or header-bearing identity accepted")
		}
	}
	path := filepath.Join(t.TempDir(), "chain.pem")
	if err := os.WriteFile(path, append(append([]byte{}, valid...), valid...), 0o600); err != nil {
		t.Fatal(err)
	}
	if name, err := certificateDNSName(path); err != nil || name != "zoneprobe.example" {
		t.Fatalf("bounded certificate chain refused: name=%q err=%v", name, err)
	}
}

type refusedProbeOutput struct{}

// Write simulates a failed verdict destination after successful TLS verification.
func (refusedProbeOutput) Write([]byte) (int, error) {
	return 0, errors.New("output unavailable")
}

// TestTLSOnlyFailedOutputCannotReportSuccess makes output failure part of the exit verdict.
func TestTLSOnlyFailedOutputCannotReportSuccess(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("TLS health entered HTTP")
	}))
	defer server.Close()
	target, ca := probeTarget(t, server)
	var errOut bytes.Buffer
	if code := run(t.Context(), []string{"-tls-only", "-url", target, "-ca-file", ca}, func(string) string {
		t.Fatal("health check read admission material")
		return ""
	}, refusedProbeOutput{}, &errOut); code != 1 || errOut.Len() != 0 {
		t.Fatalf("failed output reported success: code=%d stderr=%q", code, errOut.String())
	}
}
