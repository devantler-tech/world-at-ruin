package zonesock

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// A movement peer must negotiate only with operator opt-in; refusal happens
// before socket creation, while an enabled peer receives a real join snapshot.
func TestMovementNegotiationBothStates(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "off", true: "on"}[enabled], func(t *testing.T) {
			h, key := newTestHub(t, Config{MovementEnabled: enabled})
			s := httptest.NewTLSServer(h.Handler())
			defer s.Close()
			drive := startSim(t, h)
			defer drive.stop()
			c, response, err := dialVersion(t, s, key, 1, wire.MovementVersion)
			if response != nil && response.Body != nil {
				defer func() { _ = response.Body.Close() }()
			}
			if !enabled {
				if c != nil {
					closeConnection(t, c)
				}
				if err == nil || response == nil || response.StatusCode != http.StatusUpgradeRequired {
					t.Fatal("movement enabled without opt-in")
				}
				return
			}
			if err != nil {
				t.Fatalf("enabled movement negotiation refused: %v", err)
			}
			defer closeConnection(t, c)
			m := readMessage(t, c)
			if m.Kind != wire.KindSnapshot || m.Version != wire.MovementVersion {
				t.Fatal("join was not the first v3 frame")
			}
		})
	}
}

func TestMovementHoldConfigurationIsBounded(t *testing.T) {
	v, _ := NewHMACVerifier(testSecret(1), "allocation-a")
	if _, err := NewHub(Config{Verifier: v, MovementEnabled: true, MovementHoldTicks: 301}); err == nil {
		t.Fatal("unbounded input hold accepted")
	}
}

func TestRetainedPeersRefuseInputWithMovementEnabled(t *testing.T) {
	for _, version := range []uint16{wire.LegacyVersion, wire.Version} {
		t.Run(map[uint16]string{1: "v1", 2: "v2"}[version], func(t *testing.T) {
			h, key := newTestHub(t, Config{MovementEnabled: true})
			s := httptest.NewTLSServer(h.Handler())
			defer s.Close()
			drive := startSim(t, h)
			defer drive.stop()
			c, response, err := dialVersion(t, s, key, 1, version)
			if response != nil && response.Body != nil {
				_ = response.Body.Close()
			}
			if err != nil {
				t.Fatal(err)
			}
			defer closeConnection(t, c)
			if m := readMessage(t, c); m.Kind != wire.KindSnapshot || m.Version != version {
				t.Fatal("retained join changed")
			}
			b, _ := wire.EncodeIntent(wire.MovementIntent{Sequence: 1, X: 1000})
			if err := c.Write(t.Context(), websocket.MessageBinary, b); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), time.Second)
			defer cancel()
			for {
				_, _, err := c.Read(ctx)
				if err != nil {
					if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
						t.Fatalf("retained input not refused: %v", err)
					}
					break
				}
			}
		})
	}
}

func TestMovementProtocolViolationAfterInputBudget(t *testing.T) {
	h, key := newTestHub(t, Config{MovementEnabled: true})
	s := httptest.NewTLSServer(h.Handler())
	defer s.Close()
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{ID: 1, MaxSpeed: 4000})
	c, response, err := dialVersion(t, s, key, 1, wire.MovementVersion)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, c)
	waitMovement(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pending) > 0 })
	h.BeforeStep(w)
	_ = readMessage(t, c)
	for seq := uint64(1); seq <= 64; seq++ {
		b, _ := wire.EncodeIntent(wire.MovementIntent{Sequence: seq})
		if err := c.Write(t.Context(), websocket.MessageBinary, b); err != nil {
			t.Fatal(err)
		}
	}
	waitMovement(t, func() bool { return movementReceived(h, 64) })
	b, _ := wire.EncodeMovementAck(wire.MovementAck{})
	if err := c.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	if _, _, err := c.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("server-only message was not refused after budget: %v", err)
	}
}

