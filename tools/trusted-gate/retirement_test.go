package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func recordingInspectorClient(t *testing.T) (*Client, *atomic.Int32) {
	t.Helper()
	calls := new(atomic.Int32)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		fmt.Fprint(w, `{}`)
	}))
	t.Cleanup(server.Close)
	return &Client{BaseURL: server.URL, Token: "read-fixture", HTTP: server.Client()}, calls
}

func TestRetiredCommandsNeverContactAPIOrWriteOutput(t *testing.T) {
	for _, command := range []string{"resolve", "publish"} {
		for _, activation := range []string{"", "false", "true", "TRUE", "1"} {
			t.Run(command+"/"+strconv.Quote(activation), func(t *testing.T) {
				client, calls := recordingInspectorClient(t)
				env := map[string]string{
					"WAR_REPOSITORY_TRUSTED_GATE_ENABLED": activation,
					"TRUSTED_GATE_APP_ID":                 "123456",
					"GITHUB_REPOSITORY":                   "devantler-tech/world-at-ruin",
					"GITHUB_WORKFLOW_REF":                 "devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main",
					"GITHUB_WORKFLOW_SHA":                 strings.Repeat("a", 40),
					"GITHUB_EVENT_NAME":                   "workflow_run",
					"GITHUB_TOKEN":                        "retired-fixture",
				}
				output := filepath.Join(t.TempDir(), "github-output")
				args := []string{"resolve", "--run-id", "73", "--output", output}
				if command == "publish" {
					identity := fmt.Sprintf(`{"kind":"pull_request","pr_number":7,"run_id":73,"head":%q,"base":%q,"candidate":%q,"ref":"refs/pull/7/merge"}`, strings.Repeat("1", 40), strings.Repeat("2", 40), strings.Repeat("3", 40))
					args = []string{"publish", "--identity", identity, "--verdict", "success"}
				}
				var out bytes.Buffer
				if err := execute(args, env, client, &out); err == nil || calls.Load() != 0 || out.Len() != 0 {
					t.Fatalf("retired command reached a side effect: err=%v calls=%d output=%q", err, calls.Load(), out.String())
				}
				if _, err := os.Lstat(output); !os.IsNotExist(err) {
					t.Fatalf("retired command created output or inspection failed: %v", err)
				}
			})
		}
	}
}

func TestRetiredProducerSourcesAreAbsent(t *testing.T) {
	for _, name := range []string{
		".github/workflows/repository-trusted-regressions.yaml",
		"tools/repository-trusted-gate-admission.sh", "tools/repository-trusted-gate-admission.test.sh",
		"tools/repository-trusted-gate-workflow-guard.sh", "tools/repository-trusted-gate-workflow-guard.test.sh",
		"tools/trusted-gate/resolver.go", "tools/trusted-gate/resolver_test.go",
		"tools/trusted-gate/publisher.go", "tools/trusted-gate/publisher_test.go",
	} {
		if _, err := os.Lstat(filepath.Join("../..", name)); !os.IsNotExist(err) {
			t.Errorf("retired producer source remains or inspection failed: %s: %v", name, err)
		}
	}
}

func TestInspectorTransportRefusesWritesBeforeNetwork(t *testing.T) {
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodGet} {
		t.Run(method, func(t *testing.T) {
			client, calls := recordingInspectorClient(t)
			var payload any
			if method == http.MethodGet {
				payload = map[string]string{"state": "success"}
			}
			if err := client.DoJSON(context.Background(), method, gateAPIPath, payload, nil); err == nil || calls.Load() != 0 {
				t.Fatalf("inspector admitted mutation/body: err=%v requests=%d", err, calls.Load())
			}
		})
	}
}
