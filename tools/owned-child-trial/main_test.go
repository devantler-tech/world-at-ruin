package ownedchild

import (
	"flag"
	"fmt"
	"os"
	"testing"
)

var experimental = flag.Bool("war-experimental", false, "explicit disposable process trial opt-in")
var workerMode = flag.String("war-worker", "", "fixture-owned worker mode")
var orphanMode = flag.Bool("war-orphan-scenario", false, "separate expected-refusal containment scenario")

// TestMain refuses native work before spawning any process without explicit opt-in.
func TestMain(m *testing.M) {
	flag.Parse()
	if *orphanMode {
		if !*experimental || !nativeEnabled() {
			os.Exit(2)
		}
		os.Exit(orphanScenario())
	}
	if *workerMode != "" {
		if !*experimental {
			os.Exit(2)
		}
		os.Exit(worker(*workerMode))
	}
	if nativeEnabled() && !*experimental {
		fmt.Fprintln(os.Stderr, "owned child trial requires explicit opt-in before any process")
		os.Exit(2)
	}
	os.Exit(m.Run())
}
