package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	canonicalArtifact                = "client-macos-universal"
	expectedAttachReleaseSHA256      = "190e86bef7d107b2da75ca9c1603f671d271b1ef4ddf9390294174dfce7bde6b"
	expectedPublishReleaseSHA256     = "dc6e02a9fa8ca3bef86ab903bf4839b78d56e3c363a0a852d1cfa2930d5802d2"
	attachReleaseJob                 = "attach-release"
	publishReleaseJob                = "publish-release"
	publishMacOSJob                  = "publish-macos"
	publishGHCRJob                   = "publish-ghcr"
	requiredChecksJob                = "cd-required-checks"
	releaseUploadAssetBinding        = `ASSET="build/WorldAtRuin-${TAG#v}-macOS-universal.zip"`
	attachReleaseAggregateExpression = "${{ needs.attach-release.result }}"
)

var secretReference = regexp.MustCompile(`(^|[^[:alnum:]_])secrets([^[:alnum:]_]|$)`)

type workflow struct {
	root map[string]any
	jobs map[string]any
}

func main() {
	if len(os.Args) != 2 {
		fail("usage: release-credential-boundary WORKFLOW")
	}

	document, err := loadWorkflow(os.Args[1])
	if err != nil {
		fail(err.Error())
	}
	if err := document.validate(); err != nil {
		fail(err.Error())
	}

	fmt.Println("release-credential-boundary: PASS")
}

func fail(message string) {
	fmt.Fprintf(os.Stderr, "release-credential-boundary: %s\n", message)
	os.Exit(1)
}

func loadWorkflow(path string) (*workflow, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("workflow not found: %s: %w", path, err)
	}
	defer file.Close()

	decoder := yaml.NewDecoder(file)
	root := make(map[string]any)
	if err := decoder.Decode(&root); err != nil {
		return nil, fmt.Errorf("workflow must be valid YAML: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, fmt.Errorf("workflow must be valid YAML: %w", err)
		}
		return nil, errors.New("workflow must contain exactly one YAML document")
	}

	jobs, err := stringMap(root["jobs"], "jobs")
	if err != nil {
		return nil, err
	}
	if len(jobs) == 0 {
		return nil, errors.New("jobs must contain at least one job")
	}

	return &workflow{root: root, jobs: jobs}, nil
}

func (workflow *workflow) validate() error {
	if _, exists := workflow.root["defaults"]; exists {
		return errors.New("workflow-level defaults are forbidden because privileged run steps must use their audited shell")
	}
	if !reflect.DeepEqual(workflow.root["permissions"], map[string]any{"contents": "read"}) {
		return errors.New("workflow permissions must set only contents: read")
	}
	if containsSecretReference(workflow.root["env"]) {
		return errors.New("workflow-level env must not expose secrets to publish-macos")
	}

	for jobName, rawJob := range workflow.jobs {
		job, err := stringMap(rawJob, jobName)
		if err != nil {
			return err
		}
		contents, err := effectiveContentsPermission(job, workflow.root["permissions"])
		if err != nil {
			return fmt.Errorf("%s has an unsupported or ambiguous permissions declaration: %w", jobName, err)
		}
		if (contents == "write" || contents == "write-all") && jobName != attachReleaseJob && jobName != publishReleaseJob {
			return fmt.Errorf("%s must not receive release-write repository contents permission", jobName)
		}
	}

	publishMacOS, err := workflow.job(publishMacOSJob)
	if err != nil {
		return err
	}
	if !hasExactPermissions(publishMacOS, "contents", "read") {
		return errors.New("publish-macos must set only contents: read")
	}
	if containsSecretReference(publishMacOS) {
		return errors.New("publish-macos must not consume repository secrets")
	}
	if jobRunText(publishMacOS, "gh release upload") {
		return errors.New("publish-macos must not attach the release asset")
	}
	if !hasArtifactAction(publishMacOS, "actions/upload-artifact@", canonicalArtifact, "") {
		return errors.New("publish-macos must upload the canonical client workflow artifact")
	}

	attachRelease, err := workflow.job(attachReleaseJob)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(attachRelease["needs"], []any{publishMacOSJob}) {
		return errors.New("attach-release must wait only for publish-macos")
	}
	if attachRelease["timeout-minutes"] != 15 {
		return errors.New("attach-release timeout must cover the fail-closed retry budget")
	}
	if !hasExactPermissions(attachRelease, "contents", "write") {
		return errors.New("attach-release must set only contents: write")
	}
	if !hasArtifactAction(attachRelease, "actions/download-artifact@", canonicalArtifact, "build") {
		return errors.New("attach-release must download the canonical client artifact into build")
	}
	if !jobRunText(attachRelease, "gh release upload") {
		return errors.New("attach-release must own the release upload")
	}
	if !jobRunText(attachRelease, releaseUploadAssetBinding) {
		return errors.New("attach-release must bind the handed-off zip to the canonical asset path")
	}
	if executesRepositoryCode(attachRelease) {
		return errors.New("attach-release must never check out or execute repository-controlled code")
	}

	publishGHCR, err := workflow.job(publishGHCRJob)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(publishGHCR["needs"], []any{publishMacOSJob, attachReleaseJob}) {
		return errors.New("publish-ghcr must wait for successful release attachment")
	}

	publishRelease, err := workflow.job(publishReleaseJob)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(publishRelease["needs"], []any{attachReleaseJob, publishGHCRJob}) {
		return errors.New("publish-release must wait for both asset publication jobs")
	}
	if !hasExactPermissions(publishRelease, "contents", "write") {
		return errors.New("publish-release must set only contents: write")
	}
	if executesRepositoryCode(publishRelease) {
		return errors.New("publish-release must never check out or execute repository-controlled code")
	}

	requiredChecks, err := workflow.job(requiredChecksJob)
	if err != nil {
		return err
	}
	if !stringSliceContains(requiredChecks["needs"], attachReleaseJob) {
		return errors.New("CD required checks must include attach-release")
	}
	if !containsString(requiredChecks, attachReleaseAggregateExpression) {
		return errors.New("CD aggregate must include attach-release's result")
	}

	if err := requireJobDigest(attachReleaseJob, attachRelease, expectedAttachReleaseSHA256); err != nil {
		return err
	}
	return requireJobDigest(publishReleaseJob, publishRelease, expectedPublishReleaseSHA256)
}

