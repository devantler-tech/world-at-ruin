package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, group string) string {
	t.Helper()
	dir := t.TempDir()
	put := func(name, body string) {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if group == "activity" {
		for _, name := range []string{"light-response", "replication", "mob-chase", "breath", "walk", "run", "gait-transition", "gait-drive"} {
			put(name+"/frame.png", strings.Repeat("p", 12000))
			put(name+"/frame.txt", "caption")
		}
		put("logs/capture-replication.log", "REPLICATION on\n")
		put("logs/capture-mob-chase.log", "MOB CHASE on\n")
	} else {
		for _, name := range []string{"sunward", "crossfield", "shrine", "bonepale", "cinderreach", "cave-chamber", "cave-walkout", "cave-mouth"} {
			put(name+".png", strings.Repeat("p", 12000))
			put(name+".txt", "caption")
		}
		if group == "world" {
			put("opt-in-previews/enabled-flags.txt", "WAR_FIXTURE_PREVIEW=1\n")
			for _, name := range []string{"sunward", "crossfield", "shrine", "bonepale", "cinderreach", "cave-chamber", "cave-walkout", "cave-mouth"} {
				put("opt-in-previews/"+name+".png", strings.Repeat("p", 12000))
				put("opt-in-previews/"+name+".txt", "caption")
			}
			put("logs/capture.log", "REPLICATION off\n")
		} else {
			put("logs/base-capture.log", "CAPTURE PASS\n")
		}
	}
	return dir
}

func testContext(t *testing.T) evidenceContext {
	t.Helper()
	return evidenceContext{Version: 1, Integration: strings.Repeat("a", 40), Base: strings.Repeat("b", 40), Run: "123", Attempt: "1"}
}

func TestCollectCompleteEvidenceAndKnownBaseFailure(t *testing.T) {
	for _, baseOK := range []bool{true, false} {
		t.Run(map[bool]string{true: "complete", false: "known-base-failure"}[baseOK], func(t *testing.T) {
			ctx := testContext(t)
			world, activity, base := fixture(t, "world"), fixture(t, "activity"), fixture(t, "base")
			for _, item := range []struct {
				group, path string
				ok          bool
			}{{"world", world, true}, {"activity", activity, true}, {"base", base, baseOK}} {
				if err := seal(ctx, item.group, item.path, item.ok); err != nil {
					t.Fatal(err)
				}
			}
			out := filepath.Join(t.TempDir(), "joined")
			if err := collect(ctx, world, activity, base, out); err != nil {
				t.Fatal(err)
			}
			for _, path := range []string{"shots/sunward.png", "shots/replication/frame.png", "logs/capture.log", "logs/capture-mob-chase.log"} {
				if _, err := os.Stat(filepath.Join(out, path)); err != nil {
					t.Fatal(err)
				}
			}
			_, err := os.Stat(filepath.Join(out, "shots-base/sunward.png"))
			if baseOK && err != nil {
				t.Fatal(err)
			}
			if !baseOK && !os.IsNotExist(err) {
				t.Fatal("known failed base leaked partial comparison frames")
			}
		})
	}
}

func TestRejectIncompleteAlteredOrStaleEvidenceBeforePublishing(t *testing.T) {
	for _, mutation := range []string{"missing-file", "changed-bytes", "extra-file", "symlink", "missing-manifest", "stale-source", "stale-base", "stale-run", "stale-attempt", "mixed-flags", "failed-head", "truncated-manifest", "unexpected-group"} {
		t.Run(mutation, func(t *testing.T) {
			ctx := testContext(t)
			world, activity, base := fixture(t, "world"), fixture(t, "activity"), fixture(t, "base")
			altered := ctx
			switch mutation {
			case "stale-source":
				altered.Integration = strings.Repeat("c", 40)
			case "stale-base":
				altered.Base = strings.Repeat("c", 40)
			case "stale-run":
				altered.Run = "124"
			case "stale-attempt":
				altered.Attempt = "2"
			case "mixed-flags":
				altered.GPUGated = true
			}
			if err := seal(altered, "world", world, true); err != nil {
				t.Fatal(err)
			}
			if err := seal(ctx, "activity", activity, true); err != nil {
				t.Fatal(err)
			}
			if err := seal(ctx, "base", base, true); err != nil {
				t.Fatal(err)
			}
			switch mutation {
			case "missing-file":
				mustTest(t, os.Remove(filepath.Join(world, "sunward.png")))
			case "changed-bytes":
				mustTest(t, os.WriteFile(filepath.Join(world, "sunward.png"), []byte("changed"), 0644))
			case "extra-file":
				mustTest(t, os.WriteFile(filepath.Join(world, "extra.png"), []byte("extra"), 0644))
			case "symlink":
				mustTest(t, os.Symlink("sunward.png", filepath.Join(world, "link.png")))
			case "missing-manifest":
				mustTest(t, os.Remove(filepath.Join(world, "evidence.json")))
			case "truncated-manifest":
				mustTest(t, os.WriteFile(filepath.Join(world, "evidence.json"), []byte("{"), 0644))
			case "failed-head", "unexpected-group":
				name := filepath.Join(world, "evidence.json")
				raw, err := os.ReadFile(name)
				mustTest(t, err)
				old, next := "\"success\": true", "\"success\": false"
				if mutation == "unexpected-group" {
					old, next = "\"group\": \"world\"", "\"group\": \"base\""
				}
				mustTest(t, os.WriteFile(name, []byte(strings.Replace(string(raw), old, next, 1)), 0644))
			}
			out := filepath.Join(t.TempDir(), "joined")
			if err := collect(ctx, world, activity, base, out); err == nil {
				t.Fatal("accepted " + mutation)
			}
			if _, err := os.Lstat(out); !os.IsNotExist(err) {
				t.Fatal("invalid input published partial evidence")
			}
		})
	}
}

func TestSealRejectsMissingScenarioAndLinks(t *testing.T) {
	for _, mutation := range []string{"missing-scenario", "missing-caption", "link", "empty-log", "existing-manifest"} {
		t.Run(mutation, func(t *testing.T) {
			root := fixture(t, "activity")
			switch mutation {
			case "missing-scenario":
				mustTest(t, os.RemoveAll(filepath.Join(root, "walk")))
			case "missing-caption":
				mustTest(t, os.Remove(filepath.Join(root, "walk/frame.txt")))
			case "link":
				mustTest(t, os.Symlink("walk", filepath.Join(root, "linked")))
			case "empty-log":
				mustTest(t, os.WriteFile(filepath.Join(root, "logs/capture-replication.log"), nil, 0644))
			case "existing-manifest":
				mustTest(t, os.WriteFile(filepath.Join(root, "evidence.json"), []byte("old"), 0644))
			}
			if err := seal(testContext(t), "activity", root, true); err == nil {
				t.Fatal("accepted " + mutation)
			}
		})
	}
}

func mustTest(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestSealRequiresEveryWorldAndPreviewVantage(t *testing.T) {
	for _, name := range []string{"cave-mouth.png", "opt-in-previews/shrine.png"} {
		t.Run(name, func(t *testing.T) {
			root := fixture(t, "world")
			mustTest(t, os.Remove(filepath.Join(root, name)))
			if err := seal(testContext(t), "world", root, true); err == nil {
				t.Fatal("accepted a missing committed world vantage")
			}
		})
	}
}

func TestContextRefusesUnknownFlagsAndMalformedSources(t *testing.T) {
	valid := map[string]string{"GITHUB_SHA": strings.Repeat("a", 40), "BASE_SHA": strings.Repeat("b", 40), "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "FIRST_RUN": "false", "GPU_GATED": "false"}
	for key, value := range valid {
		t.Setenv(key, value)
	}
	if _, err := contextFromEnv(); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct{ key, value string }{{"GITHUB_SHA", "unknown"}, {"BASE_SHA", ""}, {"GITHUB_RUN_ID", "0"}, {"GITHUB_RUN_ATTEMPT", "-1"}, {"FIRST_RUN", "yes"}, {"GPU_GATED", ""}} {
		t.Run(item.key, func(t *testing.T) {
			t.Setenv(item.key, item.value)
			if _, err := contextFromEnv(); err == nil {
				t.Fatal("accepted malformed context")
			}
		})
	}
}

func TestSealAllowsAnEmptyRegisteredPreviewFlagList(t *testing.T) {
	root := fixture(t, "world")
	mustTest(t, os.WriteFile(filepath.Join(root, "opt-in-previews/enabled-flags.txt"), nil, 0644))
	if err := seal(testContext(t), "world", root, true); err != nil {
		t.Fatal(err)
	}
}

func TestSealRequiresThePreviewFlagRecord(t *testing.T) {
	root := fixture(t, "world")
	mustTest(t, os.Remove(filepath.Join(root, "opt-in-previews/enabled-flags.txt")))
	if err := seal(testContext(t), "world", root, true); err == nil {
		t.Fatal("accepted preview frames without their actual flag record")
	}
}

func TestTransportDoesNotRejudgePNGCompression(t *testing.T) {
	root := fixture(t, "world")
	mustTest(t, os.WriteFile(filepath.Join(root, "first_run_small.png"), []byte("small nonempty transport fixture"), 0644))
	mustTest(t, os.WriteFile(filepath.Join(root, "first_run_small.txt"), []byte("caption"), 0644))
	if err := seal(testContext(t), "world", root, true); err != nil {
		t.Fatal(err)
	}
	// The native capture keeps its own image/boot/luminance and nontrivial-PNG
	// guards. The transport layer must not impose a new per-image size policy.
}

func TestCLISealsAndCollectsBoundEvidence(t *testing.T) {
	for key, value := range map[string]string{"GITHUB_SHA": strings.Repeat("a", 40), "BASE_SHA": strings.Repeat("b", 40), "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "FIRST_RUN": "false", "GPU_GATED": "false"} {
		t.Setenv(key, value)
	}
	world, activity, base := fixture(t, "world"), fixture(t, "activity"), fixture(t, "base")
	for _, item := range []struct{ group, path string }{{"world", world}, {"activity", activity}, {"base", base}} {
		if err := run([]string{"seal", item.group, item.path, "success"}); err != nil {
			t.Fatal(err)
		}
	}
	out := filepath.Join(t.TempDir(), "joined")
	if err := run([]string{"collect", world, activity, base, out}); err != nil {
		t.Fatal(err)
	}
	receipt, err := os.ReadFile(filepath.Join(out, "shots/source-evidence.txt"))
	mustTest(t, err)
	if !strings.Contains(string(receipt), "run: 123\nattempt: 1\nbase_capture_success: true\n") {
		t.Fatal("missing exact evidence receipt")
	}
	for _, args := range [][]string{nil, {"unknown"}, {"seal", "world", world, "unknown"}} {
		if err := run(args); err == nil {
			t.Fatal("accepted invalid CLI arguments")
		}
	}
	if err := run([]string{"collect", world, activity, base, out}); err == nil {
		t.Fatal("overwrote existing output")
	}
	retained, err := os.ReadFile(filepath.Join(out, "shots/source-evidence.txt"))
	mustTest(t, err)
	if string(retained) != string(receipt) {
		t.Fatal("refused operation changed existing output")
	}
}
