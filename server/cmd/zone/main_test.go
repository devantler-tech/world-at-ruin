package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
)

// The tests here run the built zone binary — the same artifact an operator
// runs — so the -agones flag contract is pinned at the user surface, in both
// states, not only at the package level.

var zoneBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "zone-bin-*")
	if err != nil {
		panic(err)
	}
	zoneBin = filepath.Join(dir, "zone")
	build := exec.Command("go", "build", "-o", zoneBin, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		os.RemoveAll(dir)
		panic("build zone binary: " + err.Error())
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// closedPort returns a loopback port that was just released, so nothing is
// listening on it for the duration of a short test.
func closedPort(t *testing.T) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("probe port: %v", err)
	}
	_, port, _ := net.SplitHostPort(lis.Addr().String())
	lis.Close()
	return port
}

// TestRealtimeWithoutAgonesNeverDials pins the default-off state: with no
// sidecar anywhere (the env points at a closed port), a plain -realtime run
// must succeed untouched. If the lifecycle ever ran unflagged, Ready would
// fail against the closed port and the exit code would flip — so this test
// goes red if anyone flips the default on.
func TestRealtimeWithoutAgonesNeverDials(t *testing.T) {
	cmd := exec.Command(zoneBin, "-realtime", "-duration", "150ms")
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+closedPort(t),
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("flag-off realtime run failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "hash=") {
		t.Fatalf("flag-off realtime run did not print the closing hash line:\n%s", out)
	}
}

// writeSelfSignedCert generates an ECDSA key pair and a self-signed
// certificate valid between notBefore and notAfter, writes both as PEM
// files, and returns their paths — the fixture for the TLS-validity gates.
func writeSelfSignedCert(t *testing.T, notBefore, notAfter time.Time) (certFile, keyFile string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "zone.test"},
		DNSNames:     []string{"zone.test"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	dir := t.TempDir()
	certFile = filepath.Join(dir, "cert.pem")
	keyFile = filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return certFile, keyFile
}

// TestAgonesServesRealTLSWhenCertValid is the fleet shape end-to-end with
// nothing faked but the sidecar: a valid certificate, the real wss listener,
// Ready exactly once, live heartbeats, and a Shutdown on the deadline exit.
func TestAgonesServesRealTLSWhenCertValid(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)
	certFile, keyFile := writeSelfSignedCert(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))

	cmd := exec.Command(zoneBin,
		"-allocation-id", "allocation-a", "-listen", "127.0.0.1:0", "-tls-cert", certFile, "-tls-key", keyFile,
		"-duration", "400ms",
		"-agones", "-agones-health-interval", "50ms",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
		"WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32),
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("valid-cert wss run failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "zone: listening on wss://") {
		t.Fatalf("wss listener never came up:\n%s", out)
	}
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls = %d, want exactly 1", got)
	}
	// 400ms at a 50ms cadence is ~8 beats; ≥3 keeps the bound generous
	// against CI wall-clock noise while still proving a live cadence.
	if got := f.HealthBeats(); got < 3 {
		t.Fatalf("health beats = %d, want at least 3", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1 (a deadline exit must still inform the sidecar)", got)
	}
}

// TestAgonesRefusesReadyWhenCertExpired pins the validity-window gate: a
// parseable but expired certificate is an endpoint no client will accept, so
// the process must die loudly with Ready never sent.
func TestAgonesRefusesReadyWhenCertExpired(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)
	certFile, keyFile := writeSelfSignedCert(t, time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour))

	cmd := exec.Command(zoneBin,
		"-allocation-id", "allocation-a", "-listen", "127.0.0.1:0", "-tls-cert", certFile, "-tls-key", keyFile,
		// The gate refuses before serving, so the deadline never matters on
		// the intended path — it exists so a REGRESSION (gate gone, process
		// serving) fails this test quickly instead of hanging it.
		"-duration", "300ms",
		"-agones",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
		"WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32),
	)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("expired-cert run succeeded; want a loud failure\n%s", out)
	}
	if !strings.Contains(string(out), "validity window") {
		t.Fatalf("failure did not name the validity window:\n%s", out)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0: an unusable endpoint must never declare Ready", got)
	}
}

