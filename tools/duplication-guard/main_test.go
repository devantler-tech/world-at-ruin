package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixture writes report, catalog and ownership inputs with real scanner fields.
// It exercises the production multiset checker rather than a count-only model.
func fixture(t *testing.T) (string, string, string, string, string) {
	t.Helper()
	dir := t.TempDir()
	put := func(name string, value any) string { return putJSON(t, dir, name, value) }
	configPath := copyConfig(t, dir)
	location := func(name string, start int) map[string]any {
		return map[string]any{"name": name, "start": start, "end": start + 6}
	}
	clone := map[string]any{"format": "go", "fragment": "func repeated() { return 123456 }", "lines": 7, "tokens": 55,
		"firstFile": location("a.go", 1), "secondFile": location("b.go", 20)}
	reportPath := putReport(t, dir, "report.json", []any{clone}, 40, 100, 7, 55)
	catalogPath := filepath.Join(dir, "catalog.json")
	if err := generate(reportPath, configPath, catalogPath); err != nil {
		t.Fatal(err)
	}
	basePath := filepath.Join(dir, "base.json")
	data, err := os.ReadFile(catalogPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(basePath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	ownerPath := put("owner.json", map[string]any{"number": 276, "state": "open"})
	return reportPath, catalogPath, basePath, configPath, ownerPath
}

// putJSON writes one JSON fixture file into dir and returns its path.
func putJSON(t *testing.T, dir, name string, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// copyConfig copies the repository's detection settings into dir.
func copyConfig(t *testing.T, dir string) string {
	t.Helper()
	config, err := os.ReadFile(filepath.Join(guardDir, "../../.jscpd.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, config, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// putReport writes a Go-only scanner report whose statistics agree with its clones.
func putReport(t *testing.T, dir, name string, clones []any, lines, tokens, duplicatedLines, duplicatedTokens int) string {
	t.Helper()
	stats := map[string]any{"clones": len(clones), "sources": 2, "lines": lines, "tokens": tokens,
		"duplicatedLines": duplicatedLines, "duplicatedTokens": duplicatedTokens}
	return putJSON(t, dir, name, map[string]any{"duplicates": clones, "statistics": map[string]any{
		"detectionDate": "2026-10-11T00:00:00Z", "total": stats, "formats": map[string]any{"go": stats}}})
}

// guardDir is this test's own directory, captured before any test changes directory.
var guardDir = func() string {
	dir, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return dir
}()

// alter changes one fixture's JSON without duplicating the checker implementation.
func alter(t *testing.T, path string, change func(map[string]any)) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	change(value)
	data, err = json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// expectResult distinguishes required success from a specific refusal.
func expectResult(t *testing.T, want string, err error) {
	t.Helper()
	actual := ""
	if err != nil {
		actual = err.Error()
	}
	if want == "" && actual != "" {
		t.Fatalf("unexpected failure: %s", actual)
	}
	if want != "" && (actual == "" || !strings.Contains(actual, want)) {
		t.Fatalf("want %q, got %v", want, err)
	}
}

// trackedSources creates an isolated Git inventory for source-selection controls.
func trackedSources(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	for _, name := range []string{"a.go", "b.go"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("package fixture\nfunc repeated() { return 123456 }\n// source inventory control\n// line four\n// line five\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Chdir(dir)
	for _, args := range [][]string{{"init", "--quiet"}, {"add", "a.go", "b.go"}} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("fixture Git: %v %s", err, output)
		}
	}
}

// TestCatalogBehavior checks stable identities and refusal of growth or missing evidence.
func TestCatalogBehavior(t *testing.T) {
	cases := []struct {
		name, want string
		change     func(*testing.T, string, string, string, string, string)
	}{
		{name: "unchanged"},
		{name: "line movement", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) {
				x := v["duplicates"].([]any)[0].(map[string]any)
				x["firstFile"].(map[string]any)["start"] = 100
				x["firstFile"].(map[string]any)["end"] = 106
			})
		}},
		{name: "new clone", want: "unaccepted clone", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) {
				v["duplicates"].([]any)[0].(map[string]any)["fragment"] = "a different repeated block"
			})
		}},
		{name: "removed clone stale entry", want: "stale catalog", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) {
				v["duplicates"] = []any{}
				stats := v["statistics"].(map[string]any)
				for _, x := range []map[string]any{stats["total"].(map[string]any), stats["formats"].(map[string]any)["go"].(map[string]any)} {
					x["clones"] = 0
					x["duplicatedLines"] = 0
					x["duplicatedTokens"] = 0
				}
			})
		}},
		{name: "baseline laundering", want: "catalog growth", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) {
				v["duplicates"].([]any)[0].(map[string]any)["fragment"] = "laundered repeated block"
			})
			if err := generate(r, s, c); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "occurrence growth", want: "catalog growth", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, c, func(v map[string]any) { v["entries"].([]any)[0].(map[string]any)["occurrences"] = 2 })
		}},
		{name: "missing owner", want: "cleanup owner", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, c, func(v map[string]any) { v["entries"].([]any)[0].(map[string]any)["cleanupIssue"] = 0 })
		}},
		{name: "closed owner", want: "open cleanup owner", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, o, func(v map[string]any) { v["state"] = "closed" })
		}},
		{name: "missing report", want: "report", change: func(t *testing.T, r, c, b, s, o string) {
			if err := os.Remove(r); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "incomplete report", want: "statistics", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) { delete(v, "statistics") })
		}},
		{name: "inconsistent report", want: "statistics", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, r, func(v map[string]any) { v["statistics"].(map[string]any)["total"].(map[string]any)["clones"] = 99 })
		}},
		{name: "changed settings", want: "settings", change: func(t *testing.T, r, c, b, s, o string) {
			alter(t, s, func(v map[string]any) { v["ignore"] = []any{"**/*.go"} })
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			r, c, b, s, o := fixture(t)
			if test.change != nil {
				test.change(t, r, c, b, s, o)
			}
			err := check(r, c, b, s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
			expectResult(t, test.want, err)
			if test.name == "new clone" && (!strings.Contains(err.Error(), "a.go:1") || !strings.Contains(err.Error(), "b.go:20")) {
				t.Fatalf("missing both locations: %v", err)
			}
		})
	}
}

