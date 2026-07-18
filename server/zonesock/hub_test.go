package zonesock

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// simHarness drives the demo world on a dedicated goroutine — the "sim
// goroutine" of the package's concurrency contract — calling hub.Tick after
// every step, exactly as the zone command's realtime loop does.
type simHarness struct {
	hub  *Hub
	quit chan struct{}
	done chan struct{}
}

func startSim(t *testing.T, hub *Hub) *simHarness {
	t.Helper()
	h := &simHarness{hub: hub, quit: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(h.done)
		w := sim.NewDemoWorld()
		for {
			select {
			case <-h.quit:
				return
			default:
			}
			sim.DriveDemoTick(w)
			w.Step()
			hub.Tick(w)
			time.Sleep(time.Millisecond)
		}
	}()
	t.Cleanup(h.stop)
	return h
}

func (h *simHarness) stop() {
	select {
	case <-h.quit:
	default:
		close(h.quit)
	}
	<-h.done
}

// onSim runs f on the sim goroutine (via the hub's marshalling path) and
// waits for it, so a test can inspect World state without racing the loop.
func (h *simHarness) onSim(t *testing.T, f func(w *sim.World)) {
	t.Helper()
	ran := make(chan struct{})
	h.hub.enqueue(func(w *sim.World) {
		f(w)
		close(ran)
	})
	select {
	case <-ran:
	case <-time.After(5 * time.Second):
		t.Fatal("sim goroutine did not run the marshalled function")
	}
}

func newTestHub(t *testing.T, cfg Config) (*Hub, []byte) {
	t.Helper()
	secret := testSecret(0xA5)
	if cfg.Verifier == nil {
		v, err := NewHMACVerifier(secret)
		if err != nil {
			t.Fatalf("NewHMACVerifier: %v", err)
		}
		cfg.Verifier = v
	}
	hub, err := NewHub(cfg)
	if err != nil {
		t.Fatalf("NewHub: %v", err)
	}
	return hub, secret
}

func dial(t *testing.T, ts *httptest.Server, secret []byte, observer sim.EntityID) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	tok, err := MintToken(secret, observer, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken: %v", err)
	}
	return dialToken(t, ts, "Bearer "+tok)
}

func dialToken(t *testing.T, ts *httptest.Server, authorization string) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	hdr := http.Header{}
	if authorization != "" {
		hdr.Set("Authorization", authorization)
	}
	return websocket.Dial(ctx, ts.URL, &websocket.DialOptions{HTTPClient: ts.Client(), HTTPHeader: hdr})
}

func readMessage(t *testing.T, c *websocket.Conn) wire.Message {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	typ, b, err := c.Read(ctx)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if typ != websocket.MessageBinary {
		t.Fatalf("received %v message, want binary", typ)
	}
	m, err := wire.Decode(b)
	if err != nil {
		t.Fatalf("wire.Decode: %v", err)
	}
	return m
}

