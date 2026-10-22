package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func gitFixture(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid",
		"GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git fixture: %v: %s", err, out)
	}
	return strings.TrimSpace(string(out))
}

func sceneFixture(t *testing.T, skip string) (string, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "client", "tests")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	guards := []string{"save_fixture_guard_test", "creature_factory_test", "save_vault_guard_test",
		"boot_recovery_guard_test", "vault_restore_boot_test", "ability_registry_test"}
	for i := 0; i < 12; i++ {
		guards = append(guards, fmt.Sprintf("case%02d_test", i))
	}
	for _, name := range guards {
		if err := os.WriteFile(filepath.Join(dir, name+".tscn"), []byte("[gd_scene]\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if skip != "" {
		if err := os.WriteFile(filepath.Join(dir, "ci-skip.txt"), []byte(skip), 0600); err != nil {
			t.Fatal(err)
		}
	}
	gitFixture(t, root, "init", "-q", "-b", "main")
	gitFixture(t, root, "add", "client/tests")
	gitFixture(t, root, "commit", "-qm", "fixture")
	return root, gitFixture(t, root, "rev-parse", "HEAD")
}

func mustPlan(t *testing.T, root, sha string, shard int) scenePlan {
	t.Helper()
	p, err := buildPlan(root, sha, "77", "2", shard)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func journal(p scenePlan) []byte { return []byte(strings.Join(p.Scenes, "\n") + "\n") }

func TestCompleteDisjointPlan(t *testing.T) {
	root, sha := sceneFixture(t, "")
	seen := map[string]bool{}
	digest := ""
	for shard := 0; shard < 3; shard++ {
		p := mustPlan(t, root, sha, shard)
		if len(p.Scenes) != 4 {
			t.Fatalf("shard %d: %v", shard, p.Scenes)
		}
		if digest != "" && digest != p.Digest {
			t.Fatal("workers disagree about the full plan")
		}
		digest = p.Digest
		for _, name := range p.Scenes {
			if seen[name] || !strings.HasPrefix(name, "case") {
				t.Fatalf("duplicate or dedicated guard: %s", name)
			}
			seen[name] = true
		}
	}
	if len(seen) != 12 {
		t.Fatal("incomplete scene union")
	}
	p := mustPlan(t, root, sha, 0)
	if !reflect.DeepEqual(p.Scenes, []string{"case00_test", "case03_test", "case06_test", "case09_test"}) {
		t.Fatal(p.Scenes)
	}
}

func TestSkipSemanticsAndIdentity(t *testing.T) {
	root, sha := sceneFixture(t, " \t# comment\n\ncase01_test\n case02_test\ncase03_test \nsave_fixture_guard_test\n")
	count := 0
	for shard := 0; shard < 3; shard++ {
		p := mustPlan(t, root, sha, shard)
		count += len(p.Scenes)
		for _, name := range p.Scenes {
			if name == "case01_test" {
				t.Fatal("listed scene was run")
			}
		}
	}
	if count != 11 {
		t.Fatalf("skip semantics drifted: %d", count)
	}
	for _, args := range [][4]string{
		{"bad", "77", "2", "0"}, {sha, "0", "2", "0"}, {sha, "077", "2", "0"},
		{sha, "77", "0", "0"}, {sha, "77", "2", "3"},
	} {
		shard := 0
		if args[3] == "3" {
			shard = 3
		}
		if _, err := buildPlan(root, args[0], args[1], args[2], shard); err == nil {
			t.Fatal("accepted invalid identity")
		}
	}
	if err := os.WriteFile(filepath.Join(root, "client/tests/case00_test.tscn"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := buildPlan(root, sha, "77", "2", 0); err == nil {
		t.Fatal("accepted dirty scene source")
	}
}

func TestSealRequiresEverySuccessfulSceneExactlyOnce(t *testing.T) {
	root, sha := sceneFixture(t, "")
	p := mustPlan(t, root, sha, 0)
	r, err := sealPlan(p, journal(p))
	if err != nil || !r.Complete || !reflect.DeepEqual(r.Scenes, p.Scenes) {
		t.Fatalf("%+v %v", r, err)
	}
	for _, data := range [][]byte{nil, journal(scenePlan{Scenes: p.Scenes[1:]}),
		[]byte(strings.Join(append(append([]string{}, p.Scenes...), p.Scenes[0]), "\n") + "\n"),
		[]byte(strings.Join(p.Scenes, "\n")), []byte("unknown_test\n")} {
		if _, err := sealPlan(p, data); err == nil {
			t.Fatal("accepted incomplete, duplicate or malformed journal")
		}
	}
}

func TestPlanRejectsChangedProductSource(t *testing.T) {
	root, _ := sceneFixture(t, "")
	dir := filepath.Join(root, "client/scripts")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "product.gd")
	if err := os.WriteFile(path, []byte("extends Node\n"), 0600); err != nil {
		t.Fatal(err)
	}
	gitFixture(t, root, "add", "client/scripts/product.gd")
	gitFixture(t, root, "commit", "-qm", "product source")
	sha := gitFixture(t, root, "rev-parse", "HEAD")
	mustPlan(t, root, sha, 0)
	if err := os.WriteFile(path, []byte("extends Node2D\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := buildPlan(root, sha, "77", "2", 0); err == nil {
		t.Fatal("accepted product code different from the tested integration")
	}
}

func TestInventoryRefusesEmptyMissingAliasedAndUntrackedScenes(t *testing.T) {
	for _, mode := range []string{"empty", "missing-guard", "symlink", "untracked"} {
		t.Run(mode, func(t *testing.T) {
			root, sha := sceneFixture(t, "")
			switch mode {
			case "empty":
				for i := 0; i < 12; i++ {
					if err := os.Remove(filepath.Join(root, fmt.Sprintf("client/tests/case%02d_test.tscn", i))); err != nil {
						t.Fatal(err)
					}
				}
			case "missing-guard":
				if err := os.Remove(filepath.Join(root, "client/tests/save_fixture_guard_test.tscn")); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				path := filepath.Join(root, "client/tests/case00_test.tscn")
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("case01_test.tscn", path); err != nil {
					t.Fatal(err)
				}
			case "untracked":
				if err := os.WriteFile(filepath.Join(root, "client/tests/extra_test.tscn"), []byte("[gd_scene]\n"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if mode != "untracked" {
				gitFixture(t, root, "add", "client/tests")
				gitFixture(t, root, "commit", "-qm", "changed inventory")
				sha = gitFixture(t, root, "rev-parse", "HEAD")
			}
			if _, err := buildPlan(root, sha, "77", "2", 0); err == nil {
				t.Fatal("accepted an incomplete or aliased inventory")
			}
		})
	}
}

func TestReducerRejectsMissingStalePartialAndDuplicateReceipts(t *testing.T) {
	root, sha := sceneFixture(t, "")
	makeEvidence := func() string {
		dir := t.TempDir()
		for shard := 0; shard < 3; shard++ {
			p := mustPlan(t, root, sha, shard)
			r, err := sealPlan(p, journal(p))
			if err != nil {
				t.Fatal(err)
			}
			sub := filepath.Join(dir, artifactName(p))
			if err := os.Mkdir(sub, 0700); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(r)
			if err := os.WriteFile(filepath.Join(sub, "receipt.json"), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}
	if count, err := verifyReceipts(root, sha, "77", "2", makeEvidence()); err != nil || count != 12 {
		t.Fatalf("%d %v", count, err)
	}
	for _, mutation := range []string{"missing-worker", "extra-worker", "wrong-shard", "wrong-sha", "wrong-run", "wrong-attempt", "wrong-plan", "missing-scene", "duplicate-scene", "incomplete", "unknown-field", "duplicate-key", "partial", "trailing-json", "symlink"} {
		t.Run(mutation, func(t *testing.T) {
			dir := makeEvidence()
			p := mustPlan(t, root, sha, 0)
			sub := filepath.Join(dir, artifactName(p))
			file := filepath.Join(sub, "receipt.json")
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			var r sceneReceipt
			if err := json.Unmarshal(data, &r); err != nil {
				t.Fatal(err)
			}
			switch mutation {
			case "missing-worker":
				if err := os.RemoveAll(sub); err != nil {
					t.Fatal(err)
				}
			case "extra-worker":
				if err := os.Mkdir(filepath.Join(dir, "extra"), 0700); err != nil {
					t.Fatal(err)
				}
			case "wrong-shard":
				r.Shard = 1
			case "wrong-sha":
				r.SHA = strings.Repeat("a", 40)
			case "wrong-run":
				r.Run = "78"
			case "wrong-attempt":
				r.Attempt = "1"
			case "wrong-plan":
				r.Digest = strings.Repeat("a", 64)
			case "missing-scene":
				r.Scenes = r.Scenes[1:]
			case "duplicate-scene":
				r.Scenes[1] = r.Scenes[0]
			case "incomplete":
				r.Complete = false
			case "unknown-field":
				data = append(data[:len(data)-1], []byte(",\"extra\":true}")...)
			case "duplicate-key":
				data = append(data[:len(data)-1], []byte(",\"complete\":true}")...)
			case "partial":
				data = data[:len(data)-1]
			case "trailing-json":
				data = append(data, []byte("\n{}")...)
			case "symlink":
				if err := os.Remove(file); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(root, "client/tests/case00_test.tscn"), file); err != nil {
					t.Fatal(err)
				}
			}
			if mutation != "missing-worker" && mutation != "extra-worker" && mutation != "symlink" {
				if !strings.Contains("unknown-field duplicate-key partial trailing-json", mutation) {
					data, _ = json.Marshal(r)
				}
				if err := os.WriteFile(file, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := verifyReceipts(root, sha, "77", "2", dir); err == nil {
				t.Fatal("accepted invalid receipt")
			}
		})
	}
}

func TestCLIUsesTheActualPlan(t *testing.T) {
	root, sha := sceneFixture(t, "")
	var out bytes.Buffer
	if err := execute(root, []string{"list", sha, "77", "2", "0"}, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != string(journal(mustPlan(t, root, sha, 0))) {
		t.Fatal("CLI selection differs from canonical plan")
	}
	for _, args := range [][]string{nil, {"list", sha}, {"list", sha, "77", "2", "00"}, {"unknown", sha, "77", "2", "0"}} {
		if err := execute(root, args, &out); err == nil {
			t.Fatal("accepted malformed invocation")
		}
	}
}
