package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
			err := check(r, c, b, s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "")
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
	if err := check(r, c, "", s, o, adoptionRevision, ""); err == nil {
		t.Fatal("an invented catalog bootstrapped against the adoption revision")
	}
	if err := check(r, c, "", s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ""); err == nil {
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
	if err := check(r, c, b, s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ""); err != nil {
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

// frozenClone is one reported Go clone between two files, from column 0 of its
// first line to column 20 of its last.
func frozenClone(first, second, text string, lines int) map[string]any {
	return place(map[string]any{"format": "go", "fragment": text, "lines": lines, "tokens": 10 * lines,
		"firstFile": map[string]any{"name": first}, "secondFile": map[string]any{"name": second}}, 1, 0, 20)
}

// place puts both sides of a clone at a start line, between two columns.
func place(copy map[string]any, start, startColumn, endColumn int) map[string]any {
	end := start + copy["lines"].(int) - 1
	for _, side := range []string{"firstFile", "secondFile"} {
		copy[side] = map[string]any{"name": copy[side].(map[string]any)["name"], "start": start, "end": end,
			"startLoc": map[string]any{"line": start, "column": startColumn}, "endLoc": map[string]any{"line": end, "column": endColumn}}
	}
	return copy
}

// shifted moves both sides of a clone to start at the given line.
func shifted(copy map[string]any, start int) map[string]any { return place(copy, start, 0, 20) }

// with sets one field of a clone.
func with(copy map[string]any, field string, value any) map[string]any {
	copy[field] = value
	return copy
}

// unplaced drops the scanner's line and column coordinates from both sides.
func unplaced(copy map[string]any) map[string]any {
	for _, side := range []string{"firstFile", "secondFile"} {
		delete(copy[side].(map[string]any), "startLoc")
		delete(copy[side].(map[string]any), "endLoc")
	}
	return copy
}

// cloneReport writes a scanner report whose statistics agree with its clones.
func cloneReport(t *testing.T, dir, name string, clones []any) string {
	t.Helper()
	lines, tokens := 0, 0
	for _, copy := range clones {
		lines += copy.(map[string]any)["lines"].(int)
		tokens += copy.(map[string]any)["tokens"].(int)
	}
	return putReport(t, dir, name, clones, 100, 1000, lines, tokens)
}

// TestFrozenReferenceSplitNeedsTheBaseScan accepts an uncatalogued clone between
// a live file and a frozen reference only as a split of what the pinned scanner
// reported for the same pair at the base, within the base's duplicated lines.
func TestFrozenReferenceSplitNeedsTheBaseScan(t *testing.T) {
	const live, frozen, other, older = "client/scripts/live.go", "client/tests/historical/frozen.go", "client/scripts/other.go", "client/tests/historical/older.go"
	// Thirty lines of 25 columns, so every reported line and column is real text.
	var body strings.Builder
	for i := 1; i <= 30; i++ {
		fmt.Fprintf(&body, "value%02d := input*%02d + %03d\n", i, i, 7*i)
	}
	whole := frozenClone(live, frozen, "whole", 10)
	cases := []struct {
		name, want  string
		base, head  []any
		unheld      bool // the base catalog holds no entry for the pair, as after an accepted split
		handDeleted bool // the head catalog holds none of the head clones, as if deleted by hand
		noBaseScan  bool
		editFrozen  bool
	}{
		{name: "a split of a reported clone is accepted",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), shifted(frozenClone(live, frozen, "back", 4), 6)}},
		{name: "the frozen side may be reported first",
			base: []any{whole}, head: []any{frozenClone(frozen, live, "front", 5), shifted(frozenClone(frozen, live, "back", 4), 6)}},
		{name: "a split may use exactly the base's duplicated lines",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), shifted(frozenClone(live, frozen, "back", 5), 6)}},
		{name: "a hand-deleted catalog entry is refused", want: "unaccepted clone", handDeleted: true,
			base: []any{whole}, head: []any{whole}},
		{name: "a split inside the reported region may sit anywhere in it",
			base: []any{whole}, head: []any{shifted(frozenClone(live, frozen, "middle", 4), 4)}},
		{name: "text copied from outside the reported region is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{shifted(frozenClone(live, frozen, "elsewhere", 5), 20)}},
		{name: "text straddling the reported region is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{shifted(frozenClone(live, frozen, "edge", 4), 8)}},
		{name: "a split may start partway through the reported first line",
			base: []any{place(frozenClone(live, frozen, "whole", 10), 1, 15, 20)}, head: []any{place(frozenClone(live, frozen, "front", 5), 1, 15, 20)}},
		{name: "a split reaching into the unshared start of a boundary line is refused", want: "unaccepted clone",
			base: []any{place(frozenClone(live, frozen, "whole", 10), 1, 15, 20)}, head: []any{place(frozenClone(live, frozen, "front", 5), 1, 0, 20)}},
		{name: "a split reaching past the reported last column is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{place(frozenClone(live, frozen, "back", 5), 6, 0, 21)}},
		{name: "a split without scanner columns is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{unplaced(frozenClone(live, frozen, "front", 5))}},
		{name: "two splits sharing reference text are refused", want: "more often",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), shifted(frozenClone(live, frozen, "again", 4), 4)}},
		{name: "fragments of a split sharing the token at the cut are accepted",
			base: []any{whole}, head: []any{with(place(frozenClone(live, frozen, "front", 5), 1, 0, 4), "tokens", 51), with(place(frozenClone(live, frozen, "back", 6), 5, 1, 20), "tokens", 50)}},
		{name: "another clone of the pair without scanner columns fails closed", want: "more often",
			base: []any{whole, shifted(frozenClone(live, frozen, "tail", 4), 20)}, head: []any{frozenClone(live, frozen, "front", 5), unplaced(shifted(frozenClone(live, frozen, "tail", 4), 20))}},
		{name: "a removed clone cannot fund text shared twice inside one line", want: "more often",
			base: []any{whole, shifted(frozenClone(live, frozen, "gone", 5), 20)}, head: []any{frozenClone(live, frozen, "front", 5), place(frozenClone(live, frozen, "back", 6), 5, 0, 20)}},
		{name: "a cut sharing more than one word is refused", want: "more often",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), place(frozenClone(live, frozen, "back", 6), 5, 0, 20)}},
		{name: "a cut sharing a compact expression is refused", want: "more often",
			base: []any{whole}, head: []any{with(place(frozenClone(live, frozen, "front", 5), 1, 0, 19), "tokens", 51), with(place(frozenClone(live, frozen, "back", 6), 5, 11, 20), "tokens", 50)}},
		{name: "a cut keeps its allowance when another clone of the pair is removed",
			base: []any{whole, shifted(frozenClone(live, frozen, "gone", 5), 20)}, head: []any{with(place(frozenClone(live, frozen, "front", 5), 1, 0, 4), "tokens", 51), with(place(frozenClone(live, frozen, "back", 6), 5, 1, 20), "tokens", 50)}},
		{name: "a changed clone keeping the whole span is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "reformatted", 10)}},
		{name: "two cuts may each share one word",
			base: []any{whole}, head: []any{with(place(frozenClone(live, frozen, "front", 5), 1, 0, 4), "tokens", 51), with(place(frozenClone(live, frozen, "middle", 3), 5, 1, 4), "tokens", 25), with(place(frozenClone(live, frozen, "back", 4), 7, 1, 20), "tokens", 26)}},
		{name: "keeping one occurrence of an identity leaves another occurrence free to be cut",
			base: []any{frozenClone(live, frozen, "twin", 10), shifted(frozenClone(live, frozen, "twin", 10), 20)},
			head: []any{shifted(frozenClone(live, frozen, "twin", 10), 20), with(place(frozenClone(live, frozen, "front", 5), 1, 0, 4), "tokens", 51), with(place(frozenClone(live, frozen, "back", 6), 5, 1, 20), "tokens", 50)}},
		{name: "a clone added inside an unchanged clone earns no cut", want: "more often",
			base: []any{whole}, head: []any{whole, with(place(frozenClone(live, frozen, "word", 1), 5, 1, 4), "tokens", 1)}},
		{name: "a clone cut twice may share a word at each cut while another is removed",
			base: []any{whole, shifted(frozenClone(live, frozen, "gone", 5), 20)}, head: []any{with(place(frozenClone(live, frozen, "front", 5), 1, 0, 4), "tokens", 51), with(place(frozenClone(live, frozen, "middle", 3), 5, 1, 4), "tokens", 25), with(place(frozenClone(live, frozen, "back", 4), 7, 1, 20), "tokens", 26)}},
		{name: "fragments sharing text across a line break are refused", want: "more often",
			base: []any{whole}, head: []any{place(frozenClone(live, frozen, "front", 5), 1, 0, 4), place(frozenClone(live, frozen, "back", 6), 4, 18, 20)}},
		{name: "a split sharing reference text with a catalogued clone is refused", want: "more often",
			base: []any{whole}, head: []any{whole, shifted(frozenClone(live, frozen, "again", 4), 3)}},
		{name: "splitting one of two clones that already overlapped is accepted",
			base: []any{whole, place(frozenClone(live, frozen, "tail", 6), 9, 0, 20)},
			head: []any{frozenClone(live, frozen, "front", 5), shifted(frozenClone(live, frozen, "back", 5), 6), place(frozenClone(live, frozen, "tail", 6), 9, 0, 20)}},
		{name: "a split adding a third cover to text two clones already shared is refused", want: "more often",
			base: []any{whole, place(frozenClone(live, frozen, "tail", 6), 9, 0, 20)},
			head: []any{whole, place(frozenClone(live, frozen, "tail", 6), 9, 0, 20), shifted(frozenClone(live, frozen, "again", 2), 9)}},
		{name: "splits meeting at one column are accepted",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), place(frozenClone(live, frozen, "touch", 4), 5, 20, 20)}},
		{name: "a split adding lines beyond one per cut is refused", want: "grows duplication",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), with(shifted(frozenClone(live, frozen, "back", 5), 6), "lines", 7)}},
		{name: "a split adding tokens beyond one per cut is refused", want: "grows duplication",
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5), with(shifted(frozenClone(live, frozen, "back", 5), 6), "tokens", 52)}},
		{name: "an unsplit clone gets no cut allowance", want: "grows duplication", unheld: true,
			base: []any{frozenClone(live, frozen, "front", 5)}, head: []any{with(shifted(frozenClone(live, frozen, "inner", 3), 2), "tokens", 51)}},
		{name: "a later split of an accepted split is accepted", unheld: true,
			base: []any{frozenClone(live, frozen, "front", 5)}, head: []any{shifted(frozenClone(live, frozen, "inner", 3), 2)}},
		{name: "an untouched fragment of an accepted split is accepted", unheld: true,
			base: []any{frozenClone(live, frozen, "front", 5)}, head: []any{frozenClone(live, frozen, "front", 5)}},
		{name: "a later split must stay inside the accepted split", want: "unaccepted clone", unheld: true,
			base: []any{frozenClone(live, frozen, "front", 5)}, head: []any{shifted(frozenClone(live, frozen, "inner", 3), 4)}},
		{name: "a pair the base never reported is refused", want: "unaccepted clone",
			base: []any{whole}, head: []any{frozenClone(other, frozen, "front", 5)}},
		{name: "an edited reference is refused", want: "unaccepted clone", editFrozen: true,
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5)}},
		{name: "a missing base scan is refused", want: "unaccepted clone", noBaseScan: true,
			base: []any{whole}, head: []any{frozenClone(live, frozen, "front", 5)}},
		{name: "two ordinary files are refused", want: "unaccepted clone", handDeleted: true,
			base: []any{frozenClone(live, other, "whole", 10)}, head: []any{frozenClone(live, other, "front", 5)}},
		{name: "two frozen references are refused", want: "unaccepted clone",
			base: []any{frozenClone(older, frozen, "whole", 10)}, head: []any{frozenClone(older, frozen, "front", 5)}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			revision := frozenRepo(t, map[string]string{live: body.String(), frozen: body.String(), other: body.String(), older: body.String()})
			if test.editFrozen {
				if err := os.WriteFile(frozen, []byte(body.String()+"delta := 4\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			dir := t.TempDir()
			configPath := copyConfig(t, dir)
			empty := cloneReport(t, dir, "empty.json", []any{})
			baseReport := cloneReport(t, dir, "base-report.json", test.base)
			headReport := cloneReport(t, dir, "report.json", test.head)
			basePath, catalogPath := filepath.Join(dir, "base.json"), filepath.Join(dir, "catalog.json")
			held := baseReport
			if test.unheld {
				held = empty
			}
			if err := generate(held, configPath, basePath); err != nil {
				t.Fatal(err)
			}
			// The head catalog is regenerated from the base one, as a contributor would.
			data, err := os.ReadFile(basePath)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(catalogPath, data, 0o600); err != nil {
				t.Fatal(err)
			}
			regenerated := headReport
			if test.handDeleted {
				regenerated = empty
			}
			if err := generate(regenerated, configPath, catalogPath); err != nil {
				t.Fatal(err)
			}
			scanned := baseReport
			if test.noBaseScan {
				scanned = ""
			}
			owner := putJSON(t, dir, "owner.json", map[string]any{"number": 276, "state": "open"})
			expectResult(t, test.want, check(headReport, catalogPath, basePath, configPath, owner, revision, scanned))
		})
	}
}

// TestGenerationKeepsAnEmptyCatalogAnUpdate refuses to catalog a frozen-reference
// split when the prior catalog exists but holds no entries: an empty catalog is
// still an update, so only check's base scan may accept the split.
func TestGenerationKeepsAnEmptyCatalogAnUpdate(t *testing.T) {
	dir := t.TempDir()
	configPath := copyConfig(t, dir)
	catalogPath := filepath.Join(dir, "catalog.json")
	if err := generate(cloneReport(t, dir, "empty.json", []any{}), configPath, catalogPath); err != nil {
		t.Fatal(err)
	}
	split := cloneReport(t, dir, "report.json", []any{frozenClone("client/scripts/live.go", "client/tests/historical/frozen.go", "front", 5)})
	if err := generate(split, configPath, catalogPath); err != nil {
		t.Fatal(err)
	}
	value, _, err := readCatalog(catalogPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Entries) != 0 {
		t.Fatalf("an empty prior catalog was treated as a first generation: %d new entries", len(value.Entries))
	}
}
