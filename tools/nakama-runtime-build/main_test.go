package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TestBuildRequiresOptIn catches a builder that reads source or creates an output
// before explicit permission for the experimental artifact is present.
func TestBuildRequiresOptIn(t *testing.T) {
	base := t.TempDir()
	out := filepath.Join(base, "bundle")
	var log bytes.Buffer
	err := execute(context.Background(), []string{"-source", filepath.Join(base, "absent"), "-output", out}, &log)
	if err == nil || err.Error() != "native Nakama build requires -experimental" {
		t.Fatalf("missing opt-in: %v", err)
	}
	if _, err := os.Lstat(out); !os.IsNotExist(err) {
		t.Fatalf("disabled build touched output: %v", err)
	}
}

// TestBuildRefusesExistingOutput catches replacement of another build or user file.
func TestBuildRefusesExistingOutput(t *testing.T) {
	base := t.TempDir()
	if err := os.WriteFile(filepath.Join(base, "retained"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	err := execute(context.Background(), []string{"-experimental", "-source", base, "-output", base}, &bytes.Buffer{})
	if err == nil || err.Error() != "native Nakama build output must be absent" {
		t.Fatalf("existing output: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(base, "retained"))
	if err != nil || string(got) != "keep" {
		t.Fatalf("retained bytes changed: %q %v", got, err)
	}
}

// TestBuildRefusesMissingLockedGraph catches a build that silently falls back to
// the ordinary server graph, which cannot load the plugin in Nakama 3.40.
func TestBuildRefusesMissingLockedGraph(t *testing.T) {
	base := t.TempDir()
	err := execute(context.Background(), []string{"-experimental", "-source", base, "-output", filepath.Join(base, "bundle")}, &bytes.Buffer{})
	if err == nil || err.Error() != "native Nakama build locked graph unavailable" {
		t.Fatalf("missing graph: %v", err)
	}
}

// The issued lane must select its own locks rather than silently falling back
// to the older native graph, even when that graph is available.
func TestIssuedProfileRequiresItsOwnGraph(t *testing.T) {
	base := t.TempDir()
	if err := os.Mkdir(filepath.Join(base, "nakama-runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{"go.mod", "go.sum"} {
		if err := os.WriteFile(filepath.Join(base, "nakama-runtime", file), []byte("old native graph"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	err := execute(context.Background(), []string{"-experimental", "-profile", "issued", "-source", base, "-output", filepath.Join(base, "bundle")}, &bytes.Buffer{})
	if err == nil || err.Error() != "native Nakama build locked graph unavailable" {
		t.Fatalf("issued graph fallback: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(base, "bundle")); !os.IsNotExist(err) {
		t.Fatal("missing graph created output")
	}
}

func TestUnknownProfileRefusesBeforeSourceAccess(t *testing.T) {
	base := t.TempDir()
	err := execute(context.Background(), []string{"-experimental", "-profile", "arbitrary", "-source", filepath.Join(base, "absent"), "-output", filepath.Join(base, "bundle")}, &bytes.Buffer{})
	if err == nil || err.Error() != "native Nakama build profile refused" {
		t.Fatalf("unknown profile: %v", err)
	}
}