// TestBootstrapIsExactRevisionOnly rejects invented catalogs and unknown adoption bases.
func TestBootstrapIsExactRevisionOnly(t *testing.T) {
	r, c, _, s, o := fixture(t)
	if err := check(r, c, "", s, o, adoptionRevision); err == nil {
		t.Fatal("an invented catalog bootstrapped against the adoption revision")
	}
	if err := check(r, c, "", s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); err == nil {
		t.Fatal("unknown base was allowed to bootstrap")
	}
}

// TestGenerationPreservesReviewedJustification retains deliberate copies after owner closure.
func TestGenerationPreservesReviewedJustification(t *testing.T) {
	r, c, b, s, o := fixture(t)
	for _, path := range []string{c, b} {
		alter(t, path, func(value map[string]any) {
			e := value["entries"].([]any)[0].(map[string]any)
			delete(e, "cleanupIssue")
			e["reason"] = "Independent compatibility oracle must retain its original implementation."
		})
	}
	alter(t, o, func(value map[string]any) { value["state"] = "closed" })
	if err := generate(r, s, c); err != nil {
		t.Fatal(err)
	}
	if err := check(r, c, b, s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); err != nil {
		t.Fatalf("regeneration erased the reviewed justification: %v", err)
	}
}

// TestScannerCompletionBoundary rejects failed, stale and internally inconsistent producers.
func TestScannerCompletionBoundary(t *testing.T) {
	for _, test := range []struct{ name, mode, want string }{
		{"complete threshold report", "complete", ""},
		{"failed producer with plausible report", "exit-two", "scanner failed"},
		{"missing producer report", "missing", "report"},
		{"mismatched console count", "wrong-count", "do not agree"},
		{"additional producer error", "extra-error", "scanner failed"},
		{"copied old report", "old", "not produced during this scan"},
	} {
		t.Run(test.name, func(t *testing.T) {
			r, _, _, config, _ := fixture(t)
			alter(t, r, func(v map[string]any) {
				date := time.Now()
				if test.mode == "old" {
					date = date.Add(-time.Hour)
				}
				v["statistics"].(map[string]any)["detectionDate"] = date.Format(time.RFC3339Nano)
			})
			dir := t.TempDir()
			output := filepath.Join(dir, "output")
			t.Setenv("DUPLICATION_TEST_REPORT", r)
			t.Setenv("DUPLICATION_TEST_OUTPUT", output)
			t.Setenv("DUPLICATION_TEST_MODE", test.mode)
			program := filepath.Join(dir, "scanner")
			script := `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --version ]]; then printf 'cpd 5.0.16\n'; exit 0; fi
if [[ "$DUPLICATION_TEST_MODE" == missing ]]; then exit 2; fi
mkdir -p "$DUPLICATION_TEST_OUTPUT"
cp "$DUPLICATION_TEST_REPORT" "$DUPLICATION_TEST_OUTPUT/jscpd-report.json"
if [[ "$DUPLICATION_TEST_MODE" == wrong-count ]]; then printf 'Found 99 clones.\n'; else printf 'Found 1 clones.\n'; fi
printf 'JSON report saved to %s/jscpd-report.json\n' "$DUPLICATION_TEST_OUTPUT"
printf 'ERROR: jscpd found too many duplicates (1.6%%) over threshold (0.0%%)\n'
if [[ "$DUPLICATION_TEST_MODE" == extra-error ]]; then printf 'ERROR: failed to read source\n'; fi
if [[ "$DUPLICATION_TEST_MODE" == exit-two ]]; then exit 2; fi
exit 1
`
			if err := os.WriteFile(program, []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}
			trackedSources(t)
			err := scan(program, output, config)
			expectResult(t, test.want, err)
		})
	}
}

