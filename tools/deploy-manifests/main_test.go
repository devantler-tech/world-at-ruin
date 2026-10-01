package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const standardPolicy = `apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-policy
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
`

const configMap = `apiVersion: v1
kind: ConfigMap
metadata:
  name: ordinary-tenant-resource
`

// TestRenderedDocuments accepts complete ordinary output and rejects host policies
// or malformed, incomplete and empty documents anywhere in the stream.
func TestRenderedDocuments(t *testing.T) {
	for _, tc := range []struct {
		name, manifest string
		wantError      string
	}{
		{"ordinary resource", configMap, ""},
		{"multiple resources", configMap + "---\n" + configMap, ""},
		{"host-owned policy", standardPolicy, "host-owned"},
		{"policy after ordinary resource", configMap + "---\n" + standardPolicy, "host-owned"},
		{"empty render", "", "empty"},
		{"empty document", configMap + "---\n# empty\n", "empty"},
		{"malformed document", "kind: [", "decode"},
		{"missing kind", "apiVersion: v1\n", "kind"},
		{"missing apiVersion", "kind: ConfigMap\n", "apiVersion"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			assertError(t, validateDocuments(strings.NewReader(tc.manifest)), tc.wantError)
		})
	}
}

// TestNestedPolicyIsRejectedAfterRealRender exercises Kustomize's expansion of
// nested resources and Lists before applying the host-ownership boundary.
func TestNestedPolicyIsRejectedAfterRealRender(t *testing.T) {
	for _, tc := range []struct {
		name, resource string
		wantError      string
	}{
		{"ordinary nested resource", configMap, ""},
		{"nested NetworkPolicy", standardPolicy, "host-owned"},
		{"NetworkPolicy inside List", "apiVersion: v1\nkind: List\nitems:\n  - " + strings.ReplaceAll(strings.TrimSuffix(standardPolicy, "\n"), "\n", "\n    ") + "\n", "host-owned"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFixture(t, filepath.Join(dir, "kustomization.yaml"), "resources: [nested]\n")
			writeFixture(t, filepath.Join(dir, "nested", "kustomization.yaml"), "resources: [resource.yaml]\n")
			writeFixture(t, filepath.Join(dir, "nested", "resource.yaml"), tc.resource)
			assertError(t, validateDirectory(t.Context(), dir), tc.wantError)
		})
	}
}

// TestBrokenRenderIsRejected proves missing resources and empty output cannot
// produce a successful ownership check.
func TestBrokenRenderIsRejected(t *testing.T) {
	dir := t.TempDir()
	writeFixture(t, filepath.Join(dir, "kustomization.yaml"), "resources: [missing.yaml]\n")
	assertError(t, validateDirectory(t.Context(), dir), "render")
	writeFixture(t, filepath.Join(dir, "kustomization.yaml"), "resources: []\n")
	assertError(t, validateDirectory(t.Context(), dir), "empty")
}

// TestPublishedDeploymentUsesHostOwnedNetworkIsolation checks this repository's
// actual publishable bundle rather than a copied deployment fixture.
func TestPublishedDeploymentUsesHostOwnedNetworkIsolation(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the actual deployment bundle")
	}
	deployment := filepath.Join(filepath.Dir(source), "..", "..", "deploy")
	assertError(t, validateDirectory(t.Context(), deployment), "")
}

// assertError requires success for an empty expectation, or a real error
// containing the expected diagnostic for a negative control.
func assertError(t *testing.T, err error, want string) {
	t.Helper()
	if want == "" {
		if err != nil {
			t.Fatal(err)
		}
		return
	}
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("expected error containing %q, got %v", want, err)
	}
}

// writeFixture creates private nested test inputs and fails the test on any
// filesystem error instead of validating a partial fixture.
func writeFixture(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}
