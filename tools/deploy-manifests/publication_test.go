package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

const publicationImageDigest = "sha256:" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const publicationManifestDigest = "sha256:" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

// TestZoneManifestPublication runs the committed publication shell steps against
// recording registry/signature clients. A selectable version must never precede
// either signature verification, including when a later operation fails.
func TestZoneManifestPublication(t *testing.T) {
	for _, tc := range []struct {
		name, failure, result, release, runID, attempt string
		wantSuccess                                    bool
	}{
		{name: "both digests verified", wantSuccess: true},
		{name: "image signing fails", failure: "sign-image"},
		{name: "image verification fails", failure: "verify-image"},
		{name: "manifest signing fails", failure: "sign-manifest"},
		{name: "manifest verification fails", failure: "verify-manifest"},
		{name: "invalid push response", result: "not JSON"},
		{name: "missing manifest digest", result: `{}`},
		{name: "invalid manifest digest", result: `{"digest":"not-a-digest"}`},
		{name: "prerelease refused", release: "v8.7.6-rc.1"},
		{name: "invalid run ID", runID: "not-a-run"},
		{name: "invalid run attempt", attempt: "not-an-attempt"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			bin := filepath.Join(dir, "bin")
			if err := os.MkdirAll(bin, 0o700); err != nil {
				t.Fatal(err)
			}
			deployment, err := os.ReadFile(filepath.Join(publishedBundlePath(t), "deployment.yaml"))
			if err != nil {
				t.Fatal(err)
			}
			writeFixture(t, filepath.Join(dir, "deploy", "deployment.yaml"), string(deployment))
			publicationClient(t, bin, "flux", publicationFluxStub)
			publicationClient(t, bin, "cosign", publicationCosignStub)

			release := tc.release
			if release == "" {
				release = "v8.7.6"
			}
			result := tc.result
			if result == "" {
				result = `{"digest":"` + publicationManifestDigest + `"}`
			}
			logPath := filepath.Join(dir, "operations")
			runID, attempt := tc.runID, tc.attempt
			if runID == "" {
				runID = "123456"
			}
			if attempt == "" {
				attempt = "2"
			}
			env := append(os.Environ(),
				"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"),
				"PUBLICATION_LOG="+logPath,
				"PUBLICATION_FAILURE="+tc.failure,
				"PUBLICATION_RESULT="+result,
				"PUBLICATION_EXPECTED_SIGNER=https://github.com/devantler-tech/world-at-ruin/.github/workflows/server-cd.yaml@refs/tags/"+release,
				"GITHUB_RUN_ID="+runID, "GITHUB_RUN_ATTEMPT="+attempt,
				"GITHUB_OUTPUT="+filepath.Join(dir, "output"),
				"GITHUB_STEP_SUMMARY="+filepath.Join(dir, "summary"),
			)
			var runErr error
			var output []byte
			bindings := map[string]string{
				"github.repository":          "devantler-tech/world-at-ruin",
				"github.ref_name":            release,
				"github.ref":                 "refs/tags/" + release,
				"github.sha":                 strings.Repeat("c", 40),
				"steps.image.outputs.digest": publicationImageDigest,
			}
			for _, step := range publicationWorkflowSteps(t) {
				stepEnv := append([]string(nil), env...)
				for key, value := range step.Env {
					for expression, replacement := range bindings {
						value = strings.ReplaceAll(value, "${{ "+expression+" }}", replacement)
					}
					if strings.Contains(value, "${{") {
						t.Fatalf("unresolved workflow binding in %s: %s", step.Name, key)
					}
					stepEnv = append(stepEnv, key+"="+value)
				}
				command := exec.CommandContext(t.Context(), "bash", "-e", "-o", "pipefail", "-c", step.Run)
				command.Dir, command.Env = dir, stepEnv
				output, runErr = command.CombinedOutput()
				if runErr != nil {
					break
				}
				if step.ID != "" {
					outputs, err := os.ReadFile(filepath.Join(dir, "output"))
					if err != nil {
						t.Fatal(err)
					}
					for _, line := range strings.Split(strings.TrimSpace(string(outputs)), "\n") {
						key, value, ok := strings.Cut(line, "=")
						if !ok {
							t.Fatalf("invalid workflow output: %q", line)
						}
						bindings["steps."+step.ID+".outputs."+key] = value
					}
				}
			}
			if (runErr == nil) != tc.wantSuccess {
				t.Fatalf("success=%t, want %t: %v\n%s", runErr == nil, tc.wantSuccess, runErr, output)
			}
			operations, err := os.ReadFile(logPath)
			if err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			trace := string(operations)
			selected := strings.Index(trace, "selected:")
			if !tc.wantSuccess {
				if selected >= 0 {
					t.Fatalf("failed publication exposed a selectable version:\n%s", trace)
				}
				return
			}
			for _, verification := range []string{"verify-image\n", "verify-manifest\n"} {
				verified := strings.Index(trace, verification)
				if verified < 0 || selected < 0 || selected < verified {
					t.Fatalf("selectable publication preceded %s:\n%s", strings.TrimSpace(verification), trace)
				}
			}
			if strings.Count(trace, "selected:") != 1 ||
				!strings.Contains(trace, "selected:oci://ghcr.io/devantler-tech/world-at-ruin/zone-manifests@"+publicationManifestDigest+":8.7.6\n") {
				t.Fatalf("promotion did not preserve the verified digest:\n%s", trace)
			}
			if !strings.Contains(trace, "staged:oci://ghcr.io/devantler-tech/world-at-ruin/zone-manifests:staging-123456-2\n") {
				t.Fatalf("artifact was not staged outside stable version selection:\n%s", trace)
			}
			pinned, err := os.ReadFile(filepath.Join(dir, "deploy", "deployment.yaml"))
			if err != nil || !strings.Contains(string(pinned), "ghcr.io/devantler-tech/world-at-ruin/zone@"+publicationImageDigest) {
				t.Fatalf("published declaration lost its tested image digest: %v", err)
			}
		})
	}
}

