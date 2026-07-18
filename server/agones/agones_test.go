package agones

import (
	"context"
	"errors"
	"sync/atomic"
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

// TestHealthBeatsSurviveSidecarStreamLoss pins the recovery contract: when
// the sidecar drops the health stream (a sidecar restart), the lifecycle
// re-dials and beats resume — it never voluntarily goes silent while its
// context lives. A dead gRPC client stream can never carry another send, so
// recovery MUST be a re-dial; blind retries on the old stream fail forever.
func TestHealthBeatsSurviveSidecarStreamLoss(t *testing.T) {
	f := startFake(t, nil)
	f.KillHealthStreamAt(2)

	l, err := Start(context.Background(), Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer func() {
		if err := l.Shutdown(); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	}()

	// Beats 1–2 arrive on the first stream, which the fake then kills; any
	// count beyond 2 can only come from a re-established conversation.
	waitFor(t, 10*time.Second, func() bool { return f.HealthBeats() >= 5 }, "beats resuming past the killed stream")
	if got := f.ReadyCalls(); got != 1 {
		t.Fatalf("Ready calls after re-dial = %d, want exactly 1 (re-dial must NOT re-send Ready: it could regress an Allocated GameServer)", got)
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

// TestShutdownNotBlockedByHungRedial pins the termination-grace contract:
// the SDK's dial blocks up to ~30s, so when a health failure triggers a
// re-dial against an unreachable sidecar and SIGTERM arrives mid-dial,
// Shutdown must abandon the dial and return promptly instead of burning the
// pod's grace period behind it.
func TestShutdownNotBlockedByHungRedial(t *testing.T) {
	f := startFake(t, nil)
	f.KillHealthStreamAt(1)

	// First dial (Start) is real; every later dial (the recovery path)
	// hangs until the test ends — the unreachable-sidecar shape.
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	orig := dial
	var dials atomic.Int32
	dial = func() (sidecar, error) {
		if dials.Add(1) == 1 {
			return orig()
		}
		<-release
		return nil, errors.New("hung dial released by test teardown")
	}
	t.Cleanup(func() { dial = orig })

	l, err := Start(context.Background(), Config{HealthInterval: 20 * time.Millisecond, Logf: t.Logf})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	// One beat lands, the fake kills the stream, the next beat fails and
	// the loop enters the hung re-dial.
	waitFor(t, 5*time.Second, func() bool { return dials.Load() >= 2 }, "the health loop to enter the recovery dial")

	done := make(chan error, 1)
	go func() { done <- l.Shutdown() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Shutdown: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown blocked behind the hung re-dial; want a prompt return")
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