// TestAgonesSigtermShutsDownCleanly sends the signal Agones actually sends
// (SIGTERM) mid-run and requires a clean exit that still informed the
// sidecar — the drain path an operator's fleet depends on.
func TestAgonesSigtermShutsDownCleanly(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)

	cmd := exec.Command(zoneBin,
		"-allocation-id", "allocation-a", "-listen", "127.0.0.1:0", "-insecure-plaintext",
		"-duration", "30s",
		"-agones", "-agones-health-interval", "50ms",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
		"WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32),
	)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start zone: %v", err)
	}
	// Wait for liveness (the first beat) before signalling, so the test
	// exercises a running process, not a starting one.
	deadline := time.Now().Add(10 * time.Second)
	for f.HealthBeats() < 1 {
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			t.Fatal("timed out waiting for the first health beat")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("signal: %v", err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("zone exited non-zero after SIGTERM: %v", err)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls after signal = %d, want exactly 1", got)
	}
}

// TestAgonesRefusesReadyWhenTLSBroken pins Ready-means-servable: with an
// unloadable certificate, the process must die loudly WITHOUT ever telling
// Agones it is Ready — otherwise the fleet allocates a GameServer whose TLS
// endpoint never came up.
func TestAgonesRefusesReadyWhenTLSBroken(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)

	cmd := exec.Command(zoneBin,
		"-allocation-id", "allocation-a", "-listen", "127.0.0.1:0",
		"-tls-cert", filepath.Join(t.TempDir(), "missing-cert.pem"),
		"-tls-key", filepath.Join(t.TempDir(), "missing-key.pem"),
		"-agones",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
		"WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32),
	)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("broken-TLS run succeeded; want a loud failure\n%s", out)
	}
	if got := f.ReadyCalls(); got != 0 {
		t.Fatalf("Ready calls = %d, want 0: a GameServer whose endpoint cannot start must never declare Ready", got)
	}
}

// TestAgonesRequiresListen pins the loud refusal: Ready must mean a
// connectable endpoint, so -agones without the socket — bare, or with the
// listener-less -realtime harness — is a usage error, never a silent ignore
// and never a Ready the fleet would trust.
func TestAgonesRequiresListen(t *testing.T) {
	for _, args := range [][]string{
		{"-agones"},
		{"-agones", "-realtime", "-duration", "100ms"},
	} {
		out, err := exec.Command(zoneBin, args...).CombinedOutput()
		if err == nil {
			t.Fatalf("%v succeeded; want a usage error\n%s", args, out)
		}
		if !strings.Contains(string(out), "-agones requires -listen") {
			t.Fatalf("refusal for %v did not explain itself:\n%s", args, out)
		}
	}
}

// TestAgonesComposesWithListen runs the deployment shape a fleet GameServer
// actually has — the zone socket serving plus the Agones lifecycle — and
// requires Ready, live heartbeats, and a Shutdown on the deadline exit. This
// is the test that makes silently ignoring -agones in -listen mode
// impossible: with the wiring absent, ReadyCalls stays 0 and this fails.
func TestAgonesComposesWithListen(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)

	cmd := exec.Command(zoneBin,
		"-allocation-id", "allocation-a", "-listen", "127.0.0.1:0", "-insecure-plaintext",
		"-duration", "400ms",
		"-agones", "-agones-health-interval", "50ms",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
		"WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32),
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("listen+agones run failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "zone: listening on ws://") {
		t.Fatalf("socket never came up:\n%s", out)
	}
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls = %d, want exactly 1", got)
	}
	if got := f.HealthBeats(); got < 3 {
		t.Fatalf("health beats = %d, want at least 3", got)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown calls = %d, want exactly 1", got)
	}
}
