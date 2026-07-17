// Command cave generates the Phase 0 procedural cave chamber as binary glTF.
//
// Deterministic by construction: geometry derives only from -seed (a seeded
// permutation table drives the noise field itself). Same seed ⇒ identical
// MANIFEST; CI runs it twice and diffs.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/devantler-tech/world-at-ruin/tools/artgen"
)

func main() {
	seed := flag.Int64("seed", 42, "generation seed; the whole cave derives from it")
	out := flag.String("out", "", "output .glb path (required)")
	radius := flag.Float64("radius", 8, "chamber radius in metres")
	flag.Parse()
	if *out == "" {
		log.Fatal("-out is required")
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		log.Fatal(err)
	}
	mesh := artgen.Cave(artgen.CaveParams{Seed: *seed, Radius: *radius})
	fmt.Println(mesh.Manifest())
	if err := artgen.WriteGLB(mesh, *out); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("WROTE %s\n", *out)
}
