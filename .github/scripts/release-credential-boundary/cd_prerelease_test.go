package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Execute the production publication blocks. Only the engine and network
// boundaries are doubled; transfers, JSON parsing, checksums, layer selection
// and the latest-tag controller operate on real files and registry state.
func TestCDStableAndPrereleasePublication(t *testing.T) {
	for _, tc := range []struct {
		version  string
		manifest bool
		corrupt  bool
	}{
		{"1.2.3", true, false},
		{"1.2.3-rc.1", false, false},
		{"1.2.3", true, true},
	} {
		t.Run(fmt.Sprintf("%s/corrupt=%v", tc.version, tc.corrupt), func(t *testing.T) {
			doc := loadRepositoryWorkflow(t)
			root := t.TempDir()
			write := func(path, contents string) {
				t.Helper()
				path = filepath.Join(root, path)
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			write("build/WorldAtRuin-"+tc.version+"-macOS-universal.zip", "released build bytes")
			write("server/wire/wire.go", "const LegacyVersion uint16 = 1\nconst Version uint16 = 2\n")
			write("registry/tags", "1.2.2\n")
			write("registry/latest", "1.2.2\n")
			_, source, _, ok := runtime.Caller(0)
			if !ok {
				t.Fatal("resolve test source")
			}
			sequence, err := os.ReadFile(filepath.Join(filepath.Dir(source), "..", "..", "..", "tools", "manifest-sequence.sh"))
			if err != nil {
				t.Fatal(err)
			}
			write("tools/manifest-sequence.sh", string(sequence))
			if err := os.Chmod(filepath.Join(root, "tools/manifest-sequence.sh"), 0o700); err != nil {
				t.Fatal(err)
			}
			outputs := map[string]string{"version": tc.version, "tag": "v" + tc.version}
			manifestSHA := ""
			zipSHA := ""
			artifact := ""
			digest := ""
			uploadedManifest := false
			downloadedManifest := false
			verified := false
			for _, jobID := range []string{"publish-macos", "publish-ghcr"} {
				job, err := doc.job(jobID)
				if err != nil {
					t.Fatal(err)
				}
				steps, ok := job["steps"].([]any)
				if !ok {
					t.Fatal("missing publication steps")
				}
				for _, raw := range steps {
					step, ok := raw.(map[string]any)
					if !ok {
						t.Fatal("bad step")
					}
					name, _ := step["name"].(string)
					id, _ := step["id"].(string)
					with, _ := step["with"].(map[string]any)
					manifestTransfer := with["name"] == "client-update-manifest"
					selected := id == "version" || id == "manifest" || id == "push" || manifestTransfer ||
						strings.Contains(name, "Confirm the build matches") || strings.Contains(name, "manifest crossed") ||
						strings.Contains(name, "Sign the artifact by digest") || strings.Contains(name, "Verify signature and byte-identity") ||
						strings.Contains(name, "Advance the verified latest digest") || strings.Contains(name, "Attest completed release verification")
					if !selected {
						continue
					}
					if condition, ok := step["if"].(string); ok {
						// The supported GitHub expression is deliberately small. An
						// unknown condition cannot silently skip the observed path.
						if strings.TrimSpace(condition) != "${{ !contains(steps.version.outputs.version, '-') }}" {
							t.Fatalf("unsupported condition on %s: %s", name, condition)
						}
						if strings.Contains(tc.version, "-") {
							continue
						}
					}
					if manifestTransfer {
						uses, _ := step["uses"].(string)
						input, destination := "", ""
						if strings.HasPrefix(uses, "actions/upload-artifact@") {
							input, destination = "build/update-manifest.json", "artifacts/client-update-manifest.json"
							uploadedManifest = true
						} else if strings.HasPrefix(uses, "actions/download-artifact@") {
							input, destination = "artifacts/client-update-manifest.json", "oci/update-manifest.json"
							downloadedManifest = true
						} else {
							t.Fatalf("unknown manifest transfer: %s", uses)
						}
						bytes, err := os.ReadFile(filepath.Join(root, input))
						if err != nil {
							t.Fatalf("%s: %v", name, err)
						}
						write(destination, string(bytes))
						continue
					}
					write("oci/WorldAtRuin-"+tc.version+"-macOS-universal.zip", "released build bytes")
					if zipSHA == "" {
						cmd := exec.Command("shasum", "-a", "256", filepath.Join(root, "build/WorldAtRuin-"+tc.version+"-macOS-universal.zip"))
						out, err := cmd.Output()
						if err != nil {
							t.Fatal(err)
						}
						zipSHA = strings.Fields(string(out))[0]
					}
					env := []string{"RAW_TAG=v" + tc.version, "FIXTURE_ROOT=" + root, "CORRUPT=" + fmt.Sprint(tc.corrupt),
						"GITHUB_OUTPUT=" + filepath.Join(root, "output"), "GITHUB_REPOSITORY=devantler-tech/world-at-ruin",
						"ARTIFACT=" + artifact, "DIGEST=" + digest, "GITHUB_SERVER_URL=https://github.com", "GITHUB_SHA=" + strings.Repeat("e", 40)}
					if values, ok := step["env"].(map[string]any); ok {
						for key, value := range values {
							v, ok := value.(string)
							if !ok {
								t.Fatalf("non-string environment %s", key)
							}
							v = strings.NewReplacer(
								"${{ steps.version.outputs.version }}", tc.version,
								"${{ steps.version.outputs.tag }}", "v"+tc.version,
								"${{ needs.publish-macos.outputs.sha256 }}", zipSHA,
								"${{ needs.publish-macos.outputs.revision }}", outputs["revision"],
								"${{ needs.publish-macos.outputs.manifest_sha256 }}", manifestSHA,
								"${{ steps.push.outputs.artifact }}", artifact,
								"${{ steps.push.outputs.digest }}", digest,
								"${{ github.ref_type == 'tag' && github.ref_name || inputs.tag }}", "v"+tc.version).Replace(v)
							if strings.Contains(v, "${{") {
								t.Fatalf("unresolved environment %s", key)
							}
							env = append(env, key+"="+v)
						}
					}
					run, _ := step["run"].(string)
					write("output", "")
					cmd := exec.Command("bash", "-c", publicationBoundaryDouble+"\n"+run)
					cmd.Dir = root
					cmd.Env = append(os.Environ(), env...)
					out, err := cmd.CombinedOutput()
					if strings.Contains(name, "Verify signature and byte-identity") && tc.corrupt {
						if err == nil {
							t.Fatal("corrupt stable manifest was accepted")
						}
						if !strings.Contains(string(out), "FAILED") {
							t.Fatalf("wrong corruption refusal: %s", out)
						}
						verified = true
						break
					}
					if err != nil {
						t.Fatalf("%s: %v\n%s", name, err, out)
					}
					if strings.Contains(name, "Verify signature and byte-identity") {
						verified = true
					}
					bytes, err := os.ReadFile(filepath.Join(root, "output"))
					if err != nil {
						t.Fatal(err)
					}
					for _, line := range strings.Split(string(bytes), "\n") {
						key, value, ok := strings.Cut(line, "=")
						if ok {
							outputs[key] = value
						}
					}
					if id == "version" && (outputs["version"] != tc.version || outputs["tag"] != "v"+tc.version) {
						t.Fatal("version resolver changed release")
					}
					if id == "manifest" {
						manifestSHA = outputs["sha256"]
					}
					if id == "push" {
						artifact = outputs["artifact"]
						digest = outputs["digest"]
					}
				}
			}
			if uploadedManifest != tc.manifest || downloadedManifest != tc.manifest || !verified {
				t.Fatalf("upload=%v download=%v verify=%v", uploadedManifest, downloadedManifest, verified)
			}
			_, err = os.Stat(filepath.Join(root, "registry/update-manifest.json"))
			if (err == nil) != tc.manifest {
				t.Fatalf("wrong OCI manifest layer: %v", err)
			}
			latest, err := os.ReadFile(filepath.Join(root, "registry/latest"))
			if err != nil {
				t.Fatal(err)
			}
			wantLatest := "1.2.2"
			if tc.manifest && !tc.corrupt {
				wantLatest = tc.version
			}
			if strings.TrimSpace(string(latest)) != wantLatest {
				t.Fatalf("latest=%q want %s", latest, wantLatest)
			}
			signed, err := os.ReadFile(filepath.Join(root, "registry/signed"))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(signed), "@sha256:") {
				t.Fatal("artifact was not signed by digest")
			}
		})
	}
}

