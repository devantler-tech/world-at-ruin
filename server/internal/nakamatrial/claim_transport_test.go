package nakamatrial

import (
	"io"
	"net"
	"time"
)

// relayClaim forwards private TLS bytes without inspecting or authenticating them.
// A nonzero deadline selects the bounded delayed-disconnect native fault control.
func relayClaim(client, backend net.Conn, deadline time.Time, disconnected func()) {
	defer func() { _ = client.Close(); _ = backend.Close() }()
	if !deadline.IsZero() {
		_ = client.SetDeadline(deadline)
		_ = backend.SetDeadline(deadline)
	}
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(backend, client)
		if deadline.IsZero() {
			_ = backend.Close()
			_ = client.Close()
		}
		if disconnected != nil {
			disconnected()
		}
		close(done)
	}()
	_, _ = io.Copy(client, backend)
	_ = backend.Close()
	_ = client.Close()
	<-done
}
