package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
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
			rendered, err := renderDirectory(t.Context(), dir)
			if err != nil {
				t.Fatal(err)
			}
			assertError(t, validateDocuments(bytes.NewReader(rendered)), tc.wantError)
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

// TestPublishedZoneCannotOmitRenameOrDuplicateItsDeployment prevents unchecked publication.
func TestPublishedZoneCannotOmitRenameOrDuplicateItsDeployment(t *testing.T) {
	rendered := renderPublishedBundle(t, "")
	if err := validateBundle(strings.NewReader(string(rendered)+"\n---\n"+string(rendered)), true); err == nil {
		t.Fatal("published checker accepted duplicate zone Deployments")
	}
	for _, contents := range []string{
		configMap,
		strings.ReplaceAll(string(rendered), "name: world-at-ruin-zone\n", "name: renamed-zone\n"),
		string(rendered) + "\n---\n" + string(rendered),
	} {
		dir := t.TempDir()
		writeFixture(t, filepath.Join(dir, "kustomization.yaml"), "resources: [bundle.yaml]\n")
		writeFixture(t, filepath.Join(dir, "bundle.yaml"), contents)
		err := validateDirectory(t.Context(), dir)
		// Kustomize itself refuses duplicate resource identities; a successful
		// render must still contain exactly one intended zone Deployment.
		if err == nil {
			t.Fatal("published bundle passed without exactly one zone Deployment")
		}
	}
}

// TestPublishedDeploymentUsesHostOwnedNetworkIsolation checks this repository's
// actual publishable bundle rather than a copied deployment fixture.
func TestPublishedDeploymentUsesHostOwnedNetworkIsolation(t *testing.T) {
	for _, entry := range publishedEntryPoints {
		deployment := filepath.Join(publishedBundlePath(t), entry)
		assertError(t, validateDirectory(t.Context(), deployment), "")
	}
}

// The platform reconciles prod at the artifact root, so the root must render
// exactly what the prod overlay renders.
func TestPublishedRootIsTheProdOverlay(t *testing.T) {
	if !bytes.Equal(renderPublishedBundle(t, ""), renderPublishedBundle(t, "prod")) {
		t.Fatal("artifact root no longer renders exactly the prod overlay")
	}
}

// TestDevOverlayHoldsNoProdIdentity keeps dev (#1700) to one replica with its
// documented experimental flag, and without a prod secret path, disruption
// budget, route, certificate, DNS record or hostname.
func TestDevOverlayHoldsNoProdIdentity(t *testing.T) {
	prodPaths := map[string]bool{}
	for _, document := range decodeRendered(t, renderPublishedBundle(t, "prod")) {
		collectSecretPaths(document, prodPaths)
	}
	if len(prodPaths) == 0 {
		t.Fatal("prod render names no secret path to compare dev against")
	}
	dev := renderPublishedBundle(t, "dev")
	for path := range prodPaths {
		if strings.Contains(string(dev), path) {
			t.Fatalf("dev references prod secret path %q", path)
		}
	}
	if regexp.MustCompile(`(^|[^.a-z0-9-])zone-trial\.devantler\.tech`).Match(dev) {
		t.Fatal("dev references the prod hostname")
	}
	prodOnly := []string{
		"PodDisruptionBudget", "Ingress", "Gateway", "HTTPRoute", "GRPCRoute", "TLSRoute",
		"Certificate", "Issuer", "ClusterIssuer", "DNSEndpoint",
	}
	for entry, wantFlag := range map[string]bool{"dev": true, "prod": false} {
		zones := 0
		for _, document := range decodeRendered(t, renderPublishedBundle(t, entry)) {
			kind, _ := document["kind"].(string)
			if entry == "dev" && slices.Contains(prodOnly, kind) {
				t.Fatalf("dev renders prod-only %s", kind)
			}
			if kind != "Deployment" {
				continue
			}
			zones++
			spec := document["spec"].(map[string]any)
			if entry == "dev" && spec["replicas"] != 1 {
				t.Fatalf("dev zone runs %v replicas, want 1", spec["replicas"])
			}
			pod := spec["template"].(map[string]any)["spec"].(map[string]any)
			for _, container := range pod["containers"].([]any) {
				zone := container.(map[string]any)
				if zone["name"] != "world-at-ruin" {
					continue
				}
				args, _ := zone["args"].([]any)
				if slices.Contains(args, any("-movement-intents")) != wantFlag {
					t.Fatalf("%s experimental movement flag = %t, want %t", entry, !wantFlag, wantFlag)
				}
			}
		}
		if zones != 1 {
			t.Fatalf("%s renders %d Deployments, want 1", entry, zones)
		}
	}
}

// collectSecretPaths records every external secret store path a rendered object names.
func collectSecretPaths(node any, paths map[string]bool) {
	switch value := node.(type) {
	case map[string]any:
		if ref, ok := value["remoteRef"].(map[string]any); ok {
			for _, field := range []string{"key", "remoteKey"} {
				if path, ok := ref[field].(string); ok && path != "" {
					paths[path] = true
				}
			}
		}
		for _, child := range value {
			collectSecretPaths(child, paths)
		}
	case []any:
		for _, child := range value {
			collectSecretPaths(child, paths)
		}
	}
}

// Certificate refresh belongs to new TLS handshakes, not a timer that regularly
// terminates a healthy Deployment. Check every actual publishable render.
func TestPublishedZoneRunsUntilSignalled(t *testing.T) {
	for _, entry := range publishedEntryPoints {
		t.Run("deploy/"+entry, func(t *testing.T) { assertZoneRunsUntilSignalled(t, renderPublishedBundle(t, entry)) })
	}
}

