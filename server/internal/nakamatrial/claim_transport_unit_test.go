//go:build !war_native_trial

package nakamatrial

import (
	"io"
	"net"
	"testing"
	"time"
)

// TestClaimTransportDisconnect uses actual byte streams, including a dead sender.
func TestClaimTransportDisconnect(t *testing.T) {
	for _, delayed := range []bool{false, true} {
		t.Run(map[bool]string{false: "ordinary", true: "delayed"}[delayed], func(t *testing.T) {
			zone, client := net.Pipe()
			backend, server := net.Pipe()
			t.Cleanup(func() { _ = zone.Close(); _ = client.Close(); _ = backend.Close(); _ = server.Close() })
			deadline := time.Time{}
			if delayed {
				deadline = time.Now().Add(300 * time.Millisecond)
			}
			done := make(chan struct{})
			frontendGone := make(chan struct{})
			go func() { relayClaim(client, backend, deadline, func() { close(frontendGone) }); close(done) }()
			written := make(chan error, 1)
			go func() { _, err := zone.Write([]byte("opaque TLS record")); written <- err }()
			bytes := make([]byte, len("opaque TLS record"))
			if _, err := io.ReadFull(server, bytes); err != nil || string(bytes) != "opaque TLS record" {
				t.Fatalf("original bytes changed: %q, %v", bytes, err)
			}
			if err := <-written; err != nil {
				t.Fatal(err)
			}
			_ = zone.Close()
			select {
			case <-frontendGone:
			case <-time.After(time.Second):
				t.Fatal("frontend EOF was not observed")
			}
			if delayed {
				// The independently owned backend must still accept its real reply.
				if _, err := server.Write([]byte("accepted remote reply")); err != nil {
					t.Fatalf("zone EOF closed retained backend: %v", err)
				}
			} else {
				if _, err := server.Write([]byte("remote reply")); err == nil {
					t.Fatal("ordinary EOF failed to close backend")
				}
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("transport workers failed to join")
			}
		})
	}
}

// TestClaimTransportBound catches retained backend leaks when no reply arrives.
func TestClaimTransportBound(t *testing.T) {
	zone, client := net.Pipe()
	backend, server := net.Pipe()
	t.Cleanup(func() { _ = zone.Close(); _ = client.Close(); _ = backend.Close(); _ = server.Close() })
	done := make(chan struct{})
	go func() { relayClaim(client, backend, time.Now().Add(100*time.Millisecond), nil); close(done) }()
	_ = zone.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("delayed disconnect exceeded its bound")
	}
	if _, err := server.Write([]byte("late reply")); err == nil {
		t.Fatal("bound left backend open")
	}
}