func TestCDChannelPublishersSerializeAcrossReleaseTags(t *testing.T) {
	doc := loadRepositoryWorkflow(t)
	job, err := doc.job("publish-ghcr")
	if err != nil {
		t.Fatal(err)
	}
	concurrency, ok := job["concurrency"].(map[string]any)
	if !ok || concurrency["group"] != "world-at-ruin-client-channel" || concurrency["cancel-in-progress"] != false || concurrency["queue"] != "max" {
		t.Fatalf("channel publishers must queue across tags without cancelling verification: %#v", job["concurrency"])
	}
	// A tag or run-specific lock admits two writers; this literal one excludes
	// both, including a resumed older publisher after a newer release finishes.
	group := concurrency["group"].(string)
	if strings.Contains(group, "${{") {
		t.Fatal("channel lock depends on the release event")
	}
	steps, ok := job["steps"].([]any)
	if !ok {
		t.Fatal("missing steps")
	}
	verified, completed, promoted := -1, -1, -1
	for i, raw := range steps {
		step := raw.(map[string]any)
		name, _ := step["name"].(string)
		if strings.Contains(name, "Verify signature and byte-identity") {
			verified = i
		}
		if strings.Contains(name, "Attest completed release verification") {
			completed = i
		}
		if strings.Contains(name, "Advance the verified latest digest") {
			promoted = i
		}
	}
	if verified < 0 || completed <= verified || promoted <= completed {
		t.Fatalf("verification/completion/promotion order %d/%d/%d", verified, completed, promoted)
	}
}

