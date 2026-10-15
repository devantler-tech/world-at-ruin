package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// inventoryFixture supplies packages and metadata with an explicit terminal record.
func inventoryFixture() string {
	var b strings.Builder
	b.WriteString("WAR_RUNTIME_INVENTORY\t1\namd64\n")
	for name, version := range directPins {
		fmt.Fprintf(&b, "package\t%s\t%s\tamd64\tinstalled\n", name, version)
	}
	b.WriteString("package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\n")
	for _, path := range []string{"/var/lib/apt/lists/snapshot_InRelease", "/var/lib/apt/lists/snapshot_main_binary-amd64_Packages.lz4", "/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt"} {
		fmt.Fprintf(&b, "file\t%s\t123\t%s\n", strings.Repeat("a", 64), path)
	}
	fmt.Fprintf(&b, "engine\t%s\nEND\n", strings.Repeat("b", 64))
	return b.String()
}

// TestObservedInventory checks full inventory capture and deterministic report ordering.
func TestObservedInventory(t *testing.T) {
	got, err := parseInventory([]byte(inventoryFixture()), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Packages) != 11 || len(got.Files) != 6 || got.Architecture != "amd64" {
		t.Fatalf("incomplete inventory: %+v", got)
	}
	other, err := parseInventory([]byte(inventoryFixture()), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	var a, b bytes.Buffer
	if err = writeReport(got, &a); err != nil {
		t.Fatal(err)
	}
	if err = writeReport(other, &b); err != nil {
		t.Fatal(err)
	}
	if a.String() != b.String() {
		t.Fatal("map iteration changed canonical report")
	}
}

// TestIncompleteAndAmbiguousInventory refuses missing, duplicate and conflicting records.
func TestIncompleteAndAmbiguousInventory(t *testing.T) {
	original := inventoryFixture()
	cases := map[string]string{
		"partial":            strings.TrimSuffix(original, "END\n"),
		"trailing":           original + "package\tlate\t1\tamd64\tinstalled\n",
		"duplicate":          strings.Replace(original, "END\n", "package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\nEND\n", 1),
		"wrong pin":          strings.Replace(original, "2.15.0-1.1ubuntu2", "99", 1),
		"wrong architecture": strings.Replace(original, "\namd64\n", "\narm64\n", 1),
		"unconfigured":       strings.Replace(original, "\tinstalled\n", "\tunpacked\n", 1),
		"missing indexes":    strings.ReplaceAll(original, "/var/lib/apt/lists/", "/etc/apt/"),
		"missing signature":  strings.ReplaceAll(original, "_InRelease", "_Other"),
		"escape":             strings.Replace(original, "/etc/apt/apt.conf.d/50snapshot", "/etc/apt/../private", 1),
		"duplicate file":     strings.Replace(original, "END\n", "file\t"+strings.Repeat("a", 64)+"\t123\t/etc/apt/apt.conf.d/50snapshot\nEND\n", 1),
		"unknown":            strings.Replace(original, "package\tbase-files", "mystery\tbase-files", 1),
		"oversize":           original + strings.Repeat("x", maximumInventoryBytes),
		"empty":              "",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseInventory([]byte(raw), strings.Repeat("b", 64)); err == nil {
				t.Fatal("accepted incomplete inventory")
			}
		})
	}
	if _, err := parseInventory([]byte(original), strings.Repeat("c", 64)); err == nil {
		t.Fatal("accepted wrong engine")
	}
}

// TestImageContract rejects a partial inspection or a different execution boundary.
func TestImageContract(t *testing.T) {
	good := `[{"Id":"sha256:` + strings.Repeat("a", 64) + `","Os":"linux","Architecture":"amd64","Config":{"User":"1001:1001","WorkingDir":"/project","Entrypoint":["/usr/local/bin/godot"]}}]`
	if _, err := parseImage([]byte(good)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{good + "[]", good[:len(good)-2], strings.Replace(good, "amd64", "arm64", 1), strings.Replace(good, "1001:1001", "0", 1), strings.Replace(good, "/project", "/", 1), strings.Replace(good, "/usr/local/bin/godot", "/bin/sh", 1)} {
		if _, err := parseImage([]byte(bad)); err == nil {
			t.Fatal("accepted wrong image contract")
		}
	}
}

type shortReportWriter struct{}

// Write simulates an output sink that accepts only part of a report.
func (shortReportWriter) Write(raw []byte) (int, error) { return len(raw) - 1, nil }

// TestReportWriteFailure ensures a short output write cannot succeed.
func TestReportWriteFailure(t *testing.T) {
	if writeReport(inventory{}, shortReportWriter{}) == nil {
		t.Fatal("partial write became complete report")
	}
}

// TestDiagnosticSelection keeps the default inert and rejects unknown selections.
func TestDiagnosticSelection(t *testing.T) {
	var output bytes.Buffer
	if err := run(nil, &output); err != nil || output.Len() != 0 {
		t.Fatal("default mode observed or emitted data")
	}
	if err := run([]string{"--unknown"}, &output); err == nil || output.Len() != 0 {
		t.Fatal("unknown selection admitted")
	}
}

// TestRecipeReadsAreBoundedAndObserveChangedBytes exercises real file replacement and refusal paths.
func TestRecipeReadsAreBoundedAndObserveChangedBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "builder.sh")
	if err := os.WriteFile(path, []byte("first recipe"), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := fileIdentity(path, "tools/builder.sh", 32)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, []byte("changed recipe"), 0600); err != nil {
		t.Fatal(err)
	}
	after, err := fileIdentity(path, "tools/builder.sh", 32)
	if err != nil || before.SHA256 == after.SHA256 {
		t.Fatal("recipe replacement retained prior identity")
	}
	if _, err = boundedFile(path, 2); err == nil {
		t.Fatal("oversized recipe accepted")
	}
	link := path + ".link"
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err = boundedFile(link, 32); err == nil {
		t.Fatal("linked recipe accepted")
	}
	if _, err = boundedFile(filepath.Dir(path), 32); err == nil {
		t.Fatal("directory accepted")
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err = boundedFile(path, 32); err == nil {
		t.Fatal("missing recipe accepted")
	}
}
