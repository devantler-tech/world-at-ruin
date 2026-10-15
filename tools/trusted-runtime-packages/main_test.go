package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// verifierRecipe supplies the mandatory build-time comparison block.
func verifierRecipe() string {
	return "\nCOPY expected-packages.tsv verify-trusted-runtime-packages.sh /tmp/\nRUN bash /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv \\\n    && rm /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv\n"
}

// fixtureLock includes a direct package and its otherwise unrequested base dependency.
func fixtureLock() packageLock {
	return packageLock{1, "amd64", "sha256:" + strings.Repeat("a", 64), "20261003T000000Z", []packageIdentity{{"base-files", "13ubuntu10.3", "amd64"}, {"libgl1", "1.7.0-1build1", "amd64"}}}
}

// TestPackageLockRefusals checks complete decoding and canonical installed identities.
func TestPackageLockRefusals(t *testing.T) {
	good, _ := json.Marshal(fixtureLock())
	if _, err := decodeLock(good); err != nil {
		t.Fatal(err)
	}
	for name, raw := range map[string]string{
		"schema":         strings.Replace(string(good), `"schema":1`, `"schema":2`, 1),
		"architecture":   strings.Replace(string(good), `"architecture":"amd64"`, `"architecture":"arm64"`, 1),
		"empty packages": strings.Replace(string(good), `"packages":[`, `"packages":[] , "unused":[`, 1),
		"unknown":        strings.Replace(string(good), `"schema":1`, `"extra":1,"schema":1`, 1),
		"partial":        string(good[:len(good)-1]), "trailing": string(good) + "{}",
		"empty": "", "overflow": strings.Repeat(" ", maximumLockBytes+1),
		"package escape": strings.Replace(string(good), "base-files", "base-files\u000aevil", 1),
		"version escape": strings.Replace(string(good), "13ubuntu10.3", "1;evil", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeLock([]byte(raw)); err == nil {
				t.Fatal("accepted invalid lock")
			}
		})
	}
	for _, pkgs := range [][]packageIdentity{nil, {{"same", "1", "all"}, {"same", "1", "amd64"}}, {{"z", "1", "all"}, {"a", "1", "all"}}, {{"a", "1", "arm64"}}} {
		value := fixtureLock()
		value.Packages = pkgs
		raw, _ := json.Marshal(value)
		if _, err := decodeLock(raw); err == nil {
			t.Fatal("accepted empty, duplicate, unordered or foreign packages")
		}
	}
}

// TestRecipeJoinAndCompleteEmission exercises real files and refuses output on recipe drift.
func TestRecipeJoinAndCompleteEmission(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".github", "containers")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	value := fixtureLock()
	recipe := "FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\n libgl1=1.7.0-1build1 \\\n"
	recipe = strings.Replace(recipe, " libgl1=", " apt-get install -y --no-install-recommends libgl1=", 1) + "&& true\n"
	recipe += verifierRecipe()
	write := func(path string, raw []byte) {
		t.Helper()
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(dir, "trusted-regressions.Dockerfile"), []byte(recipe))
	raw, _ := json.Marshal(value)
	lockPath := filepath.Join(dir, "trusted-runtime-packages.lock.json")
	write(lockPath, raw)
	var out bytes.Buffer
	if err := emit(root, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\npackage\tlibgl1\t1.7.0-1build1\tamd64\tinstalled\n" {
		t.Fatal(out.String())
	}
	for _, replacement := range []string{strings.Replace(recipe, value.RuntimeManifest, "sha256:"+strings.Repeat("b", 64), 1), strings.Replace(recipe, value.Snapshot, "20261004T000000Z", 1), strings.Replace(recipe, "libgl1=1.7.0-1build1", "libgl1=99", 1), strings.Replace(recipe, "RUN bash /tmp/verify", "RUN true /tmp/verify", 1), recipe + verifierRecipe(), strings.Replace(recipe, "\nRUN bash", "\n# RUN bash", 1), strings.Replace(recipe, "&& rm /tmp/verify", "|| true; rm /tmp/verify", 1)} {
		write(filepath.Join(dir, "trusted-regressions.Dockerfile"), []byte(replacement))
		out.Reset()
		if err := emit(root, &out); err == nil || out.Len() != 0 {
			t.Fatal("recipe drift emitted accepted expectation")
		}
	}
	write(filepath.Join(dir, "trusted-regressions.Dockerfile"), []byte(recipe))
	if err := os.Rename(lockPath, lockPath+".original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(lockPath+".original", lockPath); err != nil {
		t.Fatal(err)
	}
	if err := emit(root, &out); err == nil {
		t.Fatal("linked lock accepted")
	}
}