// TestJoinAndDeltaStreamOverTLS is the end-to-end proof of the ADR's happy
// path: a token-admitted client on a real TLS WebSocket receives a
// KindSnapshot join and then the per-tick KindSnapshotDelta stream, and the
// whole stream decode-verifies against an independent replay of the
// deterministic demo world — with no delta skipped and no tick repeated.
func TestJoinAndDeltaStreamOverTLS(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	c, _, err := dial(t, ts, secret, 1)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()
	c.SetReadLimit(4 << 20)

	join := readMessage(t, c)
	if join.Kind != wire.KindSnapshot {
		t.Fatalf("first message kind = %d, want KindSnapshot", join.Kind)
	}
	t0 := join.Snapshot.Tick

	// Independent replay: the demo world is deterministic, so a fresh copy
	// stepped to the join tick must produce the identical snapshot, and a
	// tracker primed there must produce the identical delta stream.
	ref := sim.NewDemoWorld()
	ref.SetInterestRadius(1, DefaultInterestMM)
	for ref.Tick < t0 {
		sim.DriveDemoTick(ref)
		ref.Step()
	}
	if want := ref.Snapshot(1); !reflect.DeepEqual(join.Snapshot, want) {
		t.Fatalf("join snapshot diverged from replay:\n got %+v\nwant %+v", join.Snapshot, want)
	}
	tracker := sim.NewSnapshotTracker(1)
	tracker.Update(ref)

	last := t0
	for received := 0; received < 25; received++ {
		m := readMessage(t, c)
		if m.Kind != wire.KindSnapshotDelta {
			t.Fatalf("message %d kind = %d, want KindSnapshotDelta", received, m.Kind)
		}
		if m.Delta.Tick <= last {
			t.Fatalf("delta tick %d not after previous %d", m.Delta.Tick, last)
		}
		for ref.Tick < m.Delta.Tick {
			sim.DriveDemoTick(ref)
			ref.Step()
			d := tracker.Update(ref)
			if ref.Tick < m.Delta.Tick {
				// The stream carries every non-empty delta: a gap here means
				// the socket silently dropped one without a resync.
				if !d.Empty() {
					t.Fatalf("stream skipped non-empty delta at tick %d", ref.Tick)
				}
				continue
			}
			if d.Empty() {
				t.Fatalf("received delta at tick %d but replay's is empty", ref.Tick)
			}
			if !reflect.DeepEqual(m.Delta, d) {
				t.Fatalf("delta at tick %d diverged from replay:\n got %+v\nwant %+v", ref.Tick, m.Delta, d)
			}
		}
		last = m.Delta.Tick
	}
}

// TestAdmissionFailClosed proves the token gate refuses before the upgrade:
// every invalid credential is a plain 401 with no WebSocket, and the same
// server still admits a valid one (the positive control that the gate is a
// gate, not a wall).
func TestAdmissionFailClosed(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	expired, err := MintToken(secret, 1, time.Now().Add(-time.Minute))
	if err != nil {
		t.Fatalf("MintToken(expired): %v", err)
	}
	forged, err := MintToken(testSecret(0x5A), 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken(forged): %v", err)
	}
	cases := []struct {
		name          string
		authorization string
	}{
		{"missing header", ""},
		{"not bearer", "Basic abc"},
		{"garbage token", "Bearer not-a-token"},
		{"expired token", "Bearer " + expired},
		{"forged token", "Bearer " + forged},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			conn, resp, err := dialToken(t, ts, tc.authorization)
			if err == nil {
				conn.CloseNow()
				t.Fatal("dial succeeded, want refusal")
			}
			if resp == nil || resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("refusal response = %+v, want 401", resp)
			}
		})
	}
	if hub.Connected() != 0 {
		t.Fatalf("Connected() = %d after refusals, want 0", hub.Connected())
	}

	c, _, err := dial(t, ts, secret, 1)
	if err != nil {
		t.Fatalf("valid dial refused: %v", err)
	}
	defer c.CloseNow()
	if m := readMessage(t, c); m.Kind != wire.KindSnapshot {
		t.Fatalf("admitted client's first message kind = %d, want KindSnapshot", m.Kind)
	}
}

// TestUnknownObserverRefused: a validly signed token for an entity the world
// does not hold admits the upgrade but is closed at attach, before any state
// is replicated.
func TestUnknownObserverRefused(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	c, _, err := dial(t, ts, secret, 99)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := c.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("read error = %v, want close with StatusPolicyViolation", err)
	}
	if hub.Connected() != 0 {
		t.Fatalf("Connected() = %d, want 0", hub.Connected())
	}
}

