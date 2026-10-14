package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestAttachReleaseRetainsRecoveryBudget executes the maintained shell blocks
// through their last successful attempts without network access or real waits.
func TestAttachReleaseRetainsRecoveryBudget(t *testing.T) {
	document := loadRepositoryWorkflow(t)
	job, err := document.job(attachReleaseJob)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	bin := filepath.Join(work, "bin")
	if err := os.MkdirAll(filepath.Join(work, "build"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, "build", "WorldAtRuin-1.2.3-macOS-universal.zip"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	writeAttachmentExecutable(t, filepath.Join(bin, "sleep"), `#!/bin/bash
set -euo pipefail
[[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]] || exit 99
printf '%s\n' "$1" >> "$WAR_ATTACH_TEST_WAITS"
`)
	writeAttachmentExecutable(t, filepath.Join(bin, "gh"), `#!/bin/bash
set -euo pipefail
if [[ "$1" != release ]]; then exit 99; fi
if [[ "$2" == upload ]]; then
  mode=upload; limit=5
elif [[ "$2" == view && "$*" == *"--json tagName"* ]]; then
  mode=wait; limit=30
elif [[ "$2" == view && "$*" == *"--json isDraft"* ]]; then
  mode=state; limit=3
else
  exit 99
fi
count=0
if [[ -f "$WAR_ATTACH_TEST_STATE/$mode" ]]; then
  IFS= read -r count < "$WAR_ATTACH_TEST_STATE/$mode"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$WAR_ATTACH_TEST_STATE/$mode"
if [[ "$count" -lt "$limit" ]]; then exit 1; fi
if [[ "$mode" == state ]]; then printf 'true\n'; fi
`)
	waits := filepath.Join(work, "waits")
	for index, name := range []string{"⏳ Wait for the draft release to exist", "📤 Attach the build to the release"} {
		script := filepath.Join(work, "step-"+strconv.Itoa(index)+".sh")
		writeAttachmentExecutable(t, script, attachmentRun(t, job, name))
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		command := exec.CommandContext(ctx, "/bin/bash", script)
		command.Dir = work
		command.Env = []string{
			"PATH=" + bin + ":/usr/bin:/bin", "GH_TOKEN=fixture-only", "TAG=v1.2.3",
			"GITHUB_REPOSITORY=devantler-tech/world-at-ruin",
			"WAR_ATTACH_TEST_STATE=" + work, "WAR_ATTACH_TEST_WAITS=" + waits,
		}
		command.WaitDelay = time.Second
		output, err := command.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("%s: %v\n%s", name, err, output)
		}
	}
	for _, attempt := range []struct {
		name string
		want int
	}{{"wait", 30}, {"state", 3}, {"upload", 5}} {
		actual, err := os.ReadFile(filepath.Join(work, attempt.name))
		if err != nil || strings.TrimSpace(string(actual)) != strconv.Itoa(attempt.want) {
			t.Fatalf("%s attempts = %q, error %v; want %d", attempt.name, actual, err, attempt.want)
		}
	}
	observed, err := os.ReadFile(waits)
	if err != nil {
		t.Fatal(err)
	}
	var inlineWait time.Duration
	for _, value := range strings.Fields(string(observed)) {
		seconds, err := strconv.Atoi(value)
		if err != nil || seconds < 0 {
			t.Fatalf("invalid virtual sleep %q: %v", value, err)
		}
		inlineWait += time.Duration(seconds) * time.Second
	}
	if inlineWait != 525*time.Second {
		t.Fatalf("maintained shell retry waits = %s, want 8m45s", inlineWait)
	}
	// download-artifact 8.0.2's pinned named-artifact path has three metadata
	// RPCs, each admitting 120s cumulative retry sleeps, and four 5s blob sleeps.
	// Its metadata cap is per RPC, not a whole-action execution deadline.
	const metadataWait = 3 * 120 * time.Second
	const blobWait = 4 * 5 * time.Second
	maximumWait := inlineWait + metadataWait + blobWait
	if maximumWait != 905*time.Second || maximumWait <= 15*time.Minute {
		t.Fatalf("15-minute control did not reproduce exhaustion: %s", maximumWait)
	}
	// The previous pinned downloader's three metadata RPCs slept <106s in
	// total. Preserve the old job's remaining allowance for real work; neither
	// this model nor the finite job deadline promises bounded remote latency.
	previousWorkAllowance := 15*time.Minute - inlineWait - blobWait - 106*time.Second
	minutes, ok := job["timeout-minutes"].(int)
	if !ok || time.Duration(minutes)*time.Minute < maximumWait+previousWorkAllowance {
		t.Fatalf("attachment deadline %v minutes cannot retain %s retry waits plus the previous %s work allowance", job["timeout-minutes"], maximumWait, previousWorkAllowance)
	}
}

// attachmentRun selects the actual maintained step rather than a copied loop.
func attachmentRun(t *testing.T, job map[string]any, name string) string {
	t.Helper()
	steps, ok := job["steps"].([]any)
	if !ok {
		t.Fatal("attachment steps are not a sequence")
	}
	for _, raw := range steps {
		step, err := stringMap(raw, "attachment step")
		if err != nil {
			t.Fatal(err)
		}
		if step["name"] == name {
			run, ok := step["run"].(string)
			if !ok || strings.TrimSpace(run) == "" {
				t.Fatalf("%s has no shell block", name)
			}
			return run
		}
	}
	t.Fatalf("attachment step %q is missing", name)
	return ""
}

// writeAttachmentExecutable writes only disposable, locally owned test files.
func writeAttachmentExecutable(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
}
