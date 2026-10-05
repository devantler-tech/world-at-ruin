package zonesock

import (
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
			c.held = movementVelocity(i, w.Get(id).MaxSpeed)
			c.remaining = h.cfg.MovementHoldTicks
			c.nextSequence, c.applyTick = i.Sequence, w.Tick+1
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
	if c.inputActive.Load() && i.Sequence > c.received {
		c.received, c.latest = i.Sequence, i
	}
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