// TestDuplicateObserverRefused: a second connection for an already-attached
// observer is refused, and its refusal must not disturb the live connection.
func TestDuplicateObserverRefused(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	first, _, err := dial(t, ts, secret, 2)
	if err != nil {
		t.Fatalf("first dial: %v", err)
	}
	defer first.CloseNow()
	first.SetReadLimit(4 << 20)
	if m := readMessage(t, first); m.Kind != wire.KindSnapshot {
		t.Fatalf("first connection join kind = %d, want KindSnapshot", m.Kind)
	}

	second, _, err := dial(t, ts, secret, 2)
	if err != nil {
		t.Fatalf("second dial: %v", err)
	}
	defer second.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := second.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("second connection read error = %v, want StatusPolicyViolation", err)
	}

	// The live connection keeps streaming, and its observer state survived
	// the duplicate's identity-guarded detach.
	if m := readMessage(t, first); m.Kind != wire.KindSnapshotDelta {
		t.Fatalf("live connection message kind = %d, want KindSnapshotDelta", m.Kind)
	}
	if hub.Connected() != 1 {
		t.Fatalf("Connected() = %d, want 1", hub.Connected())
	}
}

// TestClientDataMessageRefused: wire v1 defines no client→server kinds, so a
// small, well-formed-looking inbound message is a policy violation.
func TestClientDataMessageRefused(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	c, _, err := dial(t, ts, secret, 3)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()
	c.SetReadLimit(4 << 20)
	if m := readMessage(t, c); m.Kind != wire.KindSnapshot {
		t.Fatalf("join kind = %d, want KindSnapshot", m.Kind)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := c.Write(ctx, websocket.MessageBinary, []byte{1, 2, 3}); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if got := awaitCloseStatus(ctx, c); got != websocket.StatusPolicyViolation {
		t.Fatalf("close status = %v, want StatusPolicyViolation", got)
	}
}

// TestInboundOversizeDisconnects: the hard read limit at the socket layer
// trips before the message reaches the read loop, closing with
// StatusMessageTooBig — the size path, distinct from the policy path above
// (each is the other's control).
func TestInboundOversizeDisconnects(t *testing.T) {
	hub, secret := newTestHub(t, Config{MaxInboundBytes: 256})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	startSim(t, hub)

	c, _, err := dial(t, ts, secret, 3)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()
	c.SetReadLimit(4 << 20)
	if m := readMessage(t, c); m.Kind != wire.KindSnapshot {
		t.Fatalf("join kind = %d, want KindSnapshot", m.Kind)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := c.Write(ctx, websocket.MessageBinary, make([]byte, 1024)); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if got := awaitCloseStatus(ctx, c); got != websocket.StatusMessageTooBig {
		t.Fatalf("close status = %v, want StatusMessageTooBig", got)
	}
}

// awaitCloseStatus reads (draining any still-queued replication frames) until
// the connection closes, returning the close status.
func awaitCloseStatus(ctx context.Context, c *websocket.Conn) websocket.StatusCode {
	for {
		if _, _, err := c.Read(ctx); err != nil {
			return websocket.CloseStatus(err)
		}
	}
}

// TestIdleDeadlineDisconnectsMutePeer: a peer that stops reading answers no
// pings, so it is torn down within roughly IdleTimeout and its observer state
// released; a peer that keeps reading survives the same window (the control).
func TestIdleDeadlineDisconnectsMutePeer(t *testing.T) {
	hub, secret := newTestHub(t, Config{IdleTimeout: 200 * time.Millisecond, WriteTimeout: 100 * time.Millisecond})
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	h := startSim(t, hub)

	// Control: a draining peer outlives several idle windows.
	alive, _, err := dial(t, ts, secret, 1)
	if err != nil {
		t.Fatalf("dial (draining peer): %v", err)
	}
	defer alive.CloseNow()
	alive.SetReadLimit(4 << 20)
	drainCtx, drainCancel := context.WithCancel(context.Background())
	defer drainCancel()
	go func() {
		for {
			if _, _, err := alive.Read(drainCtx); err != nil {
				return
			}
		}
	}()

	// The mute peer: joins, then never reads again.
	mute, _, err := dial(t, ts, secret, 2)
	if err != nil {
		t.Fatalf("dial (mute peer): %v", err)
	}
	defer mute.CloseNow()

	// First wait for BOTH to attach — Connected()==1 is transiently true
	// while the mute peer's attach is still pending, and polling for 1
	// straight away would observe that moment, not the teardown.
	deadline := time.Now().Add(5 * time.Second)
	for hub.Connected() != 2 {
		if time.Now().After(deadline) {
			t.Fatalf("Connected() = %d, want 2 (peers not attached)", hub.Connected())
		}
		time.Sleep(10 * time.Millisecond)
	}
	for hub.Connected() != 1 {
		if time.Now().After(deadline) {
			t.Fatalf("Connected() = %d, want 1 (mute peer not torn down)", hub.Connected())
		}
		time.Sleep(10 * time.Millisecond)
	}

	// The released observer's interest radius is cleared on the world; the
	// surviving one keeps its.
	h.onSim(t, func(w *sim.World) {
		if r := w.Get(2).InterestRadius; r != 0 {
			t.Errorf("mute observer interest radius = %d, want 0", r)
		}
		if r := w.Get(1).InterestRadius; r != DefaultInterestMM {
			t.Errorf("draining observer interest radius = %d, want %d", r, DefaultInterestMM)
		}
	})
}

// TestOverflowResync exercises the bounded-queue rule at the unit level, where
// it is deterministic: a writer that never drains fills the queue, and the
// overflowing tick must drop everything queued and leave exactly one fresh
// KindSnapshot resync — with the tracker re-primed so the next delta carries
// no phantom Entered entries.
func TestOverflowResync(t *testing.T) {
	hub, _ := newTestHub(t, Config{SendQueue: 2})
	w := sim.NewDemoWorld()

	// Attach by hand on the test goroutine, which acts as the sim goroutine —
	// no writer goroutine ever drains c.out.
	c := &conn{hub: hub, observer: 1, out: make(chan []byte, 2)}
	w.SetInterestRadius(1, DefaultInterestMM)
	c.tracker = sim.NewSnapshotTracker(1)
	c.tracker.Update(w)
	hub.conns[1] = c

	step := func() {
		sim.DriveDemoTick(w)
		w.Step()
		hub.Tick(w)
	}
	step() // queue 1/2
	step() // queue 2/2
	if len(c.out) != 2 {
		t.Fatalf("queue holds %d frames before overflow, want 2 (deltas not flowing)", len(c.out))
	}
	step() // overflow: drop both, enqueue one resync snapshot

	if len(c.out) != 1 {
		t.Fatalf("queue holds %d frames after overflow, want exactly 1 resync", len(c.out))
	}
	m, err := wire.Decode(<-c.out)
	if err != nil {
		t.Fatalf("decode resync: %v", err)
	}
	if m.Kind != wire.KindSnapshot {
		t.Fatalf("post-overflow frame kind = %d, want KindSnapshot", m.Kind)
	}
	if m.Snapshot.Tick != w.Tick {
		t.Fatalf("resync snapshot tick = %d, want current tick %d", m.Snapshot.Tick, w.Tick)
	}
	if want := w.Snapshot(1); !reflect.DeepEqual(m.Snapshot, want) {
		t.Fatalf("resync snapshot diverged from world state:\n got %+v\nwant %+v", m.Snapshot, want)
	}

	// The tracker was re-primed at the resync point: the next delta updates
	// known entities, it does not re-introduce them.
	step()
	if len(c.out) != 1 {
		t.Fatalf("queue holds %d frames after post-resync tick, want 1", len(c.out))
	}
	m, err = wire.Decode(<-c.out)
	if err != nil {
		t.Fatalf("decode post-resync delta: %v", err)
	}
	if m.Kind != wire.KindSnapshotDelta {
		t.Fatalf("post-resync frame kind = %d, want KindSnapshotDelta", m.Kind)
	}
	if m.Delta.Tick != w.Tick {
		t.Fatalf("post-resync delta tick = %d, want %d", m.Delta.Tick, w.Tick)
	}
	if len(m.Delta.Entered) != 0 {
		t.Fatalf("post-resync delta re-introduces %d entities; tracker was not re-primed", len(m.Delta.Entered))
	}
}