// TestEveryInstallArgumentIsPinned exercises partial pin removal and duplicates.
func TestEveryInstallArgumentIsPinned(t *testing.T) {
	value := fixtureLock()
	prefix := "FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\napt-get install -y --no-install-recommends "
	for _, arguments := range []string{
		"libgl1 base-files=13ubuntu10.3", "libgl1=1.7.0-1build1 base-files",
		"libgl1=1.7.0-1build1 libgl1=1.7.0-1build1",
		"libgl1=1.7.0-1build1 libgl1=99", "libgl1=1.7.0-1build1; true",
	} {
		t.Run(arguments, func(t *testing.T) {
			if err := joinRecipe(value, []byte(prefix+arguments+" && true\n"+verifierRecipe())); err == nil {
				t.Fatal("accepted an unpinned, duplicate or non-package install argument")
			}
		})
	}
}

// fixtureReport supplies the complete cold-report envelope, including source identities.
func fixtureReport() map[string]any {
	file := func(path string) map[string]any {
		return map[string]any{"path": path, "sha256": strings.Repeat("a", 64), "bytes": 1}
	}
	apt := []any{}
	for _, path := range []string{"/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt", "/var/lib/apt/lists/example_InRelease", "/var/lib/apt/lists/example_Packages.lz4"} {
		apt = append(apt, file(path))
	}
	recipes := []any{}
	for _, path := range []string{
		".github/containers/trusted-regressions.Dockerfile", "tools/build-trusted-regression-runtime.sh", "tools/install-ci-godot.sh",
		"tools/trusted-regression-lifecycle.sh", "tools/trusted-regression-phase.sh", "tools/trusted-phase-command.sh",
		"tools/process-group-lifecycle.sh", "tools/capture-trusted-runtime-inventory.sh", "tools/inspect-trusted-runtime.sh",
		"tools/trusted-runtime-inventory/main.go", ".github/containers/trusted-runtime-bases.sources.json",
		".github/containers/trusted-runtime-bases.lock.json", "tools/trusted-runtime-bases/main.go", "tools/build-locked-trusted-runtime.sh",
	} {
		recipes = append(recipes, file(path))
	}
	return map[string]any{
		"schema": 1, "evidence": "observed-cold-build-inventory-only",
		"image":        map[string]any{"Id": "sha256:" + strings.Repeat("a", 64), "Os": "linux", "Architecture": "amd64", "Config": map[string]any{"User": "1001:1001", "WorkingDir": "/project", "Entrypoint": []string{"/usr/local/bin/godot"}}},
		"inventory":    map[string]any{"architecture": "amd64", "installed_packages": fixtureLock().Packages, "apt_inputs": apt, "engine_sha256": strings.Repeat("b", 64)},
		"recipe_files": recipes, "caller_engine_version": "4.6.stable", "caller_engine_archive_sha512": strings.Repeat("c", 128),
	}
}