type publicationStep struct {
	Name, ID, Run, If string
	Env               map[string]string
}

// publicationWorkflowSteps reads the real shell blocks instead of copying the
// publication algorithm into its regression fixture.
func publicationWorkflowSteps(t *testing.T) []publicationStep {
	t.Helper()
	path := filepath.Join(publishedBundlePath(t), "..", ".github", "workflows", "server-cd.yaml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Jobs map[string]struct {
			Steps []publicationStep
		}
	}
	if err := yaml.Unmarshal(contents, &workflow); err != nil {
		t.Fatal(err)
	}
	var scripts []publicationStep
	var requiresTag, publishes, verifies bool
	for _, step := range workflow.Jobs["publish-zone"].Steps {
		selected := step.Name == "Require an exact stable release tag" || step.ID == "manifests" ||
			step.Name == "Sign and verify the immutable published digest" ||
			strings.Contains(step.Run, "flux push artifact") || strings.Contains(step.Run, "flux tag artifact") ||
			strings.Contains(step.Run, "cosign sign") || strings.Contains(step.Run, "cosign verify")
		if !selected {
			continue
		}
		if step.Run == "" || (step.If != "" && step.If != "success()") {
			t.Fatalf("publication step %q has no script or can bypass a previous failure", step.Name)
		}
		requiresTag = requiresTag || step.Name == "Require an exact stable release tag"
		publishes = publishes || step.ID == "manifests"
		verifies = verifies || step.Name == "Sign and verify the immutable published digest"
		scripts = append(scripts, step)
	}
	if !requiresTag || !publishes || !verifies {
		t.Fatal("real release validation, manifest publication and signature verification steps must be present")
	}
	return scripts
}

// publicationClient installs one executable recorder in an isolated fixture.
func publicationClient(t *testing.T, bin, name, script string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
}

const publicationFluxStub = `#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'push artifact')
    if [[ "$3" =~ :[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf 'selected:%s\n' "$3" >> "$PUBLICATION_LOG"
    else
      printf 'staged:%s\n' "$3" >> "$PUBLICATION_LOG"
    fi
    printf '%s\n' "$PUBLICATION_RESULT"
    ;;
  'tag artifact')
    [[ "$#" == 5 && "$4" == '--tag' ]] || exit 91
    printf 'selected:%s:%s\n' "$3" "$5" >> "$PUBLICATION_LOG"
    ;;
  *) exit 92 ;;
esac
`

const publicationCosignStub = `#!/usr/bin/env bash
set -euo pipefail
operation="$1"
reference="${!#}"
if [[ "$operation" == 'verify' ]]; then
  [[ "$#" == 6 && "$2" == '--certificate-oidc-issuer' && "$3" == 'https://token.actions.githubusercontent.com' && "$4" == '--certificate-identity' && "$5" == "$PUBLICATION_EXPECTED_SIGNER" ]] || exit 93
elif [[ "$operation" == 'sign' ]]; then
  [[ "$#" == 3 && "$2" == '--yes' ]] || exit 94
else
  exit 95
fi
case "$reference" in
  'ghcr.io/devantler-tech/world-at-ruin/zone@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') stage="${operation}-image" ;;
  'ghcr.io/devantler-tech/world-at-ruin/zone-manifests@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') stage="${operation}-manifest" ;;
  *) exit 96 ;;
esac
printf '%s\n' "$stage" >> "$PUBLICATION_LOG"
[[ "$PUBLICATION_FAILURE" != "$stage" ]] || exit 17
`
