package main

import (
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

// TestAgonesLifecycleEndToEnd runs the real binary, flag on, against the
// fake sidecar: the process must come up Ready, sustain heartbeats at the
// configured cadence, and Shutdown when its deadline exit fires.
func TestAgonesLifecycleEndToEnd(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)

	cmd := exec.Command(zoneBin,
		"-realtime", "-duration", "400ms",
		"-agones", "-agones-health-interval", "50ms",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("flag-on realtime run failed: %v\n%s", err, out)
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
		"-realtime", "-duration", "30s",
		"-agones", "-agones-health-interval", "50ms",
	)
	cmd.Env = append(os.Environ(),
		"AGONES_SDK_GRPC_HOST=127.0.0.1",
		"AGONES_SDK_GRPC_PORT="+f.PortString(),
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

// TestAgonesRequiresRealtime pins the loud refusal: the lifecycle on a
// fixed-tick CI run would be meaningless, so the flag without -realtime is a
// usage error, never a silent ignore.
func TestAgonesRequiresRealtime(t *testing.T) {
	out, err := exec.Command(zoneBin, "-agones").CombinedOutput()
	if err == nil {
		t.Fatalf("-agones without -realtime succeeded; want a usage error\n%s", out)
	}
	if !strings.Contains(string(out), "-agones requires -realtime") {
		t.Fatalf("refusal did not explain itself:\n%s", out)
	}
}
