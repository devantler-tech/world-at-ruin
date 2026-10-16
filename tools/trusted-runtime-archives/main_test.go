package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureManifest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func fixturePackages() []any {
	return []any{
		map[string]any{"name": "apt", "version": "2.8.3", "architecture": "amd64"},
		map[string]any{"name": "base-files", "version": "1", "architecture": "amd64"},
		map[string]any{"name": "foo", "version": "1.0", "architecture": "amd64"},
	}
}

func fixtureOrigin() originExpectation {
	return originExpectation{
		PackageFilename: "pool/main/f/foo/foo_1.0_amd64.deb",
		RepositoryURI:   "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/",
		BaseURI:         "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/dists/noble/",
		Release:         "noble", Component: "main", Architecture: "amd64", Trusted: true,
		Origin: "Ubuntu", Label: "Ubuntu", Codename: "noble", Suite: "noble",
		IndexURI:  "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/dists/noble/main/binary-amd64/Packages",
		Index:     evidenceFile{Path: "/var/lib/apt/lists/snapshot_Packages", SHA256: strings.Repeat("b", 64), Bytes: 200},
		InRelease: evidenceFile{Path: "/var/lib/apt/lists/snapshot_InRelease", SHA256: strings.Repeat("c", 64), Bytes: 100},
	}
}

func fixtureArchive() archiveExpectation {
	origin := fixtureOrigin()
	return archiveExpectation{
		Name: "foo", Version: "1.0", Architecture: "amd64", Basename: "foo_1.0_amd64.deb",
		RequestedURI: origin.RepositoryURI + origin.PackageFilename,
		Bytes:        4, SHA256: strings.Repeat("d", 64), Origins: []originExpectation{origin},
	}
}

