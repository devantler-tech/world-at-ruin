package main

import (
	"bytes"
	"context"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

const fixtureToken = "private-fixture-token-never-print"

func TestProbeVerifiedTLSBothProtocolsAndPrivateOutput(t *testing.T) {
	var mu sync.Mutex
	var received []string
	server := newProbeServer(t, func(ctx context.Context, conn *websocket.Conn, version uint16) {
		writeFixture(t, ctx, conn, version, "valid")
	}, func(r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		received = append(received, r.Header.Get("Authorization")+"|"+r.Header.Get(zonesock.WireVersionHeader))
	})
	url, ca := probeTarget(t, server)
	var out, errOut bytes.Buffer
	code := run(context.Background(), []string{"-url", url, "-ca-file", ca, "-timeout", "2s"}, fixtureEnvironment, &out, &errOut)
	if code != 0 || !strings.Contains(out.String(), "ZONEPROBE PASS") || !strings.Contains(out.String(), "protocols=1,2") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
	}
	assertPrivateOutput(t, out.String()+errOut.String(), url, ca)
	mu.Lock()
	defer mu.Unlock()
	if len(received) != 4 || received[0] != "|" || received[1] == "Bearer "+fixtureToken+"|" || received[2] != "Bearer "+fixtureToken+"|" || received[3] != "Bearer "+fixtureToken+"|2" {
		t.Fatalf("expected missing/wrong rejection followed by retained/newest protocol handshakes; got %d requests", len(received))
	}
}

func TestProbeRejectsBadOrStalledStreams(t *testing.T) {
	for _, kind := range []string{"text", "malformed", "wrong-version", "delta-first", "stale-tick", "unchanged", "unknown-move", "observer-change", "stalled", "oversized", "unknown-cast-end"} {
		t.Run(kind, func(t *testing.T) {
			server := newProbeServer(t, func(ctx context.Context, conn *websocket.Conn, version uint16) {
				writeFixture(t, ctx, conn, version, kind)
			}, nil)
			url, ca := probeTarget(t, server)
			var out, errOut bytes.Buffer
			code := run(context.Background(), []string{"-url", url, "-ca-file", ca, "-timeout", "150ms"}, fixtureEnvironment, &out, &errOut)
			if code == 0 || strings.Contains(out.String(), "PASS") || errOut.Len() == 0 {
				t.Fatalf("invalid stream was accepted: code=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
			}
			assertPrivateOutput(t, out.String()+errOut.String(), url, ca)
		})
	}
}

func TestProbeFailsClosedOnTLSAndAdmission(t *testing.T) {
	t.Run("untrusted certificate", func(t *testing.T) {
		server := newProbeServer(t, func(ctx context.Context, conn *websocket.Conn, version uint16) {
			writeFixture(t, ctx, conn, version, "valid")
		}, nil)
		url, _ := probeTarget(t, server)
		var out, errOut bytes.Buffer
		if run(context.Background(), []string{"-url", url, "-timeout", "1s"}, fixtureEnvironment, &out, &errOut) == 0 {
			t.Fatal("untrusted server was accepted")
		}
		assertPrivateOutput(t, out.String()+errOut.String(), url)
	})
	for _, status := range []int{http.StatusForbidden, http.StatusServiceUnavailable, http.StatusTemporaryRedirect} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Location", "https://must-not-follow.invalid/private")
				w.WriteHeader(status)
				if _, err := w.Write([]byte(fixtureToken)); err != nil {
					t.Errorf("write response: %v", err)
				}
			}))
			t.Cleanup(server.Close)
			url, ca := probeTarget(t, server)
			var out, errOut bytes.Buffer
			if run(context.Background(), []string{"-url", url, "-ca-file", ca, "-timeout", "1s"}, fixtureEnvironment, &out, &errOut) == 0 {
				t.Fatal("non-admission failure was mistaken for verified refusal")
			}
			assertPrivateOutput(t, out.String()+errOut.String(), url, "must-not-follow.invalid")
		})
	}
	t.Run("anonymous upgrade", func(t *testing.T) {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			conn, err := websocket.Accept(w, r, nil)
			if err != nil {
				t.Errorf("accept: %v", err)
				return
			}
			if err := conn.CloseNow(); err != nil {
				t.Errorf("close: %v", err)
			}
		}))
		t.Cleanup(server.Close)
		url, ca := probeTarget(t, server)
		var out, errOut bytes.Buffer
		if run(context.Background(), []string{"-url", url, "-ca-file", ca}, fixtureEnvironment, &out, &errOut) == 0 {
			t.Fatal("anonymous admission was accepted")
		}
	})
}

