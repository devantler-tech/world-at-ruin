package main

import "testing"

func TestProbeDNSOverridePolicy(t *testing.T) {
	t.Parallel()
	for name, want := range map[string]bool{"single": false, "123": false, "Zone.Example": true, "12.3": true, "127.0.0.1": false, "::1": false, "Zone.Example.": false, "a..example": false} {
		if got := validDNSName(name); got != want {
			t.Errorf("probe override %q: got %v want %v", name, got, want)
		}
	}
}