func TestCDRunsStampedDevLogScenesBeforeExport(t *testing.T) {
	doc := loadRepositoryWorkflow(t)
	job, err := doc.job("publish-macos")
	if err != nil {
		t.Fatal(err)
	}
	steps, ok := job["steps"].([]any)
	if !ok {
		t.Fatal("missing build steps")
	}
	stamp, imported, validation, exported := -1, -1, -1, -1
	root := t.TempDir()
	var run string
	var environment map[string]any
	for index, raw := range steps {
		step, ok := raw.(map[string]any)
		if !ok {
			t.Fatal("bad build step")
		}
		name, _ := step["name"].(string)
		body, _ := step["run"].(string)
		if strings.Contains(name, "Stamp dev-log entries") {
			stamp = index
		}
		if strings.Contains(name, "Headless import") {
			imported = index
		}
		if strings.Contains(name, "Validate the stamped development log") {
			validation, run = index, body
			environment, _ = step["env"].(map[string]any)
		}
		if strings.Contains(name, "Export .app") {
			exported = index
		}
	}
	if stamp < 0 || imported <= stamp || validation <= imported || exported <= validation {
		t.Fatalf("stamp/import/validate/export order = %d/%d/%d/%d", stamp, imported, validation, exported)
	}
	if err := os.Mkdir(filepath.Join(root, "tools"), 0o700); err != nil {
		t.Fatal(err)
	}
	// The workflow owns selecting the two runtime scenes; their actual client
	// behavior is separately exercised on a fully stamped release tree.
	probe := "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s:%s\\n' \"$1\" \"${WAR_DEVLOG_RELEASE_TREE:-missing}\" >> invocations\n"
	if err := os.WriteFile(filepath.Join(root, "tools/run-client-test.sh"), []byte(probe), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", run)
	cmd.Dir = root
	cmd.Env = os.Environ()
	for key, value := range environment {
		literal, ok := value.(string)
		if !ok || strings.Contains(literal, "${{") {
			t.Fatalf("unsupported validation environment %s", key)
		}
		cmd.Env = append(cmd.Env, key+"="+literal)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("stamped validation: %v\n%s", err, out)
	}
	got, err := os.ReadFile(filepath.Join(root, "invocations"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "devlog_storage_test:1\ndevlog_entries_test:1\n" {
		t.Fatalf("executed scenes=%q", got)
	}
}

const publicationBoundaryDouble = `
git() { printf "%s\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
date() {
  if [ "$*" = '-u +%s' ]; then printf '1790953136\n'; else printf '2026-10-03T00:00:00Z\n'; fi
}
godot() { printf '{"fixture":"emitted contract"}\n' > "$WAR_MANIFEST_OUT"; echo 'MANIFEST OK'; }
cosign() {
  if [ "$1" = attest ]; then cp release-completion.json "$FIXTURE_ROOT/registry/completion.json"; fi
  if [ "$1" = verify-attestation ]; then
    local statement
    statement=$(jq -n --arg artifact "$ARTIFACT" --arg digest "$DIGEST" --slurpfile predicate "$FIXTURE_ROOT/registry/completion.json" '{predicateType:"https://devantler.tech/world-at-ruin/release-completion/v1",subject:[{name:$artifact,digest:{sha256:($digest|ltrimstr("sha256:"))}}],predicate:$predicate[0]}')
    jq -n --arg payload "$(printf '%s' "$statement" | base64 | tr -d '\n')" '{payload:$payload}'
  fi
  if [ "$1" = sign ]; then printf '%s\n' "$3" > "$FIXTURE_ROOT/registry/signed"; fi
}
oras() {
  local registry="$FIXTURE_ROOT/registry"
  case "$1 $2" in
    'repo tags') cat "$registry/tags" ;;
    'manifest fetch')
      if [ "$3" = --descriptor ]; then
        if [[ "$4" == *:latest ]] && [ "$(cat "$registry/latest")" != "$(cat "$registry/pushed-version")" ]; then
          printf '{"digest":"sha256:%064d"}\n' 2
        else printf '{"digest":"sha256:%064d"}\n' 1; fi
      elif [[ "$3" == *@sha256:*2 ]]; then
        printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "$(cat "$registry/latest")"
      elif [[ "$3" == *@sha256:* ]]; then
        jq -n --arg version "$(cat "$registry/pushed-version")" --arg revision "$(cat "$registry/pushed-revision")" --arg archive "$(sha256sum "$registry"/*.zip | cut -d' ' -f1)" --arg manifest "$(sha256sum "$registry/update-manifest.json" | cut -d' ' -f1)" '{annotations:{"org.opencontainers.image.version":$version,"org.opencontainers.image.revision":$revision},layers:[{mediaType:"application/zip",digest:("sha256:"+$archive),annotations:{"org.opencontainers.image.title":("WorldAtRuin-"+$version+"-macOS-universal.zip")}},{mediaType:"application/vnd.devantler.worldatruin.client.manifest.v1+json",digest:("sha256:"+$manifest),annotations:{"org.opencontainers.image.title":"update-manifest.json"}}]}'
      else
        printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "$(cat "$registry/latest")"
      fi ;;
    *)
      case "$1" in
        push)
          local reference="$2" layer
          printf '%s\n' "${reference##*:}" >> "$registry/tags"
          printf '%s\n' "${reference##*:}" > "$registry/pushed-version"
          shift 2
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --artifact-type) shift 2 ;;
              --annotation)
                if [[ "$2" == org.opencontainers.image.revision=* ]]; then printf '%s\n' "${2#*=}" > "$registry/pushed-revision"; fi
                shift 2 ;;

              *) layer="${1%%:*}"; cp "$layer" "$registry/$(basename "$layer")"; shift ;;
            esac
          done ;;
        tag)
          if [[ "$3" == completed-* ]]; then printf '%s\n' "$3" >> "$registry/tags";
          else cat "$registry/pushed-version" > "$registry/latest"; fi ;;
        pull)
          cp "$registry"/*.zip .
          if [ -f "$registry/update-manifest.json" ]; then
            cp "$registry/update-manifest.json" .
            if [ "$CORRUPT" = true ]; then printf 'corrupted' > update-manifest.json; fi
          fi ;;
        *) echo "unexpected ORAS command: $*" >&2; return 2 ;;
      esac ;;
  esac
}
`

// A dispatch can execute on main while building a different, fully qualified tag.
func TestCDRevisionIdentifiesTheCheckedOutTagInsteadOfDispatchHead(t *testing.T) {
	doc := loadRepositoryWorkflow(t)
	job, err := doc.job("publish-macos")
	if err != nil {
		t.Fatal(err)
	}
	var resolver string
	for _, raw := range job["steps"].([]any) {
		step := raw.(map[string]any)
		if step["id"] == "version" {
			resolver = step["run"].(string)
		}
	}
	if resolver == "" {
		t.Fatal("missing build version resolver")
	}
	root := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	git("init", "--initial-branch=main")
	git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "tagged build")
	revision := git("rev-parse", "HEAD")
	git("tag", "v1.2.3")
	git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "later dispatch head")
	dispatch := git("rev-parse", "HEAD")
	git("checkout", "refs/tags/v1.2.3")
	output := filepath.Join(root, "output")
	run := func() ([]byte, error) {
		t.Helper()
		if err := os.WriteFile(output, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("bash", "-c", resolver)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "RAW_TAG=v1.2.3", "GITHUB_SHA="+dispatch, "GITHUB_OUTPUT="+output)
		log, err := cmd.CombinedOutput()
		if err != nil {
			return log, err
		}
		contents, readErr := os.ReadFile(output)
		if readErr != nil {
			t.Fatal(readErr)
		}
		return contents, nil
	}
	contents, err := run()
	if err != nil {
		t.Fatalf("tagged build: %v: %s", err, contents)
	}
	if !strings.Contains(string(contents), "revision="+revision+"\n") || strings.Contains(string(contents), "revision="+dispatch) {
		t.Fatalf("build did not identify tagged revision %s instead of dispatch %s: %s", revision, dispatch, contents)
	}
	git("checkout", "main")
	if log, err := run(); err == nil {
		t.Fatalf("untagged checkout accepted: %s", log)
	}
	outputs := job["outputs"].(map[string]any)
	if outputs["revision"] != "${{ steps.version.outputs.revision }}" {
		t.Fatal("build revision not transferred to publisher")
	}
}