func fixtureRecipe(t *testing.T) (string, map[string]any) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, ".github", "containers")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	packageLock := map[string]any{
		"schema": 1, "architecture": "amd64", "runtime_manifest": fixtureManifest,
		"snapshot": "20261003T000000Z", "packages": fixturePackages(),
	}
	packageRaw, _ := json.Marshal(packageLock)
	baseRaw := []byte(`{"schema":1,"proofs":[]}`)
	recipe := "FROM golang:1.27.1@sha256:" + strings.Repeat("e", 64) + " AS certificates\n" +
		"FROM ubuntu:24.04@" + fixtureManifest + "\n" +
		"RUN printf 'APT::Snapshot \"20261003T000000Z\";' > /etc/apt/apt.conf.d/50snapshot \\\n" +
		" && bash /tmp/observe-runtime-transaction.sh \"$WAR_RUNTIME_INVENTORY\" \"$WAR_RUNTIME_ARCHIVE_POLICY\" apt-get install -y --no-install-recommends foo=1.0 \\\n" +
		" && true\n"
	for name, raw := range map[string][]byte{
		"trusted-runtime-packages.lock.json": packageRaw,
		"trusted-runtime-bases.lock.json":    baseRaw,
		"trusted-regressions.Dockerfile":     []byte(recipe),
	} {
		if err := os.WriteFile(filepath.Join(dir, name), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range requiredRecipeFiles {
		absolute := filepath.Join(root, path)
		if _, err := os.Stat(absolute); err == nil {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(absolute), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(absolute, []byte("fixture "+path+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	report := fixtureReport(t, root)
	return root, report
}

func fixtureReport(t *testing.T, root string) map[string]any {
	t.Helper()
	archive := fixtureArchive()
	origin := archive.Origins[0]
	file := func(path string) map[string]any {
		return map[string]any{"path": path, "sha256": strings.Repeat("f", 64), "bytes": 1}
	}
	recipes := make([]any, 0, len(requiredRecipeFiles))
	for _, path := range requiredRecipeFiles {
		raw, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		item := map[string]any{"path": path, "sha256": sha256Hex(raw), "bytes": len(raw)}
		recipes = append(recipes, item)
	}
	return map[string]any{
		"schema": 1, "evidence": "observed-cold-build-inventory-only",
		"image": map[string]any{
			"Id": "sha256:" + strings.Repeat("1", 64), "Os": "linux", "Architecture": "amd64",
			"Config": map[string]any{"User": "1001:1001", "WorkingDir": "/project", "Entrypoint": []string{"/usr/local/bin/godot"}},
		},
		"inventory": map[string]any{
			"architecture": "amd64", "engine_sha256": strings.Repeat("2", 64),
			"installed_packages": fixturePackages(),
			"apt_inputs": []any{
				file("/etc/apt/sources.list.d/ubuntu.sources"), file("/etc/apt/apt.conf.d/50snapshot"),
				file("/usr/share/keyrings/ubuntu-archive-keyring.gpg"), file("/etc/ssl/certs/ca-certificates.crt"),
				map[string]any{"path": origin.Index.Path, "sha256": origin.Index.SHA256, "bytes": origin.Index.Bytes},
				map[string]any{"path": origin.InRelease.Path, "sha256": origin.InRelease.SHA256, "bytes": origin.InRelease.Bytes},
			},
			"transaction": map[string]any{
				"apt_version": "2.8.3", "direct_arguments": []string{"foo=1.0"},
				"preinstall_packages": []any{
					map[string]any{"name": "apt", "version": "2.8.3", "architecture": "amd64"},
					map[string]any{"name": "base-files", "version": "1", "architecture": "amd64"},
				},
				"apt_targets": []any{map[string]any{
					"index_uri": origin.IndexURI, "repository_uri": origin.RepositoryURI, "base_uri": origin.BaseURI,
					"release": origin.Release, "component": origin.Component, "architecture": origin.Architecture,
					"trusted": true, "origin": origin.Origin, "label": origin.Label, "codename": origin.Codename, "suite": origin.Suite,
					"index": origin.Index, "inrelease": origin.InRelease,
				}},
				"downloaded_archives": []archiveExpectation{archive},
			},
		},
		"recipe_files":          recipes,
		"caller_engine_version": "4.7.1", "caller_engine_archive_sha512": strings.Repeat("3", 128),
	}
}

func fixtureTransaction() string {
	a := fixtureArchive()
	o := a.Origins[0]
	return "apt-version\t2.8.3\n" +
		"base-package\tapt\t2.8.3\tamd64\tinstalled\n" +
		"base-package\tbase-files\t1\tamd64\tinstalled\n" +
		"argument\tfoo=1.0\n" +
		"plan\t" + a.RequestedURI + "\t" + a.Basename + "\t4\t" + a.SHA256 + "\n" +
		"archive\t" + a.Basename + "\tfoo\t1.0\tamd64\t4\t" + a.SHA256 + "\n" +
		"target\t" + o.IndexURI + "\t" + o.Index.Path + "\t200\t" + o.Index.SHA256 + "\t" + o.RepositoryURI + "\t" + o.BaseURI + "\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\t" + o.InRelease.Path + "\t100\t" + o.InRelease.SHA256 + "\n" +
		"origin\t" + a.Basename + "\tfoo\t1.0\tamd64\t" + o.PackageFilename + "\t" + o.RepositoryURI + "\t" + o.BaseURI + "\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\t" + o.IndexURI + "\t" + o.Index.Path + "\t200\t" + o.Index.SHA256 + "\t" + o.InRelease.Path + "\t100\t" + o.InRelease.SHA256 + "\n"
}

func fixtureGeneratedLock(t *testing.T) (string, []byte) {
	t.Helper()
	root, report := fixtureRecipe(t)
	raw, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	lock, err := generate(raw, root)
	if err != nil {
		t.Fatal(err)
	}
	lockRaw, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	return root, lockRaw
}

func TestGenerateCanonicalArchiveExpectation(t *testing.T) {
	root, report := fixtureRecipe(t)
	raw, _ := json.Marshal(report)
	first, err := generate(raw, root)
	if err != nil {
		t.Fatal(err)
	}
	second, err := generate(raw, root)
	if err != nil || len(first.Archives) != 1 || first.Archives[0].Basename != "foo_1.0_amd64.deb" || first.ReportSHA256 != second.ReportSHA256 {
		t.Fatalf("non-canonical result: %+v %v", first, err)
	}
	a, _ := json.Marshal(first)
	b, _ := json.Marshal(second)
	if !bytes.Equal(a, b) {
		t.Fatal("same report generated different archive expectations")
	}
}

func TestParseRecipeRequiresExecutableObserverBeforeInstall(t *testing.T) {
	prefix := "FROM ubuntu:24.04@" + fixtureManifest + "\n" +
		"RUN printf 'APT::Snapshot \"20261003T000000Z\";' > /etc/apt/apt.conf.d/50snapshot\n"
	observer := `bash /tmp/observe-runtime-transaction.sh "$WAR_RUNTIME_INVENTORY" "$WAR_RUNTIME_ARCHIVE_POLICY"`
	for name, recipe := range map[string]string{
		"comment only":  prefix + "# " + observer + "\nRUN apt-get install -y --no-install-recommends foo=1.0 && true\n",
		"after install": prefix + "RUN apt-get install -y --no-install-recommends foo=1.0 && " + observer + " true\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, _, err := parseRecipe([]byte(recipe)); err == nil {
				t.Fatal("non-executable or misordered observer satisfied the recipe binding")
			}
		})
	}
}

func TestGenerateRefusesIncompleteConflictingAndUnboundEvidence(t *testing.T) {
	for name, mutate := range map[string]func(map[string]any){
		"schema": func(r map[string]any) { r["schema"] = 2 },
		"untrusted origin": func(r map[string]any) {
			r["inventory"].(map[string]any)["transaction"].(map[string]any)["downloaded_archives"].([]archiveExpectation)[0].Origins[0].Trusted = false
		},
		"untrusted target": func(r map[string]any) {
			r["inventory"].(map[string]any)["transaction"].(map[string]any)["apt_targets"].([]any)[0].(map[string]any)["trusted"] = false
		},
		"missing origin": func(r map[string]any) {
			r["inventory"].(map[string]any)["transaction"].(map[string]any)["downloaded_archives"].([]archiveExpectation)[0].Origins = nil
		},
		"wrong final tuple": func(r map[string]any) {
			r["inventory"].(map[string]any)["installed_packages"].([]any)[2].(map[string]any)["version"] = "2.0"
		},
		"wrong argument": func(r map[string]any) {
			r["inventory"].(map[string]any)["transaction"].(map[string]any)["direct_arguments"] = []string{"foo=2.0"}
		},
		"extra recipe file": func(r map[string]any) {
			r["recipe_files"] = append(r["recipe_files"].([]any), map[string]any{"path": "tools/unreviewed.sh", "sha256": strings.Repeat("f", 64), "bytes": 1})
		},
		"unknown field": func(r map[string]any) { r["unexpected"] = true },
		"duplicate archive": func(r map[string]any) {
			tx := r["inventory"].(map[string]any)["transaction"].(map[string]any)
			a := tx["downloaded_archives"].([]archiveExpectation)[0]
			tx["downloaded_archives"] = []archiveExpectation{a, a}
		},
		"duplicate target": func(r map[string]any) {
			tx := r["inventory"].(map[string]any)["transaction"].(map[string]any)
			target := tx["apt_targets"].([]any)[0]
			tx["apt_targets"] = []any{target, target}
		},
	} {
		t.Run(name, func(t *testing.T) {
			root, report := fixtureRecipe(t)
			mutate(report)
			raw, _ := json.Marshal(report)
			if _, err := generate(raw, root); err == nil {
				t.Fatal("invalid report generated an archive expectation")
			}
		})
	}
	root, report := fixtureRecipe(t)
	raw, _ := json.Marshal(report)
	path := filepath.Join(root, ".github", "containers", "trusted-runtime-packages.lock.json")
	if err := os.WriteFile(path, []byte(`{"changed":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := generate(raw, root); err == nil {
		t.Fatal("report detached from the current installed-package lock")
	}

	for name, replace := range map[string]func(string) error{
		"changed helper": func(path string) error { return os.WriteFile(path, []byte("changed\n"), 0600) },
		"linked helper": func(path string) error {
			if err := os.Rename(path, path+".real"); err != nil {
				return err
			}
			return os.Symlink(path+".real", path)
		},
	} {
		t.Run(name, func(t *testing.T) {
			root, report := fixtureRecipe(t)
			raw, _ := json.Marshal(report)
			path := filepath.Join(root, "tools", "propose-trusted-runtime-archives.sh")
			if err := replace(path); err != nil {
				t.Fatal(err)
			}
			if _, err := generate(raw, root); err == nil {
				t.Fatal("report detached from a current recipe helper")
			}
		})
	}
}

func TestVerifyRefusesArchiveAndOriginMutations(t *testing.T) {
	_, lockRaw := fixtureGeneratedLock(t)
	good := fixtureTransaction()
	if err := verify(lockRaw, []byte(good)); err != nil {
		t.Fatal(err)
	}
	mutations := map[string]string{
		"missing":      strings.Replace(good, "archive\tfoo_1.0_amd64.deb\tfoo\t1.0\tamd64\t4\t"+strings.Repeat("d", 64)+"\n", "", 1),
		"extra":        good + "archive\tbar.deb\tbar\t1\tamd64\t4\t" + strings.Repeat("d", 64) + "\n",
		"wrong tuple":  strings.Replace(good, "\tfoo\t1.0\tamd64\t", "\tfoo\t2.0\tamd64\t", 1),
		"origin tuple": strings.Replace(good, "origin\tfoo_1.0_amd64.deb\tfoo\t1.0\tamd64", "origin\tfoo_1.0_amd64.deb\tfoo\t2.0\tamd64", 1),
		"wrong size":   strings.Replace(good, "\t4\t"+strings.Repeat("d", 64), "\t5\t"+strings.Repeat("d", 64), 1),
		"corrupt":      strings.Replace(good, strings.Repeat("d", 64), strings.Repeat("9", 64), 1),
		"duplicate":    good + strings.Split(good, "\n")[5] + "\n",
		"untrusted":    strings.ReplaceAll(good, "\tamd64\tyes\tUbuntu", "\tamd64\tno\tUbuntu"),
		"partial":      good[:len(good)-1],
	}
	for name, changed := range mutations {
		t.Run(name, func(t *testing.T) {
			if err := verify(lockRaw, []byte(changed)); err == nil {
				t.Fatal("mutated transaction satisfied the archive lock")
			}
		})
	}
}

func TestEmitAndVerificationInputsMustBeRegularCompleteFiles(t *testing.T) {
	root, lockRaw := fixtureGeneratedLock(t)
	lockPath := filepath.Join(root, ".github", "containers", "trusted-runtime-archives.lock.json")
	if err := os.WriteFile(lockPath, lockRaw, 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := emit(root, &out); err != nil || out.Len() == 0 {
		t.Fatalf("valid lock did not emit: %v", err)
	}
	if err := os.Rename(lockPath, lockPath+".real"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(lockPath+".real", lockPath); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := emit(root, &out); err == nil || out.Len() != 0 {
		t.Fatal("linked archive lock emitted authority")
	}
}
