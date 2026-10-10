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

// Reports use the pinned scanner's real field names. Exercise the production
// checker, including multiset identity, rather than a parallel count-only model.
func fixture(t *testing.T) (string, string, string, string, string) {
	t.Helper()
	dir := t.TempDir()
	config, err := os.ReadFile("../../.jscpd.json")
	if err != nil {
		t.Fatal(err)
	}
	put := func(name string, value any) string {
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
	configPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	location := func(name string, start int) map[string]any {
		return map[string]any{"name": name, "start": start, "end": start + 6}
	}
	clone := map[string]any{"format": "go", "fragment": "func repeated() { return 123456 }", "lines": 7, "tokens": 55,
		"firstFile": location("a.go", 1), "secondFile": location("b.go", 20)}
	stats := map[string]any{"clones": 1, "sources": 2, "lines": 40, "tokens": 100, "duplicatedLines": 7, "duplicatedTokens": 55}
	reportPath := put("report.json", map[string]any{"duplicates": []any{clone}, "statistics": map[string]any{
		"detectionDate": "2026-10-11T00:00:00Z", "total": stats, "formats": map[string]any{"go": stats}}})
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

func TestBootstrapIsExactRevisionOnly(t *testing.T) {
	r, c, _, s, o := fixture(t)
	if err := check(r, c, "", s, o, adoptionRevision); err == nil {
		t.Fatal("an invented catalog bootstrapped against the adoption revision")
	}
	if err := check(r, c, "", s, o, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); err == nil {
		t.Fatal("unknown base was allowed to bootstrap")
	}
}

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