// TestReportEvidenceCannotBeOmitted rejects plausible package rows without their envelope.
func TestReportEvidenceCannotBeOmitted(t *testing.T) {
	value := fixtureLock()
	recipe := []byte("FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\napt-get install -y --no-install-recommends libgl1=1.7.0-1build1 && true\n" + verifierRecipe())
	for _, path := range [][]string{{"image", "Id"}, {"inventory", "apt_inputs"}, {"inventory", "engine_sha256"}, {"recipe_files"}, {"caller_engine_version"}, {"caller_engine_archive_sha512"}} {
		t.Run(strings.Join(path, "/"), func(t *testing.T) {
			report := fixtureReport()
			parent := report
			for _, key := range path[:len(path)-1] {
				parent = parent[key].(map[string]any)
			}
			delete(parent, path[len(path)-1])
			raw, err := json.Marshal(report)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := generate(raw, recipe); err == nil {
				t.Fatal("generated a lock from an incomplete source report")
			}
		})
	}
}

// TestMalformedReportEvidence rejects shortened inventories and invalid evidence rows.
func TestMalformedReportEvidence(t *testing.T) {
	value := fixtureLock()
	recipe := []byte("FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\napt-get install -y --no-install-recommends libgl1=1.7.0-1build1 && true\n" + verifierRecipe())
	for name, mutate := range map[string]func(map[string]any){
		"direct packages only": func(r map[string]any) {
			r["inventory"].(map[string]any)["installed_packages"] = fixtureLock().Packages[1:]
		},
		"bad image digest":   func(r map[string]any) { r["image"].(map[string]any)["Id"] = "sha256:short" },
		"bad engine digest":  func(r map[string]any) { r["inventory"].(map[string]any)["engine_sha256"] = "short" },
		"bad archive digest": func(r map[string]any) { r["caller_engine_archive_sha512"] = "short" },
		"missing APT config": func(r map[string]any) {
			inv := r["inventory"].(map[string]any)
			inv["apt_inputs"] = inv["apt_inputs"].([]any)[1:]
		},
		"missing APT index": func(r map[string]any) {
			inv := r["inventory"].(map[string]any)
			inv["apt_inputs"] = inv["apt_inputs"].([]any)[:5]
		},
		"missing recipe file": func(r map[string]any) { r["recipe_files"] = r["recipe_files"].([]any)[1:] },
		"duplicate recipe": func(r map[string]any) {
			files := r["recipe_files"].([]any)
			r["recipe_files"] = append(files, files[0])
		},
		"bad file digest": func(r map[string]any) { r["recipe_files"].([]any)[0].(map[string]any)["sha256"] = "short" },
		"empty file":      func(r map[string]any) { r["recipe_files"].([]any)[0].(map[string]any)["bytes"] = 0 },
		"escaped file":    func(r map[string]any) { r["recipe_files"].([]any)[0].(map[string]any)["path"] = "../outside" },
	} {
		t.Run(name, func(t *testing.T) {
			report := fixtureReport()
			mutate(report)
			raw, err := json.Marshal(report)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := generate(raw, recipe); err == nil {
				t.Fatal("generated a lock from invalid source evidence")
			}
		})
	}
}

// TestGeneratedExpectationRequiresCompleteReport preserves complete report generation.
func TestGeneratedExpectationRequiresCompleteReport(t *testing.T) {
	value := fixtureLock()
	recipe := "FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\napt-get install -y --no-install-recommends libgl1=1.7.0-1build1 && true\n"
	recipe += verifierRecipe()
	raw, err := json.Marshal(fixtureReport())
	if err != nil {
		t.Fatal(err)
	}
	report := string(raw)
	got, err := generate([]byte(report), []byte(recipe))
	if err != nil || len(got.Packages) != 2 || got.Packages[0].Name != "base-files" {
		t.Fatalf("%+v %v", got, err)
	}
	for _, bad := range []string{report + "{}", report[:len(report)-1], strings.Replace(report, "observed-cold-build-inventory-only", "unknown", 1), strings.Replace(report, "1001:1001", "0", 1), strings.Replace(report, "amd64", "arm64", 1), strings.Replace(report, "libgl1", "missing", 1)} {
		if _, err := generate([]byte(bad), []byte(recipe)); err == nil {
			t.Fatal("bad report accepted")
		}
	}
}
