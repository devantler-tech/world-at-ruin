package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func gateEnvironment() map[string]string {
	return map[string]string{
		"WAR_REPOSITORY_TRUSTED_GATE_ENABLED": "true",
		"TRUSTED_GATE_APP_ID":                 strconv.FormatInt(publisherTestAppID, 10),
		"GITHUB_REPOSITORY":                   "devantler-tech/world-at-ruin",
		"GITHUB_WORKFLOW_REF":                 "devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main",
		"GITHUB_WORKFLOW_SHA":                 strings.Repeat("a", 40),
		"GITHUB_EVENT_NAME":                   "workflow_run",
		"GITHUB_TOKEN":                        "fixture",
	}
}

func TestDisabledGateHasNoPublisherSideEffects(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		env := gateEnvironment()
		env["WAR_REPOSITORY_TRUSTED_GATE_ENABLED"] = flag
		var out bytes.Buffer
		if err := execute([]string{"publish", "--identity", "invalid", "--verdict", "success"}, env, nil, &out); err != nil {
			t.Fatal(err)
		}
		if out.String() != "admitted=false\n" {
			t.Fatalf("disabled output %q", out.String())
		}
	}
}

func TestMalformedActivationNeverClearsAdmission(t *testing.T) {
	t.Run("enabled baseline", func(t *testing.T) {
		fixture := newResolverFixture()
		client := fixture.client(t)
		var out bytes.Buffer
		if err := execute([]string{"resolve", "--run-id", "73"}, gateEnvironment(), &client, &out); err != nil {
			t.Fatal(err)
		}
		if len(fixture.seen) == 0 || !strings.Contains(out.String(), "admitted=true\n") {
			t.Fatal("enabled baseline did not resolve a real fixture")
		}
	})
	for _, flag := range []string{"TRUE", "1", " false", "true\n"} {
		fixture := newResolverFixture()
		client := fixture.client(t)
		env := gateEnvironment()
		env["WAR_REPOSITORY_TRUSTED_GATE_ENABLED"] = flag
		var out bytes.Buffer
		if err := execute([]string{"resolve", "--run-id", "73"}, env, &client, &out); err == nil || len(fixture.seen) != 0 || out.Len() != 0 {
			t.Fatalf("accepted flag %q or contacted API: err=%v requests=%d output=%q", flag, err, len(fixture.seen), out.String())
		}
	}
}

func TestCandidateWorkflowAndMissingCredentialsCannotPublish(t *testing.T) {
	identity := publisherIdentity()
	rawIdentity, err := json.Marshal(identity)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"publish", "--identity", string(rawIdentity), "--verdict", "success"}
	t.Run("enabled baseline", func(t *testing.T) {
		client, seen := publisherClient(t, identity, publisherFaults{})
		var out bytes.Buffer
		if err := execute(args, gateEnvironment(), client, &out); err != nil {
			t.Fatal(err)
		}
		if seen.posts != 1 || seen.refreshes == 0 || seen.readbacks != 1 || out.String() != "published=success\n" {
			t.Fatalf("enabled baseline did not publish: %+v output=%q", seen, out.String())
		}
	})
	for key, value := range map[string]string{
		"GITHUB_REPOSITORY":   "external/world-at-ruin",
		"GITHUB_WORKFLOW_REF": "devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/pull/1/merge",
		"GITHUB_WORKFLOW_SHA": "missing",
		"GITHUB_EVENT_NAME":   "pull_request",
		"GITHUB_TOKEN":        "",
		"TRUSTED_GATE_APP_ID": "0",
	} {
		t.Run(key, func(t *testing.T) {
			client, seen := publisherClient(t, identity, publisherFaults{})
			env := gateEnvironment()
			env[key] = value
			var out bytes.Buffer
			if err := execute(args, env, client, &out); err == nil || seen.posts != 0 || seen.refreshes != 0 || seen.readbacks != 0 || out.Len() != 0 {
				t.Fatalf("invalid %s reached API: err=%v observed=%+v output=%q", key, err, seen, out.String())
			}
		})
	}
	t.Run("Actions producer", func(t *testing.T) {
		client, seen := publisherClient(t, identity, publisherFaults{})
		env := gateEnvironment()
		env["TRUSTED_GATE_APP_ID"] = strconv.FormatInt(knownActionsAppID, 10)
		var out bytes.Buffer
		if err := execute(args, env, client, &out); err == nil || seen.posts != 0 || seen.refreshes != 0 || seen.readbacks != 0 || out.Len() != 0 {
			t.Fatalf("Actions producer reached API: err=%v observed=%+v output=%q", err, seen, out.String())
		}
	})
}

func TestIdentityInputRejectsUnknownFieldsAndTrailingJSON(t *testing.T) {
	for _, raw := range []string{`{"unknown":true}`, `{} {}`, `null`, `[]`} {
		if _, err := decodeIdentity(raw); err == nil {
			t.Fatalf("accepted identity %q", raw)
		}
	}
}

func TestOutputFileUsesBoundedSingleLineIdentity(t *testing.T) {
	identity := Identity{Kind: "pull_request", PRNumber: 7, RunID: 9, Head: strings.Repeat("1", 40), Base: strings.Repeat("2", 40), Candidate: strings.Repeat("3", 40), Ref: "refs/pull/7/merge"}
	path := filepath.Join(t.TempDir(), "github-output")
	if err := writeIdentity(identity, path, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "trusted-sha="+identity.Base+"\n") || !strings.Contains(string(data), "candidate-sha="+identity.Candidate+"\n") || strings.Count(string(data), "identity-json=") != 1 {
		t.Fatalf("output %q", data)
	}
}

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