// TestIndependentSourceInventory proves tracked input cannot disappear through exclusions.
func TestIndependentSourceInventory(t *testing.T) {
	for _, test := range []struct {
		name, want string
		change     func(*testing.T)
	}{
		{name: "complete"},
		{name: "tracked shebang source in excluded directory", want: "excluded directory", change: func(t *testing.T) {
			if err := os.Mkdir("source-cache", 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile("source-cache/run", []byte("#!/usr/bin/env bash\nprintf 'tracked source must stay visible\\n'\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := exec.Command("git", "add", "source-cache/run").Run(); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "tracked code in excluded directory", want: "excluded directory", change: func(t *testing.T) {
			if err := os.Mkdir("source-cache", 0o700); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile("b.go")
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile("source-cache/c.go", data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := exec.Command("git", "add", "source-cache/c.go").Run(); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "unreadable", want: "unreadable", change: func(t *testing.T) {
			if err := os.Chmod("b.go", 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "oversize", want: "oversize", change: func(t *testing.T) {
			if err := os.WriteFile("b.go", bytes.Repeat([]byte(" "), 1048577), 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "oversize shebang without extension", want: "oversize", change: func(t *testing.T) {
			if err := os.Rename("b.go", "b"); err != nil {
				t.Fatal(err)
			}
			data := append([]byte("#!/usr/bin/env bash\n"), bytes.Repeat([]byte(" "), 1048577)...)
			if err := os.WriteFile("b", data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := exec.Command("git", "add", "b", "b.go").Run(); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "symlink", want: "non-regular", change: func(t *testing.T) {
			if err := os.Remove("b.go"); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("a.go", "b.go"); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "suppression", want: "suppression", change: func(t *testing.T) {
			data := []byte("// " + "jscpd:" + "ignore-start\npackage fixture\n")
			if err := os.WriteFile("b.go", data, 0o600); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, _, _, config, _ := fixture(t)
			trackedSources(t)
			if test.change != nil {
				test.change(t)
			}
			stage, counts, err := stageSources(context.Background(), config)
			if stage != "" {
				defer os.RemoveAll(stage)
			}
			expectResult(t, test.want, err)
			if test.want == "" && counts["go"] != 2 {
				t.Fatalf("incomplete inventory: %v", counts)
			}
		})
	}
}

// frozenSide is one side of a reported clone: the file, its head bytes and the duplicated text.
type frozenSide struct {
	name string
	data string
	text string
}

// frozenRepo commits base files in a throwaway repository and returns its revision.
func frozenRepo(t *testing.T, files map[string]string) string {
	t.Helper()
	t.Chdir(t.TempDir())
	for name, data := range files {
		if err := os.MkdirAll(filepath.Dir(name), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{{"init", "--quiet"}, {"add", "."},
		{"-c", "commit.gpgsign=false", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "base"}} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("fixture Git: %v %s", err, output)
		}
	}
	revision, err := exec.Command("git", "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(revision))
}

// frozenReport writes head files and a one-clone report whose positions are the
// scanner's byte offsets of each side's duplicated text, plus empty catalogs.
func frozenReport(t *testing.T, first, second frozenSide, shift int) (string, string, string, string, string) {
	t.Helper()
	side := func(s frozenSide) map[string]any {
		if err := os.WriteFile(s.name, []byte(s.data), 0o600); err != nil {
			t.Fatal(err)
		}
		start := strings.Index(s.data, s.text)
		if start < 0 {
			t.Fatalf("fixture text missing from %s", s.name)
		}
		end := start + len(s.text)
		return map[string]any{"name": s.name,
			"start": strings.Count(s.data[:start], "\n") + 1, "end": strings.Count(s.data[:end], "\n") + 1,
			"startLoc": map[string]any{"position": start + shift}, "endLoc": map[string]any{"position": end + shift}}
	}
	dir := t.TempDir()
	configPath := copyConfig(t, dir)
	// Both catalogs are empty, so only the base proof can accept the clone.
	empty := putReport(t, dir, "empty.json", []any{}, 6, 12, 0, 0)
	catalogPath, basePath := filepath.Join(dir, "catalog.json"), filepath.Join(dir, "base.json")
	for _, path := range []string{catalogPath, basePath} {
		if err := generate(empty, configPath, path); err != nil {
			t.Fatal(err)
		}
	}
	clone := map[string]any{"format": "go", "fragment": first.text, "lines": 2, "tokens": 6, "firstFile": side(first), "secondFile": side(second)}
	reportPath := putReport(t, dir, "report.json", []any{clone}, 6, 12, 2, 6)
	return reportPath, catalogPath, basePath, configPath, putJSON(t, dir, "owner.json", map[string]any{"number": 276, "state": "open"})
}

// TestFrozenReferenceSplitNeedsABaseProof accepts an uncatalogued clone between a
// live file and a frozen reference only when both already held its text at the base.
func TestFrozenReferenceSplitNeedsABaseProof(t *testing.T) {
	const live, frozen, other = "client/scripts/live.go", "client/tests/historical/frozen.go", "client/scripts/other.go"
	const body = "alpha := 1\nbeta := 2\ngamma := 3\n"
	const pair = "alpha := 1\nbeta := 2"
	cases := []struct {
		name, want    string
		base          map[string]string
		first, second frozenSide
		shift         int
	}{
		{name: "unchanged text is proven",
			base:  map[string]string{live: body, frozen: body},
			first: frozenSide{live, body, pair}, second: frozenSide{frozen, body, pair}},
		{name: "an edit elsewhere in the live file only moves the proven text",
			base:  map[string]string{live: body, frozen: body},
			first: frozenSide{live, "inserted := 0\n" + body, pair}, second: frozenSide{frozen, body, pair}},
		{name: "the frozen side may be reported first",
			base:  map[string]string{live: body, frozen: body},
			first: frozenSide{frozen, body, pair}, second: frozenSide{live, "inserted := 0\n" + body, pair}},
		{name: "text newly copied from the reference is refused", want: "unaccepted clone",
			base:  map[string]string{live: "alpha := 1\n", frozen: body},
			first: frozenSide{live, "alpha := 1\nbeta := 2\n", pair}, second: frozenSide{frozen, body, pair}},
		{name: "an edited reference is refused", want: "unaccepted clone",
			base:  map[string]string{live: body, frozen: body},
			first: frozenSide{live, body, pair}, second: frozenSide{frozen, body + "delta := 4\n", pair}},
		{name: "two ordinary files are refused", want: "unaccepted clone",
			base:  map[string]string{live: body, other: body},
			first: frozenSide{live, body, pair}, second: frozenSide{other, body, pair}},
		{name: "offsets that miss their reported lines are refused", want: "unaccepted clone", shift: 11,
			base:  map[string]string{live: body, frozen: body},
			first: frozenSide{live, body, pair}, second: frozenSide{frozen, body, pair}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			revision := frozenRepo(t, test.base)
			r, c, b, s, o := frozenReport(t, test.first, test.second, test.shift)
			expectResult(t, test.want, check(r, c, b, s, o, revision))
		})
	}
}
