// Package nettest supplies invocation-owned loopback fixtures, never a
// production address-policy exception.
package nettest

import (
	"errors"
	"net"
	"testing"
)

// Loopback reserves an ephemeral listener and registers cleanup before return.
func Loopback(t *testing.T) net.Listener {
	t.Helper()
	listener, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			t.Error("owned test listener cleanup failed")
		}
	})
	return listener
}