// Manual tick ownership gives input an observable before/after boundary;
// neither the socket reader nor wall-clock sleeps can move the world.
func TestMovementTLSAppliesOnlyOwnedActorAndAcknowledgesCompletedStep(t *testing.T) {
	h, key := newTestHub(t, Config{MovementEnabled: true, MovementHoldTicks: 2, SendQueue: 1})
	s := httptest.NewTLSServer(h.Handler())
	defer s.Close()
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{ID: 1, MaxSpeed: 4000})
	w.Add(sim.Entity{ID: 2, Pos: sim.Vec3{X: 10000}, MaxSpeed: 6000})
	stepper, ok := any(h).(interface{ BeforeStep(*sim.World) })
	if !ok {
		t.Fatal("socket hub has no simulation-owner input phase")
	}
	c, response, err := dialVersion(t, s, key, 1, wire.MovementVersion)
	if response != nil && response.Body != nil {
		defer func() { _ = response.Body.Close() }()
	}
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, c)
	waitMovement(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pending) > 0 })
	stepper.BeforeStep(w)
	if got := readMessage(t, c); got.Kind != wire.KindSnapshot {
		t.Fatal("own ack preceded join")
	}
	for _, seq := range []uint64{1, 2, 3} {
		b, _ := wire.EncodeIntent(wire.MovementIntent{Sequence: seq, X: 1000, Sprint: true})
		if err := c.Write(t.Context(), websocket.MessageBinary, b); err != nil {
			t.Fatal(err)
		}
	}
	// Let the real reader fill the fixed mailbox. Its occupancy is inspected
	// through a read-only synchronization method, not by changing sim state.
	waitMovement(t, func() bool { return movementReceived(h, 3) })
	if w.Get(1).Pos.X != 0 {
		t.Fatal("reader moved the world outside its owner")
	}
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack := readMovementAck(t, c)
	if ack.AppliedSequence != 3 || ack.Tick != 1 || ack.Pos.X != 133 || ack.Pos.Y != 0 || w.Get(2).Pos.X != 10000 {
		t.Fatalf("wrong ownership/applied state: %+v", ack)
	}
	// Replays cannot refresh hold, nor replace the last applied sequence.
	stale, _ := wire.EncodeIntent(wire.MovementIntent{Sequence: 2, Z: 1000, Sprint: true})
	if err := c.Write(t.Context(), websocket.MessageBinary, stale); err != nil {
		t.Fatal(err)
	}
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack = readMovementAck(t, c)
	if ack.AppliedSequence != 3 || ack.Pos.X != 266 || ack.Tick != 2 {
		t.Fatalf("held movement not acknowledged: %+v", ack)
	}
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack = readMovementAck(t, c)
	if ack.Pos.X != 266 || ack.Tick != 3 {
		t.Fatalf("input silence did not stop: %+v", ack)
	}
	duplicate, response, err := dialVersion(t, s, key, 1, wire.MovementVersion)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, duplicate)
	b, _ := wire.EncodeIntent(wire.MovementIntent{Sequence: 100, Z: 1000, Sprint: true})
	if err := duplicate.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
	waitMovement(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pending) > 0 })
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	if ack = readMovementAck(t, c); ack.AppliedSequence != 3 || ack.Pos.X != 266 || ack.Pos.Z != 0 {
		t.Fatal("duplicate socket stole movement")
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	if _, _, err := duplicate.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("duplicate was not refused: %v", err)
	}
	closeConnection(t, c)
	waitMovement(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pending) > 0 })
	sim.DriveDemoTick(w)
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	if w.Get(1).Pos.X != 266 || w.Get(1).Pos.Z != 0 {
		t.Fatal("disconnect resumed scripted movement")
	}
	reconnected, response, err := dialVersion(t, s, key, 1, wire.MovementVersion)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, reconnected)
	waitMovement(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pending) > 0 })
	stepper.BeforeStep(w)
	w.Step()
	h.Tick(w)
	if got := readMessage(t, reconnected); got.Kind != wire.KindSnapshot {
		t.Fatal("reconnect did not begin with join")
	}
	ack = readMovementAck(t, reconnected)
	if ack.AppliedSequence != 0 || ack.Pos.X != 266 || ack.Pos.Z != 0 {
		t.Fatal("reconnect inherited movement")
	}
	if err := h.Shutdown(t.Context(), w); err != nil {
		t.Fatal(err)
	}
	if h.Connected() != 0 || w.Get(1).Intent != (sim.Vec3{}) {
		t.Fatal("terminal shutdown left movement authority")
	}
}

func movementReceived(h *Hub, sequence uint64) bool {
	// The private test adapter permits the test to wait for actual decoded
	// ingress; an absent implementation fails instead of a timing guess.
	if seen, ok := any(h).(interface{ movementSequenceForTest() uint64 }); ok {
		return seen.movementSequenceForTest() >= sequence
	}
	return false
}

// Test-only inspection synchronizes with the real reader without giving the
// production Hub a test API or mutating its owner-confined world.
func (h *Hub) movementSequenceForTest() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	var latest uint64
	for c := range h.sockets {
		c.inputMu.Lock()
		if c.received > latest {
			latest = c.received
		}
		c.inputMu.Unlock()
	}
	return latest
}

