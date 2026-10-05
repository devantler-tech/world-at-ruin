// Command groundgoldens prints the deterministic cross-tier ground fixtures.
package main

import (
	"log"
	"os"

	"github.com/devantler-tech/world-at-ruin/server/internal/groundgoldens"
)

// main writes the reproducible corpus to standard output or reports generation failure.
func main() {
	raw, err := groundgoldens.Bytes()
	if err != nil {
		log.Fatal(err)
	}
	if _, err := os.Stdout.Write(raw); err != nil {
		log.Fatal(err)
	}
}