func TestProbeInvalidArgumentsAreSanitizedBeforeNetwork(t *testing.T) {
	for _, args := range [][]string{
		nil, {"-url", "ws://localhost/zone"}, {"-url", "wss://user:" + fixtureToken + "@localhost/zone"},
		{"-url", "wss://localhost/zone?token=" + fixtureToken}, {"-url", "wss://localhost/zone#" + fixtureToken},
		{"-url", "wss://localhost/zone", "-timeout", "0"}, {"-url", "wss://localhost/zone", "-timeout", "2m"},
		{"-" + fixtureToken}, {"-timeout", fixtureToken}, {"-url", "wss://localhost/zone", fixtureToken},
		{"-url", "wss://localhost/zone", "-ca-file", "/missing/" + fixtureToken},
		{"-url", "wss://public.example/zone", "-tls-server-name", "private.example"},
		{"-url", "wss://localhost/zone", "-tls-server-name", "*.private.example"},
		{"-url", "wss://localhost/zone", "-tls-server-name", "127.0.0.1"},
	} {
		var out, errOut bytes.Buffer
		if run(context.Background(), args, fixtureEnvironment, &out, &errOut) == 0 {
			t.Fatalf("invalid flags were accepted: %d arguments", len(args))
		}
		assertPrivateOutput(t, out.String()+errOut.String(), "wss://", "ws://")
	}
	var out, errOut bytes.Buffer
	if run(context.Background(), []string{"-url", "wss://localhost/zone"}, func(string) string { return "" }, &out, &errOut) == 0 {
		t.Fatal("missing token was accepted")
	}
}

func TestProbeLoopbackCertificateIdentity(t *testing.T) {
	server := newProbeServer(t, func(ctx context.Context, conn *websocket.Conn, version uint16) {
		writeFixture(t, ctx, conn, version, "valid")
	}, nil)
	url, ca := probeTarget(t, server)
	name := server.Certificate().DNSNames[0]
	var out, errOut bytes.Buffer
	if run(context.Background(), []string{"-url", url, "-ca-file", ca, "-tls-server-name", name, "-timeout", "2s"}, fixtureEnvironment, &out, &errOut) != 0 {
		t.Fatalf("valid tunneled identity refused: %s", errOut.String())
	}
	out.Reset()
	errOut.Reset()
	if run(context.Background(), []string{"-url", url, "-ca-file", ca, "-tls-server-name", "wrong.example", "-timeout", "1s"}, fixtureEnvironment, &out, &errOut) == 0 {
		t.Fatal("wrong tunneled identity accepted")
	}
	assertPrivateOutput(t, out.String()+errOut.String(), url, name, "wrong.example")
}

func TestProbeRealHubReleasesOnlyItsOwnObserver(t *testing.T) {
	secret := bytes.Repeat([]byte{7}, 32)
	verifier, err := zonesock.NewHMACVerifier(secret, "private-trial")
	if err != nil {
		t.Fatal(err)
	}
	hub, err := zonesock.NewHub(zonesock.Config{Verifier: verifier, InterestMM: 12000})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewTLSServer(hub.Handler())
	url, ca := probeTarget(t, server)
	token, err := zonesock.MintToken(secret, "private-trial", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		world := sim.NewDemoWorld()
		ticker := time.NewTicker(time.Second / sim.TickHz)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				drainCtx, stop := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
				defer stop()
				if err := hub.Shutdown(drainCtx, world); err != nil {
					t.Errorf("shutdown hub: %v", err)
				}
				return
			case <-ticker.C:
				sim.DriveDemoTick(world)
				world.Step()
				hub.Tick(world)
			}
		}
	}()
	t.Cleanup(func() { cancel(); <-finished; server.Close() })
	getenv := func(string) string { return token }
	var out, errOut bytes.Buffer
	if run(ctx, []string{"-url", url, "-ca-file", ca, "-timeout", "2s"}, getenv, &out, &errOut) != 0 {
		t.Fatalf("real hub rejected sequential protocols: %s", errOut.String())
	}
	// The probe must never steal a pre-existing observer to make its proof pass.
	time.Sleep(100 * time.Millisecond)
	foreign, response, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if response != nil && response.Body != nil {
		if err := response.Body.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := foreign.CloseNow(); err != nil && !errors.Is(err, net.ErrClosed) {
			t.Errorf("close existing observer: %v", err)
		}
	})
	readCtx, stop := context.WithTimeout(ctx, time.Second)
	defer stop()
	if _, _, err := foreign.Read(readCtx); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	errOut.Reset()
	if run(ctx, []string{"-url", url, "-ca-file", ca, "-timeout", "250ms"}, getenv, &out, &errOut) == 0 {
		t.Fatal("busy observer was accepted")
	}
	if _, _, err := foreign.Read(readCtx); err != nil || hub.Connected() != 1 {
		t.Fatal("probe disrupted the existing observer")
	}
}

