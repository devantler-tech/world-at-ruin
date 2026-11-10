package zonesock

import (
	"sync/atomic"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

const maxInputFramesPerTick = 64

// BeforeStep runs on the simulation owner after server AI/demo intent and
// before World.Step. Input never touches world state on a socket goroutine.
func (h *Hub) BeforeStep(w *sim.World) {
	if !h.cfg.MovementEnabled {
		return
	}
	h.runPending(w)
	for id := range h.controlled {
		w.SetIntent(id, sim.Vec3{})
	}
	for id, c := range h.conns {
		if c.wireVersion() != wire.MovementVersion || !c.inputActive.Load() {
			continue
		}
		c.inputMu.Lock()
		i := c.latest
		c.latest = wire.MovementIntent{}
		c.inputFrames = 0
		c.inputMu.Unlock()
		if i.Sequence != 0 {
			c.intents.applied.Add(1)
			c.held = movementVelocity(i, w.Get(id).MaxSpeed)
			c.remaining = h.cfg.MovementHoldTicks
			c.nextSequence, c.applyTick = i.Sequence, w.Tick+1
		} else if c.remaining > 0 {
			c.intents.held.Add(1)
		}
		if c.remaining > 0 {
			w.SetIntent(id, c.held)
			c.remaining--
		}
	}
}

// Server-owned sprint uses the actor's cap; walking uses half that cap.
// Arithmetic is bounded before multiplication and the world still enforces
// its own speed/collision/navmesh constraints on the authoritative step.
func movementVelocity(i wire.MovementIntent, maximum int64) sim.Vec3 {
	if maximum <= 0 {
		return sim.Vec3{}
	}
	if maximum > 1_000_000_000 {
		maximum = 1_000_000_000
	}
	if !i.Sprint {
		maximum /= 2
	}
	return sim.Vec3{X: int64(i.X) * maximum / 1000, Z: int64(i.Z) * maximum / 1000}
}

func (c *conn) inputBudget() bool {
	c.inputMu.Lock()
	defer c.inputMu.Unlock()
	if c.inputFrames >= maxInputFramesPerTick {
		return false
	}
	c.inputFrames++
	return true
}

func (c *conn) offerIntent(i wire.MovementIntent) {
	c.inputMu.Lock()
	defer c.inputMu.Unlock()
	if !c.inputActive.Load() {
		return
	}
	if i.Sequence <= c.received {
		c.intents.dropped.Add(1)
		return
	}
	if c.latest.Sequence != 0 {
		// A newer intent in the same tick supersedes the unapplied one.
		c.intents.dropped.Add(1)
	}
	c.received, c.latest = i.Sequence, i
}

// Own-state acknowledgements have their own single coalesced slot. Replication
// resync may discard deltas, but cannot discard the latest own position.
func (h *Hub) ackMovement(w *sim.World, c *conn) {
	if c.wireVersion() != wire.MovementVersion || !c.inputActive.Load() {
		return
	}
	if c.applyTick != 0 && w.Tick >= c.applyTick {
		c.appliedSequence = c.nextSequence
	}
	e := w.Get(c.observer)
	if e == nil {
		return
	}
	b, err := wire.EncodeMovementAck(wire.MovementAck{AppliedSequence: c.appliedSequence, Tick: w.Tick, Pos: e.Pos})
	if err != nil {
		c.teardown()
		return
	}
	c.ackMu.Lock()
	c.ack = b
	c.ackMu.Unlock()
	select {
	case c.ackReady <- struct{}{}:
	default:
	}
}

func (c *conn) takeAck() []byte {
	c.ackMu.Lock()
	defer c.ackMu.Unlock()
	b := c.ack
	c.ack = nil
	return b
}

// MovementCounters is one observer's movement-intent tally (#813), the
// server half of measuring prediction before its snap budget and intent hold
// are tuned. Applied counts intents a tick applied, each refreshing the hold.
// Held counts ticks that moved on a held intent with no new one. Dropped counts
// intent frames never applied: superseded by a newer one in the same tick,
// over the per-tick input budget, malformed, or not newer than one already
// received.
type MovementCounters struct {
	Applied, Held, Dropped uint64
}

// intentCounters is written by the socket reader (dropped) and the simulation
// owner (applied, held), so each count is atomic.
type intentCounters struct {
	applied, held, dropped atomic.Uint64
}

func (c *intentCounters) snapshot() MovementCounters {
	return MovementCounters{Applied: c.applied.Load(), Held: c.held.Load(), Dropped: c.dropped.Load()}
}

// MovementCounters reports an attached v3 observer's intent tally. It must be
// called from the simulation goroutine, like Tick; the same tally is logged
// when the observer detaches.
func (h *Hub) MovementCounters(observer sim.EntityID) (MovementCounters, bool) {
	c, ok := h.conns[observer]
	if !ok || c.wireVersion() != wire.MovementVersion {
		return MovementCounters{}, false
	}
	return c.intents.snapshot(), true
}
