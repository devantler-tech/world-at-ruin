// Command zone runs a single World at Ruin zone simulation.
//
// It is the authoritative realtime tier taking shape: one fixed-timestep tick
// loop, one process, one zone. With -replicate it runs the full replication
// pipeline in-process — tracker delta → wire-encode → decode → verify — and
// reports the payload sizes. With -listen it serves the real zone socket per
// the transport ADR (docs/design/zone-transport.md): a WebSocket-over-TLS
// endpoint at /zone carrying one wire-codec message per binary frame, with
// token-gated admission. With -agones (default off, -listen only) the socket
// server additionally speaks the Agones GameServer lifecycle through the
// official SDK, which is what makes the binary deployable on the fleet: Ready
// once a player could actually connect, Health on a cadence, Shutdown on
// exit. The Nakama layer remains a later child of the server-foundation epic.
// The socket is opt-in: without -listen the command behaves exactly as before.
//
//	zone                     # 600 deterministic ticks, then print the state hash
//	zone -ticks 1800         # a different fixed count
//	zone -realtime -duration 3s   # drive the fixed loop from real time for 3s
//	zone -replicate 1        # also track observer 1, wire-encode its delta stream
//	zone -listen :8443 -tls-cert cert.pem -tls-key key.pem  # serve the zone socket (wss)
//	zone -listen :8443 -tls-cert cert.pem -tls-key key.pem -agones  # ...as a fleet GameServer
//	zone -mint-token 1       # developer helper: mint an admission token, print it, exit
//
// The admission-token secret is read from the environment variable named by
// -admission-secret-env (hex-encoded, at least 32 bytes decoded); the flag
// carries the variable's NAME, never the secret itself.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"reflect"
	"syscall"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

func main() {
	ticks := flag.Int("ticks", 600, "run this many fixed ticks deterministically, then print the state hash")
	realtime := flag.Bool("realtime", false, "drive the fixed loop from the wall clock instead of a fixed count")
	duration := flag.Duration("duration", 2*time.Second, "run length in -realtime mode (and, when set explicitly, -listen mode)")
	replicate := flag.Uint64("replicate", 0, "observer entity ID: track its replication deltas, wire-encode and decode-verify each, and print payload stats (fixed-tick mode)")
	interest := flag.Int64("interest", 12_000, "observer interest radius in mm for -replicate and -listen")
	listen := flag.String("listen", "", "serve the zone socket (WebSocket at /zone) on this address; empty (the default) keeps the socket off")
	tlsCert := flag.String("tls-cert", "", "PEM certificate chain file for -listen (identity is a DNS name per the transport ADR)")
	tlsKey := flag.String("tls-key", "", "PEM private key file for -listen")
	insecurePlaintext := flag.Bool("insecure-plaintext", false, "LOCAL DEVELOPMENT ONLY: serve -listen without TLS (ws://)")
	secretEnv := flag.String("admission-secret-env", "WAR_ZONE_ADMISSION_SECRET", "NAME of the environment variable holding the hex-encoded admission-token secret")
	mintObserver := flag.Uint64("mint-token", 0, "developer helper: mint an admission token for this observer entity ID using the admission secret, print it, and exit")
	mintTTL := flag.Duration("mint-ttl", 5*time.Minute, "expiry window for -mint-token")
	withAgones := flag.Bool("agones", false, "register with the local Agones SDK sidecar (Ready/Health/Shutdown); requires -listen, since Ready must mean a connectable endpoint")
	healthInterval := flag.Duration("agones-health-interval", agones.DefaultHealthInterval, "heartbeat cadence for -agones; keep it under half the fleet's health periodSeconds")
	flag.Parse()

	durationSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "duration" {
			durationSet = true
		}
	})

	if *mintObserver != 0 {
		runMint(*secretEnv, sim.EntityID(*mintObserver), *mintTTL)
		return
	}
	if *listen != "" && *replicate != 0 {
		fatalf("-listen and -replicate are mutually exclusive")
	}
	if *withAgones && *listen == "" {
		fatalf("-agones requires -listen: Agones Ready must mean a player can actually connect, and only -listen opens the zone socket")
	}

	w := sim.NewDemoWorld()
	switch {
	case *listen != "":
		d := time.Duration(0) // run until signalled
		if durationSet {
			d = *duration
		}
		if err := runListen(w, *listen, *tlsCert, *tlsKey, *secretEnv, *insecurePlaintext, *interest, d, *withAgones, *healthInterval); err != nil {
			fatalf("%v", err)
		}
	case *realtime:
		runRealtime(w, *duration)
	case *replicate != 0:
		runReplicate(w, *ticks, sim.EntityID(*replicate), *interest)
	default:
		for range *ticks {
			sim.DriveDemoTick(w)
			w.Step()
		}
	}
	fmt.Printf("zone: entities=%d tick=%d hash=%016x\n", w.Count(), w.Tick, w.Hash())
}

