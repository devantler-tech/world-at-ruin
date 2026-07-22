package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func loadFixture(t *testing.T, contents string) (*workflow, error) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "workflow.yaml")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return loadWorkflow(path)
}

func loadRepositoryWorkflow(t *testing.T) *workflow {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	path := filepath.Join(filepath.Dir(source), "..", "..", "..", ".github", "workflows", "cd.yaml")
	document, err := loadWorkflow(path)
	if err != nil {
		t.Fatal(err)
	}
	return document
}

func TestQuotedJobIDAndPermissionAreNormalized(t *testing.T) {
	workflow, err := loadFixture(t, `jobs:
  "release-helper":
    permissions:
      contents: "write"
`)
	if err != nil {
		t.Fatal(err)
	}
	job, err := workflow.job("release-helper")
	if err != nil {
		t.Fatal(err)
	}
	permission, err := effectiveContentsPermission(job, map[string]any{"contents": "read"})
	if err != nil {
		t.Fatal(err)
	}
	if permission != "write" {
		t.Fatalf("permission = %q, want write", permission)
	}
}

func TestAliasInjectedSecretIsResolved(t *testing.T) {
	workflow, err := loadFixture(t, `jobs:
  anchor-source:
    env: &shared-secret-env
      RELEASE_SECRET: ${{ secrets.RELEASE_TOKEN }}
  publish-macos:
    env: *shared-secret-env
`)
	if err != nil {
		t.Fatal(err)
	}
	job, err := workflow.job("publish-macos")
	if err != nil {
		t.Fatal(err)
	}
	if !containsSecretReference(job) {
		t.Fatal("alias-injected secret reference was not detected")
	}
}

func TestDuplicateJobIDIsRejected(t *testing.T) {
	_, err := loadFixture(t, `jobs:
  attach-release:
    runs-on: ubuntu-latest
  "attach-release":
    runs-on: macos-latest
`)
	if err == nil {
		t.Fatal("duplicate job ID was accepted")
	}
}

func TestWorkflowLevelEnvironmentIsRejected(t *testing.T) {
	workflow := loadRepositoryWorkflow(t)
	workflow.root["env"] = map[string]any{"BASH_ENV": "build/payload.sh"}
	if err := workflow.validate(); err == nil {
		t.Fatal("workflow-level BASH_ENV was accepted")
	}
}

func TestBuildArtifactPathMustBeExact(t *testing.T) {
	workflow := loadRepositoryWorkflow(t)
	delete(workflow.root, "env")
	publishMacOS, err := workflow.job(publishMacOSJob)
	if err != nil {
		t.Fatal(err)
	}

	mutated := false
	for _, rawStep := range steps(publishMacOS) {
		step, ok := rawStep.(map[string]any)
		if !ok {
			continue
		}
		uses, _ := step["uses"].(string)
		if !strings.HasPrefix(uses, "actions/upload-artifact@") {
			continue
		}
		with, ok := step["with"].(map[string]any)
		if !ok {
			t.Fatal("upload-artifact step has no with mapping")
		}
		with["path"] = "build"
		mutated = true
	}
	if !mutated {
		t.Fatal("upload-artifact step not found")
	}
	if err := workflow.validate(); err == nil {
		t.Fatal("widened build artifact path was accepted")
	}
}
