package main

import (
	"strings"
	"testing"
)

// TestCDWorkflowQueuesTheReleaseTag checks that manual and automatic publishers
// use the same release identity before any build or release-asset write starts.
func TestCDWorkflowQueuesTheReleaseTag(t *testing.T) {
	doc := loadRepositoryWorkflow(t)
	concurrency, ok := doc.root["concurrency"].(map[string]any)
	if !ok || concurrency["cancel-in-progress"] != false || concurrency["queue"] != "max" {
		t.Fatalf("release workflows must queue without cancelling publication: %#v", doc.root["concurrency"])
	}
	group, ok := concurrency["group"].(string)
	if !ok {
		t.Fatal("missing workflow concurrency group")
	}
	const releaseTag = "${{ github.ref_type == 'tag' && github.ref_name || inputs.tag }}"
	// Checkout and each publisher must consume the same tag selector as the
	// workflow lock. A branch dispatch's ref name cannot identify its release.
	if group != "CD-"+releaseTag {
		t.Fatalf("workflow lock must identify the built release, not its dispatch branch: %q", group)
	}
	for _, jobID := range []string{"publish-macos", "attach-release", "publish-ghcr", "publish-release"} {
		job, err := doc.job(jobID)
		if err != nil {
			t.Fatal(err)
		}
		seen := false
		for _, raw := range steps(job) {
			step, ok := raw.(map[string]any)
			if !ok {
				t.Fatal("invalid publication step")
			}
			env, _ := step["env"].(map[string]any)
			for _, input := range []string{"RAW_TAG", "TAG"} {
				tag, exists := env[input]
				if !exists || tag == "${{ steps.version.outputs.tag }}" {
					continue
				}
				seen = true
				if tag != releaseTag {
					t.Fatalf("%s publishes a different release from the workflow lock: %v", jobID, tag)
				}
			}
			with, _ := step["with"].(map[string]any)
			if ref, ok := with["ref"].(string); ok && strings.Contains(ref, "refs/tags/") {
				if ref != "refs/tags/"+releaseTag {
					t.Fatalf("%s checks out a different release from the workflow lock: %q", jobID, ref)
				}
			}
		}
		if !seen {
			t.Fatalf("%s has no observed release-tag input", jobID)
		}
	}
}
