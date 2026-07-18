// Command zone runs a single World at Ruin zone simulation.
//
// It is the skeleton of the authoritative realtime tier: one fixed-timestep
// tick loop, one process, one zone. It is not yet wired to a socket or the
// Agones SDK — those are later children of the server-foundation epic — so for
// now it exists to prove the tick core boots, steps deterministically, and can
// also be driven from the wall clock. With -replicate it additionally runs the
// full replication pipeline a transport will carry — tracker delta →
// wire-encode → decode → verify — and reports the payload sizes, so the wire
// layer is exercised end-to-end before any socket exists (and the numbers are
// the baseline for future bandwidth evidence).
//
//	zone                     # 600 deterministic ticks, then print the state hash
//	zone -ticks 1800         # a different fixed count
//	zone -realtime -duration 3s   # drive the fixed loop from real time for 3s
//	zone -replicate 1        # also track observer 1, wire-encode its delta stream
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"reflect"
	"syscall"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

func main() {
	ticks := flag.Int("ticks", 600, "run this many fixed ticks deterministically, then print the state hash")
	realtime := flag.Bool("realtime", false, "drive the fixed loop from the wall clock instead of a fixed count")
	duration := flag.Duration("duration", 2*time.Second, "run length in -realtime mode")
	replicate := flag.Uint64("replicate", 0, "observer entity ID: track its replication deltas, wire-encode and decode-verify each, and print payload stats (fixed-tick mode)")
	interest := flag.Int64("interest", 12_000, "observer interest radius in mm for -replicate")
	flag.Parse()

	w := sim.NewDemoWorld()
	switch {
	case *realtime:
		runRealtime(w, *duration)
	case *replicate != 0:
		runReplicate(w, *ticks, sim.EntityID(*replicate), *interest)
	default:
		for range *ticks {
			sim.DriveDemoTick(w)
			w.Step()
		}
	}
	fmt.Printf("zone: entities=%d tick=%d hash=%016x\n", w.Count(), w.Tick, w.Hash())
}

// runReplicate drives the fixed demo ticks while tracking one observer's
// replication stream through the wire codec: every non-empty per-tick delta is
// encoded, decoded back and verified, and the final full snapshot (the join
// payload) runs the same round trip. Interest configuration is not part of the
// hashed step state, so the closing hash line still prints the same golden
// hash as a plain run — replication observation cannot move the sim.
func runReplicate(w *sim.World, ticks int, observer sim.EntityID, interestMM int64) {
	w.SetInterestRadius(observer, interestMM)
	tr := sim.NewSnapshotTracker(observer)

	frames, totalBytes, maxFrame := 0, 0, 0
	for range ticks {
		sim.DriveDemoTick(w)
		w.Step()
		d := tr.Update(w)
		if d.Empty() {
			continue
		}
		b, err := wire.EncodeSnapshotDelta(d)
		if err != nil {
			fatalf("tick %d: encode delta: %v", w.Tick, err)
		}
		m, err := wire.Decode(b)
		if err != nil {
			fatalf("tick %d: decode delta: %v", w.Tick, err)
		}
		if !reflect.DeepEqual(m.Delta, d) {
			fatalf("tick %d: wire round trip diverged from the tracker's delta", w.Tick)
		}
		frames++
		totalBytes += len(b)
		if len(b) > maxFrame {
			maxFrame = len(b)
		}
	}

	join := w.Snapshot(observer)
	jb, err := wire.EncodeSnapshot(join)
	if err != nil {
		fatalf("encode join snapshot: %v", err)
	}
	jm, err := wire.Decode(jb)
	if err != nil {
		fatalf("decode join snapshot: %v", err)
	}
	if !reflect.DeepEqual(jm.Snapshot, join) {
		fatalf("join snapshot wire round trip diverged")
	}

	fmt.Printf("zone: replicated observer=%d interest=%dmm deltaFrames=%d deltaBytes=%d maxDelta=%dB joinSnapshot=%dB (all decode-verified)\n",
		observer, interestMM, frames, totalBytes, maxFrame, len(jb))
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "zone: "+format+"\n", args...)
	os.Exit(1)
}

// runRealtime drives the world through a FixedLoop off the monotonic clock
// until d elapses or the process is asked to stop. Timing jitter changes how
// many ticks run, but never what a given tick computes — that is the point of
// decoupling the sim rate from the wall clock.
func runRealtime(w *sim.World, d time.Duration) {
	loop := sim.NewFixedLoop()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Poll faster than the sim rate so the accumulator sees fine-grained
	// deltas rather than one lumpy step per fixed interval.
	poll := time.NewTicker(time.Duration(loop.StepNanos() / 2))
	defer poll.Stop()
	deadline := time.NewTimer(d)
	defer deadline.Stop()

	last := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			return
		case now := <-poll.C:
			elapsed := now.Sub(last).Nanoseconds()
			last = now
			loop.Advance(elapsed, func() {
				sim.DriveDemoTick(w)
				w.Step()
			})
		}
	}
}
