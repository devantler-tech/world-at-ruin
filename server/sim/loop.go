package sim

const nanosPerSecond = 1_000_000_000

// defaultMaxCatchUp bounds how many fixed steps a single Advance may run. If a
// process stalls (GC pause, scheduler starvation) it must not then try to run
// hundreds of steps at once to "catch up" — that spiral of death would blow the
// tick budget and stall it further. Past the cap, simulation time is dropped
// rather than replayed.
const defaultMaxCatchUp = 8

// FixedLoop advances a World in fixed timesteps decoupled from wall-clock time,
// using an accumulator. The simulation therefore runs at exactly TickHz however
// jittery the host's real elapsed time is, and the cadence of rendering,
// networking or the OS scheduler never bleeds into the authoritative step.
//
// A FixedLoop is the wall-clock driver for exactly one World in one process
// (the zone tick loop is never decomposed). It holds no reference to the World:
// the caller passes a step function, which keeps the loop trivially testable
// with a synthetic time source and no real clock.
type FixedLoop struct {
	stepNanos  int64
	accumNanos int64
	maxCatchUp int
}

// NewFixedLoop returns a loop that fires TickHz fixed steps per real second.
func NewFixedLoop() *FixedLoop {
	return &FixedLoop{
		stepNanos:  nanosPerSecond / TickHz,
		maxCatchUp: defaultMaxCatchUp,
	}
}

// StepNanos is the fixed timestep length in nanoseconds (1/TickHz seconds).
func (l *FixedLoop) StepNanos() int64 { return l.stepNanos }

// Advance adds realElapsedNanos to the accumulator and runs one fixed step per
// whole timestep that has accumulated, calling step each time. It returns the
// number of steps run.
//
// A non-positive delta is ignored (a backwards or zero clock never rewinds or
// spins the sim). At most maxCatchUp steps run per call; if more time than that
// has piled up, the whole backlog beyond one sub-step remainder is discarded so
// it cannot burst on a later call. The remainder is preserved, so steady real
// time still maps exactly onto steady tick counts across successive calls.
func (l *FixedLoop) Advance(realElapsedNanos int64, step func()) int {
	if realElapsedNanos > 0 {
		l.accumNanos += realElapsedNanos
	}
	n := 0
	for l.accumNanos >= l.stepNanos {
		if n >= l.maxCatchUp {
			// Drop the backlog, keep the sub-step remainder.
			l.accumNanos %= l.stepNanos
			break
		}
		step()
		l.accumNanos -= l.stepNanos
		n++
	}
	return n
}
