package main

import (
	"os"
	"path/filepath"
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