// assertZoneRunsUntilSignalled requires listener arguments without a recycle timer.
func assertZoneRunsUntilSignalled(t *testing.T, rendered []byte) {
	t.Helper()
	decoder := yaml.NewDecoder(bytes.NewReader(rendered))
	found := false
	for {
		var resource struct {
			Kind string `yaml:"kind"`
			Spec struct {
				Template struct {
					Spec struct {
						Containers []struct {
							Name string   `yaml:"name"`
							Args []string `yaml:"args"`
						} `yaml:"containers"`
					} `yaml:"spec"`
				} `yaml:"template"`
			} `yaml:"spec"`
		}
		if err := decoder.Decode(&resource); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		if resource.Kind != "Deployment" {
			continue
		}
		for _, container := range resource.Spec.Template.Spec.Containers {
			if container.Name != "world-at-ruin" {
				continue
			}
			found = true
			if len(container.Args) == 0 {
				t.Fatal("published zone is missing its listener arguments")
			}
			for _, arg := range container.Args {
				if arg == "-duration" || arg == "--duration" || strings.HasPrefix(arg, "-duration=") || strings.HasPrefix(arg, "--duration=") {
					t.Fatal("published zone still recycles a healthy listener on a duration timer")
				}
			}
		}
	}
	if !found {
		t.Fatal("published zone container is missing")
	}
}

// Render the actual bundle, then mutate the rendered probe contract. This
// catches drift after Kustomize transformations rather than matching source.
func TestRenderedZoneHealthProbesRejectUnsafeDrift(t *testing.T) {
	documents := decodeRendered(t, renderPublishedBundle(t, ""))
	var container map[string]any
	for _, document := range documents {
		if document["kind"] == "Deployment" {
			spec := document["spec"].(map[string]any)
			template := spec["template"].(map[string]any)
			pod := template["spec"].(map[string]any)
			container = pod["containers"].([]any)[0].(map[string]any)
		}
	}
	if container == nil {
		t.Fatal("published bundle has no zone Deployment")
	}
	// The positive fixture uses the intended command, independently of the
	// checker. The published-bundle test separately validates the actual probes.
	valid := func() map[string]any {
		return map[string]any{
			"exec": map[string]any{"command": []string{
				"/zoneprobe", "-tls-only", "-url", "wss://127.0.0.1:8443/zone",
				"-tls-server-name-file", "/credentials/tls.crt", "-timeout", "1500ms",
			}},
			"timeoutSeconds": 2,
		}
	}
	for _, field := range []string{"readinessProbe", "livenessProbe"} {
		for _, kind := range []string{"valid", "TCP", "HTTP", "missing", "wrong command", "extra handler", "equal deadline", "shorter kubelet deadline", "missing kubelet deadline"} {
			t.Run(field+"/"+kind, func(t *testing.T) {
				container["readinessProbe"], container["livenessProbe"] = valid(), valid()
				probe := container[field].(map[string]any)
				switch kind {
				case "valid":
				case "TCP":
					delete(probe, "exec")
					probe["tcpSocket"] = map[string]any{"port": "zone-tls"}
				case "HTTP":
					delete(probe, "exec")
					probe["httpGet"] = map[string]any{"path": "/zone", "port": "zone-tls"}
				case "missing":
					delete(container, field)
				case "wrong command":
					probe["exec"] = map[string]any{"command": []string{"/zoneprobe", "-url", "wss://127.0.0.1:8443/zone"}}
				case "extra handler":
					probe["tcpSocket"] = map[string]any{"port": "zone-tls"}
				case "equal deadline":
					probe["exec"].(map[string]any)["command"].([]string)[7] = "2s"
				case "shorter kubelet deadline":
					probe["timeoutSeconds"] = 1
				case "missing kubelet deadline":
					delete(probe, "timeoutSeconds")
				}
				var output bytes.Buffer
				encoder := yaml.NewEncoder(&output)
				for _, document := range documents {
					if err := encoder.Encode(document); err != nil {
						t.Fatal(err)
					}
				}
				if err := encoder.Close(); err != nil {
					t.Fatal(err)
				}
				want := "TLS health"
				if kind == "valid" {
					want = ""
				}
				assertError(t, validateDocuments(&output), want)
			})
		}
	}
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

// publishedBundlePath locates the actual committed bundle beside this test source.
func publishedBundlePath(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the actual deployment bundle")
	}
	return filepath.Join(filepath.Dir(source), "..", "..", "deploy")
}

// publishedEntryPoints are the Kustomizations the platform reconciles from the
// one artifact: the root (prod), the prod overlay itself and the dev overlay.
var publishedEntryPoints = []string{"", "prod", "dev"}

// renderPublishedBundle exercises real Kustomize transformations of one entry point.
func renderPublishedBundle(t *testing.T, entry string) []byte {
	t.Helper()
	command := exec.CommandContext(t.Context(), "kubectl", "kustomize", filepath.Join(publishedBundlePath(t), entry))
	rendered, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	return rendered
}

// decodeRendered splits a render into generic documents and fails on malformed output.
func decodeRendered(t *testing.T, rendered []byte) []map[string]any {
	t.Helper()
	var documents []map[string]any
	decoder := yaml.NewDecoder(bytes.NewReader(rendered))
	for {
		var document map[string]any
		err := decoder.Decode(&document)
		if errors.Is(err, io.EOF) {
			return documents
		}
		if err != nil {
			t.Fatal(err)
		}
		documents = append(documents, document)
	}
}
