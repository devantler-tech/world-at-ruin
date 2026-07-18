// Package agones owns the zone process's conversation with the Agones
// sidecar — the lifecycle contract that makes the binary deployable as a
// GameServer on the fleet (server-foundation epic).
//
// Agones's contract is hard: a GameServer that never calls Ready is never
// allocated, and one that stops calling Health is killed as unhealthy. This
// package speaks exactly that contract through the official Agones Go SDK —
// Ready once the serving loop is up, Health heartbeats on a fixed cadence,
// Shutdown when the process exits — and nothing else. It never touches the
// simulation: lifecycle signalling cannot move a tick, so every settled
// golden is structurally out of its reach.
//
// The whole package is opt-in (the zone command's -agones flag, default
// off). Flag off means no SDK dial at all — a local or CI run is
// byte-identical to a build without this package.
package agones

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	gosdk "agones.dev/agones/sdks/go"
)

// DefaultHealthInterval is the heartbeat cadence. Agones's default health
// spec expects a beat within every periodSeconds (5s) window; beating at
// less than half that means a single delayed send never trips the sidecar's
// failure threshold.
const DefaultHealthInterval = 2 * time.Second

// sidecar is the slice of the Agones SDK the lifecycle drives. It exists so
// tests can exercise failure paths without the real SDK's 30-second blocking
// dial; production always talks to the official client.
type sidecar interface {
	Ready() error
	Health() error
	Shutdown() error
}

// dial connects to the local sidecar. A package variable only so tests can
// substitute a failing dial; see sidecar.
var dial = func() (sidecar, error) {
	s, err := gosdk.NewSDK()
	if err != nil {
		return nil, err
	}
	return s, nil
}

// Config tunes a Lifecycle. The zero value is production-correct.
type Config struct {
	// HealthInterval overrides DefaultHealthInterval when positive.
	HealthInterval time.Duration
	// Logf receives non-fatal lifecycle events (a health send failing).
	// Nil logs to stderr.
	Logf func(format string, args ...any)
}

// Lifecycle is a started conversation with the sidecar: Ready has been
// sent and the health loop is beating. Stop it with Shutdown, exactly once.
type Lifecycle struct {
	mu   sync.Mutex // guards sdk: the health loop re-dials on stream loss
	sdk  sidecar
	logf func(format string, args ...any)
	stop context.CancelFunc
	done chan struct{}
}

func (l *Lifecycle) getSDK() sidecar {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sdk
}

func (l *Lifecycle) setSDK(s sidecar) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sdk = s
}

// Start dials the local sidecar, marks the GameServer Ready, and begins
// health heartbeats. It fails loudly on an unreachable sidecar or a refused
// Ready — running flagged-on without Agones present is a deployment error,
// never a silent no-op.
//
// Cancelling ctx stops the health loop; the process should still call
// Shutdown on exit so Agones reaps the GameServer instead of waiting for a
// health timeout.
func Start(ctx context.Context, cfg Config) (*Lifecycle, error) {
	s, err := dial()
	if err != nil {
		return nil, fmt.Errorf("agones: dial sidecar: %w", err)
	}
	if err := s.Ready(); err != nil {
		return nil, fmt.Errorf("agones: mark ready: %w", err)
	}

	interval := cfg.HealthInterval
	if interval <= 0 {
		interval = DefaultHealthInterval
	}
	logf := cfg.Logf
	if logf == nil {
		logf = func(format string, args ...any) {
			fmt.Fprintf(os.Stderr, "zone: "+format+"\n", args...)
		}
	}

	hctx, cancel := context.WithCancel(ctx)
	l := &Lifecycle{sdk: s, logf: logf, stop: cancel, done: make(chan struct{})}
	go l.healthLoop(hctx, interval)
	return l, nil
}

// healthLoop beats immediately and then on every interval tick, so a
// short-lived process still reports at least one beat. On a send error it
// RE-DIALS the sidecar and keeps beating: the SDK's health stream never
// heals once broken, so blind retries on the old handle would fail forever —
// while a fresh dial survives a sidecar restart and lets a healthy allocated
// zone keep its players. It never voluntarily goes silent while ctx lives.
// The re-dial deliberately does NOT re-send Ready: allocation state lives in
// the GameServer resource, and a fresh Ready could regress an Allocated
// server back to the Ready pool.
func (l *Lifecycle) healthLoop(ctx context.Context, interval time.Duration) {
	defer close(l.done)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if err := l.getSDK().Health(); err != nil {
			l.logf("agones: health beat failed (%v) — re-dialling the sidecar", err)
			if s, derr := dial(); derr != nil {
				l.logf("agones: re-dial failed, retrying on the next beat: %v", derr)
			} else {
				l.setSDK(s)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Shutdown stops the health loop, waits for it to exit, and tells the
// sidecar the process is done — Agones then deletes the GameServer. Call it
// exactly once, on every exit path of a flagged-on process.
func (l *Lifecycle) Shutdown() error {
	l.stop()
	<-l.done
	if err := l.getSDK().Shutdown(); err != nil {
		return fmt.Errorf("agones: shutdown: %w", err)
	}
	return nil
}
