// Command zone runs a single World at Ruin zone simulation.
//
// It is the skeleton of the authoritative realtime tier: one fixed-timestep
// tick loop, one process, one zone. It is not yet wired to networking or the
// Agones SDK — those are later children of the server-foundation epic — so for
// now it exists to prove the tick core boots, steps deterministically, and can
// also be driven from the wall clock.
//
//	zone                     # 600 deterministic ticks, then print the state hash
//	zone -ticks 1800         # a different fixed count
//	zone -realtime -duration 3s   # drive the fixed loop from real time for 3s
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

func main() {
	ticks := flag.Int("ticks", 600, "run this many fixed ticks deterministically, then print the state hash")
	realtime := flag.Bool("realtime", false, "drive the fixed loop from the wall clock instead of a fixed count")
	duration := flag.Duration("duration", 2*time.Second, "run length in -realtime mode")
	flag.Parse()

	w := sim.NewDemoWorld()
	if *realtime {
		runRealtime(w, *duration)
	} else {
		for range *ticks {
			sim.DriveDemoTick(w)
			w.Step()
		}
	}
	fmt.Printf("zone: entities=%d tick=%d hash=%016x\n", w.Count(), w.Tick, w.Hash())
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
