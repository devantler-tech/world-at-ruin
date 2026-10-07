package main

import (
	"context"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

func TestBuiltZoneMovementBothStates(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "off", true: "on"}[enabled], func(t *testing.T) {
			port := closedPort(t)
			args := []string{"-listen", "127.0.0.1:" + port, "-allocation-id", "allocation-a", "-insecure-plaintext", "-duration", "10s"}
			if enabled {
				args = append(args, "-movement-intents", "-movement-hold-ticks", "2")
			}
			cmd := zoneCommand(t, args...)
			cmd.Env = append(os.Environ(), "WAR_ZONE_ADMISSION_SECRET="+strings.Repeat("ab", 32))
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait(); close(done) }()
			t.Cleanup(func() {
				_ = cmd.Process.Kill()
				select {
				case <-done:
				case <-time.After(3 * time.Second):
					t.Error("zone did not retire")
				}
			})
			secret := make([]byte, 32)
			for i := range secret {
				secret[i] = 0xab
			}
			token, err := zonesock.MintToken(secret, "allocation-a", 1, time.Now().Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 4*time.Second)
			defer cancel()
			hdr := http.Header{"Authorization": {"Bearer " + token}, zonesock.WireVersionHeader: {"3"}}
			var c *websocket.Conn
			var response *http.Response
			for {
				c, response, err = websocket.Dial(ctx, "ws://127.0.0.1:"+port+"/zone", &websocket.DialOptions{HTTPHeader: hdr})
				if response != nil && response.Body != nil {
					_ = response.Body.Close()
				}
				if err == nil || response != nil || ctx.Err() != nil {
					break
				}
				select {
				case err := <-done:
					t.Fatalf("movement command stopped before serving: %v", err)
				case <-time.After(time.Millisecond * 10):
				}
			}
			if !enabled {
				if c != nil {
					_ = c.CloseNow()
				}
				if err == nil || response == nil || response.StatusCode != 426 {
					t.Fatal("default command admitted movement")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = c.CloseNow() }()
			typ, b, err := c.Read(ctx)
			if err != nil || typ != websocket.MessageBinary {
				t.Fatal("missing movement join")
			}
			join, err := wire.Decode(b)
			if err != nil || join.Kind != wire.KindSnapshot || join.Version != 3 {
				t.Fatal("movement join changed")
			}
			before := commandAck(t, ctx, c)
			b, _ = wire.EncodeIntent(wire.MovementIntent{Sequence: 1, X: 1000, Sprint: true})
			if err := c.Write(ctx, websocket.MessageBinary, b); err != nil {
				t.Fatal(err)
			}
			var ack wire.MovementAck
			for ack.AppliedSequence != 1 {
				ack = commandAck(t, ctx, c)
			}
			if ack.Pos.X-before.Pos.X <= 0 || ack.Pos.X-before.Pos.X > 266 {
				t.Fatalf("built zone failed bounded movement: before=%+v after=%+v", before, ack)
			}
			for ack.Tick < before.Tick+8 {
				ack = commandAck(t, ctx, c)
			}
			stopped := ack
			for ack.Tick < stopped.Tick+3 {
				ack = commandAck(t, ctx, c)
			}
			if ack.Pos != stopped.Pos || ack.AppliedSequence != 1 {
				t.Fatal("built command kept moving after input expired")
			}
		})
	}
}

func commandAck(t *testing.T, ctx context.Context, c *websocket.Conn) wire.MovementAck {
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

func TestBuiltMovementRefusesInvalidConfiguration(t *testing.T) {
	for _, args := range [][]string{{"-movement-intents"}, {"-movement-intents", "-listen", "127.0.0.1:0", "-movement-hold-ticks", "0"}, {"-movement-intents", "-listen", "127.0.0.1:0", "-movement-hold-ticks", "301"}} {
		out, err := zoneCommand(t, args...).CombinedOutput()
		if err == nil || !strings.Contains(string(out), "movement intents:") {
			t.Fatalf("invalid movement settings did not refuse at startup: %v %s", err, out)
		}
	}
}
