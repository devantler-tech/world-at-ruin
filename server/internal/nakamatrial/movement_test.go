//go:build war_native_trial

package nakamatrial

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// TestClosedLoopAuthoritativeMovement binds real input to authenticated native
// storage ownership and the actual packaged zone's single authoritative loop.
func TestClosedLoopAuthoritativeMovement(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "off", true: "on"}[enabled], func(t *testing.T) {
			f := closedFixture(t)
			var options []string
			if enabled {
				options = []string{"-movement-intents", "-movement-hold-ticks", "3"}
			}
			z := f.startZone("zone-a", f.key, "", false, options...)
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			account, uid := f.account("movement-closed-loop")
			got := f.handoff(account)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			c, err := z.dial(ctx, got, wire.MovementVersion)
			if !enabled {
				if c != nil {
					_ = c.CloseNow()
				}
				if err == nil || !strings.Contains(err.Error(), "HTTP 426") {
					t.Fatal("native default zone admitted movement")
				}
				z.snapshot(got)
				f.claimed(leaseKey(uid))
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = c.CloseNow() }()
			_, b, err := c.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			join, err := wire.Decode(b)
			if err != nil || join.Kind != wire.KindSnapshot || join.Version != wire.MovementVersion {
				t.Fatal("native movement join missing")
			}
			_, claimedVersion := f.claimed(leaseKey(uid))
			before := nativeMovementAck(t, ctx, c)
			b, _ = wire.EncodeIntent(wire.MovementIntent{Sequence: 7, X: 1000, Sprint: true})
			if err := c.Write(ctx, websocket.MessageBinary, b); err != nil {
				t.Fatal(err)
			}
			ack := nativeMovementAck(t, ctx, c)
			for ack.AppliedSequence != 7 {
				ack = nativeMovementAck(t, ctx, c)
			}
			if ack.Tick <= before.Tick || ack.Pos.X <= before.Pos.X || ack.Pos.X-before.Pos.X > 399 || ack.Pos.Y != before.Pos.Y {
				t.Fatalf("native movement exceeded authority or did not step: %+v → %+v", before, ack)
			}
			applied := ack.Tick
			for ack.Tick < applied+8 {
				ack = nativeMovementAck(t, ctx, c)
			}
			stopped := ack
			for ack.Tick < stopped.Tick+3 {
				ack = nativeMovementAck(t, ctx, c)
			}
			if ack.Pos != stopped.Pos {
				t.Fatal("native movement did not stop after input silence")
			}
			// An invalid direction is dropped without refreshing input ownership.
			b, _ = wire.EncodeIntent(wire.MovementIntent{Sequence: 8, X: 1000, Sprint: true})
			b[11], b[12] = 0xe9, 0x03 // direction 1001, beyond the unit bound
			if err := c.Write(ctx, websocket.MessageBinary, b); err != nil {
				t.Fatal(err)
			}
			for ack.Tick < stopped.Tick+7 {
				ack = nativeMovementAck(t, ctx, c)
			}
			if ack.AppliedSequence != 7 || ack.Pos != stopped.Pos {
				t.Fatal("native malformed input changed movement")
			}
			_ = c.CloseNow()
			// The exact durable claim is retained; a fresh socket owns a fresh
			// sequence lifetime and cannot inherit the former socket's intent.
			var reconnected *websocket.Conn
			for {
				reconnected, err = z.dial(ctx, got, wire.MovementVersion)
				if err == nil {
					_, b, err = reconnected.Read(ctx)
					if err == nil {
						break
					}
					_ = reconnected.CloseNow()
				}
				if ctx.Err() != nil {
					t.Fatal("native movement reconnect did not settle")
				}
				time.Sleep(10 * time.Millisecond)
			}
			defer func() { _ = reconnected.CloseNow() }()
			join, err = wire.Decode(b)
			if err != nil || join.Kind != wire.KindSnapshot {
				t.Fatal("reconnect omitted join")
			}
			ack = nativeMovementAck(t, ctx, reconnected)
			if ack.AppliedSequence != 0 || ack.Pos != stopped.Pos {
				t.Fatal("reconnect inherited old movement")
			}
			_, replayVersion := f.claimed(leaseKey(uid))
			if replayVersion != claimedVersion {
				t.Fatal("movement reconnect replaced durable ownership")
			}
		})
	}
}

func nativeMovementAck(t *testing.T, ctx context.Context, c *websocket.Conn) wire.MovementAck {
	t.Helper()
	for {
		_, b, err := c.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		m, err := wire.Decode(b)
		if err != nil {
			t.Fatal(err)
		}
		if m.Kind == wire.KindMovementAck {
			return m.Ack
		}
	}
}
