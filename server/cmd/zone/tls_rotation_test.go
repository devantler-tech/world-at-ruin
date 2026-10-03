package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// New handshakes must see the currently projected certificate without recycling
// the serving process. Exercise the built command, not an isolated TLS callback.
func TestListenReloadsCertificateFiles(t *testing.T) {
	now := time.Now()
	certFile, keyFile := writeSelfSignedCert(t, now.Add(-time.Hour), now.Add(time.Hour))
	nextCert, nextKey := writeSelfSignedCert(t, now.Add(-time.Hour), now.Add(2*time.Hour))
	config := rotationClientConfig(t, certFile, nextCert)
	addr := startTLSZone(t, certFile, keyFile)
	before := handshakeCertificate(t, addr, config)
	replaceTLSFiles(t, certFile, keyFile, nextCert, nextKey)
	after := handshakeCertificate(t, addr, config)
	if bytes.Equal(before, after) {
		t.Fatal("new handshake retained the startup certificate after replacement")
	}
	pair, err := tls.LoadX509KeyPair(nextCert, nextKey)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, pair.Certificate[0]) {
		t.Fatal("new handshake did not serve the exact replacement certificate")
	}
}

func TestListenRejectsInvalidCertificateReplacement(t *testing.T) {
	for _, kind := range []string{"missing", "malformed", "mismatched key", "expired", "not yet valid"} {
		t.Run(kind, func(t *testing.T) {
			now := time.Now()
			certFile, keyFile := writeSelfSignedCert(t, now.Add(-time.Hour), now.Add(time.Hour))
			config := rotationClientConfig(t, certFile)
			addr := startTLSZone(t, certFile, keyFile)
			before := handshakeCertificate(t, addr, config)
			savedCert, savedKey := readTLSFiles(t, certFile, keyFile)
			switch kind {
			case "missing":
				if err := os.Remove(certFile); err != nil {
					t.Fatal(err)
				}
			case "malformed":
				writeTLSFile(t, certFile, []byte("invalid certificate"))
			case "mismatched key":
				_, otherKey := writeSelfSignedCert(t, now.Add(-time.Hour), now.Add(time.Hour))
				writeTLSFile(t, keyFile, readTLSFile(t, otherKey))
			case "expired":
				badCert, badKey := writeSelfSignedCert(t, now.Add(-2*time.Hour), now.Add(-time.Hour))
				replaceTLSFiles(t, certFile, keyFile, badCert, badKey)
			case "not yet valid":
				badCert, badKey := writeSelfSignedCert(t, now.Add(time.Hour), now.Add(2*time.Hour))
				replaceTLSFiles(t, certFile, keyFile, badCert, badKey)
			}
			dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: time.Second}, Config: config}
			conn, err := dialer.DialContext(t.Context(), "tcp", addr)
			if conn != nil {
				if closeErr := conn.Close(); closeErr != nil {
					t.Error(closeErr)
				}
			}
			if err == nil {
				t.Fatal("invalid replacement silently fell back to the startup certificate")
			}
			if !strings.Contains(err.Error(), "remote error: tls:") {
				t.Fatalf("server did not refuse invalid material before sending a certificate: %v", err)
			}
			writeTLSFile(t, certFile, savedCert)
			writeTLSFile(t, keyFile, savedKey)
			if got := handshakeCertificate(t, addr, config); !bytes.Equal(got, before) {
				t.Fatal("listener did not recover after valid certificate material returned")
			}
		})
	}
}

func rotationClientConfig(t *testing.T, certFiles ...string) *tls.Config {
	t.Helper()
	roots := x509.NewCertPool()
	for _, path := range certFiles {
		if !roots.AppendCertsFromPEM(readTLSFile(t, path)) {
			t.Fatal("load fixture trust roots")
		}
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots, ServerName: "zone.test",
		ClientSessionCache: tls.NewLRUClientSessionCache(1),
	}
}

func handshakeCertificate(t *testing.T, addr string, config *tls.Config) []byte {
	t.Helper()
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: time.Second}, Config: config}
	connection, err := dialer.DialContext(t.Context(), "tcp", addr)
	if err != nil {
		t.Fatalf("verified handshake: %v", err)
	}
	conn, ok := connection.(*tls.Conn)
	if !ok {
		t.Fatal("verified dial did not return a TLS connection")
	}
	// Read post-handshake tickets if a regression enables them. A resumed
	// session must not bypass checking newly projected certificate material.
	if err := conn.SetReadDeadline(time.Now().Add(20 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var data [1]byte
	if _, err := conn.Read(data[:]); err == nil || !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("unexpected idle TLS read: %v", err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	state := conn.ConnectionState()
	if state.DidResume {
		t.Fatal("session resumption bypassed the current certificate check")
	}
	return state.PeerCertificates[0].Raw
}

func readTLSFiles(t *testing.T, certFile, keyFile string) ([]byte, []byte) {
	t.Helper()
	return readTLSFile(t, certFile), readTLSFile(t, keyFile)
}

func readTLSFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := fs.ReadFile(os.DirFS(filepath.Dir(path)), filepath.Base(path))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func replaceTLSFiles(t *testing.T, certFile, keyFile, nextCert, nextKey string) {
	t.Helper()
	cert, key := readTLSFiles(t, nextCert, nextKey)
	writeTLSFile(t, certFile, cert)
	writeTLSFile(t, keyFile, key)
}

func writeTLSFile(t *testing.T, path string, data []byte) {
	t.Helper()
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := root.Close(); err != nil {
			t.Error(err)
		}
	}()
	if err := root.WriteFile(filepath.Base(path), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// The production listener has no deadline; its normal SIGTERM still drains and
// exits successfully. Each test bounds startup and cleanup independently.
func startTLSZone(t *testing.T, certFile, keyFile string) string {
	t.Helper()
	cmd := zoneCommand(t, "-listen", "127.0.0.1:0", "-allocation-id", "rotation-test", "-tls-cert", certFile, "-tls-key", keyFile)
	cmd.Env = append(os.Environ(), "WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32))
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	listening := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(output).ReadString('\n')
		listening <- line
	}()
	t.Cleanup(func() {
		if err := cmd.Process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			t.Error(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("zone did not stop cleanly: %v", err)
			}
		case <-time.After(5 * time.Second):
			if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
				t.Error(err)
			}
			<-done
			t.Error("zone ignored its shutdown deadline")
		}
	})
	select {
	case line := <-listening:
		const prefix = "zone: listening on wss://"
		if !strings.HasPrefix(line, prefix) || !strings.HasSuffix(line, "/zone\n") {
			t.Fatalf("listener did not start: %q", line)
		}
		return strings.TrimSuffix(strings.TrimPrefix(line, prefix), "/zone\n")
	case <-time.After(10 * time.Second):
		t.Fatal("zone listener startup timed out")
		return ""
	}
}
