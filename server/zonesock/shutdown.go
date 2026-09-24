package zonesock

import (
	"context"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// Shutdown permanently ends admission and drains socket work. Call it only on
// the simulation owner goroutine, after its tick loop has stopped. It fences
// admission even when ctx is canceled, but returns success only after all
// admitted handlers and socket workers exit. A timeout never reopens admission;
// a later call can wait for the same drain. It releases no durable handoff lease.
func (h *Hub) Shutdown(ctx context.Context, w *sim.World) error {
	h.mu.Lock()
	first := !h.closing
	var sockets []*conn
	if first {
		h.closing = true
		h.pending = nil
		for c := range h.sockets {
			sockets = append(sockets, c)
		}
	}
	h.mu.Unlock()
	if first {
		h.stop()
		for _, c := range h.conns {
			h.detach(w, c)
		}
		// CloseNow also interrupts a close handshake already in progress. Do
		// not enter c.once here: it may be owned by that blocked handshake.
		go func() {
			for _, c := range sockets {
				c.cancel()
				_ = c.ws.CloseNow()
			}
			h.workers.Wait()
			close(h.drained)
		}()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case <-h.drained:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// beginAdmission registers work before shutdown can start waiting. Cancellation
// reaches private claims without discarding request-scoped identity values.
func (h *Hub) beginAdmission(cancel context.CancelFunc) (func(), bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closing {
		return nil, false
	}
	h.workers.Add(1)
	stop := context.AfterFunc(h.lifetime, cancel)
	return func() { stop(); h.workers.Done() }, true
}

// registerSocket atomically tracks both transport workers and queues attachment.
// An upgrade racing shutdown is closed by its still-registered HTTP handler.
func (h *Hub) registerSocket(c *conn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closing {
		return false
	}
	c.workers.Store(2)
	h.workers.Add(2)
	h.sockets[c] = struct{}{}
	h.pending = append(h.pending, func(w *sim.World) { h.attach(w, c) })
	return true
}

// socketWorkerDone retires the transport only after both workers have stopped;
// the shutdown waiter cannot finish before this bookkeeping is complete.
func (h *Hub) socketWorkerDone(c *conn) {
	if c.workers.Add(-1) == 0 {
		h.mu.Lock()
		delete(h.sockets, c)
		h.mu.Unlock()
	}
	h.workers.Done()
}