func readMovementAck(t *testing.T, c *websocket.Conn) wire.MovementAck {
	t.Helper()
	for range 20 {
		if m := readMessage(t, c); m.Kind == wire.KindMovementAck {
			return m.Ack
		}
	}
	t.Fatal("current own-state acknowledgement missing")
	return wire.MovementAck{}
}

func waitMovement(t *testing.T, ready func() bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	for !ready() {
		select {
		case <-ctx.Done():
			t.Fatal("movement boundary did not settle")
		case <-time.After(time.Millisecond):
		}
	}
}

func controlledFixture(t *testing.T, hold uint64) (*Hub, *sim.World, *conn) {
	t.Helper()
	h, _ := newTestHub(t, Config{MovementEnabled: true, MovementHoldTicks: hold, SendQueue: 1})
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{ID: 1, MaxSpeed: 4000})
	w.Add(sim.Entity{ID: 2, Pos: sim.Vec3{X: 10000}, MaxSpeed: 6000})
	c := &conn{hub: h, observer: 1, version: wire.MovementVersion, out: make(chan []byte, 1), ackReady: make(chan struct{}, 1)}
	h.attach(w, c)
	<-c.out
	return h, w, c
}

func TestMovementIngressBudgetAndReplayDoNotRefreshHold(t *testing.T) {
	h, w, c := controlledFixture(t, 1)
	for seq := uint64(1); seq <= 100; seq++ {
		if c.inputBudget() {
			c.offerIntent(wire.MovementIntent{Sequence: seq, X: 1000, Sprint: true})
		}
	}
	h.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack, err := wire.Decode(c.takeAck())
	if err != nil {
		t.Fatal(err)
	}
	if ack.Ack.AppliedSequence != 64 || ack.Ack.Pos.X != 133 {
		t.Fatalf("ingress exceeded bounded newest input: %+v", ack.Ack)
	}
	if !c.inputBudget() {
		t.Fatal("new tick did not restore ingress budget")
	}
	c.offerIntent(wire.MovementIntent{Sequence: 64, Z: 1000, Sprint: true})
	h.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack, err = wire.Decode(c.takeAck())
	if err != nil {
		t.Fatal(err)
	}
	if ack.Ack.AppliedSequence != 64 || ack.Ack.Pos.X != 133 || ack.Ack.Pos.Z != 0 {
		t.Fatal("replay refreshed held movement")
	}
	c.offerIntent(wire.MovementIntent{Sequence: 65, Z: 1000})
	h.BeforeStep(w)
	w.Step()
	h.Tick(w)
	ack, err = wire.Decode(c.takeAck())
	if err != nil {
		t.Fatal(err)
	}
	if ack.Ack.AppliedSequence != 65 || ack.Ack.Pos.Z != 66 {
		t.Fatal("fresh walking input did not use server speed")
	}
}

func TestMovementAckSurvivesOneSlotReplicationResync(t *testing.T) {
	h, w, c := controlledFixture(t, 3)
	c.offerIntent(wire.MovementIntent{Sequence: 1, X: 1000, Sprint: true})
	for range 100 {
		w.SetIntent(2, sim.Vec3{Z: 1000})
		h.BeforeStep(w)
		w.Step()
		h.Tick(w)
	}
	if len(c.out) != 1 || len(c.ackReady) != 1 {
		t.Fatal("backpressure grew queues")
	}
	resync, err := wire.Decode(<-c.out)
	if err != nil {
		t.Fatal(err)
	}
	ack, err := wire.Decode(c.takeAck())
	if err != nil {
		t.Fatal(err)
	}
	if resync.Kind != wire.KindSnapshot || resync.Snapshot.Tick != 100 || ack.Ack.Tick != 100 || ack.Ack.AppliedSequence != 1 || ack.Ack.Pos.X != 399 {
		t.Fatalf("backpressure lost current authoritative state: %+v %+v", resync, ack.Ack)
	}
}

func TestMovementScheduleIsDeterministic(t *testing.T) {
	a, aw, ac := controlledFixture(t, 3)
	b, bw, bc := controlledFixture(t, 3)
	for tick := uint64(0); tick < 100; tick++ {
		if tick%5 == 0 {
			i := wire.MovementIntent{Sequence: tick + 1, X: -600, Z: 800, Sprint: tick%2 == 0}
			ac.offerIntent(i)
			bc.offerIntent(i)
		}
		a.BeforeStep(aw)
		b.BeforeStep(bw)
		aw.Step()
		bw.Step()
		a.Tick(aw)
		b.Tick(bw)
		if aw.Hash() != bw.Hash() {
			t.Fatalf("movement schedule diverged at %d", tick)
		}
	}
}
