package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOptInPrecedesAnyReadOrWrite(t *testing.T) {
	out := filepath.Join(t.TempDir(), "untouched.json")
	if err := run([]string{"-operation", "canonicalize", "-input", "missing", "-output", out}); err == nil || !strings.Contains(err.Error(), "experimental") {
		t.Fatalf("default path did not refuse before reading: %v", err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatal("default-off command touched output")
	}
}
func TestCanonicalCommandPublishesAtomicallyWithoutReplacing(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := root.Close(); err != nil {
			t.Error(err)
		}
	})
	input := filepath.Join(dir, "input.json")
	out := filepath.Join(dir, "out.json")
	if err := os.WriteFile(input, []byte("{\"z\":1,\"a\":2}"), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"-experimental", "-operation", "canonicalize", "-input", input, "-output", out}
	if err := run(args); err != nil {
		t.Fatal(err)
	}
	got, err := root.ReadFile("out.json")
	if err != nil || string(got) != "{\"a\":2,\"z\":1}" {
		t.Fatalf("published bytes %q %v", got, err)
	}
	if err := run(args); err == nil {
		t.Fatal("existing output replaced")
	}
	again, err := root.ReadFile("out.json")
	if err != nil || string(again) != string(got) {
		t.Fatal("caller output was changed")
	}
}
