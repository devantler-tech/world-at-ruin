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
