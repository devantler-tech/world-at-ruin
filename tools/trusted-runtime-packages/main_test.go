package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func verifierRecipe() string {
	return "\nCOPY expected-packages.tsv verify-trusted-runtime-packages.sh /tmp/\nRUN bash /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv \\\n    && rm /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv\n"
}

func fixtureLock() packageLock {
	return packageLock{1, "amd64", "sha256:" + strings.Repeat("a", 64), "20261003T000000Z", []packageIdentity{{"base-files", "13ubuntu10.3", "amd64"}, {"libgl1", "1.7.0-1build1", "amd64"}}}
}

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

func TestGeneratedExpectationRequiresCompleteReport(t *testing.T) {
	value := fixtureLock()
	recipe := "FROM ubuntu:24.04@" + value.RuntimeManifest + "\n'APT::Snapshot \"" + value.Snapshot + "\";'\napt-get install -y --no-install-recommends libgl1=1.7.0-1build1 && true\n"
	recipe += verifierRecipe()
	report := `{"schema":1,"evidence":"observed-cold-build-inventory-only","image":{"Os":"linux","Architecture":"amd64","Config":{"User":"1001:1001","WorkingDir":"/project","Entrypoint":["/usr/local/bin/godot"]}},"inventory":{"architecture":"amd64","installed_packages":[{"name":"libgl1","version":"1.7.0-1build1","architecture":"amd64"},{"name":"base-files","version":"13ubuntu10.3","architecture":"amd64"}]}}`
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