// admissionSecret reads and decodes the admission secret from the environment
// variable envName. Fail-closed: a missing or undersized secret is fatal, and
// the error names the variable, never its content.
func admissionSecret(envName string) []byte {
	raw := os.Getenv(envName)
	if raw == "" {
		fatalf("admission secret: environment variable %s is unset or empty (hex-encoded, >=32 bytes decoded)", envName)
	}
	secret, err := hex.DecodeString(raw)
	if err != nil {
		fatalf("admission secret: %s is not valid hex", envName)
	}
	return secret
}

// runMint is the developer-side helper for exercising -listen: it mints an
// admission token for the given observer. Real minting belongs to the
// allocation/handoff step (a later child of the server epic) — this exists so
// the socket can be used and evaluated before that child lands.
func runMint(secretEnv string, observer sim.EntityID, ttl time.Duration) {
	token, err := zonesock.MintToken(admissionSecret(secretEnv), observer, time.Now().Add(ttl))
	if err != nil {
		fatalf("mint token: %v", err)
	}
	fmt.Println(token)
}

// runListen serves the zone socket while driving the fixed loop from the wall
// clock, per the transport ADR: TLS is the default and plaintext exists only
// behind the explicit local-development opt-in. d <= 0 runs until the process
// is signalled. It returns errors instead of exiting so every exit path runs
// the deferred cleanup — with -agones that includes telling the sidecar to
// recycle the GameServer, which os.Exit would silently skip.
func runListen(w *sim.World, addr, certFile, keyFile, secretEnv string, insecurePlaintext bool, interestMM int64, d time.Duration, withAgones bool, healthInterval time.Duration) error {
	if insecurePlaintext && (certFile != "" || keyFile != "") {
		return fmt.Errorf("-insecure-plaintext contradicts -tls-cert/-tls-key: choose one")
	}
	if !insecurePlaintext && (certFile == "" || keyFile == "") {
		return fmt.Errorf("-listen requires -tls-cert and -tls-key (or the explicit -insecure-plaintext local-development opt-in)")
	}
	verifier, err := zonesock.NewHMACVerifier(admissionSecret(secretEnv))
	if err != nil {
		return err
	}
	hub, err := zonesock.NewHub(zonesock.Config{Verifier: verifier, InterestMM: interestMM})
	if err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.Handle("/zone", hub.Handler())
	srv := &http.Server{
		Handler:           mux,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 10 * time.Second,
	}
	if !insecurePlaintext {
		// Load and validate the key pair BEFORE listening or declaring any
		// readiness: ServeTLS would otherwise discover a broken cert inside
		// the serve goroutine, after Agones was already told Ready — and the
		// fleet would allocate a GameServer whose endpoint never came up.
		cert, err := tls.LoadX509KeyPair(certFile, keyFile)
		if err != nil {
			return fmt.Errorf("load TLS key pair: %w", err)
		}
		// A parseable pair can still be unusable: outside its validity
		// window every client rejects the handshake, which to the fleet is
		// indistinguishable from a dead endpoint. (Identity/DNS-name checks
		// stay with the deployment side, which knows the served name; the
		// process only knows the files it was handed.)
		leaf, err := x509.ParseCertificate(cert.Certificate[0])
		if err != nil {
			return fmt.Errorf("parse TLS leaf certificate: %w", err)
		}
		if now := time.Now(); now.Before(leaf.NotBefore) || now.After(leaf.NotAfter) {
			return fmt.Errorf("TLS certificate is outside its validity window (NotBefore %s, NotAfter %s): no client would accept the handshake", leaf.NotBefore.Format(time.RFC3339), leaf.NotAfter.Format(time.RFC3339))
		}
		srv.TLSConfig.Certificates = []tls.Certificate{cert}
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %v", addr, err)
	}
	scheme := "wss"
	if insecurePlaintext {
		scheme = "ws"
	}
	fmt.Printf("zone: listening on %s://%s/zone\n", scheme, ln.Addr())

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveCtx, serveFailed := context.WithCancelCause(ctx)
	go func() {
		var err error
		if insecurePlaintext {
			err = srv.Serve(ln)
		} else {
			// The key pair is already loaded into TLSConfig.Certificates,
			// so the file arguments stay empty.
			err = srv.ServeTLS(ln, "", "")
		}
		serveFailed(err)
	}()
	defer srv.Close() // also severs hijacked WebSocket connections

	// Agones Ready fires only now — the listener is bound and the serve
	// goroutine is up, so "ready to be allocated" is true in the one sense
	// that matters: a player the fleet routes here can actually connect.
	if withAgones {
		lc, err := agones.Start(ctx, agones.Config{HealthInterval: healthInterval})
		if err != nil {
			return err
		}
		defer func() {
			if err := lc.Shutdown(); err != nil {
				fmt.Fprintf(os.Stderr, "zone: %v\n", err)
			}
		}()
	}

	runLoop(serveCtx, w, d, func() {
		sim.DriveDemoTick(w)
		w.Step()
		hub.Tick(w)
	})
	// A canceled serveCtx has two possible authors, and only one is an
	// error: the serve goroutine (a real serve failure) or the parent
	// signal context (a clean SIGINT/SIGTERM — whose cause under Go 1.26+
	// NAMES the signal, so comparing against context.Canceled would misread
	// a clean shutdown as a failure and exit non-zero).
	if err := context.Cause(serveCtx); err != nil && ctx.Err() == nil {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}

// runReplicate drives the fixed demo ticks while tracking one observer's
// replication stream through the wire codec: every non-empty per-tick delta is
// encoded, decoded back and verified, and the final full snapshot (the join
// payload) runs the same round trip. Interest configuration is not part of the
// hashed step state, so the closing hash line still prints the same golden
// hash as a plain run — replication observation cannot move the sim.
func runReplicate(w *sim.World, ticks int, observer sim.EntityID, interestMM int64) {
	w.SetInterestRadius(observer, interestMM)
	tr := sim.NewSnapshotTracker(observer)

	frames, totalBytes, maxFrame := 0, 0, 0
	for range ticks {
		sim.DriveDemoTick(w)
		w.Step()
		d := tr.Update(w)
		if d.Empty() {
			continue
		}
		b, err := wire.EncodeSnapshotDelta(d)
		if err != nil {
			fatalf("tick %d: encode delta: %v", w.Tick, err)
		}
		m, err := wire.Decode(b)
		if err != nil {
			fatalf("tick %d: decode delta: %v", w.Tick, err)
		}
		if !reflect.DeepEqual(m.Delta, d) {
			fatalf("tick %d: wire round trip diverged from the tracker's delta", w.Tick)
		}
		frames++
		totalBytes += len(b)
		if len(b) > maxFrame {
			maxFrame = len(b)
		}
	}

	join := w.Snapshot(observer)
	jb, err := wire.EncodeSnapshot(join)
	if err != nil {
		fatalf("encode join snapshot: %v", err)
	}
	jm, err := wire.Decode(jb)
	if err != nil {
		fatalf("decode join snapshot: %v", err)
	}
	if !reflect.DeepEqual(jm.Snapshot, join) {
		fatalf("join snapshot wire round trip diverged")
	}

	fmt.Printf("zone: replicated observer=%d interest=%dmm deltaFrames=%d deltaBytes=%d maxDelta=%dB joinSnapshot=%dB (all decode-verified)\n",
		observer, interestMM, frames, totalBytes, maxFrame, len(jb))
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "zone: "+format+"\n", args...)
	os.Exit(1)
}

