package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureHash = "770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c"

func fixture(t *testing.T) (planRequest, targetRecord) {
	t.Helper()
	dir := t.TempDir()
	index := filepath.Join(dir, "snapshot_main_binary-amd64_Packages")
	release := filepath.Join(dir, "snapshot_InRelease")
	packageFile := "pool/main/f/foo/foo_1.0+build1_amd64.deb"
	contents := fmt.Sprintf("Package: foo\nVersion: 1.0\nArchitecture: amd64\nFilename: %s\nSize: 4\nSHA256: %s\n\n", packageFile, fixtureHash)
	if err := os.WriteFile(index, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(release, []byte("signed release\n"), 0600); err != nil {
		t.Fatal(err)
	}
	target := targetRecord{
		IndexPath: index, IndexURI: "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/dists/noble/main/binary-amd64/Packages",
		RepoURI: "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/", BaseURI: "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/dists/noble/", Release: "noble", Component: "main",
		Architecture: "amd64", Trusted: "yes", Codename: "noble", Suite: "noble", Origin: "Ubuntu", Label: "Ubuntu",
		InReleasePath: release,
	}
	request := planRequest{
		URI: target.RepoURI + "pool/main/f/foo/foo_1.0%2bbuild1_amd64.deb", Basename: "foo_1.0+build1_amd64.deb", Package: "foo", Version: "1.0",
		Architecture: "amd64", Bytes: 4, SHA256: fixtureHash,
	}
	return request, target
}

func TestResolveOriginsJoinsTheCompleteAuthenticatedTarget(t *testing.T) {
	request, target := fixture(t)
	file, err := os.OpenFile(target.IndexPath, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.WriteString("Optional-Empty-Field:\n\n"); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := resolveOrigins([]planRequest{request}, []targetRecord{target})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Basename != request.Basename || got[0].PackageFilename != "pool/main/f/foo/foo_1.0+build1_amd64.deb" || got[0].IndexSHA256 == "" || got[0].InReleaseSHA256 == "" {
		t.Fatalf("incomplete origin join: %+v", got)
	}
	if got[0].RepositoryURI != target.RepoURI || got[0].Release != "noble" || got[0].Component != "main" || got[0].Origin != "Ubuntu" {
		t.Fatalf("release identity lost: %+v", got[0])
	}
}

func TestResolveOriginsRefusesIncompleteAmbiguousAndConflictingEvidence(t *testing.T) {
	request, target := fixture(t)
	mutations := map[string]func() ([]planRequest, []targetRecord){
		"untrusted target": func() ([]planRequest, []targetRecord) {
			changed := target
			changed.Trusted = "no"
			return []planRequest{request}, []targetRecord{changed}
		},
		"missing InRelease": func() ([]planRequest, []targetRecord) {
			changed := target
			changed.InReleasePath += ".missing"
			return []planRequest{request}, []targetRecord{changed}
		},
		"linked index": func() ([]planRequest, []targetRecord) {
			changed := target
			link := changed.IndexPath + ".link"
			if err := os.Symlink(changed.IndexPath, link); err != nil {
				t.Fatal(err)
			}
			changed.IndexPath = link
			return []planRequest{request}, []targetRecord{changed}
		},
		"partial stanza": func() ([]planRequest, []targetRecord) {
			changed := target
			if err := os.WriteFile(changed.IndexPath, []byte("Package: foo\nVersion: 1.0\nArchitecture: amd64\nFilename: pool/main/f/foo/foo_1.0_amd64.deb\nSize: 4\n\n"), 0600); err != nil {
				t.Fatal(err)
			}
			return []planRequest{request}, []targetRecord{changed}
		},
		"duplicate field": func() ([]planRequest, []targetRecord) {
			changed := target
			raw, err := os.ReadFile(changed.IndexPath)
			if err != nil {
				t.Fatal(err)
			}
			raw = []byte(strings.Replace(string(raw), "SHA256: ", "SHA256: "+fixtureHash+"\nSHA256: ", 1))
			if err = os.WriteFile(changed.IndexPath, raw, 0600); err != nil {
				t.Fatal(err)
			}
			return []planRequest{request}, []targetRecord{changed}
		},
		"ambiguous source": func() ([]planRequest, []targetRecord) {
			return []planRequest{request}, []targetRecord{target, target}
		},
		"conflicting source": func() ([]planRequest, []targetRecord) {
			changed := target
			dir := t.TempDir()
			changed.IndexPath = filepath.Join(dir, "conflicting_Packages")
			changed.InReleasePath = filepath.Join(dir, "conflicting_InRelease")
			conflict := strings.ReplaceAll(packageStanza(request, "pool/main/f/foo/foo_1.0+build1_amd64.deb"), fixtureHash, strings.Repeat("a", 64))
			if err := os.WriteFile(changed.IndexPath, []byte(conflict), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(changed.InReleasePath, []byte("other signed release\n"), 0600); err != nil {
				t.Fatal(err)
			}
			return []planRequest{request}, []targetRecord{target, changed}
		},
		"URI mismatch": func() ([]planRequest, []targetRecord) {
			changed := request
			changed.URI = "https://snapshot.ubuntu.com/ubuntu/other/foo.deb"
			return []planRequest{changed}, []targetRecord{target}
		},
		"tuple mismatch": func() ([]planRequest, []targetRecord) {
			changed := request
			changed.Version = "2.0"
			return []planRequest{changed}, []targetRecord{target}
		},
		"same-size digest substitution": func() ([]planRequest, []targetRecord) {
			changed := request
			changed.SHA256 = strings.Repeat("b", 64)
			return []planRequest{changed}, []targetRecord{target}
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			request, target = fixture(t)
			requests, targets := mutate()
			if _, err := resolveOrigins(requests, targets); err == nil {
				t.Fatal("accepted incomplete or ambiguous origin evidence")
			}
		})
	}
}

func packageStanza(request planRequest, filename string) string {
	return fmt.Sprintf("Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: %d\nSHA256: %s\n\n", request.Package, request.Version, request.Architecture, filename, request.Bytes, request.SHA256)
}

func TestManifestReadersRequireCompleteBoundedRows(t *testing.T) {
	request, target := fixture(t)
	plan := fmt.Sprintf("%s\t%s\t%s\t%s\t%d\t%s\ttransaction\n", request.URI, request.Basename, request.Package, request.Version, request.Bytes, request.SHA256)
	if _, err := parsePlanManifest(strings.NewReader(plan)); err == nil {
		t.Fatal("accepted plan without architecture")
	}
	targets := fmt.Sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", target.IndexPath, target.IndexURI, target.RepoURI, target.Release, target.Component, target.Architecture, target.Trusted, target.Codename, target.Suite, target.Origin, target.Label, target.InReleasePath, "extra", "fields")
	if _, err := parseTargetManifest(strings.NewReader(targets)); err == nil {
		t.Fatal("accepted target with extra fields")
	}
}

func TestTargetManifestRefusesARepeatedIndexUnderChangedMetadata(t *testing.T) {
	_, target := fixture(t)
	row := func(origin string) string {
		return fmt.Sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", target.IndexPath, target.IndexURI, target.RepoURI, target.BaseURI, target.Release, target.Component, target.Architecture, target.Trusted, target.Codename, target.Suite, origin, target.Label)
	}
	if _, err := parseTargetManifest(strings.NewReader(row("Ubuntu") + row("Changed"))); err == nil {
		t.Fatal("accepted one package index as two targets")
	}
}
