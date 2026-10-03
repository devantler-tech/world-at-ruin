// Package zonesockettest runs the real snapshot ticker for socket tests.
package zonesockettest

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

// NewTickingHub constructs the real claimed hub and starts its snapshot ticker.
// Callers retain cancellation and join ownership, including their cleanup order.
func NewTickingHub(tb testing.TB, ctx context.Context, verifier *zonesock.HMACVerifier, claim zonesock.AdmissionClaimer, timeout time.Duration) (*zonesock.Hub, <-chan struct{}) {
	tb.Helper()
	hub, err := zonesock.NewClaimedHub(zonesock.Config{Verifier: verifier}, claim, timeout)
	if err != nil {
		tb.Fatal(err)
	}
	return hub, StartTicks(tb, ctx, hub)
}

// StartTicks retains the real demo world and hub; callers cancel and join done
// using their existing cleanup order before inspecting durable claim outcomes.
func StartTicks(tb testing.TB, ctx context.Context, hub *zonesock.Hub) <-chan struct{} {
	tb.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		world := sim.NewDemoWorld()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				hub.Tick(world)
			}
		}
	}()
	return done
}

// Dial performs a real verified TLS WebSocket handshake. Callers retain the
// timeout, response body, connection and cleanup ownership.
func Dial(ctx context.Context, server *httptest.Server, token string) (*websocket.Conn, *http.Response, error) {
	return websocket.Dial(ctx, server.URL, &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
}
