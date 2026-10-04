package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultOffNeverReadsOrWrites(t *testing.T) {
	out := filepath.Join(t.TempDir(), "untouched")
	if err := run([]string{"-source", "missing", "-output", out}); err == nil || !strings.Contains(err.Error(), "experimental") {
		t.Fatalf("default path %v", err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatal("default-off created output")
	}
}
