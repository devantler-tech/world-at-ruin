package agones

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
)

// startFake runs the fake sidecar and points the real SDK's env-derived
// address at it. Every test that dials goes through the genuine
// agones.dev/agones client — the fake is only ever on the server side, so
// what is under test is the same wire conversation production has.
func startFake(t *testing.T, readyErr error) *agonestest.Sidecar {
	t.Helper()
	f, err := agonestest.Start(readyErr)
	if err != nil {
		t.Fatalf("start fake sidecar: %v", err)
	}
	t.Cleanup(f.Stop)
	t.Setenv("AGONES_SDK_GRPC_HOST", "127.0.0.1")
	t.Setenv("AGONES_SDK_GRPC_PORT", f.PortString())
	return f
}

// waitFor polls until cond holds or the deadline passes. Generous deadlines,
// tight polls: CI wall-clock is noise, so tests assert lower bounds within a
// wide window and never exact timings.
func waitFor(t *testing.T, d time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestStartMarksReadyOnceAndBeatsHealth(t *testing.T) {
	f := startFake(t, nil)

	l, err := Start(context.Background(), Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer func() {
		if err := l.Shutdown(); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	}()

	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls after Start = %d, want exactly 1", got)
	}
	// The loop beats immediately and then every interval; ≥3 beats proves
	// the cadence is live, not just the initial send.
	waitFor(t, 5*time.Second, func() bool { return f.HealthBeats() >= 3 }, "3 health beats")
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls while beating = %d, want exactly 1 (health must not re-ready)", got)
	}
}

func TestShutdownStopsHeartbeatsAndInformsSidecar(t *testing.T) {
	f := startFake(t, nil)

	l, err := Start(context.Background(), Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	waitFor(t, 5*time.Second, func() bool { return f.HealthBeats() >= 1 }, "first health beat")

	if err := l.Shutdown(); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown RPCs = %d, want exactly 1", got)
	}
	// Shutdown returns only after the health loop exits, so the beat count
	// is final now; any later beat is the loop outliving its lifecycle.
	final := f.HealthBeats()
	time.Sleep(100 * time.Millisecond)
	if got := f.HealthBeats(); got != final {
		t.Fatalf("health beats advanced after Shutdown: %d -> %d", final, got)
	}
}

func TestContextCancelStopsHeartbeatsButShutdownStillWorks(t *testing.T) {
	f := startFake(t, nil)

	ctx, cancel := context.WithCancel(context.Background())
	l, err := Start(ctx, Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	waitFor(t, 5*time.Second, func() bool { return f.HealthBeats() >= 1 }, "first health beat")

	cancel()
	// The exit path must still be able to inform the sidecar after the
	// serving context died — that is the SIGTERM ordering in cmd/zone.
	if err := l.Shutdown(); err != nil {
		t.Fatalf("Shutdown after cancel: %v", err)
	}
	if got := f.ShutdownCalls(); got != 1 {
		t.Fatalf("Shutdown RPCs = %d, want exactly 1", got)
	}
}

func TestStartFailsLoudWhenReadyRefused(t *testing.T) {
	f := startFake(t, errors.New("no capacity"))

	if _, err := Start(context.Background(), Config{Logf: t.Logf}); err == nil {
		t.Fatal("Start succeeded although the sidecar refused Ready; want a loud error")
	}
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready attempts = %d, want 1", got)
	}
}

func TestStartFailsLoudWhenDialFails(t *testing.T) {
	// The real SDK dial blocks up to 30s on an unreachable sidecar, so the
	// dial-failure contract is pinned through the seam instead of a slow
	// literal dial; TestStartMarksReadyOnceAndBeatsHealth proves the real
	// dial path against a live server.
	orig := dial
	dial = func() (sidecar, error) { return nil, errors.New("sidecar unreachable") }
	t.Cleanup(func() { dial = orig })

	if _, err := Start(context.Background(), Config{Logf: t.Logf}); err == nil {
		t.Fatal("Start succeeded although the dial failed; want a loud error")
	}
}
