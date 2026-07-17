package sim

import "testing"

// TestFixedLoopExactSteps feeds the loop exactly K timesteps' worth of time, in
// uneven fragments, and asserts exactly K steps run — the accumulator must not
// lose or invent a step because real deltas do not line up with the tick.
func TestFixedLoopExactSteps(t *testing.T) {
	l := NewFixedLoop()
	step := l.StepNanos()
	// 100 ticks delivered as jittery fragments summing to 100*step.
	frags := []int64{step / 3, step / 3, step - 2*(step/3)}
	total := 0
	for range 100 {
		for _, f := range frags {
			total += l.Advance(f, func() {})
		}
	}
	if total != 100 {
		t.Fatalf("ran %d steps, want 100", total)
	}
}

// TestFixedLoopRemainderCarries confirms a sub-step remainder is preserved
// across calls, so two half-steps make one whole step rather than vanishing.
func TestFixedLoopRemainderCarries(t *testing.T) {
	l := NewFixedLoop()
	half := l.StepNanos() / 2
	if n := l.Advance(half, func() {}); n != 0 {
		t.Fatalf("first half-step ran %d steps, want 0", n)
	}
	if n := l.Advance(half+l.StepNanos()%2, func() {}); n != 1 {
		t.Fatalf("second half-step ran %d steps, want 1", n)
	}
}

// TestFixedLoopCapsCatchUp asserts a huge time jump runs at most maxCatchUp
// steps (no spiral of death) and that the dropped backlog does not burst on the
// next call.
func TestFixedLoopCapsCatchUp(t *testing.T) {
	l := NewFixedLoop()
	big := l.StepNanos() * 1000
	n := l.Advance(big, func() {})
	if n != defaultMaxCatchUp {
		t.Fatalf("catch-up ran %d steps, want the cap %d", n, defaultMaxCatchUp)
	}
	// The 992-step backlog must have been dropped, not banked.
	if extra := l.Advance(0, func() {}); extra != 0 {
		t.Fatalf("dropped backlog burst on the next call: %d steps", extra)
	}
	// And the loop still runs normally afterwards.
	if next := l.Advance(l.StepNanos(), func() {}); next != 1 {
		t.Fatalf("loop did not recover after a drop: ran %d steps, want 1", next)
	}
}

// TestFixedLoopIgnoresNonPositiveDelta confirms a zero or backwards clock never
// advances the sim.
func TestFixedLoopIgnoresNonPositiveDelta(t *testing.T) {
	l := NewFixedLoop()
	if n := l.Advance(0, func() {}); n != 0 {
		t.Fatalf("zero delta ran %d steps", n)
	}
	if n := l.Advance(-l.StepNanos()*5, func() {}); n != 0 {
		t.Fatalf("negative delta ran %d steps", n)
	}
	// A backwards clock must not have left a negative accumulator that eats a
	// later real step.
	if n := l.Advance(l.StepNanos(), func() {}); n != 1 {
		t.Fatalf("after a backwards clock, a real step ran %d steps, want 1", n)
	}
}