func (workflow *workflow) job(name string) (map[string]any, error) {
	rawJob, exists := workflow.jobs[name]
	if !exists {
		return nil, fmt.Errorf("%s job is missing", name)
	}
	return stringMap(rawJob, name)
}

func stringMap(value any, label string) (map[string]any, error) {
	mapping, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be a mapping", label)
	}
	return mapping, nil
}

func effectiveContentsPermission(job map[string]any, inherited any) (string, error) {
	permissions, exists := job["permissions"]
	if !exists {
		permissions = inherited
	}

	switch declaration := permissions.(type) {
	case string:
		if declaration == "read-all" || declaration == "write-all" {
			return declaration, nil
		}
		return "", fmt.Errorf("unsupported scalar %q", declaration)
	case map[string]any:
		contents, exists := declaration["contents"]
		if !exists {
			return "none", nil
		}
		value, ok := contents.(string)
		if !ok || (value != "read" && value != "write" && value != "none") {
			return "", fmt.Errorf("unsupported contents value %v", contents)
		}
		return value, nil
	default:
		return "", fmt.Errorf("unsupported type %T", permissions)
	}
}

func hasExactPermissions(job map[string]any, key, value string) bool {
	return reflect.DeepEqual(job["permissions"], map[string]any{key: value})
}

func containsSecretReference(value any) bool {
	switch typed := value.(type) {
	case string:
		return secretReference.MatchString(typed)
	case []any:
		for _, item := range typed {
			if containsSecretReference(item) {
				return true
			}
		}
	case map[string]any:
		for key, item := range typed {
			if containsSecretReference(key) || containsSecretReference(item) {
				return true
			}
		}
	}
	return false
}

func steps(job map[string]any) []any {
	items, _ := job["steps"].([]any)
	return items
}

func hasArtifactAction(job map[string]any, actionPrefix, artifactName, path string) bool {
	for _, rawStep := range steps(job) {
		step, ok := rawStep.(map[string]any)
		if !ok {
			continue
		}
		uses, _ := step["uses"].(string)
		if !strings.HasPrefix(uses, actionPrefix) {
			continue
		}
		with, ok := step["with"].(map[string]any)
		if !ok || with["name"] != artifactName {
			continue
		}
		if path == "" || with["path"] == path {
			return true
		}
	}
	return false
}

func executesRepositoryCode(job map[string]any) bool {
	for _, rawStep := range steps(job) {
		step, ok := rawStep.(map[string]any)
		if !ok {
			continue
		}
		uses, _ := step["uses"].(string)
		if strings.HasPrefix(uses, "actions/checkout@") || strings.HasPrefix(uses, "./") {
			return true
		}
	}
	return false
}

func jobRunText(job map[string]any, wanted string) bool {
	for _, rawStep := range steps(job) {
		step, ok := rawStep.(map[string]any)
		if !ok {
			continue
		}
		run, _ := step["run"].(string)
		if strings.Contains(run, wanted) {
			return true
		}
	}
	return false
}

func stringSliceContains(value any, wanted string) bool {
	items, ok := value.([]any)
	if !ok {
		return false
	}
	for _, item := range items {
		if item == wanted {
			return true
		}
	}
	return false
}

func containsString(value any, wanted string) bool {
	switch typed := value.(type) {
	case string:
		return strings.Contains(typed, wanted)
	case []any:
		for _, item := range typed {
			if containsString(item, wanted) {
				return true
			}
		}
	case map[string]any:
		for key, item := range typed {
			if strings.Contains(key, wanted) || containsString(item, wanted) {
				return true
			}
		}
	}
	return false
}

func requireJobDigest(name string, job map[string]any, expected string) error {
	canonical, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("canonicalize %s: %w", name, err)
	}
	digest := sha256.Sum256(canonical)
	actual := hex.EncodeToString(digest[:])
	if actual != expected {
		return fmt.Errorf("%s structure changed; audit the complete privileged job and update its checksum deliberately (got %s)", name, actual)
	}
	return nil
}
