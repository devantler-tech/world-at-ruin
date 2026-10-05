package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

// The ordinary server job does not install Godot. Required client CI explicitly
// opts into this acceptance, where missing native prerequisites are failures.
func TestNativeGodotMovement(t *testing.T) {
	if os.Getenv("WAR_GODOT_ZONE_PROOF") != "1" {
		t.Skip("native Godot zone proof requires WAR_GODOT_ZONE_PROOF=1")
	}
	if _, err := exec.LookPath("godot"); err != nil {
		t.Fatal("native movement proof requires Godot")
	}
	for _, mode := range []string{"retained", "positive", "server_off", "wrong_identity", "wrong_trust"} {
		t.Run(mode, func(t *testing.T) { nativeMovementCase(t, mode) })
	}
}

// nativeMovementCase starts the built TLS zone and observes one bounded Godot
// client session, requiring the named success or exact refusal boundary.
func nativeMovementCase(t *testing.T, mode string) {
	t.Helper()
	port := closedPort(t)
	cert, key := writeSelfSignedCert(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))
	args := []string{"-listen", "127.0.0.1:" + port, "-allocation-id", "native-client", "-tls-cert", cert, "-tls-key", key, "-duration", "20s"}
	if mode != "server_off" {
		args = append(args, "-movement-intents", "-movement-hold-ticks", "2")
	}
	zone := zoneCommand(t, args...)
	zone.Env = append(os.Environ(), "WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32))
	if err := zone.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- zone.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = zone.Process.Kill()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("native zone did not retire")
		}
	})
	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := (&net.Dialer{Timeout: 100 * time.Millisecond}).DialContext(t.Context(), "tcp", "127.0.0.1:"+port)
		if err == nil {
			if closeErr := conn.Close(); closeErr != nil {
				t.Fatal(closeErr)
			}
			break
		}
		select {
		case err := <-done:
			t.Fatalf("native zone stopped before serving: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("native zone startup deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
	secret := bytes.Repeat([]byte{0xab}, 32)
	token, err := zonesock.MintToken(secret, "native-client", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	trust := cert
	if mode == "wrong_trust" {
		trust, _ = writeSelfSignedCert(t, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))
	}
	fixture, err := json.Marshal(map[string]string{"url": "wss://127.0.0.1:" + port + "/zone", "token": token, "certificate": trust, "mode": mode})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "fixture.json")
	if err := os.WriteFile(path, fixture, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "godot", "--headless", "--path", "client", "--script", "res://tests/zone_movement_network_probe.gd")
	cmd.Dir = "../../.."
	// Only fixed native fixture data crosses into the child; ambient trial
	// credentials or flags cannot choose a destination or weaken its trust.
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "WAR_") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	cmd.Env = append(cmd.Env, "WAR_ZONE_MOVEMENT_PROBE_FILE="+path)
	out, err := cmd.CombinedOutput()
	t.Logf("native %s output:\n%s", mode, out)
	if err != nil || ctx.Err() != nil || !bytes.Contains(out, []byte("TEST PASS: native zone movement "+mode)) || bytes.Contains(out, []byte("TEST FAIL")) || bytes.Contains(out, []byte("SCRIPT ERROR")) {
		t.Fatalf("native movement %s verdict failed: %v\n%s", mode, err, out)
	}
	// Refusals must reach the expected native boundary. Other engine errors
	// cannot coexist with a passing verdict, including in negative cases.
	expectedErrors := 0
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.HasPrefix(line, "ERROR:") {
			continue
		}
		// This secondary upgrade error is permitted only alongside a proved
		// HTTP 426 boundary; it cannot establish that refusal by itself.
		if mode == "server_off" && line == "ERROR: Invalid response headers." {
			continue
		}
		if !nativeMovementExpectedError(mode, line) {
			t.Fatalf("unexpected native engine error: %s", line)
		}
		expectedErrors++
	}
	if (mode == "server_off" || mode == "wrong_identity" || mode == "wrong_trust") && expectedErrors == 0 {
		t.Fatal("refusal never reached its native TLS/upgrade boundary")
	}
}

// nativeMovementExpectedError accepts only the native error that proves the
// requested refusal; unrelated engine errors cannot qualify a negative case.
func nativeMovementExpectedError(mode, line string) bool {
	switch mode {
	case "wrong_identity", "wrong_trust":
		return line == "ERROR: TLS handshake error: -9984"
	case "server_off":
		return line == "ERROR: Invalid status code. Got: '426', expected '101'."
	default:
		return false
	}
}

// TestNativeMovementRefusalErrorBoundary prevents generic engine failures from
// satisfying the native TLS identity, trust or protocol-negotiation controls.
func TestNativeMovementRefusalErrorBoundary(t *testing.T) {
	for _, row := range []struct {
		mode, line string
		want       bool
	}{
		{"wrong_identity", "ERROR: TLS handshake error: -9984", true},
		{"wrong_trust", "ERROR: TLS handshake error: -9984", true},
		{"server_off", "ERROR: Invalid status code. Got: '426', expected '101'.", true},
		{"server_off", "ERROR: Invalid response headers.", false},
		{"wrong_identity", "ERROR: Failed to load script", false},
		{"server_off", "ERROR: Failed to load script", false},
		{"positive", "ERROR: TLS handshake error: -9984", false},
		{"retained", "ERROR: Invalid response headers.", false},
	} {
		if got := nativeMovementExpectedError(row.mode, row.line); got != row.want {
			t.Errorf("engine refusal boundary %s: got %v, want %v", row.mode, got, row.want)
		}
	}
}