func newProbeServer(t *testing.T, stream func(context.Context, *websocket.Conn, uint16), observe func(*http.Request)) *httptest.Server {
	t.Helper()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if observe != nil {
			observe(r)
		}
		if r.Header.Get("Authorization") != "Bearer "+fixtureToken {
			http.Error(w, fixtureToken, http.StatusUnauthorized)
			return
		}
		version := wire.LegacyVersion
		if r.Header.Get(zonesock.WireVersionHeader) == "2" {
			version = wire.Version
		}
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept fixture: %v", err)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		stream(ctx, conn, version)
		// Read answers close/control frames without introducing client data.
		_, _, _ = conn.Read(ctx)
		// Refused/oversized fixtures can close the peer before its TLS alert.
		// CloseNow still retires the socket when that final write is refused.
		_ = conn.CloseNow()
	}))
	t.Cleanup(server.Close)
	return server
}

func probeTarget(t *testing.T, server *httptest.Server) (string, string) {
	t.Helper()
	ca := filepath.Join(t.TempDir(), "server-ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0o600); err != nil {
		t.Fatal(err)
	}
	return "wss" + strings.TrimPrefix(server.URL, "https") + "/zone", ca
}

func fixtureEnvironment(name string) string {
	if name == "WAR_ZONE_TOKEN" {
		return fixtureToken
	}
	return ""
}

func assertPrivateOutput(t *testing.T, output string, private ...string) {
	t.Helper()
	for _, value := range append(private, fixtureToken) {
		if strings.Contains(output, value) {
			t.Fatalf("private value escaped into output")
		}
	}
}

func writeFixture(t *testing.T, ctx context.Context, conn *websocket.Conn, version uint16, kind string) {
	t.Helper()
	if kind == "stalled" {
		return
	}
	if kind == "text" || kind == "malformed" || kind == "oversized" {
		payload := []byte(fixtureToken)
		messageType := websocket.MessageBinary
		if kind == "text" {
			messageType = websocket.MessageText
		}
		if kind == "oversized" {
			payload = make([]byte, maxFrameBytes+1)
		}
		_ = conn.Write(ctx, messageType, payload)
		return
	}
	if kind == "wrong-version" {
		version = wire.Version
	}
	snapshot := sim.Snapshot{Tick: 10, Observer: 1, Entities: []sim.EntityState{{ID: 2, Pos: sim.Vec3{X: 100}, Radius: 300}}}
	delta := sim.SnapshotDelta{Tick: 11, Moved: []sim.EntityState{{ID: 2, Pos: sim.Vec3{X: 200}, Radius: 300}}}
	if kind != "delta-first" {
		data, err := wire.EncodeSnapshotVersion(snapshot, version)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageBinary, data); err != nil {
			return // The negative fixtures may be closed as soon as their first frame is refused.
		}
	}
	switch kind {
	case "stale-tick":
		delta.Tick = 10
	case "unchanged":
		delta.Moved[0] = snapshot.Entities[0]
	case "unknown-move":
		delta.Moved[0].ID = 3
	case "unknown-cast-end":
		if version != wire.LegacyVersion {
			delta.EndedCasts = []sim.EntityID{2}
		}
	case "observer-change":
		snapshot.Tick = 11
		snapshot.Observer = 3
		data, err := wire.EncodeSnapshotVersion(snapshot, version)
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.Write(ctx, websocket.MessageBinary, data)
		return
	}
	data, err := wire.EncodeSnapshotDeltaVersion(delta, version)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Write(ctx, websocket.MessageBinary, data)
}
