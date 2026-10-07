// Package savefixturetest reads immutable shipped-save fixtures for tests.
package savefixturetest

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
)

// Fixture carries a historical version and its original, unmodified bytes.
type Fixture struct {
	Version int
	Bytes   []byte
}

// Read verifies the append-only ledger and reads every historical golden.
// Callers still seed storage and exercise their real save reader independently.
func Read(tb testing.TB, family string) []Fixture {
	tb.Helper()
	root, err := os.OpenRoot("testdata")
	if err != nil {
		tb.Fatal(err)
	}
	defer func() { _ = root.Close() }()
	ledgerBytes, err := root.ReadFile("shipped_" + family + "_versions.txt")
	if err != nil {
		tb.Fatalf("read %s schema ledger: %v", family, err)
	}
	versions := strings.Fields(string(ledgerBytes))
	if len(versions) == 0 {
		tb.Fatalf("%s schema ledger is empty", family)
	}
	fixtures := make([]Fixture, 0, len(versions))
	for index, rawVersion := range versions {
		version, err := strconv.Atoi(rawVersion)
		if err != nil {
			tb.Fatalf("schema ledger entry %q: %v", rawVersion, err)
		}
		if version != index+1 {
			tb.Fatalf("schema ledger[%d] = %d, want %d", index, version, index+1)
		}
		goldenBytes, err := root.ReadFile(fmt.Sprintf("golden_%s_v%d.json", family, version))
		if err != nil {
			tb.Fatalf("read %s schema %d golden: %v", family, version, err)
		}
		fixtures = append(fixtures, Fixture{Version: version, Bytes: goldenBytes})
	}
	return fixtures
}