// runRealtime drives the world through a FixedLoop off the monotonic clock
// until d elapses or the process is asked to stop. Timing jitter changes how
// many ticks run, but never what a given tick computes — that is the point of
// decoupling the sim rate from the wall clock. It deliberately has no Agones
// wiring: with no listener there is nothing a player could connect to, so
// declaring Ready here would hand the fleet a dead allocation (-agones is
// therefore -listen-only).
func runRealtime(w *sim.World, d time.Duration) {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	runLoop(ctx, w, d, func() {
		sim.DriveDemoTick(w)
		w.Step()
	})
}

// runLoop drives the fixed loop off the wall clock, running tick once per
// fixed step, until ctx ends or d elapses (d <= 0 means no deadline).
func runLoop(ctx context.Context, w *sim.World, d time.Duration, tick func()) {
	loop := sim.NewFixedLoop()

	// Poll faster than the sim rate so the accumulator sees fine-grained
	// deltas rather than one lumpy step per fixed interval.
	poll := time.NewTicker(time.Duration(loop.StepNanos() / 2))
	defer poll.Stop()
	var deadline <-chan time.Time // nil without a duration: never fires in the select
	if d > 0 {
		t := time.NewTimer(d)
		defer t.Stop()
		deadline = t.C
	}

	last := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-deadline:
			return
		case now := <-poll.C:
			elapsed := now.Sub(last).Nanoseconds()
			last = now
			loop.Advance(elapsed, tick)
		}
	}
}
