package main

import (
	"bytes"
	"strconv"
	"testing"
)

// TestInspectReportsOverlapWithoutClaimingActivation keeps GET-only overlap proof distinct from activation.
func TestInspectReportsOverlapWithoutClaimingActivation(t *testing.T) {
	replacement, retained := readinessRulesetFixtures()
	inventory := []map[string]any{readinessSummary(replacement), readinessSummary(retained)}
	client := readinessClient(t, replacement, retained, inventory)
	var out bytes.Buffer
	if err := execute([]string{"inspect", "--app-id", strconv.FormatInt(readinessTestAppID, 10)}, map[string]string{"GITHUB_TOKEN": "read-only-fixture"}, client, &out); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "protection_overlap_verified=true\nactivation_ready=unknown\n"; got != want {
		t.Fatalf("rule shape must not imply activation readiness: got %q want %q", got, want)
	}
}
