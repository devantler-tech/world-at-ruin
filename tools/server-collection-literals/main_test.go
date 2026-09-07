package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestCollectionLiterals binds registration to complete decoded string tokens,
// including escape forms that evade source-text matching and their data twins.
func TestCollectionLiterals(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		source  string
		want    []string
		wantErr bool
	}{
		{name: "plain", source: "const C = \"world_at_ruin_items\"", want: []string{"world_at_ruin_items"}},
		{name: "raw", source: "const C = \x60world_at_ruin_items\x60", want: []string{"world_at_ruin_items"}},
		{name: "hex prefix", source: "const C = \"\\x77orld_at_ruin_items\"", want: []string{"world_at_ruin_items"}},
		{name: "octal prefix", source: "const C = \"\\167orld_at_ruin_items\"", want: []string{"world_at_ruin_items"}},
		{name: "unicode prefix", source: "const C = \"\\u0077orld_at_ruin_items\"", want: []string{"world_at_ruin_items"}},
		{name: "long unicode prefix", source: "const C = \"\\U00000077orld_at_ruin_items\"", want: []string{"world_at_ruin_items"}},
		{name: "hex separator", source: "const C = \"world_at_ruin_shadow\\x5fstore\"", want: []string{"world_at_ruin_shadow_store"}},
		{name: "unicode suffix", source: "const C = \"world_at_ruin_item\\u0073\"", want: []string{"world_at_ruin_items"}},
		{name: "multiple and repeated", source: "const A = \"world_at_ruin_a\"; const B = \x60world_at_ruin_b\x60; const C = \"world_at_ruin_a\"", want: []string{"world_at_ruin_a", "world_at_ruin_b", "world_at_ruin_a"}},
		{name: "line comment", source: "// \"world_at_ruin_items\"\nconst C = 1"},
		{name: "block comment", source: "/* \x60world_at_ruin_items\x60 */ const C = 1"},
		{name: "quoted data", source: "const C = \"\\\"world_at_ruin_items\\\"\""},
		{name: "raw quoted data", source: "const C = \x60documentation: \"world_at_ruin_items\"\x60"},
		{name: "raw escape data", source: "const C = \x60world_at_ruin_\\x69tems\x60"},
		{name: "escaped backslash data", source: "const C = \"world_at_ruin_\\\\x69tems\""},
		{name: "literal newline data", source: "const C = \"world_at_ruin_items\\n\""},
		{name: "empty suffix", source: "const C = \"world_at_ruin_\""},
		{name: "uppercase suffix", source: "const C = \"world_at_ruin_Items\""},
		{name: "concatenation remains outside lexical contract", source: "const C = \"world_at_\" + \"ruin_items\""},
		{name: "invalid escape", source: "const C = \"\\q\"", wantErr: true},
		{name: "unterminated literal", source: "const C = \"world_at_ruin_items", wantErr: true},
		{name: "unterminated comment", source: "/* \"world_at_ruin_items\"", wantErr: true},
		{name: "malformed after collection", source: "const C = \"world_at_ruin_items\"; const D = \"\\q\"", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := collectionLiterals("store.go", []byte("package p\n"+test.source+"\n"))
			if (err != nil) != test.wantErr {
				t.Fatalf("collectionLiterals() error = %v, want error %t", err, test.wantErr)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("collectionLiterals() = %#v, want %#v", got, test.want)
			}
		})
	}
}

// TestRun emits decoded names for the selected source and refuses unreadable or
// malformed input without publishing a partial collection inventory.
func TestRun(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	source := filepath.Join(dir, "store.go")
	if err := os.WriteFile(source, []byte("package p\nconst C = \"world_at_ruin_shadow\\x5fstore\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := run([]string{source}, &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "world_at_ruin_shadow_store\n"; got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
	output.Reset()
	if err := run([]string{filepath.Join(dir, "missing.go")}, &output); err == nil {
		t.Fatal("missing source was accepted")
	}
	if err := run(nil, &output); err == nil {
		t.Fatal("missing source argument was accepted")
	}
	if err := os.WriteFile(source, []byte("package p\nconst C = \"world_at_ruin_items\"; const D = \"\\q\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{source}, &output); err == nil {
		t.Fatal("malformed source was accepted")
	}
	if output.Len() != 0 {
		t.Fatalf("failed input published partial inventory: %q", output.String())
	}
}

// TestRunPropagatesOutputFailure prevents a truncated inventory from succeeding.
func TestRunPropagatesOutputFailure(t *testing.T) {
	t.Parallel()
	source := filepath.Join(t.TempDir(), "store.go")
	if err := os.WriteFile(source, []byte("package p\nconst C = \"world_at_ruin_items\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{source}, failingWriter{}); !errors.Is(err, errOutput) {
		t.Fatalf("output error = %v, want %v", err, errOutput)
	}
}

var errOutput = errors.New("output refused")

type failingWriter struct{}

// Write supplies the output-failure boundary without replacing the source scan.
func (failingWriter) Write([]byte) (int, error) { return 0, errOutput }
